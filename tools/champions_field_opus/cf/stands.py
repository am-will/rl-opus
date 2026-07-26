"""Seating bowl, crowd, fascia boards and the roof canopy.

The bowl reuses the arena's plan curve at negative inset, so the stands follow
the same rounded octagon as the pitch and stay concentric with it all the way
out to the roof.
"""

import math
import random

from . import arena
from . import const as C
from . import util as U

# (front depth, front height, rows, tread, riser)
TIERS = [
    (1350.0, 800.0, 24, 87.5, 75.0),
    (3400.0, 3300.0, 22, 91.0, 77.0),
    (5800.0, 5700.0, 20, 90.0, 75.0),
]

ROOF_D0, ROOF_Z0 = 7500.0, 7350.0
ROOF_D1, ROOF_Z1 = 9600.0, 9900.0

DECK = (0.055, 0.058, 0.068)
CONCRETE = (0.105, 0.108, 0.118)


def _resample(pts, spacing):
    """Even-arc-length points around a closed polyline."""
    out, carry = [], 0.0
    n = len(pts)
    for i in range(n):
        a, b = pts[i], pts[(i + 1) % n]
        seg = math.hypot(b[0] - a[0], b[1] - a[1])
        t = carry
        while t < seg:
            f = t / seg
            out.append((U.lerp(a[0], b[0], f), U.lerp(a[1], b[1], f)))
            t += spacing
        carry = t - seg
    return out


def _sweep(profile, flip=False):
    """Sweep a (inset, z) profile along the plan curve. Normals face inward."""
    rings = [arena.ring(inset)[0] for inset, _ in profile]
    n = len(rings[0])
    verts = []
    for (pts, _), (_, z) in zip([(r, None) for r in rings], profile):
        verts.extend([(x, y, z) for x, y in pts])
    faces = []
    for j in range(len(profile) - 1):
        for i in range(n):
            i2 = (i + 1) % n
            a, b = j * n + i, j * n + i2
            c, d = (j + 1) * n + i, (j + 1) * n + i2
            faces.append((a, b, d, c) if flip else (a, c, d, b))
    return verts, faces


def _tier_profile(d0, z0, rows, tread, riser):
    """Stepped rake as a (inset, z) polyline. Inset is negative == outward."""
    prof = [(-d0, z0)]
    d, z = d0, z0
    for _ in range(rows):
        z += riser
        prof.append((-d, z))
        d += tread
        prof.append((-d, z))
    return prof, d, z


def build(coll, seed=5):
    rng = random.Random(seed)

    deck_mat = U.principled("CF_Deck", base=DECK, roughness=0.72)
    conc_mat = U.principled("CF_Concrete", base=CONCRETE, roughness=0.85)
    roof_mat = U.principled("CF_Roof", base=(0.075, 0.080, 0.092),
                            roughness=0.45, metallic=0.6)

    deck_v, deck_f = [], []
    conc_v, conc_f = [], []
    crowd_v, crowd_f, crowd_c = [], [], []

    tops = []
    for (d0, z0, rows, tread, riser) in TIERS:
        prof, d_end, z_end = _tier_profile(d0, z0, rows, tread, riser)
        v, f = _sweep(prof)
        deck_v, deck_f = U.merge((deck_v, deck_f), (v, f))
        tops.append((d_end, z_end))

        # Vertical fascia dropping from the tier's front edge.
        drop = z0 - (tops[-2][1] if len(tops) > 1 else 0.0)
        v, f = _sweep([(-d0, z0 - min(drop, 2600.0)), (-d0, z0)])
        conc_v, conc_f = U.merge((conc_v, conc_f), (v, f))

        # Crowd on every tread. Rows toward the back of a tier sit deeper under
        # the overhang, so they get progressively less light.
        d, z = d0, z0
        for r in range(rows):
            z += riser
            shade = 1.0 - 0.55 * (r / max(1, rows - 1)) ** 1.4
            ring_pts = arena.ring(-(d + tread * 0.5))[0]
            seats = _resample(ring_pts, 96.0)
            for si, (sx, sy) in enumerate(seats):
                if si % 27 in (0, 1):        # aisle
                    continue
                if rng.random() < 0.06:      # empty seat
                    continue
                _add_person(crowd_v, crowd_f, crowd_c, sx, sy, z, rng, shade)
            d += tread

    # Roof canopy over the top tier.
    v, f = _sweep([(-ROOF_D0, ROOF_Z0), (-ROOF_D1, ROOF_Z1)], flip=True)
    roof = U.mesh_object("CF_Roof", v, f, coll, materials=[roof_mat])
    solid = roof.modifiers.new("Thickness", "SOLIDIFY")
    solid.thickness = 1.1
    solid.offset = 1.0

    objs = {
        "deck": U.mesh_object("CF_Deck", deck_v, deck_f, coll, materials=[deck_mat]),
        "fascia": U.mesh_object("CF_Fascia", conc_v, conc_f, coll,
                                materials=[conc_mat]),
        "roof": roof,
    }

    crowd = U.mesh_object("CF_Crowd", crowd_v, crowd_f, coll,
                          materials=[_crowd_material()])
    attr = crowd.data.color_attributes.new("Col", "FLOAT_COLOR", "POINT")
    flat = [c for col in crowd_c for c in col]
    attr.data.foreach_set("color", flat)
    objs["crowd"] = crowd
    return objs


# Spectator palette: mostly dark clothing with bright team colours mixed in,
# which is what gives the reference stands their speckled look.
_PALETTE = [
    (0.55, 0.58, 0.62), (0.80, 0.82, 0.85), (0.10, 0.11, 0.13),
    (0.05, 0.22, 0.60), (0.75, 0.28, 0.05), (0.62, 0.10, 0.12),
    (0.10, 0.38, 0.20), (0.72, 0.66, 0.20), (0.35, 0.20, 0.45),
    (0.20, 0.45, 0.55), (0.88, 0.72, 0.60), (0.42, 0.30, 0.22),
]


def _add_person(verts, faces, cols, x, y, z, rng, shade=1.0):
    w = rng.uniform(34.0, 46.0)
    h = rng.uniform(78.0, 104.0)
    jx = rng.uniform(-12.0, 12.0)
    jy = rng.uniform(-12.0, 12.0)
    i = len(verts)
    hw = w * 0.5
    for dz in (0.0, h):
        for dx, dy in ((-hw, -hw), (hw, -hw), (hw, hw), (-hw, hw)):
            verts.append((x + dx + jx, y + dy + jy, z + dz))
    faces.extend([
        (i, i + 1, i + 5, i + 4), (i + 1, i + 2, i + 6, i + 5),
        (i + 2, i + 3, i + 7, i + 6), (i + 3, i, i + 4, i + 7),
        (i + 4, i + 5, i + 6, i + 7),
    ])
    base = _PALETTE[rng.randrange(len(_PALETTE))]
    # A third of the stand wears the local team's colour, which is what gives
    # the reference bowl its blue end and orange end.
    if rng.random() < 0.34:
        base = C.BLUE_HOT if y < 0 else C.ORANGE_HOT
        base = tuple(c * 0.55 for c in base)
    k = rng.uniform(0.72, 1.18) * shade
    col = (min(base[0] * k, 1.0), min(base[1] * k, 1.0), min(base[2] * k, 1.0), 1.0)
    cols.extend([col] * 8)


def _crowd_material():
    mat = U.principled("CF_Crowd", roughness=0.78)
    nt = mat.node_tree
    attr = nt.nodes.new("ShaderNodeVertexColor")
    attr.layer_name = "Col"
    attr.location = (-400, 200)
    nt.links.new(attr.outputs["Color"], U.bsdf_of(mat).inputs["Base Color"])
    return mat
