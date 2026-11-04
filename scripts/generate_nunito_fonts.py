#!/usr/bin/env python3
"""Generate bundled native faces; requires fontTools==4.68.0 (not a build dependency).

Usage: generate_nunito_fonts.py UPRIGHT_VARIABLE.ttf ITALIC_VARIABLE.ttf OUTPUT_DIR
Copy the upstream OFL.txt alongside the generated files.
"""
import sys
from pathlib import Path

from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont


def generate(upright: str, italic_source: str, destination: str) -> None:
    output = Path(destination)
    output.mkdir(parents=True, exist_ok=True)
    for italic in (False, True):
        for weight, style in [(400, "Regular"), (500, "Medium"), (600, "SemiBold"),
                              (700, "Bold"), (800, "ExtraBold")]:
            if italic and weight not in (400, 700):
                continue
            font = TTFont(italic_source if italic else upright, recalcTimestamp=False)
            axes = {axis.axisTag: axis.defaultValue for axis in font["fvar"].axes}
            axes.update(wght=weight, opsz=12)
            font = instantiateVariableFont(font, axes, inplace=True, updateFontNames=True)
            if italic:
                style = "Italic" if weight == 400 else "Bold Italic"
            family = "Nunito Sans"
            postscript = "NunitoSans-" + style.replace(" ", "")
            names = {
                1: family if weight in (400, 700) else family + " " + style,
                2: style if weight in (400, 700) else "Regular",
                3: postscript + ";Muesli;12pt", 4: family + " " + style,
                6: postscript, 16: family, 17: style,
            }
            for record in list(font["name"].names):
                if record.nameID in names:
                    font["name"].setName(names[record.nameID], record.nameID,
                                         record.platformID, record.platEncID, record.langID)
            font.save(output / (postscript + ".ttf"))


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    generate(*sys.argv[1:])
