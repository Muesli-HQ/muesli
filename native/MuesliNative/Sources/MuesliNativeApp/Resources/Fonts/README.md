# Nunito Sans

Bundled under the SIL Open Font License; see OFL.txt. Copyright 2016 The Nunito
Sans Project Authors (https://github.com/Fonthausen/NunitoSans).

Source: Google Fonts `ofl/nunitosans`, retrieved 2026-10-30:
- NunitoSans[YTLC,opsz,wdth,wght].ttf
- NunitoSans-Italic[YTLC,opsz,wdth,wght].ttf

These are static instances of the upstream variable fonts, generated with
fontTools 4.68.0 at optical size 12, width 100 and the default YTLC axis. Upright
weights: 400, 500, 600, 700, 800. Italics: 400 and 700. Name records are normalized
to the Nunito Sans typographic family and NunitoSans-* PostScript names so AppKit
bold/italic conversion and SwiftUI resolve the same faces reliably. Outlines,
glyph coverage and OpenType features are preserved. There is no runtime font
conversion or network dependency.

The reproducible generator is `scripts/generate_nunito_fonts.py`; it takes the two
upstream files and an output directory. The application loads this SwiftPM
resource directory once per process. Do not depend on locally installed fonts.

Upstream SHA-256 checksums (upright, italic):

```text
f934d7142fb4784bf828da485b7dcbd90c0c80d514e9d49a5da0ed3a1ae2491d
d9d5db18f3c11221a4fbb553cbc709391c1179964c7eaa4466ef43c78aa4492f
```
