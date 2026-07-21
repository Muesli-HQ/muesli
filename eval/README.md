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
| `sensevoice` | Batch, final transcript | FluidAudio's `SenseVoiceManager` (int8 encoder), same as the app's SenseVoice backend. Auto-downloads ~240 MB. |
| `qwen3-asr` | Batch, final transcript | FluidAudio's `Qwen3AsrManager` (int8 variant), same as the app's Qwen3 ASR backend. Auto-downloads ~900 MB; macOS 15+ required (CoreML stateful decoder), same constraint the app has. Autoregressive — noticeably slower per clip than the other models. |
| `nemotron35` | Batch, final transcript | `MuesliASRKit`'s `Nemotron35StreamingTranscriber.transcribe(wavURL:)` — the same call the app's `transcribeWithNemotron35` makes; internally chunks the WAV through the streaming RNNT pipeline at 2240ms per chunk. Multilingual (100+ locales via `prompt_id`, defaults to auto-detect). Auto-downloads ~665 MB; macOS 15+ required. **Fails outright (CoreML "zero shape" exception) on clips shorter than its 2240ms chunk size** — `run_eval.py` scores these as empty hypotheses rather than aborting the sweep; see Known gaps. |

Comparative WER, 40 clips/set, all 5 models this harness can currently reach:

```
set                  model          WER    failed
earnings22           parakeet-v2   13.3%       0
earnings22           parakeet-v3   13.7%       0
earnings22           sensevoice    17.0%       0
earnings22           qwen3-asr     20.0%       0
earnings22           nemotron35    34.6%       1
librispeech-clean    parakeet-v2    1.9%       0
librispeech-clean    parakeet-v3    2.3%       0
librispeech-clean    qwen3-asr      3.2%       0
librispeech-clean    sensevoice     3.9%       0
librispeech-clean    nemotron35     5.5%       0
```

parakeet-v3/v2 remain strongest on both clean and real-world audio in this sample.
Nemotron 3.5's much higher WER (and heavy deletion count on Earnings-22 — words
dropped, not substituted) is consistent with its design: it's a streaming,
multilingual-coverage model with greedy per-chunk decoding and no cross-chunk
correction, not tuned for single-pass English batch accuracy. Its real value is
multilingual coverage and low-latency streaming, neither of which this
English-only, batch-mode measurement credits — a fair multilingual comparison
needs a non-English set (not built yet).

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

SenseVoice and Qwen3 ASR were cheap to add: FluidAudio (already a MuesliCLI
dependency) ships public `SenseVoiceManager`/`Qwen3AsrManager` types directly,
so the CLI transcribers call them the same way the app's thin wrapper
backends do — no new package dependency, no shared-library refactor.

**Nemotron 3.5 required the refactor, and it's now done.** Its RNNT engine
(`NemotronRNNTEngine.swift`, `Nemotron35StreamingBackend.swift` — preprocessor/
encoder/decoder/joint CoreML calls, cache management, HuggingFace download)
was pure Swift + CoreML + Accelerate with zero app-only dependencies, so it
moved wholesale into a new shared library target, `MuesliASRKit`, that both
`MuesliNativeApp` and `MuesliCLI` depend on — the same pattern `MuesliCore`
already established for SQLite/paths, applied to ASR backend code for the
first time. Two small supporting pieces moved into `MuesliCore` alongside it:
`InferenceGate` (serializes concurrent CoreML calls; also used by the
unrelated Qwen3 post-processor) and `downloadWithRetry`/`DownloadError`
(shared by several other backends). The app's own Nemotron 3.5 dictation and
meeting-caption code is unchanged behaviorally — it now just calls the same
types from `MuesliASRKit` instead of defining them locally.

Cohere Transcribe and Indic ASR are still NOT CLI-reachable. Despite "Cohere
Transcribe"'s name, neither is a cloud call — both are large (1,100+ line),
fully custom CoreML pipelines (hand-rolled mel spectrogram, manual KV-cache,
custom decoder loops) living entirely in the app's executable target, with
no FluidAudio (or other linkable package) equivalent to call directly.
Reaching them needs the same kind of extraction just done for Nemotron —
each is its own separate lift, not attempted here. Whisper (Tiny/Small/
Medium/Large Turbo) is cheap in principle (WhisperKit's public API, ~139-line
app wrapper) but needs WhisperKit added as a MuesliCLI dependency, not done
in this pass.

## Dictionary correction

`--dictionary <path>` applies Muesli's actual custom-dictionary correction
(`CustomWordMatcher.apply`, promoted to `MuesliCore` so both the app and the
CLI call the identical implementation) to the transcript after transcription:

```bash
./.venv/bin/python -c "import json; json.dump([{'word': 'kubernete', 'replacement': 'Kubernetes'}], open('/tmp/dict.json', 'w'))"
muesli-cli transcribe clip.wav --dictionary /tmp/dict.json
```

The file is either a plain JSON array of `{word, replacement, matching_threshold}`
entries, or an object with a `custom_words` key in that shape (so a real
`config.json`'s dictionary can be pointed at directly).

`scripts/dictionary_eval.py` measures the WER impact as an **oracle** upper
bound: for each clip in an existing `run_eval.py` result, it builds a
per-clip dictionary from the exact substitution errors the model made on
that clip (via jiwer's alignment), re-transcribes with `--dictionary`, and
rescores. This is not a simulation of Muesli auto-detecting which words to
add (that's `DictionaryCorrectionDetector`, a separate feature that learns
from the user's manual edits over time) — it measures the ceiling: if the
right entries already existed, how much of the gap does fuzzy correction
recover? Run after `run_eval.py` has produced a baseline result:

```bash
./.venv/bin/python scripts/dictionary_eval.py --set earnings22 --model parakeet-v3
```

**Caveat:** not every substitution error is a plausible dictionary entry.
On Earnings-22, roughly a third of the oracle corrections are disfluency
noise (`um`→`uh`) or dataset `[inaudible]`-tag artifacts that no static
dictionary should try to fix — only the recurring jargon/proper-noun class
(`apec`→`apac`) matches what a real user dictionary actually contains.
Treat the oracle number as an upper bound, not an estimate of what
`DictionaryCorrectionDetector` would learn in practice.

**Standing finding, not yet addressed:** dictionary correction currently
only runs on dictations. `TranscriptionRuntime.swift`'s meeting path
intentionally skips it — so today, none of this WER recovery is reachable
for meeting transcripts, which is exactly where jargon/name errors like
"TeamViewer AG" showed up in issue #330's original findings.

## Known gaps (v1)

- One parquet shard per set — samples the head of each corpus, not a random
  draw. Fine for tracking deltas; don't quote as official corpus WER.
- No AMI (true far-field meeting) set yet; Earnings-22 is the stand-in.
- WER only — no partial-to-final flicker metric computed yet (see `--emit-partials`
  above), no latency percentiles beyond wall-clock per clip.
- **Nemotron 3.5 crashes on clips shorter than ~2.24s** (its chunk size) with a
  CoreML "zero shape" exception from the preprocessor/encoder, not a graceful
  empty result. `run_eval.py` catches this per-clip and scores it as an empty
  hypothesis so one bad clip doesn't abort the whole sweep, but the underlying
  behavior is a real bug worth fixing in `MuesliASRKit`'s `transcribe(wavURL:)`
  (short-clip padding before the first chunk), not just a harness workaround.
- Nemotron 3.5's English WER here isn't a fair read of its actual value —
  it's a multilingual, low-latency streaming model; this harness only has
  English sets, and the RNNT batch path here has no cross-chunk correction.
