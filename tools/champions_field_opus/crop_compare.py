"""Zoom into matching regions of a Blender still and a Godot capture.

    python3 tools/champions_field_opus/crop_compare.py <blender.png> <godot.png> \
        <out.png> [region ...]

`compare_shots.py` gives per-region means, which catch level errors but say
nothing about texture: a pitch that is the right average brightness can still
be visibly wrong if the grain is an order of magnitude too coarse. This crops
the same normalised box out of both frames at 1:1 and stacks them, so material
and shader differences are readable rather than inferred.

Regions default to the four that carry the look. `--` separates them from the
paths so a bare region list works.
"""

import sys

from PIL import Image, ImageDraw

# name -> (x0, y0, x1, y1) in normalised frame coordinates
REGIONS = {
    "turf":   (0.36, 0.62, 0.64, 0.86),
    "boards": (0.30, 0.40, 0.70, 0.56),
    "crowd":  (0.10, 0.14, 0.42, 0.36),
    "pads":   (0.04, 0.70, 0.30, 0.96),
    "goal":   (0.38, 0.36, 0.62, 0.58),
    "roof":   (0.30, 0.00, 0.70, 0.14),
}

SCALE = 2       # magnify the crop so shader grain is visible at a glance
PAD = 8


def crop(img, box, size):
    w, h = size
    c = img.crop((int(box[0] * w), int(box[1] * h),
                  int(box[2] * w), int(box[3] * h)))
    return c.resize((c.width * SCALE, c.height * SCALE), Image.NEAREST)


def main():
    ref_path, got_path, out = sys.argv[1], sys.argv[2], sys.argv[3]
    names = [a for a in sys.argv[4:] if a != "--"] or ["turf", "boards", "crowd", "pads"]

    got = Image.open(got_path).convert("RGB")
    # Match the Blender still to the capture's resolution first, so the two
    # crops cover the same solid angle and the same number of pixels.
    ref = Image.open(ref_path).convert("RGB").resize(got.size, Image.LANCZOS)

    cols = []
    for name in names:
        box = REGIONS[name]
        a, b = crop(ref, box, got.size), crop(got, box, got.size)
        col = Image.new("RGB", (a.width, a.height * 2 + PAD + 18), (0, 0, 0))
        col.paste(a, (0, 18))
        col.paste(b, (0, a.height + PAD + 18))
        d = ImageDraw.Draw(col)
        d.text((4, 4), name.upper(), fill=(255, 255, 0))
        cols.append(col)

    w = sum(c.width for c in cols) + PAD * (len(cols) - 1)
    h = max(c.height for c in cols) + 18
    sheet = Image.new("RGB", (w, h), (0, 0, 0))
    x = 0
    for c in cols:
        sheet.paste(c, (x, 18))
        x += c.width + PAD
    d = ImageDraw.Draw(sheet)
    d.text((4, 4), "top: BLENDER      bottom: GODOT", fill=(0, 255, 255))
    sheet.save(out)
    print(f"[sheet] {out}  ({w}x{h})")


main()
