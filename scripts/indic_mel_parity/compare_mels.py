import argparse
from pathlib import Path

import numpy as np


def read_swift_bin(path: Path) -> tuple[np.ndarray, int]:
    raw = path.read_bytes()
    header_end = raw.index(b"\n")
    header = raw[:header_end].decode("utf-8")
    real_frames = int(header.split("real_frames=", 1)[1])
    mel = np.frombuffer(raw[header_end + 1 :], dtype=np.float32).reshape(80, 1024).copy()
    return mel, real_frames


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--torch", required=True)
    parser.add_argument("--swift", required=True)
    parser.add_argument("--label", required=True)
    args = parser.parse_args()

    torch_npz = np.load(args.torch)
    torch_mel = torch_npz["mel"].astype(np.float32)
    torch_frames = int(torch_npz["real_frames"][0])
    swift_mel, swift_frames = read_swift_bin(Path(args.swift))
    frames = min(torch_frames, swift_frames, 1024)
    if frames == 0:
        print(f"label={args.label}")
        print(f"frames torch={torch_frames} swift={swift_frames} compared=0")
        print("no overlapping mel frames to compare")
        return

    diff = swift_mel[:, :frames] - torch_mel[:, :frames]
    torch_flat = torch_mel[:, :frames].reshape(-1).astype(np.float64)
    swift_flat = swift_mel[:, :frames].reshape(-1).astype(np.float64)
    denom = np.linalg.norm(torch_flat) * np.linalg.norm(swift_flat)
    cosine = float(np.dot(torch_flat, swift_flat) / denom) if denom else float("nan")

    print(f"label={args.label}")
    print(f"frames torch={torch_frames} swift={swift_frames} compared={frames}")
    print(f"max_abs_error={np.max(np.abs(diff)):.6f}")
    print(f"mean_abs_error={np.mean(np.abs(diff)):.6f}")
    print(f"rmse={np.sqrt(np.mean(diff * diff)):.6f}")
    print(f"cosine_similarity={cosine:.8f}")
    print(f"torch mean/std={torch_mel[:, :frames].mean():.6f}/{torch_mel[:, :frames].std():.6f}")
    print(f"swift mean/std={swift_mel[:, :frames].mean():.6f}/{swift_mel[:, :frames].std():.6f}")


if __name__ == "__main__":
    main()
