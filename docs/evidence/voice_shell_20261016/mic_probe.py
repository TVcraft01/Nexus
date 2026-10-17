import sys
from PIL import Image
from collections import Counter

# (966,1964) came from clustering the accent disc on the first settled capture.
# The button is a 40dp circle, 104 device px across, so this is the disc at the
# centre of it. Nothing here assumes a colour: the fill is whatever the theme
# paints (purple in light mode, a lifted purple in dark), and the ring is
# detected as *brighter than that fill*, which is true of any theme.
CX, CY = 966, 1964
R = 50


def probe(path):
    im = Image.open(path).convert('RGB')
    px = im.load()
    disc = []
    for y in range(CY - R, CY + R + 1):
        for x in range(CX - R, CX + R + 1):
            dx, dy = x - CX, y - CY
            if dx * dx + dy * dy <= R * R:
                disc.append((dx, dy, px[x, y]))
    fill, fill_n = Counter(p for _, _, p in disc).most_common(1)[0]
    inner = [p for dx, dy, p in disc if dx * dx + dy * dy <= 30 * 30]
    annulus = [(dx, dy, p) for dx, dy, p in disc if dx * dx + dy * dy >= 32 * 32]
    def bright(p):  # perceptually above the fill
        return sum(p) - sum(fill) > 60
    print(
        f'{path.split("/")[-1]:22s} fill={fill} fill_share={fill_n / len(disc):.2f} '
        f'bright_inner={sum(1 for p in inner if bright(p)):4d}/{len(inner)} '
        f'bright_annulus={sum(1 for _, _, p in annulus if bright(p)):4d}/{len(annulus)}'
    )


for p in sys.argv[1:]:
    probe(p)
