"""Cameras and the render harness."""

import math
import os

import bpy

from . import const as C
from . import util as U

S = C.S

# name -> (location uu, look-at uu, lens mm, orthographic scale or None)
SHOTS = {
    # Wide hero: high behind the blue goal, looking the length of the pitch.
    "hero":      ((0, -4500, 1560), (0, 1100, 900), 24, None),
    # Player height at the blue kickoff spot.
    "kickoff":   ((0, -4250, 120), (0, 1600, 430), 24, None),
    # Corner, reading the plan fillet and the wall sweep.
    "corner":    ((3250, -4250, 620), (-900, 1600, 380), 24, None),
    # Straight down: verifies plan geometry and every marking.
    "top":       ((0, 0, 2030), (0, 0, 0), 50, 12400 * S),
    # Goal mouth close-up.
    "goal":      ((0, -2600, 300), (0, -5600, 330), 40, None),
    # From the ceiling looking back down the pitch.
    "ceiling":   ((0, 3300, 1930), (0, -1400, 150), 24, None),
    # Broadcast: up in the side stands, shooting through the containment net.
    "broadcast": ((3620, -1500, 1880), (-700, 1200, 240), 30, None),
    # Money shot: outside and above, the whole bowl.
    "aerial":    ((17000, -21000, 20500), (0, -400, 1200), 38, None),
    # Close on the side 100 pad: plate, vents, plume and orb in one frame.
    "padbig":    ((2870, -640, 240), (3584, 40, 150), 42, None),
    # A 12 in the foreground with a 100 behind it, for the size relationship.
    "padsmall":  ((1330, -2760, 165), (1788, -2300, 40), 42, None),
    # Car height across the pads in the blue half, which is how they are
    # actually seen: a row of small ones and a 100 out at the corner.
    "padrow":    ((-500, -3900, 105), (1500, -1200, 120), 24, None),
}


def _look_at(ob, target):
    import mathutils
    d = mathutils.Vector((target[0] * S, target[1] * S, target[2] * S)) - ob.location
    ob.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()


def add_cameras(coll):
    cams = {}
    for name, (loc, tgt, lens, ortho) in SHOTS.items():
        cam = bpy.data.cameras.new("CAM_" + name)
        cam.lens = lens
        cam.clip_start = 0.2
        cam.clip_end = 4000.0
        if ortho is not None:
            cam.type = "ORTHO"
            cam.sensor_fit = "VERTICAL"   # ortho_scale should span the pitch length
            cam.ortho_scale = ortho
        ob = bpy.data.objects.new("CAM_" + name, cam)
        ob.location = (loc[0] * S, loc[1] * S, loc[2] * S)
        coll.objects.link(ob)
        _look_at(ob, tgt)
        cams[name] = ob
    return cams


def configure(scene, samples=48, res=(1600, 900), engine="BLENDER_EEVEE"):
    scene.render.engine = engine
    scene.render.resolution_x, scene.render.resolution_y = res
    scene.render.resolution_percentage = 100
    scene.render.film_transparent = False
    scene.render.image_settings.file_format = "PNG"

    try:
        scene.view_settings.view_transform = "AgX"
        scene.view_settings.look = "AgX - Punchy"
    except (TypeError, AttributeError):
        pass
    scene.view_settings.exposure = 0.0

    ee = scene.eevee
    ee.taa_render_samples = samples
    ee.taa_samples = 16
    ee.use_raytracing = True
    ee.ray_tracing_method = "SCREEN"
    ee.use_shadows = True
    ee.shadow_pool_size = '2048'
    ee.shadow_resolution_scale = 1.0
    ee.shadow_ray_count = 2
    ee.shadow_step_count = 6
    ee.use_volumetric_shadows = True
    ee.volumetric_start = 0.5
    ee.volumetric_end = 600.0
    ee.volumetric_samples = 64
    ee.volumetric_sample_distribution = 0.9
    ee.volumetric_tile_size = "4"   # "2" quadruples volume cost for no visible gain here
    ee.gi_cubemap_resolution = "1024"
    ee.clamp_surface_indirect = 8.0


def _set(node, socket, value):
    if socket in node.inputs:
        try:
            node.inputs[socket].default_value = value
        except (TypeError, AttributeError):
            pass


def add_glare(scene, threshold=1.0, size=8, strength=0.35, streaks=0.12):
    """Bloom + a little anamorphic streak.

    Blender 5.x drives the compositor from a node group and configures Glare
    through input sockets rather than node properties.
    """
    ng = bpy.data.node_groups.new("CF_Comp", "CompositorNodeTree")
    ng.interface.new_socket("Image", in_out="OUTPUT", socket_type="NodeSocketColor")

    # 5.2 feeds the scene compositor group from a Render Layers node inside the
    # group -- a Group Input socket renders as empty.
    gin = ng.nodes.new("CompositorNodeRLayers")
    gin.location = (-500, 0)
    gout = ng.nodes.new("NodeGroupOutput")
    gout.location = (500, 0)

    bloom = ng.nodes.new("CompositorNodeGlare")
    bloom.location = (-180, 60)
    _set(bloom, "Type", "Bloom")
    _set(bloom, "Quality", "High")
    _set(bloom, "Threshold", threshold)
    _set(bloom, "Size", size)
    _set(bloom, "Strength", strength)
    _set(bloom, "Smoothness", 0.4)

    streak = ng.nodes.new("CompositorNodeGlare")
    streak.location = (140, -40)
    _set(streak, "Type", "Streaks")
    _set(streak, "Quality", "High")
    _set(streak, "Threshold", threshold + 0.6)
    _set(streak, "Strength", streaks)
    _set(streak, "Streaks", 4)
    _set(streak, "Iterations", 3)
    _set(streak, "Fade", 0.88)
    _set(streak, "Color Modulation", 0.22)

    ng.links.new(gin.outputs["Image"], bloom.inputs["Image"])
    ng.links.new(bloom.outputs["Image"], streak.inputs["Image"])
    ng.links.new(streak.outputs["Image"], gout.inputs[0])

    scene.use_nodes = True
    scene.compositing_node_group = ng
    return ng


def render(scene, cams, outdir, names=None, tag=""):
    os.makedirs(outdir, exist_ok=True)
    written = []
    for name in (names or list(cams)):
        if name not in cams:
            continue
        scene.camera = cams[name]
        path = os.path.join(outdir, f"{tag}{name}.png")
        scene.render.filepath = path
        bpy.ops.render.render(write_still=True)
        written.append(path)
        print(f"[shot] {path}")
    return written
