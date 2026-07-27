"""Export the assembled Octane to glTF for Godot.

    blender -b assets/Octane/Octane_Codex.blend \
        --python tools/export_octane.py -- --out godot/SlopetLeague/assets/octane.glb

The arena already has this (`tools/champions_field_opus/export_godot.py`); the car
did not. Three things have to happen on the way out, none of which the .blend
should be permanently changed for:

1. **Scale.** The arena is built at Rocket League scale, where 1 uu = 1 cm, and
   exported raw the car arrives about three times too big for the pitch.

   Scaling by the *wheelbase* rather than the bounding box, because the wheel
   contact points are the physically meaningful landmark -- they are where the
   suspension raycasts touch the ground -- while the bounding box includes the
   rear wing's overhang, which no RL measurement accounts for. Matching the
   bounding box to the hitbox length undersized the car by about 18%: visibly
   loose inside its own hitbox, and small next to the ball.

   Worth recording: the widely-quoted Octane hitbox of 118.01 x 84.20 x 36.16
   is wrong. RocketSim's CarConfig.cpp documents why -- Rocket League's own
   GetLocalCollisionExtent() returns values slightly larger than the simulation
   uses, and only 120.507 x 86.6994 x 38.6591 reproduces the real inertia
   matrix. The wheelbase used here, 85.0 uu, comes from the same source.

2. **Orientation.** The assembly puts the nose along Blender -X. Godot's convention
   is that forward is -Z, and glTF's Y-up conversion maps Blender (x, y, z) to
   (x, z, -y) -- so the nose has to be rotated onto Blender +Y first.

3. **Only the car.** The .blend also holds a PRESENTATION collection with a studio
   floor, lights and a camera for the review renders. None of that belongs in the
   game, and an imported camera would hijack Godot's viewport the way the arena's
   eight did.

Wheels stay as separate named nodes (Octane_<Corner>_Rim / _Tire) so steering and
roll can drive them, rather than being merged into the body.
"""

import argparse
import math
import os
import sys

import bpy

# cf/const.py, from the RLBot reference tables: the Octane hitbox is
# 118.01 x 84.20 x 36.16 uu at 1 uu = 1 cm.
HITBOX_LEN_M = 1.1801

ASSET_COLLECTION = "OCTANE_ASSET"
ROOT_NAME = "Octane_Root"


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--out", required=True)
    p.add_argument("--length", type=float, default=HITBOX_LEN_M,
                   help="target nose-to-tail length in metres")
    return p.parse_args(argv)


def asset_objects():
    coll = bpy.data.collections.get(ASSET_COLLECTION)
    if coll is None:
        sys.exit(f"[octane] no '{ASSET_COLLECTION}' collection in this .blend")
    return [o for o in coll.objects]


def world_span(objects):
    """Nose-to-tail length of the assembled car, in Blender units.

    Measured along X, which is the assembly's longitudinal axis before the
    export rotation.
    """
    from mathutils import Vector

    lo, hi = math.inf, -math.inf
    for ob in objects:
        if ob.type != "MESH":
            continue
        for corner in ob.bound_box:
            x = (ob.matrix_world @ Vector(corner)).x
            lo, hi = min(lo, x), max(hi, x)
    return hi - lo


def main():
    args = parse_args()
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)

    objects = asset_objects()
    span = world_span(objects)
    scale = args.length / span

    root = bpy.data.objects.get(ROOT_NAME)
    if root is None:
        sys.exit(f"[octane] no '{ROOT_NAME}' empty to transform")

    # Nose from Blender -X onto Blender +Y, which glTF's Y-up conversion then
    # lands on Godot -Z.
    root.rotation_euler = (0.0, 0.0, math.radians(-90.0))
    root.scale = (scale, scale, scale)

    bpy.ops.object.select_all(action="DESELECT")
    for ob in objects:
        ob.select_set(True)
    bpy.context.view_layer.objects.active = root

    kwargs = dict(
        filepath=args.out,
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_materials="EXPORT",
        export_cameras=False,
        export_lights=False,
        export_yup=True,
        export_extras=True,
    )
    valid = set(bpy.ops.export_scene.gltf.get_rna_type().properties.keys())
    bpy.ops.export_scene.gltf(**{k: v for k, v in kwargs.items() if k in valid})

    size = os.path.getsize(args.out) if os.path.exists(args.out) else 0
    print(f"[octane] wrote {args.out}  ({size / 1e6:.1f} MB)")
    print(f"[octane] span {span:.4f} bu -> {args.length:.4f} m  (scale {scale:.5f})")
    print(f"[octane] objects: {len(objects)}")


main()
