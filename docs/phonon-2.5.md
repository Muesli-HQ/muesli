# Phonon-2.5 in Muesli

Phonon-2.5 is a batch transcription option for dictation, meetings and CLI files.
It uses the existing FluidAudio 0.17.3 backend and requires macOS 15+. It does not
change the default model or add a new inference runtime.

## Weights and execution

- Source: FermionResearch/Phonon-2.5 revision `2673618ad8636c8dfd20fe57e94d1f67f75bdeaa`.
- Distribution: Muesli-HQ/phonon-2.5-coreml revision `a042ef89966d289df295709b58ffdabb50bd2510`.
- Full component directory: 289,793,778 bytes, approximately 290 MB.
- Dense LUT3 encoder runs with `.cpuAndGPU`; decoder/joint keep FluidAudio defaults.
- Own encoder, decoder and joint weights; only the shared preprocessor is reused.
- Managed downloader selects the five required components at the pinned revision.
  The model repository also supplies SHA256 checksums and license/NOTICE files.
- Cache: `~/Library/Application Support/FluidAudio/Models/phonon-2.5-gpu`.

`AsrModels.loadLocal(version: .v3)` selects the compatible tensor/decoder contract,
not stock Parakeet weights. Runtime reuse and unloading use the distinct **model
ID**, because Phonon and Parakeet v3 share that contract but different weights.
App and CLI share `ParakeetRuntimePolicy` for compute selection and preparation.
Before publishing readiness, the GPU model transcribes one second of in-memory
silence with a disposable decoder state. The result is discarded. This runs once
per model load, consumes first-inference setup during preparation and propagates
errors/cancellation before the manager is cached or a ready event is emitted.
Phonon has its own model card, separate from the Parakeet family; voice selection
continues to derive choices from the existing catalog. The Fermion logo is the
unmodified [official brand asset](https://www.fermionresearch.com/images/brand/newlogo.svg)
from Fermion Research, used to identify the model provider. The logo remains the
property of Fermion Research and is not relicensed under Muesli’s MIT license.

```sh
muesli-cli transcribe recording.wav --model phonon-2.5
```

## Validation

Conversion evidence: https://github.com/FluidInference/mobius/pull/113 . The GPU
encoder passed the fixed-window tensor check against fp32 NeMo. Rechecking through
FluidAudio's actual configuration, including its GPU precision setting, also
passed: cosine 0.99999889, NRMSE 0.00149269. Eighty-three public clips across four
languages completed; 72 normalized transcripts matched the independent fp32
reference. This sample does not establish accuracy across all 25 languages or
all Apple chips. Silence and a 44-second multi-window fixture were also checked.

Twenty real-feature decoder/joint checks retained the same top-1 token and
predicted duration as fp32, with maximum aligned top-K logit difference 0.12744.
This is additional smoke coverage, not full decoder numerical equivalence.

## Future Neural Engine support

The sparse ANE encoder fails the retained strict activation gate on the tested
M5. FluidAudio 0.17.3 and 0.17.7 produce bit-identical outputs for it. This path is
not selected or distributed by Muesli. The upstream draft requests guidance.

After validation, an ANE follow-up can publish its artifact variant and update the
pinned plan/cache layout and shared encoder policy. The catalog identity and the
existing transcription workflow do not require a new backend or user toggle.

## App / CLI integration smoke test

Fetch the public fixtures with the converter's `fetch_fixtures.py`, then run:

```sh
MUESLI_PHONON_FIXTURE_DIR=/path/to/public-fixtures swift test \
  --package-path native/MuesliNative --scratch-path /path/to/test-cache \
  --filter Phonon25IntegrationTests
```

The opt-in test loads the installed model (or downloads the pinned revision),
checks four language hints through the app actor, verifies that deleting the v3
identity leaves Phonon loaded, checks unloading the matching identity, and runs
the CLI transcriber. Ordinary CI skips this test and exercises synthetic catalog,
routing, compatibility and download/deletion regressions instead.

A preparation-warmup check on the M5 took 7.72 seconds to prepare the model; the
first real 10.4-second speech fixture then transcribed in 0.38 seconds. Later
fixtures took 0.26–0.55 seconds. These are local smoke timings, not a benchmark
or a guarantee for other hardware.
