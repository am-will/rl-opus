#!/usr/bin/env python3
"""Build the Octane OEM rim's albedo map from the extracted detail mask.

    python3 tools/build_octane_rim_albedo.py

The .glb carries three images -- body, chassis, tyre -- so the rim came out of
the export as bare metal, and a bare smooth metal under a lit stadium is a
mirror: it takes the sky's colour, fills the gaps between the spokes with a
bright dish and loses the wheel's shape. The mask survives in the extracted
Unity assets as `OEM_Rim.png`.

That file is NOT an albedo map. It is greyscale (mean |R-B| = 0.14), it peaks at
121/255 and its median is 0 -- a detail/curvature mask, the same shape of asset
as `Octane_Body.png`, which is a paint mask rather than a colour. Used directly
as albedo it renders the whole wheel near-black. So the mask picks out the
spokes and this lifts them off a dark floor, which is the real Octane's read:
light spokes, dark between them.

Writes godot/SlopetLeague/assets/octane_rim_albedo.png. Deterministic -- rerun
it and the file is byte-identical, so it is safe to keep in the repo.
"""

import pathlib

import numpy as np
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "assets/octane_reference/extracted/OEM_Rim.png"
DST = ROOT / "godot/SlopetLeague/assets/octane_rim_albedo.png"

# Where an unmasked pixel lands, and how far the brightest masked pixel rises
# above it.
#
# The floor is high and the lift is modest on purpose. The mask draws the spoke
# faces DARKER than the rim lip, so a wide range around a low floor renders a
# wheel with black spokes and a bright barrel -- the opposite of the reference,
# where the spokes are the light part and the gaps between them are dark. In the
# reference that contrast is lighting and occlusion, not albedo: the whole wheel
# is one mid grey alloy. So this stays near that grey and lets the mask supply
# variation rather than the colour.
FLOOR = 0.30
LIFT = 0.32
# The mask is bottom-heavy -- p90 is 33 of a 121 maximum -- so a linear map
# leaves every spoke in the bottom third of the range. This opens it up.
GAMMA = 0.6


def main() -> None:
    mask = np.asarray(Image.open(SRC).convert("L")).astype(np.float32)
    peak = float(mask.max())
    if peak <= 0.0:
        raise SystemExit(f"{SRC} is empty")

    lifted = FLOOR + LIFT * np.power(mask / peak, GAMMA)
    out = np.clip(lifted * 255.0, 0, 255).astype(np.uint8)
    Image.fromarray(np.dstack([out, out, out]), "RGB").save(DST)
    print(f"{DST.relative_to(ROOT)}  peak={peak:.0f}  {out.min()}..{out.max()}")


if __name__ == "__main__":
    main()
