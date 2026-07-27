"""Build a Blender / Godot progress sheet across the three measured shots.

    python3 tools/champions_field_opus/progress_sheet.py <out.png> <tag> [tag ...]

Each column is a shot; each row is a stage. Row 0 is always the Blender
reference, so the eye compares down a column rather than across a page. Tags
name captures in renders/godot_fidelity, e.g. `base v2`.

Reference stills come from REFERENCES.md's table -- see that file for why the
mapping is not just <shot>.png.
"""

import os
import sys

from PIL import Image, ImageDraw

# shot -> the one current Blender still, per renders/champions_field_opus/REFERENCES.md
REFS = {
    "hero": "now_hero",
    "kickoff": "brand2_kickoff",
    "broadcast": "ball2_broadcast",
}

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
BLENDER = os.path.join(ROOT, "renders", "champions_field_opus")
GODOT = os.path.join(ROOT, "renders", "godot_fidelity")

W = 640           # per-cell width; height follows 16:9
H = W * 9 // 16
PAD = 6
LABEL = 20


def cell(path):
    if not os.path.exists(path):
        return None
    return Image.open(path).convert("RGB").resize((W, H), Image.LANCZOS)


def main():
    out = sys.argv[1]
    tags = sys.argv[2:]
    rows = ["BLENDER"] + tags
    shots = list(REFS)

    sheet = Image.new(
        "RGB",
        (len(shots) * (W + PAD) - PAD, len(rows) * (H + PAD + LABEL) - PAD),
        (12, 12, 14))
    d = ImageDraw.Draw(sheet)

    for ri, row in enumerate(rows):
        y = ri * (H + PAD + LABEL)
        for ci, shot in enumerate(shots):
            x = ci * (W + PAD)
            if ri == 0:
                img = cell(os.path.join(BLENDER, REFS[shot] + ".png"))
                tag = f"BLENDER  {shot}  ({REFS[shot]}.png)"
                col = (120, 255, 160)
            else:
                img = cell(os.path.join(GODOT, f"{row}_{shot}.png"))
                tag = f"GODOT  {shot}  [{row}]"
                col = (255, 220, 100)
            d.text((x + 4, y + 4), tag, fill=col)
            if img:
                sheet.paste(img, (x, y + LABEL))
            else:
                d.text((x + W // 3, y + LABEL + H // 2), "(no capture)",
                       fill=(90, 90, 90))

    sheet.save(out)
    print(f"[sheet] {out}  ({sheet.width}x{sheet.height})")


main()
