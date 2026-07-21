#!/usr/bin/env python3
"""Measure WER impact of Muesli's custom dictionary correction, using the
actual shipped implementation (`CustomWordMatcher.apply`, via muesli-cli
`--dictionary`) rather than reimplementing fuzzy matching in Python.

This answers "if the dictionary were enabled, how would WER look?" as an
ORACLE upper bound: for each clip, we build a per-clip dictionary containing
exactly the word-level substitution errors the model actually made on that
clip (hyp -> ref), then re-transcribe with `--dictionary` and rescore.

This is NOT a simulation of Muesli auto-detecting which words to add — that
is a separate, already-shipped feature (DictionaryCorrectionDetector) that
learns entries from the user's manual edits over time. This measures the
ceiling: if the right entries already existed in the dictionary, how much
of the WER gap does CustomWordMatcher's fuzzy correction actually recover?

Usage:
  python eval/scripts/dictionary_eval.py --set earnings22 --model parakeet-v3

Requires eval/results/<set>--<model>.jsonl to already exist (run run_eval.py
first) — reuses its ref/hyp pairs to build the oracle dictionary, then makes
a second real muesli-cli transcribe pass per clip with that dictionary applied.
"""

import argparse
import json
import subprocess
import tempfile
from pathlib import Path

import jiwer

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
RESULTS = ROOT / "results"
DEFAULT_CLI = "/Applications/Muesli.app/Contents/MacOS/muesli-cli"


def oracle_dictionary(ref: str, hyp: str) -> list[dict]:
    """Build {word: hyp_word, replacement: ref_word} for each substitution
    jiwer's alignment found between this clip's hypothesis and reference."""
    if not ref or not hyp:
        return []
    out = jiwer.process_words([ref], [hyp])
    ref_words = ref.split()
    hyp_words = hyp.split()
    entries, seen = [], set()
    for chunk in out.alignments[0]:
        if chunk.type != "substitute":
            continue
        hyp_span = " ".join(hyp_words[chunk.hyp_start_idx:chunk.hyp_end_idx])
        ref_span = " ".join(ref_words[chunk.ref_start_idx:chunk.ref_end_idx])
        key = (hyp_span, ref_span)
        if not hyp_span or not ref_span or hyp_span == ref_span or key in seen:
            continue
        seen.add(key)
        entries.append({"word": hyp_span, "replacement": ref_span, "matching_threshold": 0.85})
    return entries


def transcribe_with_dictionary(cli: str, wav: Path, model: str, entries: list[dict]) -> str:
    if not entries:
        return None  # no substitutions on this clip; dictionary can't help
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
        json.dump(entries, f)
        dict_path = f.name
    try:
        proc = subprocess.run(
            [cli, "transcribe", str(wav), "--model", model, "--format", "json", "--dictionary", dict_path],
            capture_output=True, text=True, timeout=600,
        )
        if proc.returncode != 0:
            raise RuntimeError(f"muesli-cli failed on {wav.name}: {proc.stderr.strip()[:300]}")
        stdout = proc.stdout
        obj, _ = json.JSONDecoder().raw_decode(stdout[stdout.index("{"):])
        return obj["data"]["transcript"]
    finally:
        Path(dict_path).unlink(missing_ok=True)


_PUNCT_NORMALIZE = __import__("re").compile(r"[^\w\s']", flags=__import__("re").UNICODE)
_WS_NORMALIZE = __import__("re").compile(r"\s+")


def normalize(text: str) -> str:
    text = text.lower()
    text = _PUNCT_NORMALIZE.sub(" ", text)
    return _WS_NORMALIZE.sub(" ", text).strip()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cli", default=DEFAULT_CLI)
    ap.add_argument("--set", required=True)
    ap.add_argument("--model", default="parakeet-v3")
    args = ap.parse_args()

    baseline_path = RESULTS / f"{args.set}--{args.model}.jsonl"
    if not baseline_path.exists():
        raise SystemExit(f"{baseline_path} not found — run run_eval.py --sets {args.set} --models {args.model} first")

    rows = [json.loads(line) for line in open(baseline_path) if "summary" not in json.loads(line)]
    out_path = RESULTS / f"{args.set}--{args.model}--with-dictionary.jsonl"

    refs, hyps_baseline, hyps_dict = [], [], []
    clips_with_entries = 0
    with open(out_path, "w") as out_f:
        for row in rows:
            manifest_entry = next(
                (json.loads(l) for l in open(DATA / args.set / "refs.jsonl") if json.loads(l)["id"] == row["id"]),
                None,
            )
            wav = ROOT / manifest_entry["wav"]
            entries = oracle_dictionary(row["ref"], row["hyp"])
            if entries:
                clips_with_entries += 1
            corrected = transcribe_with_dictionary(args.cli, wav, args.model, entries)
            corrected_n = normalize(corrected) if corrected is not None else row["hyp"]

            refs.append(row["ref"])
            hyps_baseline.append(row["hyp"])
            hyps_dict.append(corrected_n)
            out_f.write(json.dumps({
                "id": row["id"], "ref": row["ref"], "hyp_baseline": row["hyp"],
                "hyp_with_dictionary": corrected_n, "oracle_entries": entries,
            }) + "\n")
            tag = f"{len(entries)} entries" if entries else "no substitutions"
            print(f"  {row['id']}  {tag}")

        wer_baseline = jiwer.wer(refs, hyps_baseline)
        wer_dict = jiwer.wer(refs, hyps_dict)
        summary = {
            "set": args.set, "model": args.model, "clips": len(rows),
            "clips_with_dictionary_entries": clips_with_entries,
            "wer_baseline": round(wer_baseline, 4),
            "wer_with_oracle_dictionary": round(wer_dict, 4),
        }
        out_f.write(json.dumps({"summary": summary}) + "\n")

    print(f"\n{args.set} / {args.model}")
    print(f"  baseline WER:              {summary['wer_baseline']:.1%}")
    print(f"  WER with oracle dictionary: {summary['wer_with_oracle_dictionary']:.1%}")
    print(f"  clips where dictionary had a correction to apply: {clips_with_entries}/{len(rows)}")


if __name__ == "__main__":
    main()
