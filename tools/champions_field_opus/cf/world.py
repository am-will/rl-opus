"""Night sky and the atmospheric haze that gives the floodlights their beams."""

import bpy

from . import util as U


def build(scene, haze=0.0016, night=True):
    world = bpy.data.worlds.new("CF_World")
    if not world.node_tree:
        world.use_nodes = True
    nt = world.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputWorld")
    out.location = (700, 0)

    tex = nt.nodes.new("ShaderNodeTexCoord")
    tex.location = (-1200, 200)
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    sep.location = (-1000, 200)
    nt.links.new(tex.outputs["Generated"], sep.inputs["Vector"])

    # Horizon -> zenith gradient.
    grad = nt.nodes.new("ShaderNodeValToRGB")
    grad.location = (-800, 260)
    grad.color_ramp.elements[0].position = 0.30
    grad.color_ramp.elements[0].color = (0.055, 0.085, 0.170, 1.0)
    grad.color_ramp.elements[1].position = 0.85
    grad.color_ramp.elements[1].color = (0.010, 0.020, 0.055, 1.0)
    zmap = nt.nodes.new("ShaderNodeMapRange")
    zmap.location = (-980, 40)
    zmap.inputs["From Min"].default_value = -0.15
    zmap.inputs["From Max"].default_value = 1.0
    nt.links.new(sep.outputs["Z"], zmap.inputs["Value"])
    nt.links.new(zmap.outputs["Result"], grad.inputs["Fac"])

    # Stars: sparse high-frequency noise, thresholded hard.
    star_noise = nt.nodes.new("ShaderNodeTexVoronoi")
    star_noise.location = (-800, -220)
    star_noise.inputs["Scale"].default_value = 420.0
    star_noise.feature = "F1"
    nt.links.new(tex.outputs["Generated"], star_noise.inputs["Vector"])
    star_ramp = nt.nodes.new("ShaderNodeValToRGB")
    star_ramp.location = (-600, -220)
    star_ramp.color_ramp.elements[0].position = 0.0
    star_ramp.color_ramp.elements[0].color = (1.0, 1.0, 1.0, 1.0)
    star_ramp.color_ramp.elements[1].position = 0.055
    star_ramp.color_ramp.elements[1].color = (0.0, 0.0, 0.0, 1.0)
    nt.links.new(star_noise.outputs["Distance"], star_ramp.inputs["Fac"])

    # Cloud band, lit from below by the stadium.
    clouds = nt.nodes.new("ShaderNodeTexNoise")
    clouds.location = (-800, -520)
    clouds.inputs["Scale"].default_value = 3.4
    clouds.inputs["Detail"].default_value = 8.0
    clouds.inputs["Roughness"].default_value = 0.62
    nt.links.new(tex.outputs["Generated"], clouds.inputs["Vector"])
    cramp = nt.nodes.new("ShaderNodeValToRGB")
    cramp.location = (-600, -520)
    cramp.color_ramp.elements[0].position = 0.42
    cramp.color_ramp.elements[0].color = (0.0, 0.0, 0.0, 1.0)
    cramp.color_ramp.elements[1].position = 0.72
    cramp.color_ramp.elements[1].color = (0.075, 0.085, 0.115, 1.0)
    nt.links.new(clouds.outputs["Fac"], cramp.inputs["Fac"])

    add1 = nt.nodes.new("ShaderNodeMix")
    add1.data_type = "RGBA"
    add1.blend_type = "ADD"
    add1.location = (-340, 0)
    add1.inputs[0].default_value = 1.0
    nt.links.new(grad.outputs["Color"], add1.inputs[6])
    nt.links.new(cramp.outputs["Color"], add1.inputs[7])

    add2 = nt.nodes.new("ShaderNodeMix")
    add2.data_type = "RGBA"
    add2.blend_type = "ADD"
    add2.location = (-140, 0)
    add2.inputs[0].default_value = 0.55
    nt.links.new(add1.outputs[2], add2.inputs[6])
    nt.links.new(star_ramp.outputs["Color"], add2.inputs[7])

    bg = nt.nodes.new("ShaderNodeBackground")
    bg.location = (120, 120)
    bg.inputs["Strength"].default_value = 3.0 if night else 5.0
    nt.links.new(add2.outputs[2], bg.inputs["Color"])
    nt.links.new(bg.outputs["Background"], out.inputs["Surface"])

    if haze:
        vol = nt.nodes.new("ShaderNodeVolumeScatter")
        vol.location = (120, -200)
        vol.inputs["Color"].default_value = (0.55, 0.68, 1.0, 1.0)
        vol.inputs["Density"].default_value = haze
        vol.inputs["Anisotropy"].default_value = 0.35
        nt.links.new(vol.outputs["Volume"], out.inputs["Volume"])

    scene.world = world
    return world
