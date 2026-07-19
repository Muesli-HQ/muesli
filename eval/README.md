# Muesli STT evaluation harness

Measures word error rate (WER) of Muesli's speech-to-text backends on fixed,
public evaluation sets, so transcription quality is a tracked number instead
of a vibe. Runs entirely locally against the `muesli-cli` bundled in the
installed app — no app code changes required.

## Sets

| Set | Source | What it stresses |
|---|---|---|
| `librispeech-clean` | `openslr/librispeech_asr` (clean/test) | Clean read English — the "leaderboard" condition |
| `earnings22` | `distil-whisper/earnings22` (chunked test) | Real-world earnings calls — accents, compression, disfluencies; closest public proxy for meeting audio |

Both are fetched as parquet over HTTPS from Hugging Face (first shard,
first N usable clips of 2–40 s), decoded and resampled to 16 kHz mono
PCM16 WAV. Default N=40 per set keeps a full two-model run under ~20 min.

## Usage

```bash
cd eval
python3 -m venv .venv && ./.venv/bin/pip install numpy pyarrow soundfile jiwer
./.venv/bin/python scripts/fetch_data.py --count 40
./.venv/bin/python scripts/run_eval.py --models parakeet-v3 parakeet-v2
```

Per-clip hypotheses and a corpus summary land in `eval/results/<set>--<model>.jsonl`;
a summary table prints at the end.

## Scoring

Reference and hypothesis go through identical normalization before WER:
lowercase, punctuation stripped (in-word apostrophes kept), whitespace
collapsed. Number formats are **not** unified ("25" vs "twenty five" counts
as errors) — this penalizes all models equally but inflates absolute WER vs
leaderboard figures that use the Whisper English normalizer. Compare numbers
within this harness, not across papers.

## Known gaps (v1)

- **Only `parakeet-v3` / `parakeet-v2`** — the models `muesli-cli transcribe`
  exposes. The live-caption engines (Parakeet EOU streaming, Nemotron 3.5)
  and Whisper/Qwen3 backends are not CLI-reachable yet; extending the CLI's
  `--model` set is the prerequisite for measuring the live-transcript path.
- One parquet shard per set — samples the head of each corpus, not a random
  draw. Fine for tracking deltas; don't quote as official corpus WER.
- No AMI (true far-field meeting) set yet; Earnings-22 is the stand-in.
- WER only — no partial-to-final flicker metric for streaming, no latency
  percentiles beyond wall-clock per clip.
