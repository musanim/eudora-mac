"""Give Eudora's row icons a real alpha channel.

The art arrived as opaque near-white-backed PNGs, so on a selected (blue) row the
background showed as a white block. Keying on colour alone won't do: the
attachment icon contains legitimately near-white ink (the paper is (255,250,230)),
which a global white key would punch holes in. So the background is found by
CONNECTIVITY - flood-filled inward from the border - and only the resulting
boundary ring is feathered, which leaves interior highlights untouched.
"""
from PIL import Image
from collections import deque
import sys

BG_MIN   = 226   # min channel at or above this, and border-connected => background
FEATHER  = 185   # boundary pixels lighter than this get partial alpha
MIN_KEEP = 0.30  # never fade a boundary pixel below this, to avoid gnawing holes

def process(src, dst):
    im = Image.open(src).convert('RGBA')
    w, h = im.size
    px = im.load()
    minch = [[min(px[x, y][:3]) for y in range(h)] for x in range(w)]

    # 1. Flood fill the background from every border pixel.
    bg = [[False] * h for _ in range(w)]
    q = deque()
    for x in range(w):
        for y in (0, h - 1):
            if minch[x][y] >= BG_MIN and not bg[x][y]:
                bg[x][y] = True; q.append((x, y))
    for y in range(h):
        for x in (0, w - 1):
            if minch[x][y] >= BG_MIN and not bg[x][y]:
                bg[x][y] = True; q.append((x, y))
    while q:
        x, y = q.popleft()
        for dx, dy in ((1,0),(-1,0),(0,1),(0,-1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < w and 0 <= ny < h and not bg[nx][ny] and minch[nx][ny] >= BG_MIN:
                bg[nx][ny] = True; q.append((nx, ny))

    # 2. Alpha: background clear; boundary ring feathered by how white it is;
    #    everything else untouched. Colour is unpremultiplied from white so the
    #    feathered pixels don't keep a pale halo baked into their RGB.
    out = Image.new('RGBA', (w, h))
    op = out.load()
    for x in range(w):
        for y in range(h):
            r, g, b, _ = px[x, y]
            if bg[x][y]:
                op[x, y] = (r, g, b, 0)
                continue
            touches_bg = any(0 <= x+dx < w and 0 <= y+dy < h and bg[x+dx][y+dy]
                             for dx in (-1,0,1) for dy in (-1,0,1))
            m = minch[x][y]
            if touches_bg and m > FEATHER:
                a = (BG_MIN - m) / (BG_MIN - FEATHER)
                a = max(MIN_KEEP, min(1.0, a))
                un = lambda c: max(0, min(255, round((c - 255 * (1 - a)) / a)))
                op[x, y] = (un(r), un(g), un(b), round(a * 255))
            else:
                op[x, y] = (r, g, b, 255)
    out.save(dst)
    cleared = sum(1 for x in range(w) for y in range(h) if bg[x][y])
    partial = sum(1 for x in range(w) for y in range(h) if 0 < op[x, y][3] < 255)
    print(f"{dst}: {w}x{h}  {cleared} px cleared, {partial} px feathered, "
          f"{w*h - cleared - partial} px opaque")

for src, dst in [('assets/Unread.png', 'assets/RowUnread.png'),
                 ('assets/attachment.png', 'assets/RowAttachment.png')]:
    process(src, dst)
