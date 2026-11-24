#!/usr/bin/env python3
"""Render Finder's 920 × 406 pt installer canvas. Requires Pillow and resvg-py."""
from pathlib import Path
from io import BytesIO

import resvg_py

from PIL import Image, ImageDraw, ImageFont

ASSETS = Path(__file__).resolve().parent / "assets"
ROOT = ASSETS.parent.parent
WORDMARK = ROOT / "design-system/assets/brand/muesli-wordmark-primary.svg"
FONT = ROOT / "native/MuesliNative/Sources/MuesliNativeApp/Resources/Fonts/NunitoSans-Medium.ttf"
SCALE = 2
WIDTH, HEIGHT = 920 * SCALE, 406 * SCALE
PAPER = "#FAF7EC"
INK = "#172C44"


def render():
    canvas = Image.new("RGB", (WIDTH, HEIGHT), PAPER)
    # Website illustration: muesli-landing/src/assets/solarpunk-park-speech-lawn.png.
    # Crop the canopy so the bridge, solar roofs and seated reader share the horizon.
    with Image.open(ASSETS / "dmg-park.jpg") as source:
        scene = source.crop((0, 547, source.width, 961)).resize((WIDTH, 248 * SCALE), Image.Resampling.LANCZOS)
    # The upper edge dissolves into the paper behind the live Finder labels.
    mask = Image.new("L", (1, scene.height))
    for y in range(scene.height):
        t = min(1, y / (106 * SCALE))
        mask.putpixel((0, y), round(255 * t * t * (3 - 2 * t)))
    canvas.paste(scene, (0, HEIGHT - scene.height), mask.resize(scene.size))

    with Image.open(BytesIO(resvg_py.svg_to_bytes(svg_string=WORDMARK.read_text()))) as logo:
        logo = logo.convert("RGBA")
        logo = logo.crop(logo.getchannel("A").getbbox())
        logo.thumbnail((148 * SCALE, 50 * SCALE), Image.Resampling.LANCZOS)
        canvas.paste(logo, ((WIDTH - logo.width) // 2, 22 * SCALE), logo)

    draw = ImageDraw.Draw(canvas)
    font = ImageFont.truetype(str(FONT), 17 * SCALE)
    draw.text((WIDTH // 2, 85 * SCALE), "Drag muesli to Applications.", fill=INK, font=font, anchor="mm")
    # Finder supplies both icons and their names. Keep only the directional cue in the art.
    x, y = WIDTH // 2, 155 * SCALE
    draw.line([(x - 16 * SCALE, y), (x + 16 * SCALE, y)], fill=INK, width=2 * SCALE)
    draw.line([(x + 9 * SCALE, y - 7 * SCALE), (x + 16 * SCALE, y), (x + 9 * SCALE, y + 7 * SCALE)],
              fill=INK, width=2 * SCALE)
    canvas.save(ASSETS / "dmg-background@2x.png", dpi=(144, 144), optimize=True)
    canvas.resize((920, 406), Image.Resampling.LANCZOS).save(ASSETS / "dmg-background.png", dpi=(72, 72), optimize=True)


if __name__ == "__main__":
    render()
