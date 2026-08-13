import argparse
import struct
from pathlib import Path

import numpy as np
import torch


def read_wav(path: Path) -> tuple[int, np.ndarray]:
    data = path.read_bytes()
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError("expected RIFF/WAVE file")

    offset = 12
    audio_format = None
    channels = None
    sample_rate = None
    bits_per_sample = None
    raw = None
    while offset + 8 <= len(data):
        chunk_id = data[offset : offset + 4]
        size = struct.unpack_from("<I", data, offset + 4)[0]
        payload = offset + 8
        if chunk_id == b"fmt ":
            audio_format, channels, sample_rate = struct.unpack_from("<HHI", data, payload)
            bits_per_sample = struct.unpack_from("<H", data, payload + 14)[0]
        elif chunk_id == b"data":
            raw = data[payload : payload + size]
            break
        offset = payload + size + (size % 2)

    if raw is None or channels is None or sample_rate is None or bits_per_sample is None:
        raise ValueError("missing fmt or data chunk")
    if audio_format not in (1, 0xFFFE) or bits_per_sample != 16:
        raise ValueError(f"expected 16-bit PCM wav, got format={audio_format}, bits={bits_per_sample}")
    audio = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    audio = audio.reshape(-1, channels).mean(axis=1)
    return sample_rate, audio


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--preprocessor", required=True)
    parser.add_argument("--audio", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    sample_rate, audio = read_wav(Path(args.audio))
    if sample_rate != 16_000:
        raise ValueError(f"expected 16 kHz wav, got {sample_rate}")

    model = torch.jit.load(args.preprocessor, map_location="cpu")
    model.eval()
    signal = torch.from_numpy(audio).unsqueeze(0)
    length = torch.tensor([audio.shape[0]], dtype=torch.int64)
    with torch.no_grad():
        features, lengths = model(signal, length)

    mel = features[0].detach().cpu().numpy().astype(np.float32)
    padded = np.zeros((80, 1024), dtype=np.float32)
    frames = min(mel.shape[1], 1024)
    padded[:, :frames] = mel[:, :frames]
    np.savez_compressed(args.out, mel=padded, real_frames=np.array([int(min(int(lengths[0]), 1024))], dtype=np.int32))
    print(f"wrote {args.out} shape={padded.shape} real_frames={int(min(int(lengths[0]), 1024))}")


if __name__ == "__main__":
    main()
