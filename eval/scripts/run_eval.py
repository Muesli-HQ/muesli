#!/usr/bin/env python3
"""Run Muesli STT backends over the fetched eval sets and report WER.

Drives `muesli-cli transcribe` (the CLI bundled inside Muesli.app) per clip,
normalizes hypothesis and reference the same way, and reports corpus-level
WER with substitution/deletion/insertion breakdown per (set, model).

Usage:
  python eval/scripts/run_eval.py                        # all sets, parakeet-v3
  python eval/scripts/run_eval.py --models parakeet-v3 parakeet-v2
  python eval/scripts/run_eval.py --cli /path/to/muesli-cli

Outputs per-run JSONL to eval/results/ and prints a summary table.
"""

import argparse
import json
import re
import subprocess
import time
from pathlib import Path

import jiwer

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
RESULTS = ROOT / "results"
DEFAULT_CLI = "/Applications/Muesli.app/Contents/MacOS/muesli-cli"

# Whisper-style basic normalization: lowercase, strip punctuation except
# in-word apostrophes, collapse whitespace. Number formats are NOT unified;
# both sides pass through the same pipeline so scoring stays comparable.
_PUNCT = re.compile(r"[^\w\s']", flags=re.UNICODE)
_APOS = re.compile(r"(?<!\w)'|'(?!\w)")
_WS = re.compile(r"\s+")


def normalize(text: str) -> str:
    text = text.lower()
    text = _PUNCT.sub(" ", text)
    text = _APOS.sub(" ", text)
    return _WS.sub(" ", text).strip()


def transcribe(cli: str, wav: Path, model: str) -> tuple[str, float, float]:
    start = time.monotonic()
    proc = subprocess.run(
        [cli, "transcribe", str(wav), "--model", model, "--format", "json"],
        capture_output=True, text=True, timeout=600,
    )
    wall = time.monotonic() - start
    if proc.returncode != 0:
        raise RuntimeError(f"muesli-cli failed on {wav.name}: {proc.stderr.strip()[:300]}")
    # CoreML sometimes appends runtime noise (e.g. E5RT exceptions) after the
    # JSON envelope on stdout; decode just the first JSON object.
    stdout = proc.stdout
    obj, _ = json.JSONDecoder().raw_decode(stdout[stdout.index("{"):])
    payload = obj["data"]
    return payload["transcript"], payload.get("durationSeconds", 0.0), wall


def run(cli: str, set_name: str, model: str) -> dict:
    manifest = DATA / set_name / "refs.jsonl"
    refs_raw = [json.loads(line) for line in open(manifest)]
    RESULTS.mkdir(exist_ok=True)
    out_path = RESULTS / f"{set_name}--{model}.jsonl"

    refs, hyps, rows = [], [], []
    audio_secs = wall_secs = 0.0
    failures = 0
    for entry in refs_raw:
        wav = ROOT / entry["wav"]
        failed = False
        try:
            hyp, _, wall = transcribe(cli, wav, model)
        except RuntimeError as e:
            # A real transcription failure (e.g. Nemotron's CoreML pipeline throwing on
            # clips shorter than its chunk size) is itself a finding, not a harness bug.
            # Score it as an empty hypothesis (maximally penalized) rather than aborting
            # the whole sweep or silently skipping the clip.
            failed = True
            failures += 1
            hyp, wall = "", 0.0
            print(f"  {entry['id']}  FAILED: {str(e)[:200]}")
        ref_n, hyp_n = normalize(entry["text"]), normalize(hyp)
        refs.append(ref_n)
        hyps.append(hyp_n)
        audio_secs += entry["duration"]
        wall_secs += wall
        clip_wer = jiwer.wer(ref_n, hyp_n) if ref_n else 0.0
        rows.append({"id": entry["id"], "ref": ref_n, "hyp": hyp_n,
                     "wer": round(clip_wer, 4), "wall": round(wall, 2), "failed": failed})
        if not failed:
            print(f"  {entry['id']}  wer={clip_wer:6.1%}  wall={wall:5.1f}s")

    measures = jiwer.process_words(refs, hyps)
    summary = {
        "set": set_name, "model": model, "clips": len(rows),
        "audio_seconds": round(audio_secs, 1),
        "wer": round(measures.wer, 4),
        "substitutions": measures.substitutions,
        "deletions": measures.deletions,
        "insertions": measures.insertions,
        "hits": measures.hits,
        "wall_seconds": round(wall_secs, 1),
        "failures": failures,
    }
    with open(out_path, "w") as f:
        for row in rows:
            f.write(json.dumps(row) + "\n")
        f.write(json.dumps({"summary": summary}) + "\n")
    return summary


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cli", default=DEFAULT_CLI)
    ap.add_argument("--models", nargs="+", default=["parakeet-v3"])
    ap.add_argument("--sets", nargs="+",
                    default=[p.name for p in sorted(DATA.iterdir()) if (p / "refs.jsonl").exists()])
    args = ap.parse_args()

    summaries = []
    for model in args.models:
        for set_name in args.sets:
            print(f"== {set_name} / {model} ==")
            summaries.append(run(args.cli, set_name, model))

    print(f"\n{'set':<20} {'model':<14} {'clips':>5} {'audio':>7} {'WER':>7}  {'sub/del/ins':>13}  {'failed':>6}")
    for s in summaries:
        print(f"{s['set']:<20} {s['model']:<14} {s['clips']:>5} {s['audio_seconds']:>6.0f}s "
              f"{s['wer']:>7.1%}  {s['substitutions']:>4}/{s['deletions']}/{s['insertions']}  {s['failures']:>6}")


if __name__ == "__main__":
    main()
