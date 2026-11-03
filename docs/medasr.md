# Google MedASR

MedASR provides local English medical dictation and CLI file transcription on macOS 14.2 or later. It is a separate model card with Google's logo; it is not selected by default or offered for meeting transcription.

## Setup

1. Choose **Download** or **Set Active** on MedASR under Models.
2. Review the full Google HAI-DEF terms and prohibited-use policy, then choose **Agree & Continue**.

No Hugging Face account or token is required. Cancel starts no download and makes no selection change. Existing installations must also accept before preparation. A versioned acknowledgement is stored locally at `~/Library/Application Support/Muesli/ModelLicenses/medasr.json`, shared by the app and CLI on this Mac. It contains only the terms version and acceptance date; it is not synced or exported. Deleting the weights preserves acceptance; changed terms require renewed acceptance. Voice commands cannot grant acceptance and direct users to Models first.

CLI usage (read the terms before recording acceptance):

```bash
muesli-cli model-terms medasr
muesli-cli model-terms medasr --accept
muesli-cli transcribe recording.wav --model medasr
```

The complete terms and policy ship in the app and CLI resources, so they are available before download and offline. The distributed weights retain the license, Notice, prohibited-use policy and conversion modification record. Google's use restrictions are incorporated into the acceptance agreement; Muesli's MIT license does not replace them. The Hugging Face repository also publishes those obligations for direct downloaders.

## Runtime

The pinned conversion is `Muesli-HQ/medasr-coreml` revision `07d490538e4c77141a68767a7dd5efe946ad5f15`, derived from Google's `google/medasr`. Runtime assets occupy approximately 212 MB under `~/Library/Application Support/FluidAudio/Models/medasr-coreml`.

The 105M-parameter Conformer-CTC model runs through Core ML with CPU and Neural Engine compute enabled. An Accelerate frontend uses the conversion's exact mel/window tables. FluidAudio 0.17.3 supplies audio conversion and CTC text decoding; this addition does not update the shared transcription engine dependency.

Preparation includes a short silent warmup before the model becomes ready. Longer recordings use bounded 20-second windows with four seconds of overlap and continuous CTC decoding. Spoken punctuation controls are rendered as punctuation and paragraph breaks.

The conversion includes Google's license, Notice, prohibited-use policy and modification record. This is not a clinical accuracy certification; conversion validation has been performed on the maintainer's M5 Mac, and other supported Macs need device testing.

## Regression coverage

Ordinary tests cover model catalog/CLI parity, pinned assets, cancellation and preparation ownership, warmup, overlapping-window boundaries, punctuation, terms acceptance, and anonymous downloads. The opt-in `MedASRIntegrationTests` uses `MUESLI_MEDASR_FIXTURE_DIR` containing Google's public `test_audio.wav` and independently generated `reference-features.f32` / `reference-features-short.f32`. It compares the frontend against a float64 reference and transcribes the complete recording through both app and CLI adapters. No patient recordings are required.

Generate both independent frontend references, including a short non-hop-aligned
input with partial-frame and padding coverage:

```bash
python3 scripts/medasr_frontend_reference.py /path/to/test_audio.wav /path/to/fixtures
```

Set `MUESLI_MEDASR_ANONYMOUS_DOWNLOAD_TEST=1` to additionally exercise a fresh
anonymous download of the pinned runtime and legal assets. This opt-in test
uses a temporary directory and removes its own downloaded copies afterward.
