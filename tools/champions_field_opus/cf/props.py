"""Goal frames and nets, boost pads, and the ball."""

import math

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


def boost_materials():
    decal = U.principled("CF_BoostDecal", base=(0.055, 0.045, 0.035),
                         roughness=0.45, emission=(1.0, 0.34, 0.04),
                         emission_strength=1.4)
    core = U.emissive("CF_BoostCore", colour=(1.0, 0.46, 0.07), strength=7.0)

    # Energy, not geometry: alpha falls off up the column so the beam dissolves
    # into air rather than ending on a hard edge.
    beam = U.principled("CF_BoostBeam", base=(0.0, 0.0, 0.0), roughness=1.0,
                        emission=(1.0, 0.40, 0.05), emission_strength=6.0)
    nt = beam.node_tree
    coord = nt.nodes.new("ShaderNodeTexCoord")
    coord.location = (-800, -260)
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    sep.location = (-620, -260)
    nt.links.new(coord.outputs["UV"], sep.inputs["Vector"])
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.location = (-420, -260)
    ramp.color_ramp.interpolation = "EASE"
    ramp.color_ramp.elements[0].position = 0.0
    ramp.color_ramp.elements[0].color = (0.32, 0.32, 0.32, 1.0)
    ramp.color_ramp.elements[1].position = 1.0
    ramp.color_ramp.elements[1].color = (0.0, 0.0, 0.0, 1.0)
    nt.links.new(sep.outputs["Y"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], U.bsdf_of(beam).inputs["Alpha"])
    beam.surface_render_method = "BLENDED"
    beam.use_transparent_shadow = True
    return {"decal": decal, "core": core, "beam": beam}


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


def _flat_ngon(cx, cy, z, r, sides=6, rot=0.0):
    """A single flat polygon. No thickness, therefore no lip to catch a car."""
    verts = [(cx + r * math.cos(rot + math.tau * k / sides),
              cy + r * math.sin(rot + math.tau * k / sides), z)
             for k in range(sides)]
    return verts, [tuple(range(sides))]


def _flat_ring(cx, cy, z, r0, r1, sides=30, rot=0.0):
    verts = []
    for r in (r0, r1):
        for k in range(sides):
            a = rot + math.tau * k / sides
            verts.append((cx + r * math.cos(a), cy + r * math.sin(a), z))
    faces = [(k, (k + 1) % sides, sides + (k + 1) % sides, sides + k)
             for k in range(sides)]
    return verts, faces


def _beam(cx, cy, z0, h, r_bot, r_top, sides=6, rot=0.0):
    """Open tapered column of light. UV V runs 0 at the deck to 1 at the tip,
    which is what the material fades alpha along so it reads as energy."""
    verts, faces, uvs = [], [], []
    for r, z in ((r_bot, z0), (r_top, z0 + h)):
        for k in range(sides):
            a = rot + math.tau * k / sides
            verts.append((cx + r * math.cos(a), cy + r * math.sin(a), z))
    for k in range(sides):
        j = (k + 1) % sides
        faces.append((k, j, sides + j, sides + k))
        uvs.extend([(k / sides, 0.0), ((k + 1) / sides, 0.0),
                    ((k + 1) / sides, 1.0), (k / sides, 1.0)])
    return verts, faces, uvs


def build_boost(coll, mats):
    """Boost pads as flat decals with a weightless column of light above.

    Nothing here has thickness. The pads are single flat polygons 1.5 cm proud
    of the deck and everything that rises is alpha-blended emission, so a car
    crosses a pad exactly as if it were driving on bare floor.
    """
    decal_v, decal_f = [], []
    core_v, core_f = [], []
    beam_v, beam_f, beam_uv = [], [], []

    def add_beam(*args, **kw):
        v, f, uv = _beam(*args, **kw)
        off = len(beam_v)
        beam_v.extend(v)
        beam_f.extend(tuple(i + off for i in fc) for fc in f)
        beam_uv.extend(uv)

    for x, y, _z, big in C.BOOST_PADS:
        if big:
            r = C.BIG_PAD_R
            v, f = _flat_ring(x, y, DECAL_Z, r * 0.60, r * 0.96)
            decal_v, decal_f = U.merge((decal_v, decal_f), (v, f))
            v, f = _flat_ngon(x, y, DECAL_Z + 0.5, r * 0.52, rot=math.pi / 6)
            core_v, core_f = U.merge((core_v, core_f), (v, f))
            add_beam(x, y, DECAL_Z, 225.0, r * 0.34, r * 0.16, rot=math.pi / 6)
            add_beam(x, y, DECAL_Z, 150.0, r * 0.18, r * 0.06)
        else:
            r = C.SMALL_PAD_R
            v, f = _flat_ngon(x, y, DECAL_Z, r * 0.70, rot=math.pi / 6)
            decal_v, decal_f = U.merge((decal_v, decal_f), (v, f))
            v, f = _flat_ngon(x, y, DECAL_Z + 0.5, r * 0.42, rot=math.pi / 6)
            core_v, core_f = U.merge((core_v, core_f), (v, f))
            add_beam(x, y, DECAL_Z, 66.0, r * 0.25, r * 0.09, rot=math.pi / 6)

    out = {
        "decal": U.mesh_object("CF_BoostDecal", decal_v, decal_f, coll,
                               materials=[mats["decal"]]),
        "core": U.mesh_object("CF_BoostCore", core_v, core_f, coll,
                              materials=[mats["core"]]),
        "beam": U.mesh_object("CF_BoostBeam", beam_v, beam_f, coll,
                              materials=[mats["beam"]], uvs=beam_uv),
    }
    # Light, not matter: it casts nothing and it is not collision.
    for ob in out.values():
        ob.visible_shadow = False
    return out


# --- ball -------------------------------------------------------------------

# Panel tiling around / down the ball. The hex tile is 1.732:1 and v spans
# half the u arc on a sphere, so V_TILE = U_TILE * 0.866 keeps them regular.
U_TILE = 5.0
V_TILE = 4.33


def build_ball(coll, skin_img, rings=48, segs=64):
    verts, faces, uvs = [], [], []
    R = C.BALL_R
    cz = C.BALL_REST_Z
    for i in range(rings + 1):
        phi = math.pi * i / rings
        for j in range(segs):
            th = math.tau * j / segs
            verts.append((R * math.sin(phi) * math.cos(th),
                          R * math.sin(phi) * math.sin(th),
                          cz + R * math.cos(phi)))
    for i in range(rings):
        for j in range(segs):
            j2 = (j + 1) % segs
            a, b = i * segs + j, i * segs + j2
            c, d = (i + 1) * segs + j, (i + 1) * segs + j2
            faces.append((a, c, d, b))
            uvs.extend([(j / segs * U_TILE, i / rings * V_TILE),
                        (j / segs * U_TILE, (i + 1) / rings * V_TILE),
                        (j2 / segs * U_TILE if j2 else U_TILE,
                         (i + 1) / rings * V_TILE),
                        (j2 / segs * U_TILE if j2 else U_TILE,
                         i / rings * V_TILE)])

    # Hex-panel skin baked as real colour, so it survives glTF export intact.
    mat = U.principled("CF_Ball", base=(0.62, 0.65, 0.69), roughness=0.32,
                       metallic=0.15, coat=0.5)
    nt = mat.node_tree
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = skin_img
    tex.extension = "REPEAT"
    tex.location = (-620, 220)
    nt.links.new(tex.outputs["Color"], U.bsdf_of(mat).inputs["Base Color"])

    return U.mesh_object("CF_Ball", verts, faces, coll, materials=[mat],
                         uvs=uvs, shade_smooth=True)
