#!/usr/bin/env python3
from __future__ import annotations

import subprocess
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "assets"
SOURCE = ASSETS / "sales-caddie-icon-source.png"
ICON_PNG = ASSETS / "sales-caddie-icon.png"
MENU_1X = ASSETS / "menu_sales_caddie_template.png"
MENU_2X = ASSETS / "menu_sales_caddie_template@2x.png"
ICONSET = ASSETS / "sales-caddie.iconset"
ICNS = ASSETS / "sales-caddie.icns"


def write_iconset(source: Image.Image) -> None:
    ICONSET.mkdir(parents=True, exist_ok=True)
    for child in ICONSET.iterdir():
        child.unlink()

    sizes = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png"),
    ]
    for size, name in sizes:
        source.resize((size, size), Image.Resampling.LANCZOS).save(ICONSET / name)

    subprocess.run(["iconutil", "-c", "icns", str(ICONSET), "-o", str(ICNS)], check=True)


def write_template_icons(source: Image.Image) -> None:
    # Crop the central gradient mark and remove the dark background for a
    # monochrome macOS template icon. The wordmark is intentionally excluded.
    w, h = source.size
    mark = source.crop((int(w * 0.24), int(h * 0.18), int(w * 0.76), int(h * 0.70))).convert("RGBA")
    pixels = mark.load()
    for y in range(mark.height):
        for x in range(mark.width):
            r, g, b, _ = pixels[x, y]
            bright = max(r, g, b)
            saturation = bright - min(r, g, b)
            alpha = 0
            if bright > 80 and saturation > 22:
                alpha = min(255, max(0, int((bright - 55) * 1.5)))
            pixels[x, y] = (0, 0, 0, alpha)

    bbox = mark.getchannel("A").getbbox()
    if bbox:
        mark = mark.crop(bbox)
    else:
        mark = Image.new("RGBA", (64, 64), (0, 0, 0, 0))

    for size, path in [(22, MENU_1X), (44, MENU_2X)]:
        canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        margin = max(2, round(size * 0.12))
        scale = min((size - 2 * margin) / mark.width, (size - 2 * margin) / mark.height)
        resized = mark.resize(
            (max(1, round(mark.width * scale)), max(1, round(mark.height * scale))),
            Image.Resampling.LANCZOS,
        )
        canvas.alpha_composite(resized, ((size - resized.width) // 2, (size - resized.height) // 2))
        canvas.save(path)


def main() -> None:
    if not SOURCE.exists():
        raise SystemExit(f"Missing source icon: {SOURCE}")

    ASSETS.mkdir(exist_ok=True)
    app_icon = Image.open(SOURCE).convert("RGBA").resize((1024, 1024), Image.Resampling.LANCZOS)
    app_icon.save(ICON_PNG)
    write_iconset(app_icon)
    write_template_icons(app_icon)
    print(f"Wrote {ICON_PNG}")
    print(f"Wrote {ICNS}")
    print(f"Wrote {MENU_1X}")
    print(f"Wrote {MENU_2X}")


if __name__ == "__main__":
    main()
