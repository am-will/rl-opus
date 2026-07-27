"""Goal frames and nets, boost pads, and the ball."""

import math
import random

from . import const as C
from . import util as U


def _team_ramp(mat, blue, orange, node_out="Base Color", strength_socket=None):
    """Drive a colour from world Y so one material serves both ends."""
    nt = mat.node_tree
    geo = nt.nodes.new("ShaderNodeNewGeometry")
    geo.location = (-1100, -200)
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    sep.location = (-920, -200)
    nt.links.new(geo.outputs["Position"], sep.inputs["Vector"])
    rng = nt.nodes.new("ShaderNodeMapRange")
    rng.location = (-740, -200)
    rng.inputs["From Min"].default_value = -0.5
    rng.inputs["From Max"].default_value = 0.5
    nt.links.new(sep.outputs["Y"], rng.inputs["Value"])
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.location = (-560, -200)
    ramp.color_ramp.interpolation = "CONSTANT"
    ramp.color_ramp.elements[0].position = 0.0
    ramp.color_ramp.elements[0].color = (*blue, 1.0)
    ramp.color_ramp.elements[1].position = 0.5
    ramp.color_ramp.elements[1].color = (*orange, 1.0)
    nt.links.new(rng.outputs["Result"], ramp.inputs["Fac"])
    bsdf = U.bsdf_of(mat)
    if node_out:
        nt.links.new(ramp.outputs["Color"], bsdf.inputs[node_out])
    return ramp


# --- materials --------------------------------------------------------------

def goal_materials(hex_img=None):
    frame = U.principled("CF_GoalFrame", base=(0.055, 0.060, 0.070),
                         roughness=0.28, metallic=0.85)

    trim = U.principled("CF_GoalTrim", roughness=0.2, metallic=0.0)
    _team_ramp(trim, C.BLUE, C.ORANGE, "Base Color")
    _team_ramp(trim, C.BLUE, C.ORANGE, "Emission Color")
    U.bsdf_of(trim).inputs["Emission Strength"].default_value = 3.4

    net = U.principled("CF_GoalNet", roughness=0.55, metallic=0.1, alpha=1.0)
    _team_ramp(net, tuple(c * 0.045 for c in C.BLUE_HOT),
               tuple(c * 0.045 for c in C.ORANGE_HOT), "Base Color")
    _team_ramp(net, C.BLUE_HOT, C.ORANGE_HOT, "Emission Color")
    U.bsdf_of(net).inputs["Emission Strength"].default_value = 0.12
    if hex_img is not None:
        nt = net.node_tree
        tex = nt.nodes.new("ShaderNodeTexImage")
        tex.image = hex_img
        tex.extension = "REPEAT"
        tex.location = (-560, 320)
        nt.links.new(tex.outputs["Alpha"], U.bsdf_of(net).inputs["Alpha"])
        net.surface_render_method = "BLENDED"
        net.use_transparent_shadow = True
    return {"frame": frame, "trim": trim, "net": net}


def _mul(nt, a, b, loc):
    """a * b as a Math node, returned so chains read left to right."""
    m = nt.nodes.new("ShaderNodeMath")
    m.operation = "MULTIPLY"
    m.location = loc
    nt.links.new(a, m.inputs[0])
    if hasattr(b, "default_value") or hasattr(b, "links"):
        nt.links.new(b, m.inputs[1])
    else:
        m.inputs[1].default_value = b
    return m.outputs[0]


def boost_materials(tex=None):
    """The four pad materials: plate, ground bloom, curtain, orb.

    The plate is the only one of the four that is matter. The other three are
    light: unlit emission with alpha shaped by the geometry's own UVs, no
    shadow, no depth of their own. Godot rebuilds all three on
    `shaders/boost_glow.gdshader` because glTF carries none of this -- a
    node-driven alpha exports as fully opaque, which is exactly how the old
    beam arrived there as a solid cone.
    """
    decal = U.principled("CF_BoostDecal", base=(0.42, 0.44, 0.46),
                         roughness=0.40, metallic=0.20)
    if tex is not None:
        nt = decal.node_tree
        bsdf = U.bsdf_of(decal)
        col_img, emit_img = tex
        base = nt.nodes.new("ShaderNodeTexImage")
        base.image = col_img
        base.interpolation = "Cubic"
        base.extension = "EXTEND"
        base.location = (-620, 260)
        nt.links.new(base.outputs["Color"], bsdf.inputs["Base Color"])
        glow = nt.nodes.new("ShaderNodeTexImage")
        glow.image = emit_img
        glow.interpolation = "Cubic"
        glow.extension = "EXTEND"
        glow.location = (-620, -80)
        nt.links.new(glow.outputs["Color"], bsdf.inputs["Emission Color"])
        bsdf.inputs["Emission Strength"].default_value = 2.4

    # --- the curtain --------------------------------------------------------
    # Alpha falls off up V so the sheet dissolves into air, tapers at both ends
    # in U so an arc has no vertical edge, and is broken up by noise so it
    # reads as something burning rather than a pane of orange glass.
    beam = U.principled("CF_BoostBeam", base=(0.0, 0.0, 0.0), roughness=1.0,
                        emission=(1.0, 0.34, 0.05), emission_strength=4.0)
    nt = beam.node_tree
    coord = nt.nodes.new("ShaderNodeTexCoord")
    coord.location = (-1200, -260)
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    sep.location = (-1020, -260)
    nt.links.new(coord.outputs["UV"], sep.inputs["Vector"])

    up = nt.nodes.new("ShaderNodeValToRGB")
    up.location = (-840, -120)
    up.color_ramp.interpolation = "EASE"
    up.color_ramp.elements[0].position = 0.0
    up.color_ramp.elements[0].color = (0.34, 0.34, 0.34, 1.0)
    up.color_ramp.elements[1].position = 0.78
    up.color_ramp.elements[1].color = (0.0, 0.0, 0.0, 1.0)
    nt.links.new(sep.outputs["Y"], up.inputs["Fac"])

    # Taper BOTH ends of an arc, which a ColorRamp on U alone cannot do -- it
    # is monotonic, so it can only fade one side and the other keeps a hard
    # vertical edge. min(u, 1 - u) folds the sheet about its middle first.
    flip = nt.nodes.new("ShaderNodeMath")
    flip.operation = "SUBTRACT"
    flip.location = (-840, -400)
    flip.inputs[0].default_value = 1.0
    nt.links.new(sep.outputs["X"], flip.inputs[1])
    fold = nt.nodes.new("ShaderNodeMath")
    fold.operation = "MINIMUM"
    fold.location = (-660, -400)
    nt.links.new(sep.outputs["X"], fold.inputs[0])
    nt.links.new(flip.outputs[0], fold.inputs[1])
    ends = nt.nodes.new("ShaderNodeMapRange")
    ends.location = (-480, -400)
    ends.interpolation_type = "SMOOTHSTEP"
    ends.inputs["From Min"].default_value = 0.0
    ends.inputs["From Max"].default_value = 0.16
    nt.links.new(fold.outputs[0], ends.inputs["Value"])

    # Stretched vertically so the noise reads as strands drawn up the sheet
    # rather than as blotches on it.
    stretch = nt.nodes.new("ShaderNodeMapping")
    stretch.location = (-1020, -680)
    stretch.inputs["Scale"].default_value = (7.0, 1.6, 1.0)
    nt.links.new(coord.outputs["UV"], stretch.inputs["Vector"])
    noise = nt.nodes.new("ShaderNodeTexNoise")
    noise.location = (-840, -680)
    noise.inputs["Scale"].default_value = 2.4
    noise.inputs["Detail"].default_value = 4.0
    noise.inputs["Roughness"].default_value = 0.62
    nt.links.new(stretch.outputs["Vector"], noise.inputs["Vector"])
    # Erosion, not dimming. Remapping the noise through a threshold clips it
    # to nothing over part of the sheet, so the curtain tears into strands with
    # a ragged edge; multiplying by it merely made an even sheet blotchy.
    flicker = nt.nodes.new("ShaderNodeMapRange")
    flicker.location = (-620, -680)
    flicker.interpolation_type = "SMOOTHSTEP"
    flicker.inputs["From Min"].default_value = 0.34
    flicker.inputs["From Max"].default_value = 0.78
    flicker.inputs["To Min"].default_value = 0.0
    flicker.inputs["To Max"].default_value = 1.30
    nt.links.new(noise.outputs["Fac"], flicker.inputs["Value"])

    # Hot where it leaves the vent, cooling as it goes up. A single flat orange
    # is the other half of why the old beam read as plastic rather than fire.
    heat = nt.nodes.new("ShaderNodeValToRGB")
    heat.location = (-840, 180)
    heat.color_ramp.interpolation = "EASE"
    heat.color_ramp.elements[0].position = 0.0
    heat.color_ramp.elements[0].color = (1.00, 0.78, 0.40, 1.0)
    heat.color_ramp.elements[1].position = 0.55
    heat.color_ramp.elements[1].color = (1.00, 0.22, 0.02, 1.0)
    nt.links.new(sep.outputs["Y"], heat.inputs["Fac"])
    nt.links.new(heat.outputs["Color"], U.bsdf_of(beam).inputs["Emission Color"])

    a = _mul(nt, up.outputs["Color"], ends.outputs["Result"], (-420, -260))
    a = _mul(nt, a, flicker.outputs["Result"], (-240, -300))
    nt.links.new(a, U.bsdf_of(beam).inputs["Alpha"])
    beam.surface_render_method = "BLENDED"
    beam.use_transparent_shadow = False

    # --- ground bloom -------------------------------------------------------
    # The light the pad throws on the turf around it. Flat, so it costs one
    # quad, and radial so it has no edge.
    glow = U.principled("CF_BoostGlow", base=(0.0, 0.0, 0.0), roughness=1.0,
                        emission=(1.0, 0.42, 0.07), emission_strength=1.1)
    nt = glow.node_tree
    coord = nt.nodes.new("ShaderNodeTexCoord")
    coord.location = (-900, -300)
    centre = nt.nodes.new("ShaderNodeVectorMath")
    centre.operation = "SUBTRACT"
    centre.location = (-720, -300)
    centre.inputs[1].default_value = (0.5, 0.5, 0.0)
    nt.links.new(coord.outputs["UV"], centre.inputs[0])
    dist = nt.nodes.new("ShaderNodeVectorMath")
    dist.operation = "LENGTH"
    dist.location = (-540, -300)
    nt.links.new(centre.outputs["Vector"], dist.inputs[0])
    fall = nt.nodes.new("ShaderNodeMapRange")
    fall.location = (-360, -300)
    fall.inputs["From Min"].default_value = 0.06
    fall.inputs["From Max"].default_value = 0.5
    fall.inputs["To Min"].default_value = 0.75
    fall.inputs["To Max"].default_value = 0.0
    nt.links.new(dist.outputs["Value"], fall.inputs["Value"])
    pow_ = nt.nodes.new("ShaderNodeMath")
    pow_.operation = "POWER"
    pow_.location = (-180, -300)
    pow_.inputs[1].default_value = 2.2
    nt.links.new(fall.outputs["Result"], pow_.inputs[0])
    nt.links.new(pow_.outputs[0], U.bsdf_of(glow).inputs["Alpha"])
    glow.surface_render_method = "BLENDED"
    glow.use_transparent_shadow = False

    # --- the orb ------------------------------------------------------------
    # Only the 100s carry one. Alpha follows how squarely the surface faces the
    # camera, so it is dense through the middle and gone at the silhouette --
    # a ball of light rather than a lit ball.
    orb = U.principled("CF_BoostOrb", base=(0.20, 0.07, 0.02), roughness=0.14,
                       metallic=0.45, emission=(1.0, 0.55, 0.14),
                       emission_strength=2.6)
    nt = orb.node_tree
    facing = nt.nodes.new("ShaderNodeLayerWeight")
    facing.location = (-900, -300)
    facing.inputs["Blend"].default_value = 0.5
    # `Facing` is 0 head-on and 1 at the silhouette, i.e. the inverse of what a
    # ball of light wants -- hot through the middle, sodium orange at the edge.
    head_on = nt.nodes.new("ShaderNodeMath")
    head_on.operation = "SUBTRACT"
    head_on.location = (-720, -300)
    head_on.inputs[0].default_value = 1.0
    nt.links.new(facing.outputs["Facing"], head_on.inputs[1])

    # Opaque and polished rather than a ball of alpha, because the reference
    # orb is a *thing with a light in it*: it takes a hard specular off the
    # floodlights and picks up the arena around it. A transparent emissive
    # sphere can do neither -- it has no surface to reflect with, so however
    # bright it is made it stays a flat disc of colour.
    tint = nt.nodes.new("ShaderNodeValToRGB")
    tint.location = (-540, -80)
    tint.color_ramp.interpolation = "EASE"
    tint.color_ramp.elements[0].position = 0.02
    tint.color_ramp.elements[0].color = (1.00, 0.24, 0.03, 1.0)
    tint.color_ramp.elements[1].position = 0.82
    tint.color_ramp.elements[1].color = (1.00, 0.86, 0.55, 1.0)
    nt.links.new(head_on.outputs[0], tint.inputs["Fac"])
    nt.links.new(tint.outputs["Color"], U.bsdf_of(orb).inputs["Emission Color"])

    # Convection mottling, in object space so it does not swim with the camera.
    coord = nt.nodes.new("ShaderNodeTexCoord")
    coord.location = (-900, -560)
    mottle = nt.nodes.new("ShaderNodeTexNoise")
    mottle.location = (-720, -560)
    mottle.inputs["Scale"].default_value = 7.0
    mottle.inputs["Detail"].default_value = 4.0
    nt.links.new(coord.outputs["Object"], mottle.inputs["Vector"])
    mrange = nt.nodes.new("ShaderNodeMapRange")
    mrange.location = (-540, -560)
    mrange.inputs["To Min"].default_value = 2.2
    mrange.inputs["To Max"].default_value = 3.0
    nt.links.new(mottle.outputs["Fac"], mrange.inputs["Value"])
    nt.links.new(mrange.outputs["Result"],
                 U.bsdf_of(orb).inputs["Emission Strength"])

    return {"decal": decal, "beam": beam, "glow": glow, "orb": orb}


# --- goals ------------------------------------------------------------------

FRAME_R = 42.0        # goal frame tube radius
TRIM_R = 16.0         # neon pinstripe radius
FRAME_PROUD = 44.0    # how far the frame stands off the wall surface
TOP_CORNER = 210.0    # rounding on the two top corners


def goal_frame_path(side, r, samples_leg=14, samples_arc=9, samples_bar=8):
    """Centreline of one goal frame, as an open inverted U.

    Two things this has to get right, both of which the first version didn't:

    * It is *open at the bottom*. A closed rounded rectangle puts a rail across
      the mouth at floor level -- a lip the ball would hit on the way in.
    * The centreline is offset outward from the mouth by exactly the tube
      radius, so the tube's inner surface lands on the real goal boundary
      (x = +/-GOAL_HALF_W, z = GOAL_H) instead of floating around it.

    The legs also track the wall's floor fillet in Y, so they lie on the ramp
    rather than punching through it.
    """
    px = C.GOAL_HALF_W + r          # post centreline, inner face on the post
    zt = C.GOAL_H + r               # crossbar centreline, inner face on the lintel
    z_arc = zt - TOP_CORNER
    x_arc = px - TOP_CORNER

    def y_at(z):
        # Sit FRAME_PROUD in front of whatever the wall surface is doing here.
        return side * (C.BACK_Y - C.wall_inset_at_z(z) - FRAME_PROUD)

    def leg(sx, upward):
        # Dense low down where the ramp curves, sparse up the straight run.
        zs = [-60.0]
        zs += [C.RAMP_R * (k / samples_leg) ** 0.65 for k in range(1, samples_leg + 1)]
        zs += [C.RAMP_R + (z_arc - C.RAMP_R) * k / 4 for k in range(1, 5)]
        zs = sorted(set(zs))
        if not upward:
            zs = zs[::-1]
        return [(sx * px, y_at(max(z, 0.0)), z) for z in zs]

    pts = leg(1, upward=True)
    for cx, cz in U.arc_points(x_arc, z_arc, TOP_CORNER, 0.0, math.pi / 2, samples_arc)[1:]:
        pts.append((cx, y_at(cz), cz))
    for k in range(1, samples_bar):
        pts.append((U.lerp(x_arc, -x_arc, k / samples_bar), y_at(zt), zt))
    for cx, cz in U.arc_points(-x_arc, z_arc, TOP_CORNER, math.pi / 2, math.pi,
                               samples_arc):
        pts.append((cx, y_at(cz), cz))
    pts += leg(-1, upward=False)[1:]
    return pts


def build_goals(coll, mats):
    """Arched tubular frame proud of each mouth, plus the hex net cavity."""
    frame_v, frame_f = [], []
    trim_v, trim_f = [], []
    net_v, net_f, net_uv = [], [], []

    for side in (1, -1):
        wall_y = C.BACK_Y * side

        path = goal_frame_path(side, FRAME_R)
        v, f = U.sweep_tube_3d(path, FRAME_R, segments=14)
        frame_v, frame_f = U.merge((frame_v, frame_f), (v, f))

        # Neon pinstripe riding the front face of the frame.
        trim = [(x, y - side * (FRAME_R - TRIM_R + 4.0), z) for x, y, z in path]
        v, f = U.sweep_tube_3d(trim, TRIM_R, segments=10)
        trim_v, trim_f = U.merge((trim_v, trim_f), (v, f))

        # Net: the pocket's five inner faces pulled in slightly, carrying the
        # hex alpha map so you see through it into the cavity.
        inset = 34.0
        gx = C.GOAL_HALF_W - inset
        y0 = wall_y
        y1 = (C.BACK_Y + C.GOAL_DEPTH) * side - side * inset
        zt = C.GOAL_H - 2.0

        def quad(a, b, c, d, uv):
            i = len(net_v)
            net_v.extend([a, b, c, d])
            net_f.append((i, i + 1, i + 2, i + 3))
            net_uv.extend(uv)

        uw = (2 * gx) / 96.0
        ud = abs(y1 - y0) / 96.0
        uh = zt / 55.4
        quad((-gx, y1, 0), (gx, y1, 0), (gx, y1, zt), (-gx, y1, zt),
             [(0, 0), (uw, 0), (uw, uh), (0, uh)])
        for sx in (1, -1):
            quad((sx * gx, y0, 0), (sx * gx, y1, 0),
                 (sx * gx, y1, zt), (sx * gx, y0, zt),
                 [(0, 0), (ud, 0), (ud, uh), (0, uh)])
        quad((-gx, y0, zt), (gx, y0, zt), (gx, y1, zt), (-gx, y1, zt),
             [(0, 0), (uw, 0), (uw, abs(y1 - y0) / 55.4), (0, abs(y1 - y0) / 55.4)])

    out = {}
    out["frame"] = U.mesh_object("CF_GoalFrame", frame_v, frame_f, coll,
                                 materials=[mats["frame"]], shade_smooth=True)
    out["trim"] = U.mesh_object("CF_GoalTrim", trim_v, trim_f, coll,
                                materials=[mats["trim"]], shade_smooth=True)
    out["net"] = U.mesh_object("CF_GoalNet", net_v, net_f, coll,
                               materials=[mats["net"]], uvs=net_uv)
    return out


# --- boost ------------------------------------------------------------------

DECAL_Z = 1.5      # uu -- 1.5 cm. A decal sitting on the deck, not a step.
HALO_Z = 2.4       # the ground bloom, a hair above the plate

# Everything on a pad is a multiple of that pad's radius, so the 100 and the 12
# stay in proportion and there is one set of numbers to tune rather than two.
#
# VENT_R and VENT_SPAN have to match the slots painted in
# `textures._pad_big` -- the curtains stand *in* the vents, and 0.05 either way
# is the difference between light coming out of a slot and light hovering
# beside one.
VENT_R = 0.755
VENT_SPAN = 0.30
VENT_H = 0.62
VENT_FLARE = 1.10          # top radius over bottom: curtains lean outward

COLUMN_R = 0.36            # the main plume over a big pad
COLUMN_H = 1.05

SMALL_SLEEVE_R = 0.42      # the 12s get a low shimmer and nothing more
SMALL_SLEEVE_H = 0.30

HALO_R = 1.55              # ground bloom, as a multiple of the pad radius

# A closed column is mapped into the middle of U so the material's end taper
# never reaches its seam. See `_curtain`.
CLOSED_UV = {"u0": 0.22, "u1": 0.78}


def _uv_cell(dx, dy, r, big):
    """Pad-local offset (uu) -> atlas UV.

    `textures.build_boost` paints the two faces side by side in one map, big on
    the left half and small on the right, each spanning -1..1 pad radii.
    """
    return ((0.25 if big else 0.75) + 0.25 * dx / r, 0.5 + 0.5 * dy / r)


def _plate(cx, cy, z, r, big, sides=96):
    """A pad's deck plate: one flat polygon carrying the painted face.

    The 100 is a four-armed star (`const.pad_lobe`, the same outline the
    texture is painted to) and the 12 is a hexagon. No thickness either way, so
    there is no lip for a car to catch on.
    """
    verts, uvs = [], []
    n = sides if big else 6
    for k in range(n):
        a = math.tau * k / n
        rad = C.pad_lobe(a, r) if big else r
        dx, dy = rad * math.cos(a), rad * math.sin(a)
        verts.append((cx + dx, cy + dy, z))
        uvs.append(_uv_cell(dx, dy, r, big))
    return verts, [tuple(range(n))], uvs


def _quad(cx, cy, z, r):
    """Flat square with UV 0..1, for the radial ground bloom."""
    return ([(cx - r, cy - r, z), (cx + r, cy - r, z),
             (cx + r, cy + r, z), (cx - r, cy + r, z)],
            [(0, 1, 2, 3)],
            [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)])


def _curtain(cx, cy, z0, r0, r1, h, a0, a1, segs=24, closed=False,
             u0=0.0, u1=1.0, wobble=0.0, lobes=3):
    """A sheet of light standing on the deck. U runs along it, V up it.

    An arc, not a cone. The pads used to sweep a hex ring in to a point, and a
    tapered solid is a *shape* -- a traffic cone -- that no amount of emission
    argues you out of. A vertical sheet contributes no silhouette of its own,
    so what you see is only the falloff the material paints on it.

    `u0`/`u1` bound the U range because the material fades both ends of a sheet
    to nothing: a closed column has no ends to fade, so it is mapped into the
    middle of the range instead and never reaches the taper -- otherwise the
    seam where U wraps draws a dark stripe up the plume.
    """
    verts, faces, uvs = [], [], []
    n = segs if closed else segs + 1
    for r, z in ((r0, z0), (r1, z0 + h)):
        for k in range(n):
            a = a0 + (a1 - a0) * (k / segs)
            # A perfect cylinder reads as a tube because its silhouette is two
            # dead-straight verticals. Pushing the radius in and out around the
            # sweep breaks them without adding a single triangle.
            rr = r * (1.0 + wobble * math.sin(lobes * a))
            verts.append((cx + rr * math.cos(a), cy + rr * math.sin(a), z))
    for k in range(segs):
        j = (k + 1) % n
        faces.append((k, j, n + j, n + k))
        ua, ub = u0 + (u1 - u0) * k / segs, u0 + (u1 - u0) * (k + 1) / segs
        uvs.extend([(ua, 0.0), (ub, 0.0), (ub, 1.0), (ua, 1.0)])
    return verts, faces, uvs


def _sphere(cx, cy, cz, r, rings=18, segs=28):
    """UV sphere, triangulated at the poles so no face has a doubled vertex."""
    verts, faces, uvs = [], [], []
    row = segs + 1
    for i in range(rings + 1):
        phi = math.pi * i / rings
        for j in range(row):
            th = math.tau * j / segs
            verts.append((cx + r * math.sin(phi) * math.cos(th),
                          cy + r * math.sin(phi) * math.sin(th),
                          cz + r * math.cos(phi)))
    for i in range(rings):
        for j in range(segs):
            a, b = i * row + j, i * row + j + 1
            c, d = a + row, b + row
            uv = [(j / segs, i / rings), (j / segs, (i + 1) / rings),
                  ((j + 1) / segs, (i + 1) / rings), ((j + 1) / segs, i / rings)]
            if i == 0:
                faces.append((a, c, d))
                uvs.extend(uv[:3])
            elif i == rings - 1:
                faces.append((a, c, b))
                uvs.extend([uv[0], uv[1], uv[3]])
            else:
                faces.append((a, c, d, b))
                uvs.extend(uv)
    return verts, faces, uvs


def build_boost(coll, mats):
    """The 34 pads: a painted plate, a bloom on the turf, and light above it.

    Nothing here has thickness or collision. The plate is a single flat polygon
    1.5 cm proud of the deck and everything above it is alpha-blended emission
    that casts no shadow, so a car crosses a pad exactly as if it were driving
    on bare floor.

    The two sizes read differently on purpose, which is the whole point of the
    rebuild: a 100 stands four vent curtains and a plume on its star plate and
    hangs an orb over it, while a 12 is a hex plate with a lit core and a low
    shimmer -- it emits a bit of light, it does not put on a show.
    """
    plate = ([], [], [])
    halo = ([], [], [])
    beam = ([], [], [])
    orb = ([], [], [])

    def add(dst, piece):
        v, f, uv = piece
        off = len(dst[0])
        dst[0].extend(v)
        dst[1].extend(tuple(i + off for i in fc) for fc in f)
        dst[2].extend(uv)

    for x, y, _z, big in C.BOOST_PADS:
        r = C.BIG_PAD_R if big else C.SMALL_PAD_R
        add(plate, _plate(x, y, DECAL_Z, r, big))
        add(halo, _quad(x, y, HALO_Z, r * HALO_R))

        if not big:
            add(beam, _curtain(x, y, DECAL_Z, r * SMALL_SLEEVE_R,
                               r * SMALL_SLEEVE_R * 1.15, r * SMALL_SLEEVE_H,
                               0.0, math.tau, segs=14, closed=True,
                               wobble=0.12, **CLOSED_UV))
            continue

        for k in range(4):
            a = math.tau * k / 4
            add(beam, _curtain(x, y, DECAL_Z, r * VENT_R, r * VENT_R * VENT_FLARE,
                               r * VENT_H, a - VENT_SPAN, a + VENT_SPAN, segs=8))
        # One sleeve, not two. A cylinder is drawn front and back, so a second
        # one inside it stacks four layers of alpha and the plume goes solid.
        add(beam, _curtain(x, y, DECAL_Z, r * COLUMN_R, r * COLUMN_R * 1.18,
                           r * COLUMN_H, 0.0, math.tau, segs=24, closed=True,
                           wobble=0.16, **CLOSED_UV))
        add(orb, _sphere(x, y, C.ORB_Z, C.ORB_R))

    out = {
        "decal": U.mesh_object("CF_BoostDecal", plate[0], plate[1], coll,
                               materials=[mats["decal"]], uvs=plate[2]),
        "glow": U.mesh_object("CF_BoostGlow", halo[0], halo[1], coll,
                              materials=[mats["glow"]], uvs=halo[2]),
        "beam": U.mesh_object("CF_BoostBeam", beam[0], beam[1], coll,
                              materials=[mats["beam"]], uvs=beam[2]),
        "orb": U.mesh_object("CF_BoostOrb", orb[0], orb[1], coll,
                             materials=[mats["orb"]], uvs=orb[2],
                             shade_smooth=True),
    }
    # Light, not matter: it casts nothing and it is not collision.
    for ob in out.values():
        ob.visible_shadow = False
    return out


# --- ball -------------------------------------------------------------------
#
# The panels used to be a flat hex tile wrapped round a UV sphere, which is the
# one thing a sphere will not take: an equirectangular map's rows converge at
# the poles, so the hexes sheared as they climbed and collapsed into a rosette
# on top. No texture fixes that -- a sphere has no distortion-free flat unwrap.
#
# So the panels are geometry now. Subdividing an icosahedron and taking its
# dual gives a Goldberg polyhedron: every cell the same size, every cell a
# hexagon apart from twelve pentagons, one on each original icosahedron vertex.
# Those twelve are not a defect to be tuned out -- Euler forbids tiling a closed
# surface with hexagons alone, which is why a real football has exactly twelve
# pentagons too. What the ball no longer has anywhere is a stretched panel.

BALL_FREQ = 3          # G(3,0): 12 pentagons + 80 hexagons, matching the old tiling
BALL_GAP = 0.10        # corner inset toward the cell centre, share of cell radius
BALL_FLARE = 0.30      # how much of that inset the chamfer gives back
BALL_CHAMFER = 0.006   # chamfer drop, share of R
BALL_SHELL = 0.976     # dark under-shell radius, share of R
BALL_SKIRT = 0.958     # panel wall bottom -- inside the shell, so no gap opens


def _unit(v):
    n = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])
    return (v[0] / n, v[1] / n, v[2] / n)


def _mix(a, b, t):
    return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t,
            a[2] + (b[2] - a[2]) * t)


def _cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0])


def _dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def _icosahedron():
    """Unit icosahedron, poles first.

    Not the usual (0, +-1, +-t) form: that one puts an edge at the top of the
    ball, and `verify.py` measures the ball's radius off its z extent, so a
    dual cell has to be *centred* on each pole for the mesh to reach exactly R
    there. Pole, upper ring of five, lower ring of five offset by half a step,
    pole.
    """
    lat = math.atan(0.5)
    verts = [(0.0, 0.0, 1.0)]
    for band, sign in ((0.0, 1.0), (0.5, -1.0)):
        for i in range(5):
            a = math.tau * (i + band) / 5
            verts.append((math.cos(lat) * math.cos(a),
                          math.cos(lat) * math.sin(a), sign * math.sin(lat)))
    verts.append((0.0, 0.0, -1.0))

    faces = []
    for i in range(5):
        j = (i + 1) % 5
        faces.append((0, 1 + i, 1 + j))          # north cap
        faces.append((1 + i, 6 + i, 1 + j))      # upper band
        faces.append((1 + j, 6 + i, 6 + j))      # lower band
        faces.append((11, 6 + j, 6 + i))         # south cap
    return verts, faces


def _subdivide(verts, faces, freq):
    """Class-I geodesic: split every triangle freq^2 ways, push out to the sphere."""
    out_v, index, out_f = [], {}, []

    def add(p):
        n = _unit(p)
        key = (round(n[0], 6), round(n[1], 6), round(n[2], 6))
        if key not in index:
            index[key] = len(out_v)
            out_v.append(n)
        return index[key]

    for ia, ib, ic in faces:
        a, b, c = verts[ia], verts[ib], verts[ic]
        rows = []
        for i in range(freq + 1):
            row = []
            for j in range(i + 1):
                u, v, w = (freq - i) / freq, (i - j) / freq, j / freq
                row.append(add((a[0] * u + b[0] * v + c[0] * w,
                                a[1] * u + b[1] * v + c[1] * w,
                                a[2] * u + b[2] * v + c[2] * w)))
            rows.append(row)
        for i in range(freq):
            for j in range(i + 1):
                out_f.append((rows[i][j], rows[i + 1][j], rows[i + 1][j + 1]))
                if j < i:
                    out_f.append((rows[i][j], rows[i + 1][j + 1], rows[i][j + 1]))
    return out_v, out_f


def _dual_cells(verts, faces):
    """The Goldberg dual: (centre, corner ring) per geodesic vertex, wound CCW
    seen from outside. A cell has as many corners as its vertex had triangles --
    six everywhere except the twelve original icosahedron vertices."""
    centres, incident = [], [[] for _ in verts]
    for f in faces:
        centres.append(_unit((sum(verts[k][0] for k in f) / 3.0,
                              sum(verts[k][1] for k in f) / 3.0,
                              sum(verts[k][2] for k in f) / 3.0)))
        for k in f:
            incident[k].append(len(centres) - 1)

    cells = []
    for vi, v in enumerate(verts):
        # Sort the surrounding face centres by angle in the tangent plane. With
        # (ref, perp, v) right-handed, increasing angle is CCW from outside.
        ref = _unit(_cross(v, (0.0, 0.0, 1.0) if abs(v[2]) < 0.9 else (1.0, 0.0, 0.0)))
        perp = _cross(v, ref)
        ring = sorted(incident[vi],
                      key=lambda fi: math.atan2(_dot(centres[fi], perp),
                                                _dot(centres[fi], ref)))
        cells.append((v, [centres[fi] for fi in ring]))
    return cells


def build_ball(coll, freq=BALL_FREQ, seed=23):
    R = C.BALL_R
    cz = C.BALL_REST_Z
    verts, faces, mat_index, smooth = [], [], [], []

    def put(d, r):
        verts.append((d[0] * r, d[1] * r, cz + d[2] * r))
        return len(verts) - 1

    # Panels. Each is its own island -- nothing is shared with its neighbours,
    # or with its own wall, so the tops shade smooth and every edge stays crisp.
    rng = random.Random(seed)
    gv, gf = _subdivide(*_icosahedron(), freq=freq)
    for centre, corners in _dual_cells(gv, gf):
        rim = [_unit(_mix(p, centre, BALL_GAP)) for p in corners]
        lip = [_unit(_mix(rim[k], corners[k], BALL_FLARE)) for k in range(len(rim))]
        mid = [_unit(_mix(p, centre, 0.5)) for p in rim]

        n = len(rim)
        top = put(centre, R)
        mid_i = [put(d, R) for d in mid]
        rim_i = [put(d, R) for d in rim]
        lip_i = [put(d, R * (1.0 - BALL_CHAMFER)) for d in lip]
        wall_t = [put(d, R * (1.0 - BALL_CHAMFER)) for d in lip]
        wall_b = [put(d, R * BALL_SKIRT) for d in lip]

        shade = rng.randrange(3)
        for k in range(n):
            k2 = (k + 1) % n
            faces.append((top, mid_i[k], mid_i[k2]))
            faces.append((mid_i[k], rim_i[k], rim_i[k2], mid_i[k2]))
            faces.append((rim_i[k], lip_i[k], lip_i[k2], rim_i[k2]))
            faces.append((wall_t[k], wall_b[k], wall_b[k2], wall_t[k2]))
            smooth.extend([True, True, True, False])
            mat_index.extend([shade] * 4)

    # Dark under-shell. The panel walls end below its surface, so the seams read
    # as grooves between panels rather than as a hole through to the inside.
    rings, segs = 24, 48
    base = len(verts)
    for i in range(rings + 1):
        phi = math.pi * i / rings
        for j in range(segs):
            th = math.tau * j / segs
            put((math.sin(phi) * math.cos(th), math.sin(phi) * math.sin(th),
                 math.cos(phi)), R * BALL_SHELL)
    for i in range(rings):
        for j in range(segs):
            j2 = (j + 1) % segs
            a, b = base + i * segs + j, base + i * segs + j2
            c, d = base + (i + 1) * segs + j, base + (i + 1) * segs + j2
            faces.append((a, c, d, b))
            smooth.append(True)
            mat_index.append(3)

    # Three near-identical greys, dealt out per panel, for the faint tonal
    # variation the old skin texture carried.
    mats = [U.principled(nm, base=col, roughness=0.30, metallic=0.15, coat=0.55)
            for nm, col in (("CF_Ball", (0.620, 0.650, 0.685)),
                            ("CF_Ball_B", (0.585, 0.615, 0.655)),
                            ("CF_Ball_C", (0.655, 0.685, 0.715)))]
    mats.append(U.principled("CF_Ball_Seam", base=(0.045, 0.050, 0.062),
                             roughness=0.55, metallic=0.0))

    return U.mesh_object("CF_Ball", verts, faces, coll, materials=mats,
                         mat_index=mat_index, shade_smooth=smooth)
