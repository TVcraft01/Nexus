"""Print the centre of the composer's mic button in the given screenshot.

Found by clustering accent-coloured blobs in the lower part of the screen and
taking the largest: the button's 40dp disc is ~104 device px across, and the
only other accent on the page is the active tab glyph at half that. Both
palettes are searched, so this works in light mode (#773DDC) and in dark
(#9D6BF5).
"""
import sys
from PIL import Image

ACCENTS = ((0x77, 0x3D, 0xDC), (0x9D, 0x6B, 0xF5))


def blob_centre(path):
    im = Image.open(path).convert('RGB')
    W, H = im.size
    px = im.load()
    y0 = int(H * 0.6)
    best = None
    for target in ACCENTS:
        active, done = [], []
        for y in range(y0, H):
            runs, x = [], 0
            while x < W:
                p = px[x, y]
                if abs(p[0] - target[0]) + abs(p[1] - target[1]) + abs(p[2] - target[2]) < 40:
                    xs = x
                    while x < W:
                        q = px[x, y]
                        if abs(q[0] - target[0]) + abs(q[1] - target[1]) + abs(q[2] - target[2]) >= 40:
                            break
                        x += 1
                    runs.append((xs, x - 1))
                else:
                    x += 1
            for a, b in runs:
                hit = next((c for c in active if not (b < c['minx'] or a > c['maxx'])), None)
                if hit is None:
                    active.append(dict(minx=a, miny=y, maxx=b, maxy=y, area=b - a + 1, last=y))
                else:
                    hit['minx'] = min(hit['minx'], a)
                    hit['maxx'] = max(hit['maxx'], b)
                    hit['maxy'] = y
                    hit['area'] += b - a + 1
                    hit['last'] = y
            still = []
            for c in active:
                (still if c['last'] == y else done).append(c)
            active = still
        done.extend(active)
        for c in done:
            if c['area'] > 4000 and (best is None or c['area'] > best['area']):
                best = c
    if best is None:
        return None
    return ((best['minx'] + best['maxx']) // 2, (best['miny'] + best['maxy']) // 2, best['area'])


if __name__ == '__main__':
    for p in sys.argv[1:]:
        got = blob_centre(p)
        if got is None:
            print(f'{p}: no button found')
        else:
            print(f'{got[0]} {got[1]}  # {p} area={got[2]}')
