# Google MedASR

MedASR provides local English medical dictation and CLI file transcription on macOS 14.2 or later. It is a separate model card with Google's logo; it is not selected by default or offered for meeting transcription.

## Setup

1. Accept the model terms at [Muesli-HQ/medasr-coreml](https://huggingface.co/Muesli-HQ/medasr-coreml).
2. Sign in locally with `hf auth login` using the same Hugging Face account.
3. Download and select **MedASR** under Settings → Models.

The app and CLI reuse the standard local Hugging Face token file or `HF_TOKEN`. Tokens are used only with HTTPS requests to `huggingface.co`, stripped on CDN redirects, and never stored in app settings or logged. No credential is bundled with Muesli.

CLI usage:

```bash
muesli-cli transcribe recording.wav --model medasr
```

## Runtime

The pinned conversion is `Muesli-HQ/medasr-coreml` revision `07d490538e4c77141a68767a7dd5efe946ad5f15`, derived from Google's `google/medasr`. Runtime assets occupy approximately 212 MB under `~/Library/Application Support/FluidAudio/Models/medasr-coreml`.

The 105M-parameter Conformer-CTC model runs through Core ML with CPU and Neural Engine compute enabled. An Accelerate frontend uses the conversion's exact mel/window tables. FluidAudio 0.17.3 supplies audio conversion and CTC text decoding; this addition does not update the shared transcription engine dependency.

Preparation includes a short silent warmup before the model becomes ready. Longer recordings use bounded 20-second windows with four seconds of overlap and continuous CTC decoding. Spoken punctuation controls are rendered as punctuation and paragraph breaks.

The conversion includes Google's license, Notice, prohibited-use policy and modification record. This is not a clinical accuracy certification; conversion validation has been performed on the maintainer's M5 Mac, and other supported Macs need device testing.

## Regression coverage

Ordinary tests cover model catalog/CLI parity, pinned assets, cancellation and preparation ownership, warmup, overlapping-window boundaries, punctuation, and credential handling. The opt-in `MedASRIntegrationTests` uses `MUESLI_MEDASR_FIXTURE_DIR` containing Google's public `test_audio.wav` and independently generated `reference-features.f32`. It compares the frontend against a float64 reference and transcribes the complete recording through both app and CLI adapters. No patient recordings are required.
