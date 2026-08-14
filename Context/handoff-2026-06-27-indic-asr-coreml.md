# Indic ASR CoreML Integration Handoff

Branch: `codex/indic-asr-coreml-integration`
Worktree: `/Users/pranavhari/Desktop/hacks/muesli-indic-asr`

## Summary

Added an experimental AI4Bharat IndicConformer RNNT CoreML backend for Muesli. The app now exposes `Indic ASR` as an experimental model, lets the user select one of seven supported languages, routes dictation and meeting/audio-file transcription through the selected language, and downloads converted CoreML artifacts from `phequals/indic-conformer-600m-multilingual-coreml-rnnt` by default.

## Implementation Notes

- `IndicASRBackend.swift` contains the CoreML model store, mel frontend, tokenizer, chunked RNNT greedy loop, and HF manifest downloader.
- The model store supports the production HF cache layout under `coreml/encoder`, `coreml/rnnt`, and `metadata`.
- `MUESLI_INDIC_ASR_MODEL_DIR` remains as a development override.
- The old local Jarvis split layout is still recognized so existing development artifacts can be used during local testing.
- `scripts/indic_mel_parity/` contains the Torch-vs-Swift frontend comparison scripts used to validate mel preprocessing parity.

## Validation

- Built and launched `MuesliDevB` via the eSSD dev lane; the user verified Tamil and Hindi dictation worked in-app.
- Focused SwiftPM validation passed:
  `swift test --package-path native/MuesliNative --scratch-path /Volumes/eSSD/muesli-spm-direct/worktrees/muesli-indic-asr-1941980778/pr-test --filter ModelsTests`
  This linked `MuesliNativeApp` and ran 118 tests successfully.
- Earlier full `swift test` compiled but hit an existing unrelated `StreamingVadController` expectation failure.
- Mel frontend parity after porting serialized Torch preprocessor constants:
  Tamil cosine `0.99657430`, Hindi cosine `0.99454342`.

## Known Limitations

- Experimental backend, macOS 15+ CoreML path.
- Requires explicit language selection; there is no language autodetection.
- RNNT output does not currently add punctuation.
- Long audio is handled by chunking and transcript merge heuristics rather than a streaming UI.
