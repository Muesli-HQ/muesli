#!/usr/bin/env python3
"""Fetch small, fixed evaluation sets for the Muesli STT harness.

Pulls N samples per set from Hugging Face parquet conversions over plain
HTTPS (no `datasets` library, no torch) and writes 16 kHz mono PCM16 WAVs
plus a refs.jsonl manifest per set:

  eval/data/<set>/clips/<id>.wav
  eval/data/<set>/refs.jsonl   # {"id", "wav", "text", "duration"}

Sets:
  librispeech-clean  — clean read speech (openslr/librispeech_asr, clean/test)
  earnings22         — real-world earnings calls, accents + compressed audio
                       (distil-whisper/earnings22, chunked test split)
"""

import argparse
import io
import json
import sys
import urllib.request
from pathlib import Path

import numpy as np
import pyarrow.parquet as pq
import soundfile as sf

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"

SETS = {
    "librispeech-clean": {
        "dataset": "openslr/librispeech_asr",
        "config": "clean",
        "split": "test",
        "audio_col": "audio",
        "text_col": "text",
    },
    "earnings22": {
        "dataset": "distil-whisper/earnings22",
        "config": "chunked",
        "split": "test",
        "audio_col": "audio",
        "text_col": "transcription",
    },
}


def parquet_urls(dataset: str, config: str, split: str) -> list[str]:
    url = f"https://huggingface.co/api/datasets/{dataset}/parquet/{config}/{split}"
    with urllib.request.urlopen(url) as r:
        return json.load(r)


def to_mono_16k(data: np.ndarray, rate: int) -> np.ndarray:
    if data.ndim > 1:
        data = data.mean(axis=1)
    if rate != 16000:
        n_out = int(round(len(data) * 16000 / rate))
        x_old = np.linspace(0.0, 1.0, num=len(data), endpoint=False)
        x_new = np.linspace(0.0, 1.0, num=n_out, endpoint=False)
        data = np.interp(x_new, x_old, data)
    return data.astype(np.float32)


def fetch_set(name: str, count: int, force: bool) -> None:
    spec = SETS[name]
    out_dir = DATA / name
    clips = out_dir / "clips"
    manifest = out_dir / "refs.jsonl"
    if manifest.exists() and not force:
        print(f"[{name}] refs.jsonl exists, skipping (use --force to refetch)")
        return
    clips.mkdir(parents=True, exist_ok=True)

    urls = parquet_urls(spec["dataset"], spec["config"], spec["split"])
    print(f"[{name}] {len(urls)} parquet shard(s); reading rows from the first")
    shard = DATA / f"{name}.parquet"
    if not shard.exists() or force:
        print(f"[{name}] downloading {urls[0]}")
        urllib.request.urlretrieve(urls[0], shard)

    table = pq.read_table(shard, columns=[spec["audio_col"], spec["text_col"]])
    rows = table.to_pylist()
    written = 0
    with open(manifest, "w") as mf:
        for i, row in enumerate(rows):
            if written >= count:
                break
            audio = row[spec["audio_col"]]
            text = (row[spec["text_col"]] or "").strip()
            if not text or audio is None or audio.get("bytes") is None:
                continue
            try:
                data, rate = sf.read(io.BytesIO(audio["bytes"]))
            except Exception as e:  # unreadable codec in this row; skip it
                print(f"[{name}] row {i}: skip ({e})", file=sys.stderr)
                continue
            data = to_mono_16k(data, rate)
            duration = len(data) / 16000.0
            if duration < 2.0 or duration > 40.0:
                continue
            clip_id = f"{name}-{i:05d}"
            wav = clips / f"{clip_id}.wav"
            sf.write(wav, data, 16000, subtype="PCM_16")
            mf.write(json.dumps({
                "id": clip_id,
                "wav": str(wav.relative_to(ROOT)),
                "text": text,
                "duration": round(duration, 2),
            }) + "\n")
            written += 1
    print(f"[{name}] wrote {written} clips -> {manifest}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sets", nargs="+", default=list(SETS), choices=list(SETS))
    ap.add_argument("--count", type=int, default=40, help="clips per set")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    for name in args.sets:
        fetch_set(name, args.count, args.force)


if __name__ == "__main__":
    main()
