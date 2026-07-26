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
    base = U.principled("CF_BoostBase", base=(0.045, 0.050, 0.060),
                        roughness=0.3, metallic=0.7)
    glow = U.emissive("CF_BoostGlow", colour=(1.0, 0.42, 0.05), strength=2.2)
    glow_soft = U.emissive("CF_BoostGlowSoft", colour=(1.0, 0.50, 0.09), strength=0.9)
    return {"base": base, "glow": glow, "soft": glow_soft}


# --- goals ------------------------------------------------------------------

def build_goals(coll, mats):
    """Arched tubular frame proud of each mouth, plus the hex net cavity."""
    frame_v, frame_f = [], []
    trim_v, trim_f = [], []
    net_v, net_f, net_uv = [], [], []

    for side in (1, -1):
        wall_y = C.BACK_Y * side
        y_frame = wall_y - side * 46.0        # frame stands proud of the wall

        path = U.rounded_rect_path(
            0.0, C.GOAL_H / 2 + 40.0,
            2 * C.GOAL_HALF_W + 210.0, C.GOAL_H + 250.0,
            radius=250.0, arch=110.0, samples=9)
        # Drop the section that would sit below the floor.
        path = [(x, max(z, 26.0)) for x, z in path]

        v, f = U.sweep_planar(path, y_frame, 44.0, axis="y", segments=12, closed=True)
        frame_v, frame_f = U.merge((frame_v, frame_f), (v, f))

        v, f = U.sweep_planar(path, y_frame - side * 34.0, 19.0, axis="y",
                              segments=10, closed=True)
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

def _hex_prism(cx, cy, cz, r, h, rot=0.0):
    verts, faces = [], []
    for lvl, z in ((0, cz), (1, cz + h)):
        for k in range(6):
            a = rot + math.tau * k / 6
            verts.append((cx + r * math.cos(a), cy + r * math.sin(a), z))
    for k in range(6):
        j = (k + 1) % 6
        faces.append((k, j, 6 + j, 6 + k))
    faces.append((0, 1, 2, 3, 4, 5)[::-1])
    faces.append((6, 7, 8, 9, 10, 11))
    return verts, faces


def build_boost(coll, mats):
    """Six big pads with a floating hex core, 28 small amber chevron plates."""
    base_v, base_f = [], []
    glow_v, glow_f = [], []
    soft_v, soft_f = [], []

    for x, y, _z, big in C.BOOST_PADS:
        if big:
            r = C.BIG_PAD_R
            v, f = U.tube((x, y, 2.0), (x, y, 22.0), r * 0.92, segments=28)
            base_v, base_f = U.merge((base_v, base_f), (v, f))
            v, f = U.tube((x, y, 22.0), (x, y, 30.0), r * 0.76, segments=28)
            glow_v, glow_f = U.merge((glow_v, glow_f), (v, f))
            # Floating core.
            v, f = _hex_prism(x, y, 92.0, r * 0.38, 150.0)
            glow_v, glow_f = U.merge((glow_v, glow_f), (v, f))
            v, f = _hex_prism(x, y, 74.0, r * 0.56, 182.0, rot=math.pi / 6)
            soft_v, soft_f = U.merge((soft_v, soft_f), (v, f))
        else:
            s = C.SMALL_PAD_R * 0.62
            v, f = _hex_prism(x, y, 2.0, s, 8.0, rot=math.pi / 6)
            base_v, base_f = U.merge((base_v, base_f), (v, f))
            v, f = _hex_prism(x, y, 8.0, s * 0.80, 4.0, rot=math.pi / 6)
            glow_v, glow_f = U.merge((glow_v, glow_f), (v, f))
            v, f = _hex_prism(x, y, 11.5, s * 0.62, 3.0, rot=math.pi / 6)
            soft_v, soft_f = U.merge((soft_v, soft_f), (v, f))

    return {
        "base": U.mesh_object("CF_BoostBase", base_v, base_f, coll,
                              materials=[mats["base"]]),
        "glow": U.mesh_object("CF_BoostGlow", glow_v, glow_f, coll,
                              materials=[mats["glow"]]),
        "soft": U.mesh_object("CF_BoostSoft", soft_v, soft_f, coll,
                              materials=[mats["soft"]]),
    }


# --- ball -------------------------------------------------------------------

def build_ball(coll, hex_img, rings=48, segs=64):
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
            uvs.extend([(j / segs * 8, i / rings * 4),
                        (j / segs * 8, (i + 1) / rings * 4),
                        (j2 / segs * 8 if j2 else 8, (i + 1) / rings * 4),
                        (j2 / segs * 8 if j2 else 8, i / rings * 4)])

    # Pale shell with dark hex seams -- the hex map's alpha is the seam mask,
    # its colour is nearly black and must not drive base colour directly.
    mat = U.principled("CF_Ball", base=(0.62, 0.65, 0.69), roughness=0.34,
                       metallic=0.10, coat=0.55)
    nt = mat.node_tree
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = hex_img
    tex.extension = "REPEAT"
    tex.location = (-760, 200)
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.location = (-540, 200)
    ramp.color_ramp.elements[0].position = 0.25
    ramp.color_ramp.elements[0].color = (0.62, 0.65, 0.69, 1.0)
    ramp.color_ramp.elements[1].position = 0.75
    ramp.color_ramp.elements[1].color = (0.045, 0.050, 0.060, 1.0)
    nt.links.new(tex.outputs["Alpha"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], U.bsdf_of(mat).inputs["Base Color"])
    return U.mesh_object("CF_Ball", verts, faces, coll, materials=[mat],
                         uvs=uvs, shade_smooth=True)
