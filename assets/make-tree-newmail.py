"""Make the sidebar's green new-mail ball from Eudora 7's blue unread ball.

Stephen parks the Eudora window on a display across the room, where the 14 px
blue-lavender ball beside In is too small and too low-contrast to notice. This
produces a bigger, green version of the *same* art for the mailbox tree only —
the message rows keep the original, which is Eudora 7's own glyph and shouldn't
change.

Green deliberately matches Out's unsent glyph, `(0, 215, 129)`. The two now read
as one signal — "there is something here you'll want to do" — which is what
Stephen actually wants to see from a distance; which mailbox it is, is told by
which row it's on.

**Recoloured by luminance, not by hue rotation.** The original ball is only about
23% saturated, so simply swapping its hue gives a grey-green that is no easier to
see than the blue was. Instead each pixel's brightness is mapped onto a saturated
green ramp — dark green in the shadow, Out's green through the body, near-white
green at the specular highlight — which keeps the ball's modelling while making
the colour carry across a room.

**Resampled smoothly, not nearest-neighbour**, which is a deliberate departure
from `make-row-icons.py` and from the `.interpolation(.none)` used elsewhere. That
rule exists to stop 1x pixel art being *smeared at display time*; here we are
generating art at the size it will actually be drawn, and 14 -> 20 is a fractional
ratio, so nearest-neighbour would double some rows of a circle and not others and
leave it visibly lopsided. A 2x asset is emitted too, so Retina draws it without
scaling at all.

Unlike `make-row-icons.py`, which writes into `assets/` for hand-copying, this
writes straight into the asset catalog. There is no second copy to keep in sync.

Run from the repo root:  python3 assets/make-tree-newmail.py
"""
from PIL import Image
import os

SRC = "assets/RowUnread.png"          # already has a real alpha channel
DEST_DIR = "EudoraApp/Resources/Assets.xcassets/TreeNewMail.imageset"

# Points. The sidebar's rows self-size and the tallest thing in one is otherwise
# Out's 15 pt unsent glyph, so 20 might have pushed the In row taller than its
# neighbours. It doesn't — observed 2026aug03, In sits level with Out and Trash.
# Much beyond 20 would need looking at again.
POINT_SIZE = 20

# The ramp, darkest to lightest. The midpoint is Out's unsent green exactly.
SHADOW = (0, 78, 48)
BODY = (0, 215, 129)
HIGHLIGHT = (198, 255, 228)


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def ramp(t):
    """t in 0..1 (dark to light) through shadow -> body -> highlight."""
    if t <= 0.5:
        return lerp(SHADOW, BODY, t / 0.5)
    return lerp(BODY, HIGHLIGHT, (t - 0.5) / 0.5)


def recolour(im):
    px = im.load()
    w, h = im.size
    lums = [sum(px[x, y][:3]) / 3.0
            for x in range(w) for y in range(h) if px[x, y][3] > 0]
    lo, hi = min(lums), max(lums)
    span = (hi - lo) or 1.0

    out = Image.new("RGBA", (w, h))
    op = out.load()
    for x in range(w):
        for y in range(h):
            r, g, b, a = px[x, y]
            if a == 0:
                op[x, y] = (0, 0, 0, 0)
                continue
            t = (((r + g + b) / 3.0) - lo) / span
            op[x, y] = ramp(max(0.0, min(1.0, t))) + (a,)
    return out


def resize(im, size):
    """Resize preserving edge colour — premultiply so transparent pixels can't
    bleed their RGB into the ball's rim."""
    r, g, b, a = im.split()
    # `composite` is black.paste(rgb, mask=alpha), i.e. black*(1-a) + rgb*a —
    # which is exactly premultiplication.
    pre = Image.composite(Image.merge("RGB", (r, g, b)),
                          Image.new("RGB", im.size, (0, 0, 0)), a)
    pre = pre.resize((size, size), Image.LANCZOS)
    a2 = a.resize((size, size), Image.LANCZOS)

    # Unpremultiply.
    pp, ap = pre.load(), a2.load()
    out = Image.new("RGBA", (size, size))
    op = out.load()
    for x in range(size):
        for y in range(size):
            al = ap[x, y]
            if al == 0:
                op[x, y] = (0, 0, 0, 0)
            else:
                f = 255.0 / al
                cr, cg, cb = pp[x, y]
                op[x, y] = (min(255, round(cr * f)),
                            min(255, round(cg * f)),
                            min(255, round(cb * f)), al)
    return out


def main():
    src = Image.open(SRC).convert("RGBA")
    green = recolour(src)
    os.makedirs(DEST_DIR, exist_ok=True)

    for scale, name in ((1, "TreeNewMail.png"), (2, "TreeNewMail@2x.png")):
        img = resize(green, POINT_SIZE * scale)
        path = os.path.join(DEST_DIR, name)
        img.save(path)
        print(f"{path}: {img.size[0]}x{img.size[1]}")

    with open(os.path.join(DEST_DIR, "Contents.json"), "w") as f:
        f.write("""{
  "images" : [
    {
      "filename" : "TreeNewMail.png",
      "idiom" : "universal",
      "scale" : "1x"
    },
    {
      "filename" : "TreeNewMail@2x.png",
      "idiom" : "universal",
      "scale" : "2x"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
""")
    print(f"{DEST_DIR}/Contents.json")


if __name__ == "__main__":
    main()
