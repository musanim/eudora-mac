#!/usr/bin/env python3
"""Regenerate the app icon from the splash art.

The icon is a square lifted out of `EudoraSplash8.png`, per Stephen's spec:
the bottom edge sits on the boundary of the light blue background (y=132, where
the lighter gradient gives way to the darker QUALCOMM band), and the 8 keeps the
same margin above and to the right as it has below — 7 px, measured from the
glyph's bounding box at x 355..432, y 25..124.

LEFT = 326 squares the crop off the left, exactly as the spec implies: the 8 sits
hard against the right edge with its 7 px margin, and the surplus width — a
square tall enough for a 99 px 8 is 114 px wide, while the 8 is only 77 — falls
to the left, where it shows the tail of the EUDORA wordmark and "ion" from
"version". That fragment is wanted, not tolerated: it is what makes the icon read
as Eudora rather than as a generic numeral. It was briefly moved to 353 to keep
those letters out, which was the wrong call — at Dock size the wordmark is a
texture that says "Eudora", and losing it costs more than the tidiness gains.

Run from `assets/`:  python3 make_icon.py
Then `xcodegen generate` (asset-catalog change) and rebuild.
"""
from PIL import Image, ImageDraw

LEFT, SIDE, BOTTOM = 326, 114, 132
CORNER = 0.2237          # macOS-ish rounded-rect ratio; full-bleed, no inset
OUT = "../EudoraApp/Resources/Assets.xcassets/AppIcon.appiconset"

src = Image.open("EudoraSplash8.png").convert("RGB")
crop = src.crop((LEFT, BOTTOM - SIDE, LEFT + SIDE, BOTTOM))

for size in (16, 32, 64, 128, 256, 512, 1024):
    img = crop.resize((size, size), Image.LANCZOS).convert("RGBA")
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, size - 1, size - 1], radius=max(1, int(size * CORNER)), fill=255)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    out.save(f"{OUT}/icon_{size}.png")
    print("wrote", size)
