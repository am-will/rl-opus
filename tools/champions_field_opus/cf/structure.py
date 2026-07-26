"""Overhead rig: jumbotron, roof truss, LED fascia ribbons and the trophy."""

import math

from . import arena
from . import const as C
from . import stands
from . import util as U

JUMBO_Z = 5400.0
JUMBO_W = 1950.0
JUMBO_H = 1080.0


def _team_gradient(mat, socket="Emission Color", blend=2600.0):
    """Blue at -y through to orange at +y, in world space."""
    nt = mat.node_tree
    geo = nt.nodes.new("ShaderNodeNewGeometry")
    geo.location = (-1100, -200)
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    sep.location = (-920, -200)
    nt.links.new(geo.outputs["Position"], sep.inputs["Vector"])
    rng = nt.nodes.new("ShaderNodeMapRange")
    rng.location = (-740, -200)
    rng.inputs["From Min"].default_value = -blend * C.S
    rng.inputs["From Max"].default_value = blend * C.S
    nt.links.new(sep.outputs["Y"], rng.inputs["Value"])
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.location = (-560, -200)
    ramp.color_ramp.elements[0].color = (*C.BLUE_HOT, 1.0)
    ramp.color_ramp.elements[1].color = (*C.ORANGE_HOT, 1.0)
    nt.links.new(rng.outputs["Result"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], U.bsdf_of(mat).inputs[socket])
    return ramp


def build(coll, board_tex=None):
    steel = U.principled("CF_Steel", base=(0.070, 0.075, 0.088),
                         roughness=0.42, metallic=0.8)
    dark = U.principled("CF_StructDark", base=(0.030, 0.033, 0.040),
                        roughness=0.55, metallic=0.5)

    out = {}
    out.update(_jumbotron(coll, steel, dark))
    out.update(_truss(coll, steel))
    out.update(_ribbons(coll))
    out.update(_trophy(coll))
    out.update(_bunting(coll))
    if board_tex is not None:
        out.update(_hero_boards(coll, board_tex))
    return out


# --- set dressing -----------------------------------------------------------

def _bunting(coll, seed=11):
    """National flag bunting along the upper-deck fascia."""
    import random
    rng = random.Random(seed)
    verts, faces, cols = [], [], []

    palette = [
        (0.72, 0.10, 0.12), (0.10, 0.22, 0.62), (0.88, 0.86, 0.80),
        (0.90, 0.70, 0.10), (0.08, 0.42, 0.22), (0.55, 0.10, 0.45),
        (0.05, 0.30, 0.55), (0.85, 0.45, 0.08),
    ]
    d0, z0 = stands.TIERS[1][0], stands.TIERS[1][1]
    pts = arena.ring(-(d0 - 120.0))[0]
    n = len(pts)
    step = 1
    for i in range(0, n, step):
        a, b = pts[i], pts[(i + 1) % n]
        # Flag hangs from just under the fascia lip.
        top = z0 + 170.0
        bot = top - 190.0
        j = len(verts)
        verts.extend([(a[0], a[1], bot), (b[0], b[1], bot),
                      (b[0], b[1], top), (a[0], a[1], top)])
        faces.append((j, j + 3, j + 2, j + 1))
        c = palette[rng.randrange(len(palette))]
        cols.extend([(c[0], c[1], c[2], 1.0)] * 4)

    mat = U.principled("CF_Bunting", roughness=0.7)
    nt = mat.node_tree
    attr = nt.nodes.new("ShaderNodeVertexColor")
    attr.layer_name = "Col"
    attr.location = (-400, 200)
    nt.links.new(attr.outputs["Color"], U.bsdf_of(mat).inputs["Base Color"])

    ob = U.mesh_object("CF_Bunting", verts, faces, coll, materials=[mat])
    at = ob.data.color_attributes.new("Col", "FLOAT_COLOR", "POINT")
    at.data.foreach_set("color", [c for col in cols for c in col])
    return {"bunting": ob}


def _hero_boards(coll, board_tex, count=6):
    """Large branded panels facing the pitch off the lower-tier fascia."""
    col_img, emit_img = board_tex
    verts, faces, uvs = [], [], []
    d0, z0 = stands.TIERS[1][0], stands.TIERS[1][1]
    pts = arena.ring(-(d0 - 200.0))[0]
    n = len(pts)
    half = 12                                  # ring samples spanned per board
    for k in range(count):
        c = int(n * (k + 0.5) / count)
        seg = [pts[(c + t) % n] for t in range(-half, half + 1)]
        for t in range(len(seg) - 1):
            a, b = seg[t], seg[t + 1]
            u0 = 1.0 - t / (len(seg) - 1)
            u1 = 1.0 - (t + 1) / (len(seg) - 1)
            j = len(verts)
            verts.extend([(a[0], a[1], z0 - 340), (b[0], b[1], z0 - 340),
                          (b[0], b[1], z0 + 460), (a[0], a[1], z0 + 460)])
            faces.append((j, j + 3, j + 2, j + 1))
            uvs.extend([(u0, 0.0), (u0, 1.0), (u1, 1.0), (u1, 0.0)])

    mat = U.principled("CF_HeroBoard", roughness=0.35)
    nt = mat.node_tree
    for img, socket, loc in ((col_img, "Base Color", (-700, 300)),
                             (emit_img, "Emission Color", (-700, -60))):
        tex = nt.nodes.new("ShaderNodeTexImage")
        tex.image = img
        tex.extension = "EXTEND"
        tex.location = loc
        nt.links.new(tex.outputs["Color"], U.bsdf_of(mat).inputs[socket])
    U.bsdf_of(mat).inputs["Emission Strength"].default_value = 2.4
    return {"boards": U.mesh_object("CF_HeroBoards", verts, faces, coll,
                                    materials=[mat], uvs=uvs)}


# --- jumbotron --------------------------------------------------------------

def _jumbotron(coll, steel, dark):
    body_v, body_f = [], []
    scr_v, scr_f, scr_uv = [], [], []

    hw = JUMBO_W / 2
    hz = JUMBO_H / 2
    v, f = U.box(0, 0, JUMBO_Z, JUMBO_W * 1.04, JUMBO_W * 1.04, JUMBO_H * 1.06)
    body_v, body_f = U.merge((body_v, body_f), (v, f))

    # Four screens, one per face, inset slightly so the housing frames them.
    faces = [((0, -1), (hw, 0)), ((0, 1), (hw, 0)), ((-1, 0), (0, hw)), ((1, 0), (0, hw))]
    for (nx, ny), _ in faces:
        cx, cy = nx * hw * 1.075, ny * hw * 1.075
        ux, uy = (-ny, nx)
        pts = []
        for sx, sz in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
            pts.append((cx + ux * sx * hw * 0.88,
                        cy + uy * sx * hw * 0.88,
                        JUMBO_Z + sz * hz * 0.82))
        i = len(scr_v)
        scr_v.extend(pts)
        scr_f.append((i, i + 1, i + 2, i + 3))
        scr_uv.extend([(0, 0), (1, 0), (1, 1), (0, 1)])

    # Hanging rigging.
    for sx in (-1, 1):
        for sy in (-1, 1):
            v, f = U.tube((sx * hw * 0.8, sy * hw * 0.8, JUMBO_Z + hz),
                          (sx * 300, sy * 300, stands.ROOF_Z1 + 1800), 26,
                          segments=6)
            body_v, body_f = U.merge((body_v, body_f), (v, f))

    screen_mat = U.emissive("CF_JumboScreen", colour=(0.5, 0.7, 1.0), strength=6.0)
    _screen_gradient(screen_mat)

    return {
        "jumbo_body": U.mesh_object("CF_JumboBody", body_v, body_f, coll,
                                    materials=[dark]),
        "jumbo_screen": U.mesh_object("CF_JumboScreen", scr_v, scr_f, coll,
                                      materials=[screen_mat], uvs=scr_uv),
    }


def _screen_gradient(mat):
    """Scanline-ish tint so the screens read as panels, not flat cards."""
    nt = mat.node_tree
    emit = [n for n in nt.nodes if n.bl_idname == "ShaderNodeEmission"][0]
    coord = nt.nodes.new("ShaderNodeTexCoord")
    coord.location = (-800, 0)
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    sep.location = (-620, 0)
    nt.links.new(coord.outputs["UV"], sep.inputs["Vector"])
    wave = nt.nodes.new("ShaderNodeMath")
    wave.operation = "MULTIPLY"
    wave.location = (-440, -120)
    wave.inputs[1].default_value = 90.0
    nt.links.new(sep.outputs["Y"], wave.inputs[0])
    sine = nt.nodes.new("ShaderNodeMath")
    sine.operation = "SINE"
    sine.location = (-280, -120)
    nt.links.new(wave.outputs[0], sine.inputs[0])
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.location = (-100, -120)
    ramp.color_ramp.elements[0].position = 0.15
    ramp.color_ramp.elements[0].color = (0.06, 0.30, 0.85, 1.0)
    ramp.color_ramp.elements[1].position = 0.9
    ramp.color_ramp.elements[1].color = (0.75, 0.88, 1.0, 1.0)
    nt.links.new(sine.outputs[0], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], emit.inputs["Color"])


# --- roof truss -------------------------------------------------------------

def _truss(coll, steel):
    verts, faces = [], []
    inner = arena.ring(-(stands.ROOF_D0 - 400.0))[0]
    outer = arena.ring(-(stands.ROOF_D1 - 200.0))[0]
    n = len(inner)
    step = max(1, n // 56)

    for i in range(0, n, step):
        xi, yi = inner[i]
        xo, yo = outer[i]
        v, f = U.tube((xi, yi, stands.ROOF_Z0 - 60), (xo, yo, stands.ROOF_Z1 - 60),
                      52, segments=6)
        verts, faces = U.merge((verts, faces), (v, f))
        # Diagonal web back to the bowl.
        v, f = U.tube((xi, yi, stands.ROOF_Z0 - 60),
                      (xi * 0.94, yi * 0.94, stands.ROOF_Z0 - 1500), 40, segments=6)
        verts, faces = U.merge((verts, faces), (v, f))

    # Two continuous chords running around the ring.
    for ring_pts, z, r in ((inner, stands.ROOF_Z0 - 60, 60),
                           (outer, stands.ROOF_Z1 - 60, 60)):
        for i in range(0, n, 2):
            a = ring_pts[i]
            b = ring_pts[(i + 2) % n]
            v, f = U.tube((a[0], a[1], z), (b[0], b[1], z), r, segments=6)
            verts, faces = U.merge((verts, faces), (v, f))

    return {"truss": U.mesh_object("CF_Truss", verts, faces, coll,
                                   materials=[steel], shade_smooth=True)}


# --- LED fascia ribbons -----------------------------------------------------

def _ribbons(coll):
    verts, faces = [], []
    for (d0, z0, _rows, _tread, _riser) in stands.TIERS:
        pts = arena.ring(-(d0 - 40.0))[0]
        n = len(pts)
        for i in range(n):
            a, b = pts[i], pts[(i + 1) % n]
            j = len(verts)
            verts.extend([(a[0], a[1], z0 - 150), (b[0], b[1], z0 - 150),
                          (b[0], b[1], z0 - 20), (a[0], a[1], z0 - 20)])
            faces.append((j, j + 3, j + 2, j + 1))

    mat = U.principled("CF_Ribbon", base=(0.02, 0.02, 0.03), roughness=0.3)
    _team_gradient(mat, "Emission Color", blend=3400.0)
    U.bsdf_of(mat).inputs["Emission Strength"].default_value = 3.5
    return {"ribbons": U.mesh_object("CF_Ribbons", verts, faces, coll,
                                     materials=[mat])}


# --- trophy -----------------------------------------------------------------

def _trophy(coll):
    """The monument behind the orange end -- Champions Field's landmark."""
    cx, cy = 0.0, C.BACK_Y + 13500.0
    base_z = 2200.0
    verts, faces = [], []

    # Stepped plinth.
    for k, (w, h) in enumerate(((6400, 700), (5200, 700), (4200, 700))):
        v, f = U.box(cx, cy, base_z + 350 + k * 700, w, w, h)
        verts, faces = U.merge((verts, faces), (v, f))

    # Flared column: a stack of rings narrowing then flaring out.
    prof = [(2600, 0), (1500, 900), (1000, 2000), (900, 3400),
            (1050, 4400), (1400, 5100)]
    z0 = base_z + 2100
    for k in range(len(prof) - 1):
        r0, h0 = prof[k]
        r1, h1 = prof[k + 1]
        seg = 28
        i = len(verts)
        for r, h in ((r0, h0), (r1, h1)):
            for s in range(seg):
                a = math.tau * s / seg
                verts.append((cx + r * math.cos(a), cy + r * math.sin(a), z0 + h))
        for s in range(seg):
            s2 = (s + 1) % seg
            faces.append((i + s, i + s2, i + seg + s2, i + seg + s))

    # The loop: a torus standing on edge, cradling a sphere.
    top_z = z0 + 5100
    R, rr = 2100.0, 190.0
    seg, tub = 44, 8
    i = len(verts)
    for s in range(seg):
        a = math.tau * s / seg
        cxp = cx + R * math.cos(a)
        czp = top_z + 1900 + R * math.sin(a)
        for t in range(tub):
            b = math.tau * t / tub
            verts.append((cxp + rr * math.cos(b) * math.cos(a),
                          cy + rr * math.sin(b),
                          czp + rr * math.cos(b) * math.sin(a)))
    for s in range(seg):
        s2 = (s + 1) % seg
        for t in range(tub):
            t2 = (t + 1) % tub
            faces.append((i + s * tub + t, i + s2 * tub + t,
                          i + s2 * tub + t2, i + s * tub + t2))

    # Sphere in the loop.
    sr, rings, segs = 900.0, 16, 24
    i = len(verts)
    for a in range(rings + 1):
        phi = math.pi * a / rings
        for b in range(segs):
            th = math.tau * b / segs
            verts.append((cx + sr * math.sin(phi) * math.cos(th),
                          cy + sr * math.sin(phi) * math.sin(th),
                          top_z + 1900 + sr * math.cos(phi)))
    for a in range(rings):
        for b in range(segs):
            b2 = (b + 1) % segs
            faces.append((i + a * segs + b, i + a * segs + b2,
                          i + (a + 1) * segs + b2, i + (a + 1) * segs + b))

    mat = U.principled("CF_Trophy", base=(0.52, 0.54, 0.58), roughness=0.22,
                       metallic=0.95)
    return {"trophy": U.mesh_object("CF_Trophy", verts, faces, coll,
                                    materials=[mat], shade_smooth=True)}
