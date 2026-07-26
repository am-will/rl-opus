"""Export the built arena to glTF for Godot.

    blender -b assets/ChampionsFieldOpus/champions_field.blend \
        --python tools/champions_field_opus/export_godot.py -- --out path/to/arena.glb

Godot's glTF importer reads collision intent off node-name suffixes, so the
four play-volume meshes are renamed with `-col` on the way out. That gives them
a trimesh StaticBody on import and leaves every prop, pad, beam and piece of
stadium dressing as pure visual geometry -- which is exactly the split
build.py already recorded in the `collision` custom property.
"""

import argparse
import os
import sys

import bpy

SUFFIX = "-col"          # Godot: mesh + concave trimesh static body


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--out", required=True)
    p.add_argument("--no-lights", action="store_true")
    p.add_argument("--shadow-lights", type=int, default=6,
                   help="how many floodlights keep shadows (realtime budget)")
    return p.parse_args(argv)


def main():
    args = parse_args()
    os.makedirs(os.path.dirname(args.out), exist_ok=True)

    renamed = []
    for ob in bpy.data.objects:
        if ob.type == "MESH" and ob.get("collision") and not ob.name.endswith(SUFFIX):
            ob.name += SUFFIX
            renamed.append(ob.name)

    # 18 shadow-casting spots is fine for an offline EEVEE still and far too
    # much for a realtime forward+ renderer. Thin them for the export.
    spots = sorted((o for o in bpy.data.objects
                    if o.type == "LIGHT" and o.data.type == "SPOT"),
                   key=lambda o: o.name)
    for i, ob in enumerate(spots):
        ob.data.use_shadow = i < args.shadow_lights

    kwargs = dict(
        filepath=args.out,
        export_format="GLB",
        use_selection=False,
        export_apply=True,          # bake modifiers (the roof has a Solidify)
        export_materials="EXPORT",
        export_cameras=True,
        export_lights=not args.no_lights,
        export_yup=True,            # Godot is Y-up
        export_extras=True,         # carries the `collision` custom property
    )
    # The glTF operator's keyword set drifts between Blender versions.
    valid = set(bpy.ops.export_scene.gltf.get_rna_type().properties.keys())
    kwargs = {k: v for k, v in kwargs.items() if k in valid}

    bpy.ops.export_scene.gltf(**kwargs)

    size = os.path.getsize(args.out) if os.path.exists(args.out) else 0
    print(f"[gltf] wrote {args.out}  ({size / 1e6:.1f} MB)")
    print(f"[gltf] collision nodes: {sorted(renamed)}")
    print(f"[gltf] shadow-casting spots: {min(args.shadow_lights, len(spots))}"
          f" of {len(spots)}")


main()
