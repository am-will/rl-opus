"""Compare the tone RESPONSE of a Godot capture against a Blender still.

    python3 tools/champions_field_opus/tone_compare.py <blender.png> <godot.png>

Region means catch level errors but confound two very different faults. If the
whole rig is 20% hot, every percentile of the luminance histogram shifts up by
the same ratio and the distribution keeps its shape. If instead the tone curve
disagrees -- Godot's AgX against Blender's AgX plus a Punchy look -- the
shadows and the highlights move in opposite directions and no exposure will
ever fit both. Printing the percentiles side by side tells you which one you
have before you spend captures tuning the wrong thing.

Also prints the mean hue error in the shadows, mids and highlights, since a
tint that only shows up in one band is a light-colour problem rather than a
grade problem.
"""

import sys

import numpy as np
from PIL import Image

PCTS = [1, 5, 10, 25, 50, 75, 90, 95, 99]


def load(path, size=None):
    img = Image.open(path).convert("RGB")
    if size and img.size != size:
        img = img.resize(size, Image.LANCZOS)
    return np.asarray(img).astype(np.float64)


def luma(a):
    return a[..., 0] * 0.2126 + a[..., 1] * 0.7152 + a[..., 2] * 0.0722


def main():
    got = load(sys.argv[2])
    ref = load(sys.argv[1], (got.shape[1], got.shape[0]))

    lr, lg = luma(ref), luma(got)
    pr = np.percentile(lr, PCTS)
    pg = np.percentile(lg, PCTS)

    print(f"{'pct':>5} {'blender':>9} {'godot':>9} {'delta':>8} {'ratio':>7}")
    for p, a, b in zip(PCTS, pr, pg):
        ratio = b / a if a > 0.5 else float("nan")
        print(f"{p:>4}% {a:9.1f} {b:9.1f} {b - a:+8.1f} {ratio:7.3f}")

    # A pure exposure error keeps the ratio flat across the range. A curve
    # error makes it slope: >1 in the highlights and <1 in the shadows, or
    # the reverse.
    lo = pg[1] / pr[1] if pr[1] > 0.5 else float("nan")
    hi = pg[-2] / pr[-2] if pr[-2] > 0.5 else float("nan")
    print(f"\nshadow ratio (5%) {lo:.3f}   highlight ratio (95%) {hi:.3f}"
          f"   -> {'CURVE mismatch' if abs(hi - lo) > 0.12 else 'level only'}")

    # Colour, split by how bright the pixel is in the reference.
    print(f"\n{'band':>10} {'blender R G B':>22} {'godot R G B':>22}")
    for name, lo_l, hi_l in (("shadows", 0, 60), ("mids", 60, 140),
                             ("highs", 140, 256)):
        m = (lr >= lo_l) & (lr < hi_l)
        if m.sum() < 100:
            continue
        a = ref[m].mean(axis=0)
        b = got[m].mean(axis=0)
        print(f"{name:>10} {a[0]:7.1f}{a[1]:7.1f}{a[2]:7.1f}  "
              f"{b[0]:7.1f}{b[1]:7.1f}{b[2]:7.1f}   "
              f"delta {b[0] - a[0]:+6.1f}{b[1] - a[1]:+6.1f}{b[2] - a[2]:+6.1f}")


main()
