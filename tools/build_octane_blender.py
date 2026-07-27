"""Build and render a presentation-ready Rocket League Octane in Blender.

Run inside Blender. The source OBJ components and textures are extracted from the
downloaded Unity asset bundle by ``extract_octane_unity.py``.
"""

from __future__ import annotations

import math
from pathlib import Path

import bpy
from mathutils import Vector


ROOT = Path("/Users/am.will/Applications/rl-opus5")
SOURCE = ROOT / "assets/octane_reference/extracted"
ASSET_DIR = ROOT / "assets/Octane"
RENDER_DIR = ROOT / "renders/octane_review"
BLEND_PATH = ASSET_DIR / "Octane_Codex.blend"

ASSET_DIR.mkdir(parents=True, exist_ok=True)
RENDER_DIR.mkdir(parents=True, exist_ok=True)


def clear_scene() -> None:
    if bpy.context.object and bpy.context.object.mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj, do_unlink=True)
    for collection in list(bpy.data.collections):
        bpy.data.collections.remove(collection)
    for material in list(bpy.data.materials):
        bpy.data.materials.remove(material)


def new_collection(name: str) -> bpy.types.Collection:
    collection = bpy.data.collections.new(name)
    bpy.context.scene.collection.children.link(collection)
    return collection


def move_to_collection(
    obj: bpy.types.Object, collection: bpy.types.Collection
) -> None:
    for existing in list(obj.users_collection):
        existing.objects.unlink(obj)
    collection.objects.link(obj)


def import_obj(path: Path, collection: bpy.types.Collection) -> list[bpy.types.Object]:
    before = set(bpy.data.objects)
    bpy.ops.wm.obj_import(
        filepath=str(path),
        forward_axis="NEGATIVE_Z",
        up_axis="Y",
        use_split_objects=True,
        use_split_groups=True,
        validate_meshes=True,
    )
    imported = [
        obj for obj in set(bpy.data.objects) - before if obj.type == "MESH"
    ]
    for obj in imported:
        move_to_collection(obj, collection)
        for polygon in obj.data.polygons:
            polygon.use_smooth = True
    return sorted(imported, key=lambda item: item.name)


def image(path: Path, non_color: bool = False) -> bpy.types.Image:
    loaded = bpy.data.images.get(path.name)
    if loaded is None:
        loaded = bpy.data.images.load(str(path), check_existing=True)
    if non_color:
        loaded.colorspace_settings.name = "Non-Color"
    return loaded


def textured_material(
    name: str,
    texture_path: Path,
    *,
    metallic: float,
    roughness: float,
    tint: tuple[float, float, float, float] | None = None,
    coat: float = 0.0,
    saturation: float = 1.0,
    value: float = 1.0,
) -> bpy.types.Material:
    material = bpy.data.materials.new(name)
    material.use_nodes = True
    material.diffuse_color = tint or (0.5, 0.5, 0.5, 1.0)
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    bsdf = nodes.get("Principled BSDF")
    texture = nodes.new("ShaderNodeTexImage")
    texture.name = f"{name}_Texture"
    texture.label = texture_path.name
    texture.image = image(texture_path)
    texture.interpolation = "Linear"
    texture.extension = "REPEAT"

    color_output = texture.outputs["Color"]
    if tint is not None:
        multiply = nodes.new("ShaderNodeMixRGB")
        multiply.blend_type = "MULTIPLY"
        multiply.inputs["Fac"].default_value = 1.0
        multiply.inputs[2].default_value = tint
        links.new(texture.outputs["Color"], multiply.inputs[1])
        color_output = multiply.outputs["Color"]

    if saturation != 1.0 or value != 1.0:
        hue_saturation = nodes.new("ShaderNodeHueSaturation")
        hue_saturation.inputs["Saturation"].default_value = saturation
        hue_saturation.inputs["Value"].default_value = value
        links.new(color_output, hue_saturation.inputs["Color"])
        color_output = hue_saturation.outputs["Color"]

    links.new(color_output, bsdf.inputs["Base Color"])
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = roughness
    if "Coat Weight" in bsdf.inputs:
        bsdf.inputs["Coat Weight"].default_value = coat
        bsdf.inputs["Coat Roughness"].default_value = 0.12
    return material


def octane_paint_material(name: str, texture_path: Path) -> bpy.types.Material:
    """Map the original paint mask to a deep, high-contrast cobalt finish."""
    material = bpy.data.materials.new(name)
    material.use_nodes = True
    material.diffuse_color = (0.012, 0.12, 0.72, 1.0)
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    bsdf = nodes.get("Principled BSDF")
    texture = nodes.new("ShaderNodeTexImage")
    texture.name = f"{name}_Mask"
    texture.image = image(texture_path)
    texture.interpolation = "Linear"
    color_ramp = nodes.new("ShaderNodeValToRGB")
    color_ramp.name = f"{name}_CobaltRamp"
    ramp = color_ramp.color_ramp
    ramp.elements[0].position = 0.0
    ramp.elements[0].color = (0.001, 0.004, 0.02, 1.0)
    deep_blue = ramp.elements.new(0.18)
    deep_blue.color = (0.003, 0.018, 0.11, 1.0)
    mid_blue = ramp.elements.new(0.56)
    mid_blue.color = (0.004, 0.04, 0.28, 1.0)
    ramp.elements[-1].position = 1.0
    ramp.elements[-1].color = (0.006, 0.075, 0.55, 1.0)
    links.new(texture.outputs["Color"], color_ramp.inputs["Fac"])
    links.new(color_ramp.outputs["Color"], bsdf.inputs["Base Color"])
    bsdf.inputs["Metallic"].default_value = 0.48
    bsdf.inputs["Roughness"].default_value = 0.22
    if "Coat Weight" in bsdf.inputs:
        bsdf.inputs["Coat Weight"].default_value = 0.5
        bsdf.inputs["Coat Roughness"].default_value = 0.1
    return material


def simple_material(
    name: str,
    color: tuple[float, float, float, float],
    *,
    metallic: float = 0.0,
    roughness: float = 0.5,
    emission: tuple[float, float, float, float] | None = None,
    emission_strength: float = 0.0,
) -> bpy.types.Material:
    material = bpy.data.materials.new(name)
    material.use_nodes = True
    material.diffuse_color = color
    bsdf = material.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = color
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = roughness
    if emission is not None:
        bsdf.inputs["Emission Color"].default_value = emission
        bsdf.inputs["Emission Strength"].default_value = emission_strength
    return material


def choose_parts(
    objects: list[bpy.types.Object], prefix: str
) -> tuple[bpy.types.Object, bpy.types.Object]:
    first = next(obj for obj in objects if obj.name.endswith("_0"))
    second = next(obj for obj in objects if obj.name.endswith("_1"))
    first.name = f"{prefix}_0"
    second.name = f"{prefix}_1"
    return first, second


def duplicate_mesh_object(
    source: bpy.types.Object,
    name: str,
    collection: bpy.types.Collection,
) -> bpy.types.Object:
    obj = bpy.data.objects.new(name, source.data)
    collection.objects.link(obj)
    for material in source.data.materials:
        if material.name not in obj.data.materials:
            obj.data.materials.append(material)
    return obj


def add_brake(
    name: str,
    center: tuple[float, float, float],
    side_sign: float,
    radius: float,
    disc_material: bpy.types.Material,
    caliper_material: bpy.types.Material,
    collection: bpy.types.Collection,
) -> None:
    inner_y = center[1] - side_sign * 0.05
    bpy.ops.mesh.primitive_cylinder_add(
        vertices=48,
        radius=radius,
        depth=0.028,
        location=(center[0], inner_y, center[2]),
        rotation=(math.radians(90), 0.0, 0.0),
    )
    disc = bpy.context.object
    disc.name = f"{name}_BrakeDisc"
    move_to_collection(disc, collection)
    disc.data.materials.append(disc_material)
    bevel = disc.modifiers.new("BrakeDisc_Bevel", "BEVEL")
    bevel.width = 0.012
    bevel.segments = 2

    bpy.ops.mesh.primitive_cube_add(
        location=(
            center[0] - 0.05,
            inner_y + side_sign * 0.012,
            center[2] + radius * 0.52,
        ),
        scale=(0.075, 0.03, 0.065),
    )
    caliper = bpy.context.object
    caliper.name = f"{name}_Caliper"
    move_to_collection(caliper, collection)
    caliper.data.materials.append(caliper_material)
    bevel = caliper.modifiers.new("Caliper_Bevel", "BEVEL")
    bevel.width = 0.025
    bevel.segments = 3


def add_axle_connection(
    name: str,
    center: tuple[float, float, float],
    side_sign: float,
    scale: float,
    spindle_face_y: float,
    axle_material: bpy.types.Material,
    hub_material: bpy.types.Material,
    collection: bpy.types.Collection,
) -> None:
    """Bridge the body suspension to the inner wheel face so the wheel reads attached."""
    body_end_y = side_sign * spindle_face_y
    hub_y = center[1]
    axle_length = abs(hub_y - body_end_y)
    axle_mid_y = (hub_y + body_end_y) * 0.5
    bpy.ops.mesh.primitive_cylinder_add(
        vertices=32,
        radius=0.052 * scale,
        depth=axle_length,
        location=(center[0], axle_mid_y, center[2]),
        rotation=(math.radians(90), 0.0, 0.0),
    )
    axle = bpy.context.object
    axle.name = f"{name}_Axle"
    move_to_collection(axle, collection)
    axle.data.materials.append(axle_material)
    bevel = axle.modifiers.new("Axle_Edge_Bevel", "BEVEL")
    bevel.width = 0.012
    bevel.segments = 2

    collar_y = center[1] - side_sign * (0.075 * scale)
    bpy.ops.mesh.primitive_cylinder_add(
        vertices=40,
        radius=0.105 * scale,
        depth=0.16 * scale,
        location=(center[0], collar_y, center[2]),
        rotation=(math.radians(90), 0.0, 0.0),
    )
    collar = bpy.context.object
    collar.name = f"{name}_HubCollar"
    move_to_collection(collar, collection)
    collar.data.materials.append(hub_material)
    bevel = collar.modifiers.new("HubCollar_Bevel", "BEVEL")
    bevel.width = 0.018
    bevel.segments = 3


def add_area_light(
    name: str,
    location: tuple[float, float, float],
    energy: float,
    size: float,
    color: tuple[float, float, float],
    target: tuple[float, float, float],
    collection: bpy.types.Collection,
) -> bpy.types.Object:
    data = bpy.data.lights.new(name, type="AREA")
    data.energy = energy
    data.shape = "DISK"
    data.size = size
    data.color = color
    obj = bpy.data.objects.new(name, data)
    collection.objects.link(obj)
    obj.location = location
    obj.rotation_euler = (
        Vector(target) - obj.location
    ).to_track_quat("-Z", "Y").to_euler()
    return obj


def look_at(
    camera: bpy.types.Object,
    location: tuple[float, float, float],
    target: tuple[float, float, float],
) -> None:
    camera.location = location
    camera.rotation_euler = (
        Vector(target) - camera.location
    ).to_track_quat("-Z", "Y").to_euler()


clear_scene()
scene = bpy.context.scene
scene.name = "Octane_Asset_Scene"
scene.unit_settings.system = "METRIC"
scene.unit_settings.length_unit = "METERS"
scene["asset_name"] = "Rocket League Octane"
scene["source_note"] = (
    "Geometry reconstructed from the MeiRummy Thunderstore community port; "
    "original vehicle design and IP belong to Psyonix/Epic Games."
)
scene["reference_model"] = (
    "Jako Octane - Rocket League Car, Sketchfab model 9910f0a, CC Attribution"
)
scene["redistribution_note"] = "Review source licensing before redistribution."

asset_collection = new_collection("OCTANE_ASSET")
presentation_collection = new_collection("PRESENTATION")

body_paint = octane_paint_material(
    "Octane_Body_Blue",
    SOURCE / "Octane_Body.png",
)
chassis = textured_material(
    "Octane_Chassis",
    SOURCE / "Octane_Chassis.png",
    metallic=0.32,
    roughness=0.31,
    coat=0.2,
    saturation=1.45,
    value=1.12,
)
rim_material = simple_material(
    "Octane_OEM_Rim",
    (0.29, 0.35, 0.44, 1.0),
    metallic=0.84,
    roughness=0.23,
)
tire_material = textured_material(
    "Octane_OEM_Tire",
    SOURCE / "OEM_Tire.png",
    metallic=0.0,
    roughness=0.72,
)
disc_material = simple_material(
    "Brake_Disc", (0.23, 0.25, 0.28, 1.0), metallic=0.82, roughness=0.26
)
caliper_material = simple_material(
    "Brake_Caliper", (0.7, 0.02, 0.004, 1.0), metallic=0.42, roughness=0.29
)
axle_material = simple_material(
    "Axle_BlueBlack", (0.018, 0.035, 0.075, 1.0), metallic=0.72, roughness=0.24
)
hub_material = simple_material(
    "Hub_Steel", (0.22, 0.29, 0.4, 1.0), metallic=0.9, roughness=0.2
)
body_objects = import_obj(SOURCE / "Octane.obj", asset_collection)
paint_object, chassis_object = choose_parts(body_objects, "Octane_Body")
paint_object.data.materials.append(body_paint)
chassis_object.data.materials.append(chassis)
for obj in (paint_object, chassis_object):
    obj.location = (0.085, 0.0, 0.516)
    obj.rotation_euler[0] = math.radians(90.0)
    obj["asset_role"] = "body"

wheel_objects = import_obj(SOURCE / "OEM_Wheel.obj", asset_collection)
rim_prototype, tire_prototype = choose_parts(wheel_objects, "Wheel_Prototype")
rim_prototype.data.materials.append(rim_material)
tire_prototype.data.materials.append(tire_material)

wheel_specs = [
    # name, spindle X, wheel center Y, spindle Z, scale, body spindle face Y
    ("Front_Left", -1.1960, 0.7876, 0.3669, 1.0, 0.6363),
    ("Front_Right", -1.1960, -0.7876, 0.3669, 1.0, 0.6363),
    ("Rear_Left", 0.9417, 0.8748, 0.4085, 1.1, 0.7084),
    ("Rear_Right", 0.9417, -0.8748, 0.4085, 1.1, 0.7084),
]
for name, x, y, z, scale, spindle_face_y in wheel_specs:
    side_sign = 1.0 if y > 0.0 else -1.0
    wheel_axis_rotation = (
        math.radians(-90.0) if side_sign > 0.0 else math.radians(90.0)
    )
    for role, prototype in (("Rim", rim_prototype), ("Tire", tire_prototype)):
        obj = duplicate_mesh_object(
            prototype, f"Octane_{name}_{role}", asset_collection
        )
        obj.location = (x, y, z)
        obj.rotation_euler = (wheel_axis_rotation, 0.0, 0.0)
        obj.scale = (scale, scale, scale)
        obj["asset_role"] = "wheel"
    add_brake(
        f"Octane_{name}",
        (x, y, z),
        side_sign,
        0.245 * scale,
        disc_material,
        caliper_material,
        asset_collection,
    )
    add_axle_connection(
        f"Octane_{name}",
        (x, y, z),
        side_sign,
        scale,
        spindle_face_y,
        axle_material,
        hub_material,
        asset_collection,
    )

bpy.data.objects.remove(rim_prototype, do_unlink=True)
bpy.data.objects.remove(tire_prototype, do_unlink=True)

# A single asset root makes the assembled car easy to transform or append.
asset_root = bpy.data.objects.new("Octane_Root", None)
asset_collection.objects.link(asset_root)
asset_root["asset_role"] = "root"
asset_root["source_note"] = scene["source_note"]
for obj in list(asset_collection.objects):
    if obj is asset_root:
        continue
    world_matrix = obj.matrix_world.copy()
    obj.parent = asset_root
    obj.matrix_world = world_matrix
try:
    asset_collection.asset_mark()
    asset_collection.asset_data.author = "Codex reconstruction and assembly"
    asset_collection.asset_data.description = (
        "Rocket League Octane body, OEM wheels, suspension-visible brakes, "
        "and packed source textures."
    )
except AttributeError:
    pass

# A subtle showroom floor makes the silhouette and suspension readable without
# becoming part of the asset collection.
floor_material = simple_material(
    "Showroom_Floor", (0.017, 0.022, 0.034, 1.0), metallic=0.28, roughness=0.3
)
bpy.ops.mesh.primitive_plane_add(size=100.0, location=(0.0, 0.0, -0.01))
floor = bpy.context.object
floor.name = "Presentation_Floor"
move_to_collection(floor, presentation_collection)
floor.data.materials.append(floor_material)

# Soft studio lighting tuned so the black chassis remains legible from all sides.
add_area_light(
    "Key_Light",
    (4.6, -4.8, 6.5),
    1150.0,
    5.0,
    (1.0, 0.82, 0.68),
    (0.2, 0.0, 0.6),
    presentation_collection,
)
add_area_light(
    "Underbody_Fill",
    (-0.15, -2.8, 0.7),
    180.0,
    4.0,
    (0.38, 0.58, 1.0),
    (0.15, 0.0, 0.34),
    presentation_collection,
)
add_area_light(
    "Fill_Light",
    (0.0, 5.5, 3.4),
    920.0,
    4.0,
    (0.48, 0.68, 1.0),
    (0.0, 0.0, 0.55),
    presentation_collection,
)
add_area_light(
    "Rim_Light",
    (-4.5, -2.8, 4.0),
    1050.0,
    3.2,
    (0.35, 0.55, 1.0),
    (-0.3, 0.0, 0.7),
    presentation_collection,
)
add_area_light(
    "Front_Fill",
    (5.4, 2.0, 2.5),
    520.0,
    2.5,
    (0.72, 0.82, 1.0),
    (1.0, 0.0, 0.55),
    presentation_collection,
)

camera_data = bpy.data.cameras.new("Octane_Review_Camera")
camera = bpy.data.objects.new("Octane_Review_Camera", camera_data)
presentation_collection.objects.link(camera)
scene.camera = camera

world = scene.world or bpy.data.worlds.new("Octane_World")
scene.world = world
world.use_nodes = True
background = world.node_tree.nodes.get("Background")
background.inputs["Color"].default_value = (0.045, 0.06, 0.1, 1.0)
background.inputs["Strength"].default_value = 0.35

scene.render.engine = "BLENDER_EEVEE"
scene.render.resolution_x = 900
scene.render.resolution_y = 900
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = "PNG"
scene.render.film_transparent = False
scene.render.image_settings.color_mode = "RGBA"
try:
    scene.view_settings.look = "AgX - Medium High Contrast"
except TypeError:
    pass

review_views = {
    "front": {
        "location": (-6.3, 0.0, 1.1),
        "target": (-1.0, 0.0, 0.58),
        "type": "ORTHO",
        "ortho_scale": 3.0,
    },
    "left_side": {
        "location": (0.15, 6.5, 0.68),
        "target": (0.15, 0.0, 0.68),
        "type": "ORTHO",
        "ortho_scale": 4.45,
    },
    "right_side": {
        "location": (0.15, -6.5, 0.68),
        "target": (0.15, 0.0, 0.68),
        "type": "ORTHO",
        "ortho_scale": 4.45,
    },
    "rear": {
        "location": (6.2, 0.0, 1.1),
        "target": (0.9, 0.0, 0.63),
        "type": "ORTHO",
        "ortho_scale": 3.0,
    },
    "front_three_quarter": {
        "location": (-5.1, -4.8, 2.8),
        "target": (-0.1, 0.0, 0.62),
        "type": "PERSP",
        "lens": 58.0,
    },
    "rear_three_quarter": {
        "location": (4.8, 4.6, 2.5),
        "target": (0.2, 0.0, 0.62),
        "type": "PERSP",
        "lens": 58.0,
    },
}

for view_name, settings in review_views.items():
    camera_data.type = settings["type"]
    if camera_data.type == "ORTHO":
        camera_data.ortho_scale = settings["ortho_scale"]
    else:
        camera_data.lens = settings["lens"]
    look_at(camera, settings["location"], settings["target"])
    scene.render.filepath = str(RENDER_DIR / f"octane_{view_name}.png")
    bpy.ops.render.render(write_still=True)

look_at(camera, (-5.1, -4.8, 2.8), (-0.1, 0.0, 0.62))
camera_data.type = "PERSP"
camera_data.lens = 58.0
scene.render.filepath = str(RENDER_DIR / "octane_front_three_quarter.png")

# Select the complete asset and leave the scene ready for inspection.
bpy.ops.object.select_all(action="DESELECT")
for obj in asset_collection.objects:
    obj.select_set(True)
if paint_object.name in bpy.data.objects:
    bpy.context.view_layer.objects.active = paint_object

# Ensure the saved file opens showing the authored colors instead of Solid-mode
# viewport colors.
for screen in bpy.data.screens:
    for area in screen.areas:
        if area.type != "VIEW_3D":
            continue
        shading = area.spaces.active.shading
        shading.type = "MATERIAL"
        shading.use_scene_lights = True
        shading.use_scene_world = True

bpy.ops.file.pack_all()
bpy.ops.wm.save_as_mainfile(filepath=str(BLEND_PATH), compress=True)

result = {
    "blend_path": str(BLEND_PATH),
    "asset_objects": len(asset_collection.objects),
    "render_paths": [
        str(RENDER_DIR / f"octane_{name}.png") for name in review_views
    ],
    "body_bounds": [
        round(value, 4)
        for value in (
            paint_object.dimensions.x,
            paint_object.dimensions.y,
            paint_object.dimensions.z,
        )
    ],
}
