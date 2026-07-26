"""Shaders for the arena surfaces."""

import bpy

from . import const as C
from . import util as U


def _tex(mat, image, uv_scale=None, interpolation="Cubic", extension="EXTEND",
         loc=(-700, 200)):
    nt = mat.node_tree
    node = nt.nodes.new("ShaderNodeTexImage")
    node.image = image
    node.interpolation = interpolation
    node.extension = extension
    node.location = loc
    if uv_scale:
        mapping = nt.nodes.new("ShaderNodeMapping")
        mapping.location = (loc[0] - 220, loc[1])
        mapping.inputs["Scale"].default_value = (*uv_scale, 1.0)
        coord = nt.nodes.new("ShaderNodeTexCoord")
        coord.location = (loc[0] - 420, loc[1])
        nt.links.new(coord.outputs["UV"], mapping.inputs["Vector"])
        nt.links.new(mapping.outputs["Vector"], node.inputs["Vector"])
    return node


def turf(col_img, emit_img):
    """Pitch: baked markings, procedural blade bump, forward-scattering sheen."""
    mat = U.principled("CF_Turf", roughness=0.82)
    nt = mat.node_tree
    bsdf = U.bsdf_of(mat)

    base = _tex(mat, col_img, loc=(-700, 300))
    nt.links.new(base.outputs["Color"], bsdf.inputs["Base Color"])

    glow = _tex(mat, emit_img, loc=(-700, -60))
    nt.links.new(glow.outputs["Color"], bsdf.inputs["Emission Color"])
    bsdf.inputs["Emission Strength"].default_value = 0.55

    # Two noise octaves: coarse clumping and per-blade tufting.
    clump = nt.nodes.new("ShaderNodeTexNoise")
    clump.location = (-700, -420)
    clump.inputs["Scale"].default_value = 220.0
    clump.inputs["Detail"].default_value = 6.0
    clump.inputs["Roughness"].default_value = 0.65

    blade = nt.nodes.new("ShaderNodeTexNoise")
    blade.location = (-700, -640)
    blade.inputs["Scale"].default_value = 1400.0
    blade.inputs["Detail"].default_value = 3.0

    mix = nt.nodes.new("ShaderNodeMix")
    mix.data_type = "FLOAT"
    mix.location = (-460, -520)
    mix.inputs["Factor"].default_value = 0.45
    nt.links.new(clump.outputs["Fac"], mix.inputs["A"])
    nt.links.new(blade.outputs["Fac"], mix.inputs["B"])

    bump = nt.nodes.new("ShaderNodeBump")
    bump.location = (-240, -520)
    bump.inputs["Strength"].default_value = 0.42
    bump.inputs["Distance"].default_value = 0.012
    nt.links.new(mix.outputs["Result"], bump.inputs["Height"])
    nt.links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])

    # Roughness breakup so the mow bands catch the floodlights differently.
    rmap = nt.nodes.new("ShaderNodeMapRange")
    rmap.location = (-240, -260)
    rmap.inputs["From Min"].default_value = 0.0
    rmap.inputs["From Max"].default_value = 1.0
    rmap.inputs["To Min"].default_value = 0.66
    rmap.inputs["To Max"].default_value = 0.92
    nt.links.new(clump.outputs["Fac"], rmap.inputs["Value"])
    nt.links.new(rmap.outputs["Result"], bsdf.inputs["Roughness"])

    if "Sheen Weight" in bsdf.inputs:
        bsdf.inputs["Sheen Weight"].default_value = 0.06
        bsdf.inputs["Sheen Roughness"].default_value = 0.5
    return mat


def wall(col_img, emit_img):
    """Perimeter: opaque boards below, alpha-cut containment net above."""
    mat = U.principled("CF_Wall", roughness=0.34, metallic=0.15)
    nt = mat.node_tree
    bsdf = U.bsdf_of(mat)

    base = _tex(mat, col_img, loc=(-700, 300))
    nt.links.new(base.outputs["Color"], bsdf.inputs["Base Color"])
    nt.links.new(base.outputs["Alpha"], bsdf.inputs["Alpha"])

    glow = _tex(mat, emit_img, loc=(-700, -100))
    nt.links.new(glow.outputs["Color"], bsdf.inputs["Emission Color"])
    bsdf.inputs["Emission Strength"].default_value = 3.2

    mat.surface_render_method = "BLENDED"
    mat.use_transparent_shadow = True
    return mat


def ceiling(hex_img):
    """The hex containment canopy: mostly sky, a fine dark lattice."""
    mat = U.principled("CF_Ceiling", base=(0.05, 0.06, 0.08),
                       roughness=0.4, metallic=0.6)
    nt = mat.node_tree
    bsdf = U.bsdf_of(mat)
    tex = _tex(mat, hex_img, uv_scale=(4.0, 6.94), extension="REPEAT",
               interpolation="Linear", loc=(-700, 200))
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    nt.links.new(tex.outputs["Alpha"], bsdf.inputs["Alpha"])
    mat.surface_render_method = "BLENDED"
    return mat


def goal_interior():
    mat = U.principled("CF_GoalInterior", base=(0.020, 0.024, 0.034),
                       roughness=0.42, metallic=0.3)
    return mat


def build(tex):
    col, emi = tex["turf"]
    wcol, wemi = tex["wall"]
    return [turf(col, emi), wall(wcol, wemi), ceiling(tex["hex"]), goal_interior()]
