#!/usr/bin/env python3
"""Generate independent float64 MedASR references from Google's public PCM fixture.

Requires numpy. Input is 16 kHz, mono, signed PCM16. Output is local test data;
never commit the generated audio or feature tensors.
"""
from pathlib import Path
import argparse
import wave
import numpy as np


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("audio", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    with wave.open(str(args.audio)) as audio:
        assert audio.getnchannels() == 1 and audio.getsampwidth() == 2 and audio.getframerate() == 16000
        samples = np.frombuffer(audio.readframes(320000), dtype="<i2").astype(np.float64) / 32768
    hz = np.linspace(0, 8000, 257, dtype=np.float64)[1:]
    mel = 1127.0 * np.log1p(hz / 700.0)
    edges = np.linspace(1127.0 * np.log1p(125 / 700), 1127.0 * np.log1p(7500 / 700), 130)
    lower = (mel[:, None] - edges[:-2][None, :]) / (edges[1:-1] - edges[:-2])[None, :]
    upper = (edges[2:][None, :] - mel[:, None]) / (edges[2:] - edges[1:-1])[None, :]
    filters = np.pad(np.maximum(0, np.minimum(lower, upper)), ((1, 0), (0, 0)))
    args.output.mkdir(parents=True, exist_ok=True)
    for count, name in [(320000, "reference-features.f32"), (32017, "reference-features-short.f32")]:
        selected = samples[:count]
        padded = np.pad(selected, (0, 320000 - len(selected)))
        frames = np.lib.stride_tricks.sliding_window_view(padded, 400)[::160]
        power = np.abs(np.fft.rfft(frames * np.hanning(400), n=512, axis=-1)) ** 2
        features = np.log(np.maximum(power @ filters, 1e-5)).astype("<f4")
        assert features.shape == (1998, 128)
        features.tofile(args.output / name)
        print(f"Generated {name}: {count} samples, {features.shape}")


if __name__ == "__main__":
    main()
