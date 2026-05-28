#!/usr/bin/env python3
"""
Generate DMG background images for Muesli installer.
Produces:
  scripts/assets/dmg-background.png     — 1080x760px  (1x)
  scripts/assets/dmg-background@2x.png  — 2160x1520px (Retina)

Rendering at RENDER_SCALE× then LANCZOS downsample for SSAA.
"""

import math
import os
import random
try:
    from PIL import Image, ImageDraw, ImageFont, ImageFilter
except ImportError as exc:
    raise SystemExit("Pillow required: pip install Pillow") from exc

# ---------------------------------------------------------------------------
# Fonts (SF Pro — /Library/Fonts/ on macOS)
# ---------------------------------------------------------------------------
F_DISPLAY_BOLD = [
    "/Library/Fonts/SF-Pro-Display-Bold.otf",
    "/System/Library/Fonts/SFNS.ttf",
    "/System/Library/Fonts/HelveticaNeue.ttc",
]
F_TEXT_REGULAR = [
    "/Library/Fonts/SF-Pro-Text-Regular.otf",
    "/System/Library/Fonts/SFNS.ttf",
    "/System/Library/Fonts/HelveticaNeue.ttc",
]
F_TEXT_SEMIBOLD = [
    "/Library/Fonts/SF-Pro-Text-Semibold.otf",
    "/System/Library/Fonts/SFNS.ttf",
    "/System/Library/Fonts/HelveticaNeue.ttc",
]

# ---------------------------------------------------------------------------
# Colour palette (Muesli Design System)
# ---------------------------------------------------------------------------
C_BASE    = (0x11, 0x12, 0x14, 255)   # --bg-deep
C_SURFACE = (0x26, 0x28, 0x30, 255)   # --surface-primary
C_BORDER  = (255, 255, 255, 18)        # rgba(255,255,255,0.07)
C_ACCENT  = (0x6b, 0xa3, 0xf7, 255)   # --accent blue
C_TEXT    = (255, 255, 255, 235)       # rgba(255,255,255,0.92)
C_SUBTEXT = (255, 255, 255, 205)       # rgba(255,255,255,0.80)
C_OVERLAY = (255, 255, 255, 61)        # rgba(255,255,255,0.24) — divider

RENDER_SCALE = 4
APP_DISPLAY_NAME = os.environ.get("MUESLI_DMG_APP_NAME", "Muesli")


def rgba(c, a: int):
    return (c[0], c[1], c[2], a)


def load_font(candidates, size: int):
    for path in candidates:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size=size)
            except OSError:
                continue
    return ImageFont.load_default(size=size)


# ---------------------------------------------------------------------------
# Background glows
# ---------------------------------------------------------------------------

def _radial_glow(draw: ImageDraw.ImageDraw, cx, cy, rx, ry,
                 colour, steps: int, max_alpha: float):
    for i in range(steps):
        t = i / (steps - 1)
        alpha = int(t * max_alpha * 255)
        irx = int(rx * (1 - t * 0.92))
        iry = int(ry * (1 - t * 0.92))
        draw.ellipse(
            [cx - irx, cy - iry, cx + irx, cy + iry],
            fill=rgba(colour, alpha),
        )


def draw_glows(canvas: Image.Image, S: int):
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)

    # Subtle centre glow
    _radial_glow(draw, cx=540*S, cy=290*S, rx=480*S, ry=330*S,
                 colour=C_SURFACE[:3], steps=14, max_alpha=0.45)

    # Blue accent glow near Applications box
    _radial_glow(draw, cx=790*S, cy=315*S, rx=220*S, ry=190*S,
                 colour=C_ACCENT[:3], steps=10, max_alpha=0.07)

    canvas.alpha_composite(layer)


# ---------------------------------------------------------------------------
# Noise grain
# ---------------------------------------------------------------------------

def add_noise(canvas: Image.Image):
    """Tile a 256×256 noise patch for ~4% grain."""
    sz = 256
    tile = Image.new("RGBA", (sz, sz), (0, 0, 0, 0))
    pix = tile.load()
    rng = random.Random(42)
    for y in range(sz):
        for x in range(sz):
            v = rng.randint(160, 255)
            a = rng.randint(0, 12)
            pix[x, y] = (v, v, v, a)

    noise = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    for ny in range(0, canvas.size[1], sz):
        for nx in range(0, canvas.size[0], sz):
            noise.paste(tile, (nx, ny))
    canvas.alpha_composite(noise)


# ---------------------------------------------------------------------------
# Corkscrew cubic Bézier arrow
# ---------------------------------------------------------------------------

def _cubic_bezier(x0, y0, cx1, cy1, cx2, cy2, x1, y1, steps=80):
    pts = []
    for i in range(steps + 1):
        t = i / steps
        u = 1 - t
        x = u**3*x0 + 3*u**2*t*cx1 + 3*u*t**2*cx2 + t**3*x1
        y = u**3*y0 + 3*u**2*t*cy1 + 3*u*t**2*cy2 + t**3*y1
        pts.append((x, y))
    return pts


def draw_arrow(canvas: Image.Image, S: int):
    """
    Directional cubic Bézier arrow from Muesli box to Applications box.
    Keep it simple so the installer reads as a clear drag gesture.
    Coordinates in 1x (1080×760) space; scaled by S.
    """
    segments_1x = [
        ((350, 302), (420, 180), (500, 420), (580, 300)),
        ((580, 300), (650, 210), (730, 268), (782, 310)),
    ]
    segments = [
        tuple((int(p[0]*S), int(p[1]*S)) for p in seg)
        for seg in segments_1x
    ]

    all_pts = []
    for (p0, c1, c2, p1) in segments:
        chunk = _cubic_bezier(
            p0[0], p0[1], c1[0], c1[1], c2[0], c2[1], p1[0], p1[1], steps=80
        )
        if all_pts:
            all_pts.extend(chunk[1:])
        else:
            all_pts.extend(chunk)

    n = len(all_pts)

    # 1. Blurred glow layer
    glow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    for i in range(n - 1):
        gd.line([all_pts[i], all_pts[i + 1]], fill=C_ACCENT, width=14 * S)
    glow = glow.filter(ImageFilter.GaussianBlur(radius=10 * S))
    gr, gg, gb, ga = glow.split()
    ga = ga.point(lambda v: int(v * 0.35))
    canvas.alpha_composite(Image.merge("RGBA", (gr, gg, gb, ga)))

    # 2. Curve body — opacity ramps 40 → 255
    draw = ImageDraw.Draw(canvas)
    for i in range(n - 1):
        t = i / (n - 1)
        alpha = int(40 + t * 215)
        draw.line([all_pts[i], all_pts[i + 1]], fill=rgba(C_ACCENT, alpha), width=5 * S)

    # 3. Arrowhead oriented along final tangent
    tip = (int(790*S), int(313*S))
    dx = all_pts[-1][0] - all_pts[-8][0]
    dy = all_pts[-1][1] - all_pts[-8][1]
    length = math.hypot(dx, dy)
    if length == 0:
        return
    dx, dy = dx / length, dy / length
    px, py = -dy, dx
    head = 30 * S
    bcx = tip[0] - dx * head
    bcy = tip[1] - dy * head
    p1 = (bcx + px * head * 0.55, bcy + py * head * 0.55)
    p2 = (bcx - px * head * 0.55, bcy - py * head * 0.55)
    draw.polygon([tip, p1, p2], fill=C_ACCENT)


# ---------------------------------------------------------------------------
# Icon placeholder / app icon boxes
# ---------------------------------------------------------------------------

def draw_icon_column(canvas: Image.Image, cx, cy, label: str, font, S: int,
                     icon_path: str = None):
    box_w, box_h = 160 * S, 160 * S
    radius = 28 * S
    lx, ty = cx - box_w // 2, cy - box_h // 2
    rx, by = cx + box_w // 2, cy + box_h // 2

    # Glass fill on separate layer for correct alpha blending
    fill_layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    fd = ImageDraw.Draw(fill_layer)
    fd.rounded_rectangle([lx, ty, rx, by], radius=radius,
                         fill=rgba(C_SURFACE, 200))
    canvas.alpha_composite(fill_layer)

    # App icon (optional)
    if icon_path and os.path.exists(icon_path):
        margin = 12 * S
        icon_size = box_w - margin * 2
        try:
            icon = Image.open(icon_path).convert("RGBA")
            icon = icon.resize((icon_size, icon_size), Image.LANCZOS)
            icon_x = cx - icon_size // 2
            icon_y = cy - icon_size // 2
            canvas.paste(icon, (icon_x, icon_y), icon)
        except Exception as exc:
            print(f"Warning: could not render app icon at {icon_path}: {exc}")
    elif icon_path:
        print(f"Warning: app icon not found at {icon_path}; rendering empty icon box")

    # Stroke outline
    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle([lx, ty, rx, by], radius=radius,
                            fill=None, outline=C_BORDER, width=2 * S)

    # Render the visible label in the artwork because Finder does not expose a
    # reliable icon-label colour setting.
    label_y = by + 28 * S
    bbox = draw.textbbox((0, 0), label, font=font)
    tw = bbox[2] - bbox[0]
    shadow_offset = 2 * S
    draw.text(
        (cx - tw // 2 + shadow_offset, label_y + shadow_offset),
        label,
        font=font,
        fill=(0, 0, 0, 170),
    )
    draw.text((cx - tw // 2, label_y), label, font=font, fill=C_TEXT)


# ---------------------------------------------------------------------------
# Text helper
# ---------------------------------------------------------------------------

def draw_centred(draw: ImageDraw.ImageDraw, text: str, font,
                 y: int, colour, canvas_w: int):
    bbox = draw.textbbox((0, 0), text, font=font)
    tw = bbox[2] - bbox[0]
    draw.text(((canvas_w - tw) // 2, y), text, font=font, fill=colour)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def generate():
    W, H = 1080, 760
    S = RENDER_SCALE
    RW, RH = W * S, H * S

    font_title    = load_font(F_DISPLAY_BOLD,  size=66 * S)
    font_subtitle = load_font(F_TEXT_SEMIBOLD, size=23 * S)
    font_label    = load_font(F_TEXT_SEMIBOLD, size=22 * S)
    font_footer   = load_font(F_TEXT_SEMIBOLD, size=18 * S)

    # 1. Base canvas
    img = Image.new("RGBA", (RW, RH), C_BASE)

    # 2. Background glows
    draw_glows(img, S)

    # 3. Noise grain
    add_noise(img)

    # 4. Header text
    draw = ImageDraw.Draw(img)
    draw_centred(draw, f"Install {APP_DISPLAY_NAME}", font_title,
                 46 * S, C_TEXT, RW)
    draw_centred(draw, "Drag to Applications \U0001f4c2  \u00b7  or double-click to install",
                 font_subtitle, 136 * S, C_SUBTEXT, RW)

    # 5. Icon columns
    script_dir = os.path.dirname(os.path.abspath(__file__))
    icon_path = os.path.normpath(os.path.join(script_dir, "assets", "sales-caddie-icon.png"))

    icon_cy = 315 * S
    draw_icon_column(img, cx=260 * S, cy=icon_cy, label=APP_DISPLAY_NAME,
                     font=font_label, S=S, icon_path=icon_path)
    draw_icon_column(img, cx=820 * S, cy=icon_cy, label="Applications",
                     font=font_label, S=S)

    # 6. Corkscrew arrow
    draw_arrow(img, S=S)

    # 7. Divider
    draw = ImageDraw.Draw(img)
    draw.line([(80 * S, 490 * S), (1000 * S, 490 * S)],
              fill=C_OVERLAY, width=1 * S)

    # 8. Footer
    footer = (f"After installing, {APP_DISPLAY_NAME} will relaunch from Applications."
              "  You can then eject this disk.")
    draw_centred(draw, footer, font_footer, 520 * S, C_SUBTEXT, RW)

    # 9. Downsample with LANCZOS and save. Keep the background referenced by
    # Finder at full point resolution, and include a Retina sibling for systems
    # that resolve @2x artwork.
    out_dir = os.path.join(os.path.dirname(__file__), "assets")
    os.makedirs(out_dir, exist_ok=True)

    img.resize((W * 2, H * 2), Image.LANCZOS).save(
        os.path.join(out_dir, "dmg-background@2x.png"), "PNG")
    img.resize((W, H), Image.LANCZOS).save(
        os.path.join(out_dir, "dmg-background.png"), "PNG")

    print("Generated: scripts/assets/dmg-background.png (1080x760) "
          "and dmg-background@2x.png (2160x1520)")


if __name__ == "__main__":
    generate()
