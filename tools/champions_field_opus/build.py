"""Build Champions Field.

    blender -b --python tools/champions_field_opus/build.py -- [options]

Options:
    --out PATH        .blend to write        (default assets/ChampionsFieldOpus/champions_field.blend)
    --renders DIR     where stills go        (default renders/champions_field_opus)
    --shots a,b,c     which cameras to render (default all)
    --samples N       EEVEE render samples   (default 48)
    --res W H         resolution             (default 1600 900)
    --greybox         skip textures/detail, shell only
    --no-render       build and save, render nothing
"""

import argparse
import os
import sys

import bpy

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

REPO = os.path.abspath(os.path.join(HERE, "..", ".."))

from cf import (arena, const as C, lighting, materials, props, shots,  # noqa: E402
                stands, structure, textures, util as U, world)


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--out", default=os.path.join(
        REPO, "assets", "ChampionsFieldOpus", "champions_field.blend"))
    p.add_argument("--renders", default=os.path.join(
        REPO, "renders", "champions_field_opus"))
    p.add_argument("--shots", default="")
    p.add_argument("--tag", default="")
    p.add_argument("--samples", type=int, default=48)
    p.add_argument("--res", type=int, nargs=2, default=[1600, 900])
    p.add_argument("--greybox", action="store_true")
    p.add_argument("--quick-tex", action="store_true")
    p.add_argument("--no-crowd", action="store_true")
    p.add_argument("--haze", type=float, default=0.0007)
    p.add_argument("--no-render", action="store_true")
    return p.parse_args(argv)


def greybox_materials():
    return [
        U.principled("TurfGrey", base=(0.18, 0.28, 0.16), roughness=0.85),
        U.principled("WallGrey", base=(0.10, 0.11, 0.14), roughness=0.55),
        U.principled("CeilGrey", base=(0.05, 0.06, 0.09), roughness=0.6),
        U.principled("GoalGrey", base=(0.06, 0.07, 0.10), roughness=0.5),
    ]


def temp_lighting(coll):
    """Placeholder key/fill so the greybox reads. Replaced by lighting.py."""
    import math
    for i, (x, y, z, e) in enumerate([
        (0, -4000, 1900, 6e4), (0, 4000, 1900, 6e4),
        (-3200, 0, 1900, 5e4), (3200, 0, 1900, 5e4),
    ]):
        lt = bpy.data.lights.new(f"KEY_{i}", type="AREA")
        lt.shape = "RECTANGLE"
        lt.size, lt.size_y = 30.0, 8.0
        lt.energy = e
        lt.color = (1.0, 0.97, 0.92)
        ob = bpy.data.objects.new(f"KEY_{i}", lt)
        ob.location = (x * C.S, y * C.S, z * C.S)
        ob.rotation_euler = (math.radians(35) * (1 if y <= 0 else -1), 0,
                             0 if abs(x) < abs(y) else math.radians(90))
        coll.objects.link(ob)

    world = bpy.data.worlds.new("World")
    if not world.node_tree:
        world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs[0].default_value = (0.02, 0.03, 0.06, 1.0)
    bg.inputs[1].default_value = 1.0
    bpy.context.scene.world = world


# The play volume, and nothing else. CF_Floor is a single planar n-gon at
# z = 0, so the pitch is one flat collision surface.
COLLISION_MESHES = ("CF_Floor", "CF_Walls", "CF_Ceiling", "CF_GoalPockets")


def tag_collision(root):
    """Mark the play volume as collision and everything else as decor.

    Boost decals, energy beams, goal frames, nets, crowd and stadium dressing
    are all excluded, so a car drives over them as though they were not there.
    Tagged objects are also linked into a `Collision` collection to give an
    exporter a one-click selection.
    """
    coll = U.collection("Collision", root)
    tagged = []
    for ob in bpy.data.objects:
        if ob.type != "MESH":
            continue
        is_col = ob.name in COLLISION_MESHES
        ob["collision"] = is_col
        if is_col and ob.name not in coll.objects:
            coll.objects.link(ob)
            tagged.append(ob.name)
    print(f"[build] collision: {sorted(tagged)}")
    return coll


def main():
    args = parse_args()
    U.wipe_scene()
    scene = bpy.context.scene
    scene.unit_settings.system = "METRIC"
    scene.unit_settings.scale_length = 1.0

    root = U.collection("ChampionsField")
    c_shell = U.collection("Shell", root)
    c_cam = U.collection("Cameras", root)

    if args.greybox:
        mats = greybox_materials()
        arena.build(c_shell, mats)
        temp_lighting(c_shell)
    else:
        texdir = os.path.join(os.path.dirname(args.out), "tex")
        tex = textures.build_all(texdir, quick=args.quick_tex)
        mats = materials.build(tex)
        arena.build(c_shell, mats)

        c_props = U.collection("Props", root)
        c_stands = U.collection("Stands", root)
        c_light = U.collection("Lighting", root)

        props.build_goals(c_props, props.goal_materials(tex["hex"]))
        props.build_boost(c_props, props.boost_materials(tex["boost"]))
        props.build_ball(c_props, tex["ball"])
        if not args.no_crowd:
            stands.build(c_stands)
        structure.build(U.collection('Structure', root), board_tex=tex['board'])
        lighting.build(c_light)
        lighting.exterior(c_light)
        world.build(scene, haze=args.haze)

    tag_collision(root)

    cams = shots.add_cameras(c_cam)
    shots.configure(scene, samples=args.samples, res=tuple(args.res))
    shots.add_glare(scene)

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=args.out, compress=True)
    print(f"[build] saved {args.out}")

    if not args.no_render:
        names = [s for s in args.shots.split(",") if s] or None
        shots.render(scene, cams, args.renders, names, tag=args.tag)

    # A quick integrity dump so regressions in the shell show up as numbers.
    tot_v = sum(len(o.data.vertices) for o in bpy.data.objects if o.type == "MESH")
    tot_f = sum(len(o.data.polygons) for o in bpy.data.objects if o.type == "MESH")
    print(f"[build] meshes: {tot_v} verts / {tot_f} faces")


main()
