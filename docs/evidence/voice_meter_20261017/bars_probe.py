"""Measure the composer's level meter in a capture: how tall the tallest bar is.

The bars are painted in the accent at full strength, so this looks for that
colour *exactly* (a small tolerance for antialiasing) and takes the tallest run
of it in the composer pill's left half. Anything mixed down — the pill's own tint,
the X disc's rim at 45% — is a long way off that colour and is not counted; the
stop disc, which is full accent, sits in the right half and is out of the crop.

    python3 bars_probe.py 0*.png
"""
import sys
from PIL import Image

# kNexusAccent, #773DDC. The dark-theme accent is deliberately not accepted: in a
# light-mode capture it matches the mixed-down rims rather than the bars.
ACCENT = (0x77, 0x3D, 0xDC)
TOLERANCE = 60


def tallest_column(path):
    im = Image.open(path).convert('RGB')
    W, H = im.size
    # The composer, above the tab bar; its left half, where the meter is.
    band = im.crop((0, H - 300, W // 2, H - 90))
    px = band.load()
    bw, bh = band.size
    best = 0
    for x in range(bw):
        run = col = 0
        for y in range(bh):
            p = px[x, y]
            if abs(p[0] - ACCENT[0]) + abs(p[1] - ACCENT[1]) + \
                    abs(p[2] - ACCENT[2]) < TOLERANCE:
                col += 1
                run = max(run, col)
            else:
                col = 0
        best = max(best, run)
    return best


if __name__ == '__main__':
    for p in sys.argv[1:]:
        px = tallest_column(p)
        print(f'{p.split("/")[-1]:28s} tallest accent column = {px:3d} px'
              f'  (~{px / 2:.1f}dp)')
