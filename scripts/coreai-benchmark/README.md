# Core AI transcription benchmark

This standalone experiment runs NVIDIA Parakeet TDT 0.6B v3 through Apple's CoreAISpeech API and the FluidAudio Core ML path used by Muesli's Parakeet v3 option. It requires an Apple silicon Mac running macOS 27 and Xcode 27. SwiftPM builds the experiment separately from the app.

## Prepare the models

Use [Apple's Parakeet export recipe](https://github.com/apple/coreai-models/tree/25af63c68837b3a9da911302b9089b6ab0d50927/models/parakeet), pinned to the same commit as the Swift runtime. Install [uv](https://docs.astral.sh/uv/getting-started/installation/) for the exporter.

```bash
work="$(mktemp -d)"
git clone https://github.com/apple/coreai-models "$work/coreai-models"
git -C "$work/coreai-models" checkout --detach 25af63c68837b3a9da911302b9089b6ab0d50927
(
  cd "$work/coreai-models/models/parakeet"
  uv run export.py --dtype float16 --audio-seconds 24 --output-dir "$work/exports"
)
```

Download Parakeet v3 in Muesli to populate the Core ML directory below, or supply the path to a local copy of [the published Core ML assets](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml). The benchmark reads model assets from disk.

## Run on the same input

Run from the Muesli repository root. The harness accepts one or more 16 kHz mono files of 1 to 60 seconds, up to the exported model's fixed window. It rejects longer clips because Apple's offline API would otherwise truncate them. Use a shorter export window, such as `--audio-seconds 5`, to measure the cost of a model sized for short dictation. This example generates one clip with the macOS Samantha voice.

```bash
say -v Samantha -o "$work/short.aiff" \
  'Please send the revised meeting notes to Priya before lunch tomorrow.'
afconvert -f WAVE -d LEI16@16000 -c 1 "$work/short.aiff" "$work/short.wav"

swift run --package-path scripts/coreai-benchmark --scratch-path "$work/build" -c release \
  --force-resolved-versions \
  CoreAIBenchmark \
  "$work/exports/parakeet-tdt-0.6b-v3_float16_static" \
  "$HOME/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3" \
  "$work/short.wav"
```

Model load includes runtime initialization and any specialization work performed during that load. Apple's static model also warms its encoder during initialization. First pass means the first full transcription of that clip. Later clips can benefit from earlier runs. Warm latency is the median of five additional passes for each engine. Both engines receive the same decoded PCM and stay loaded throughout. Transcription timing includes feature extraction, inference and text decoding. The first transcript is printed for each engine so timing can be checked against recognition quality.

The Core AI export uses FP16. Muesli's Core ML v3 encoder is INT8 and FluidAudio defaults to CPU and Neural Engine placement for its inference graphs. This compares two ways of deploying the same model family. A framework-only comparison would also require matching precision and hardware placement. To evaluate a Muesli rollout, use representative recordings, score word error rate, and measure latency through the app's dictation path, including its current default backend.

## M5 results

Release build on an Apple M5 with 16 GB RAM, macOS 27.2.1 (26B131), and Xcode 27.2 (27B52). Core AI used the [NVIDIA checkpoint at `541d1f9`](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3/tree/541d1f99c6b0c3cd0b11a95167540bb8edefd82b) exported with Core AI Torch 0.4.3. The Core ML files matched the [Muesli model manifest](https://assets.muesli.works/models/fluidaudio/parakeet-tdt-0.6b-v3/legacy-local-v1/manifest.json) for all 21 entries.

The table shows the warm median on the second process launch. Each row is five timed passes after a first pass on that clip.

| Clip | Core AI window | Core ML | Core AI | Core AI / Core ML |
| --- | ---: | ---: | ---: | ---: |
| 3.53 s synthetic dictation | 5 s | 42.90 ms | 59.99 ms | 1.40× |
| 3.53 s synthetic dictation | 24 s | 42.61 ms | 111.20 ms | 2.61× |
| 11.00 s public speech | 24 s | 49.87 ms | 126.45 ms | 2.54× |
| 22.57 s synthetic meeting excerpt | 24 s | 125.45 ms | 278.69 ms | 2.22× |

With caches populated, load took 315 ms for the 5-second Core AI model and 1,283 ms for the 24-second one. Core ML took 71 ms and 106 ms in those runs. The two Core AI exports took 14.0 s and 18.6 s to initialize on their first runs. The Core ML cache had already been exercised at that point. A Core AI bundle used about 1.2 GiB on disk, compared with 461 MiB for Core ML.

The first-pass transcripts agreed on the words across all three clips. One run differed on a comma in the longer clip. The fixtures are too small to estimate recognition quality. The Core AI tokenizer logged a fallback to its standard BPE implementation.

The FP16 export with `--dynamic` loaded, then aborted inside MPSGraph during the first encoder call with `Failed to resolve dynamic dimensions for memref.alloc`. Apple's own `speech-recognizer` reproduced the abort with a model re-exported using PyTorch 2.13.0. The static export completed both runs. Narrowing the static window improved Core AI's short-clip latency, but no tested configuration beat Muesli's Parakeet v3 baseline. The experiment stays outside the shipping app. A future integration would need to isolate native runtime failures and verify actual dictation latency before offering the backend on supported Macs.

The public speech fixture was [OpenAI Whisper's JFK test clip](https://github.com/openai/whisper/blob/86098128c0b4f24f0e2aa2994de830614b474227/tests/jfk.flac), converted to 16 kHz mono WAV with the same `afconvert` command above. To recreate the longer synthetic clip, use Samantha with this text.

> On Friday we reviewed the transcription workflow with the support team. Priya will send the revised meeting notes before lunch tomorrow. Alex will measure the time from the end of a recording to the moment the transcript appears. We will compare short dictation clips and longer meeting excerpts, using the same audio for both systems. At the next meeting, we will review recognition errors along with the timing results.
