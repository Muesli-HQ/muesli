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
./.venv/bin/python scripts/run_eval.py --models parakeet-v3 parakeet-v2 parakeet-eou-320ms
```

`parakeet-eou-320ms` drives the same streaming encoder used for live meeting
captions (`StreamingEouAsrManager`, 320ms chunks) instead of the batch
Parakeet path — see "Models" below. `run_eval.py` needs no changes to support
it; `--model` is forwarded to the CLI as-is.

Per-clip hypotheses and a corpus summary land in `eval/results/<set>--<model>.jsonl`;
a summary table prints at the end.

## Scoring

Reference and hypothesis go through identical normalization before WER:
lowercase, punctuation stripped (in-word apostrophes kept), whitespace
collapsed. Number formats are **not** unified ("25" vs "twenty five" counts
as errors) — this penalizes all models equally but inflates absolute WER vs
leaderboard figures that use the Whisper English normalizer. Compare numbers
within this harness, not across papers.

## Models

| `--model` | Path measured | Notes |
|---|---|---|
| `parakeet-v3` | Batch, final transcript | Default; what "Transcribe" produces in the app and CLI. |
| `parakeet-v2` | Batch, final transcript | |
| `parakeet-eou-320ms` | Streaming | The live meeting-caption engine (`StreamingEouAsrManager`, 320ms chunks). Feeds the WAV in chunks to simulate real-time playback; final transcript is `finish()`'s accumulated text. Auto-downloads (~430 MB) to the same cache the app's live-captions setting uses, so this doesn't duplicate a download if you've already enabled live captions. |

Streaming models support `--emit-partials <path>`, which writes one JSON
object per line as transcription progresses:

```json
{"t": 1.89, "text": "comin"}
{"t": 2.52, "text": "comincord ret"}
{"t": 3.78, "text": "comincord returned to its place amidst the tents"}
```

`t` is the simulated audio position (seconds fed so far), not wall-clock CLI
runtime — streaming inference here runs much faster than real time, so
wall-clock wouldn't reflect what a live listener actually experiences. This
is the raw material for a future partial-to-final flicker / caption-lag
metric (not computed by `run_eval.py` yet).

Nemotron 3.5 (the multilingual live-caption fallback) and the Whisper/Qwen3/
SenseVoice backends still aren't CLI-reachable — their adapters live in the
app's executable target, which the CLI can't link as a library. Exposing
them needs those adapters promoted into a shared library target first; out
of scope here.

## Known gaps (v1)

- One parquet shard per set — samples the head of each corpus, not a random
  draw. Fine for tracking deltas; don't quote as official corpus WER.
- No AMI (true far-field meeting) set yet; Earnings-22 is the stand-in.
- WER only — no partial-to-final flicker metric computed yet (see `--emit-partials`
  above), no latency percentiles beyond wall-clock per clip.
