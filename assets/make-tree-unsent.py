"""Make the sidebar's grey unsent ball from Out's green one.

Out's row in the mailbox tree showed the same green ball as an unsent message's
row in the list. Stephen wants the tree's copy grey: the green in the tree is
now the In row's new-mail signal (`make-tree-newmail.py`), and a second green
ball beside Out read as a second thing wanting attention when it only means
"there are drafts here". The message rows keep the green `RowUnsent` unchanged.

Same art, same size, recoloured by luminance onto a grey ramp so the ball's
modelling survives. Written straight into the asset catalog, as
`make-tree-newmail.py` does; there is no second copy to keep in sync. 1x only,
like the row icons it sits beside, and drawn with `.interpolation(.none)` like
them.

Run from the repo root:  python3 assets/make-tree-unsent.py
"""
from PIL import Image
import json
import os

SRC = "assets/RowUnsent.png"          # already has a real alpha channel
DEST_DIR = "EudoraApp/Resources/Assets.xcassets/TreeUnsent.imageset"

# The ramp, darkest to lightest. The body sits near the sidebar's secondary
# text grey so the two read as the same weight of thing.
SHADOW = (72, 72, 72)
BODY = (150, 150, 150)
HIGHLIGHT = (236, 236, 236)


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def ramp(t):
    if t <= 0.5:
        return lerp(SHADOW, BODY, t / 0.5)
    return lerp(BODY, HIGHLIGHT, (t - 0.5) / 0.5)


def recolour(im):
    px = im.load()
    w, h = im.size
    lums = [0.299 * px[x, y][0] + 0.587 * px[x, y][1] + 0.114 * px[x, y][2]
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
            t = ((0.299 * r + 0.587 * g + 0.114 * b) - lo) / span
            op[x, y] = ramp(max(0.0, min(1.0, t))) + (a,)
    return out


def main():
    src = Image.open(SRC).convert("RGBA")
    grey = recolour(src)
    os.makedirs(DEST_DIR, exist_ok=True)
    grey.save(os.path.join(DEST_DIR, "TreeUnsent.png"))
    with open(os.path.join(DEST_DIR, "Contents.json"), "w") as f:
        json.dump({
            "images": [{"filename": "TreeUnsent.png", "idiom": "universal", "scale": "1x"}],
            "info": {"author": "xcode", "version": 1},
        }, f, indent=2)
        f.write("\n")
    print("wrote", DEST_DIR)


if __name__ == "__main__":
    main()
