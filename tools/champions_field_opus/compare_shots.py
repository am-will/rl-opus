"""Diff a Godot capture against the matching Blender still.

    python3 tools/champions_field_opus/compare_shots.py <blender.png> <godot.png> [out.png]

The Godot cameras are ports of `cf/shots.py`, so the two frames are the same
geometry from the same place and every difference is lighting, material or
grade. Prints per-region mean luminance and saturation for five bands that
matter -- roof, crowd, boards, far pitch, near pitch -- and writes a stacked
comparison sheet so the two can be read side by side.
"""

import sys

from PIL import Image, ImageDraw, ImageStat

# name -> (x0, y0, x1, y1) in normalised frame coordinates
REGIONS = {
    "roof":       (0.30, 0.00, 0.70, 0.10),
    "crowd":      (0.10, 0.28, 0.90, 0.40),
    "boards":     (0.05, 0.44, 0.45, 0.52),
    "pitch_far":  (0.35, 0.56, 0.65, 0.64),
    "pitch_near": (0.30, 0.82, 0.70, 0.98),
}


def stats(img, box):
    w, h = img.size
    crop = img.crop((int(box[0] * w), int(box[1] * h),
                     int(box[2] * w), int(box[3] * h)))
    r, g, b = ImageStat.Stat(crop).mean
    lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
    sat = 0.0 if max(r, g, b) == 0 else (max(r, g, b) - min(r, g, b)) / max(r, g, b)
    return lum, sat


def main():
    ref_path, got_path = sys.argv[1], sys.argv[2]
    out = sys.argv[3] if len(sys.argv) > 3 else None

    got = Image.open(got_path).convert("RGB")
    ref = Image.open(ref_path).convert("RGB").resize(got.size, Image.LANCZOS)

    print(f"{'region':<11} {'blender':>16}   {'godot':>16}   delta")
    print(f"{'':<11} {'lum   sat':>16}   {'lum   sat':>16}")
    for name, box in REGIONS.items():
        rl, rs = stats(ref, box)
        gl, gs = stats(got, box)
        print(f"{name:<11} {rl:7.1f} {rs:6.2f}   {gl:7.1f} {gs:6.2f}   "
              f"lum {gl - rl:+6.1f}  sat {gs - rs:+5.2f}")

    rl, _ = stats(ref, (0.0, 0.0, 1.0, 1.0))
    gl, _ = stats(got, (0.0, 0.0, 1.0, 1.0))
    print(f"{'FRAME':<11} {rl:7.1f}          {gl:7.1f}          lum {gl - rl:+6.1f}")

    if out:
        w, h = got.size
        sheet = Image.new("RGB", (w, h * 2 + 6), (0, 0, 0))
        sheet.paste(ref, (0, 0))
        sheet.paste(got, (0, h + 6))
        d = ImageDraw.Draw(sheet)
        d.text((12, 10), "BLENDER (EEVEE, AgX Punchy)", fill=(255, 255, 0))
        d.text((12, h + 16), "GODOT", fill=(255, 255, 0))
        sheet.save(out)
        print(f"[sheet] {out}")


main()
