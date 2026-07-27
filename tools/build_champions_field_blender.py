"""Build a polished Champions Field-inspired Rocket League arena in Blender.

The arena uses the standard Soccar dimensions in metres (1 Unreal unit = 1 cm)
and keeps the playable envelope separate from the decorative stadium shell.
"""

from __future__ import annotations

import math
import os
import random
from pathlib import Path

import bpy
from mathutils import Vector


ROOT = Path("/Users/am.will/Applications/rl-opus5")
OUTPUT = ROOT / "assets/ChampionsField/Champions_Field_Codex.blend"
RENDER_DIR = ROOT / "renders/champions_field_review"

# Standard Rocket League Soccar dimensions, converted from uu to metres.
HALF_WIDTH = 40.96
HALF_LENGTH = 51.20
CEILING = 20.44
GOAL_HALF_WIDTH = 8.92755
GOAL_HEIGHT = 6.42775
GOAL_DEPTH = 8.80
FLOOR_FILLET = 2.56

# A visually smooth version of the standard cut-corner footprint.
CORNER_RADIUS = 11.90
STRAIGHT_STEPS = 16
ARC_STEPS = 12

BLUE = (0.015, 0.24, 1.0, 1.0)
BLUE_SOFT = (0.03, 0.52, 1.0, 1.0)
ORANGE = (1.0, 0.17, 0.012, 1.0)
ORANGE_SOFT = (1.0, 0.48, 0.035, 1.0)
WHITE = (0.92, 0.97, 1.0, 1.0)
DARK = (0.008, 0.014, 0.030, 1.0)
STEEL = (0.08, 0.11, 0.16, 1.0)

random.seed(240705)


def clear_scene() -> None:
    if bpy.context.object and bpy.context.object.mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for collection in list(bpy.data.collections):
        if collection.name != "Collection":
            bpy.data.collections.remove(collection)
    master = bpy.context.scene.collection
    default = bpy.data.collections.get("Collection")
    if default:
        default.name = "ARENA_PLAYABLE"
    else:
        default = bpy.data.collections.new("ARENA_PLAYABLE")
        master.children.link(default)


def collection(name: str) -> bpy.types.Collection:
    existing = bpy.data.collections.get(name)
    if existing:
        return existing
    c = bpy.data.collections.new(name)
    bpy.context.scene.collection.children.link(c)
    return c


def move_to_collection(obj: bpy.types.Object, target: bpy.types.Collection) -> None:
    for c in list(obj.users_collection):
        c.objects.unlink(obj)
    target.objects.link(obj)


def material(
    name: str,
    color: tuple[float, float, float, float],
    *,
    metallic: float = 0.0,
    roughness: float = 0.5,
    emission: tuple[float, float, float, float] | None = None,
    emission_strength: float = 0.0,
    alpha: float = 1.0,
) -> bpy.types.Material:
    mat = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    mat.diffuse_color = (color[0], color[1], color[2], alpha)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = color
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = roughness
    if "Alpha" in bsdf.inputs:
        bsdf.inputs["Alpha"].default_value = alpha
    if emission:
        if "Emission Color" in bsdf.inputs:
            bsdf.inputs["Emission Color"].default_value = emission
        elif "Emission" in bsdf.inputs:
            bsdf.inputs["Emission"].default_value = emission
        if "Emission Strength" in bsdf.inputs:
            bsdf.inputs["Emission Strength"].default_value = emission_strength
    if alpha < 1.0:
        if hasattr(mat, "surface_render_method"):
            mat.surface_render_method = "DITHERED"
        elif hasattr(mat, "blend_method"):
            mat.blend_method = "BLEND"
        mat.use_transparency_overlap = False
    return mat


def turf_material() -> bpy.types.Material:
    mat = bpy.data.materials.new("CF_Turf_Procedural")
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    tex = nt.nodes.new("ShaderNodeTexCoord")
    noise = nt.nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 3.5
    noise.inputs["Detail"].default_value = 4.0
    noise.inputs["Roughness"].default_value = 0.7
    wave = nt.nodes.new("ShaderNodeTexWave")
    wave.wave_type = "BANDS"
    wave.bands_direction = "Y"
    wave.inputs["Scale"].default_value = 7.5
    wave.inputs["Distortion"].default_value = 1.0
    mix = nt.nodes.new("ShaderNodeMixRGB")
    mix.blend_type = "MULTIPLY"
    mix.inputs[0].default_value = 0.42
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = (0.012, 0.13, 0.038, 1.0)
    ramp.color_ramp.elements[1].color = (0.065, 0.48, 0.13, 1.0)
    bsdf.inputs["Roughness"].default_value = 0.88
    bsdf.inputs["Specular IOR Level"].default_value = 0.18
    nt.links.new(tex.outputs["Generated"], noise.inputs["Vector"])
    nt.links.new(tex.outputs["Generated"], wave.inputs["Vector"])
    nt.links.new(noise.outputs["Fac"], mix.inputs[1])
    nt.links.new(wave.outputs["Color"], mix.inputs[2])
    nt.links.new(mix.outputs[0], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
    return mat


def glass_hex_material() -> bpy.types.Material:
    mat = bpy.data.materials.new("CF_HexContainment")
    mat.diffuse_color = (0.018, 0.085, 0.20, 0.22)
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    tex = nt.nodes.new("ShaderNodeTexCoord")
    mapping = nt.nodes.new("ShaderNodeMapping")
    vor = nt.nodes.new("ShaderNodeTexVoronoi")
    vor.feature = "DISTANCE_TO_EDGE"
    vor.distance = "EUCLIDEAN"
    vor.inputs["Scale"].default_value = 54.0
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].position = 0.018
    ramp.color_ramp.elements[0].color = (0.035, 0.20, 0.48, 1.0)
    ramp.color_ramp.elements[1].position = 0.055
    ramp.color_ramp.elements[1].color = (0.006, 0.018, 0.045, 1.0)
    # Read as a substantial blue containment window rather than invisible
    # glass: enough tint and reflection to show the drivable surface, while
    # keeping the crowd legible behind it.
    bsdf.inputs["Base Color"].default_value = (0.018, 0.085, 0.20, 1.0)
    bsdf.inputs["Metallic"].default_value = 0.08
    bsdf.inputs["Roughness"].default_value = 0.16
    bsdf.inputs["Alpha"].default_value = 0.22
    if "Transmission Weight" in bsdf.inputs:
        bsdf.inputs["Transmission Weight"].default_value = 0.16
    if "Coat Weight" in bsdf.inputs:
        bsdf.inputs["Coat Weight"].default_value = 0.12
    if "IOR" in bsdf.inputs:
        bsdf.inputs["IOR"].default_value = 1.45
    if "Emission Color" in bsdf.inputs:
        nt.links.new(ramp.outputs["Color"], bsdf.inputs["Emission Color"])
    elif "Emission" in bsdf.inputs:
        nt.links.new(ramp.outputs["Color"], bsdf.inputs["Emission"])
    if "Emission Strength" in bsdf.inputs:
        bsdf.inputs["Emission Strength"].default_value = 0.13
    nt.links.new(tex.outputs["Generated"], mapping.inputs["Vector"])
    nt.links.new(mapping.outputs["Vector"], vor.inputs["Vector"])
    nt.links.new(vor.outputs["Distance"], ramp.inputs["Fac"])
    nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
    if hasattr(mat, "surface_render_method"):
        mat.surface_render_method = "DITHERED"
    elif hasattr(mat, "blend_method"):
        mat.blend_method = "BLEND"
    mat.use_transparency_overlap = False
    return mat


MAT_TURF = None
MAT_WHITE = None
MAT_WALL = None
MAT_GLASS = None
MAT_ROOF = None
MAT_BLUE = None
MAT_BLUE_SOFT = None
MAT_BLUE_INLAY = None
MAT_ORANGE = None
MAT_ORANGE_SOFT = None
MAT_ORANGE_INLAY = None
MAT_GOLD = None
MAT_DARK = None
MAT_STEEL = None
MAT_SEAT_BLUE = None
MAT_SEAT_ORANGE = None
MAT_SEAT_WHITE = None
MAT_SCREEN = None


def create_materials() -> None:
    global MAT_TURF, MAT_WHITE, MAT_WALL, MAT_GLASS, MAT_ROOF
    global MAT_BLUE, MAT_BLUE_SOFT, MAT_BLUE_INLAY, MAT_ORANGE, MAT_ORANGE_SOFT, MAT_ORANGE_INLAY, MAT_GOLD
    global MAT_DARK, MAT_STEEL, MAT_SEAT_BLUE, MAT_SEAT_ORANGE, MAT_SEAT_WHITE, MAT_SCREEN
    MAT_TURF = turf_material()
    MAT_WHITE = material("CF_FieldMarking", WHITE, roughness=0.38, emission=WHITE, emission_strength=0.22)
    MAT_WALL = material("CF_PlayableWall", (0.18, 0.23, 0.31, 1), metallic=0.55, roughness=0.32)
    MAT_GLASS = glass_hex_material()
    MAT_ROOF = material("CF_Roof", (0.045, 0.065, 0.115, 1), metallic=0.68, roughness=0.30)
    MAT_BLUE = material("CF_Blue", BLUE, metallic=0.22, roughness=0.28, emission=BLUE, emission_strength=4.5)
    MAT_BLUE_SOFT = material("CF_BlueSoft", BLUE_SOFT, metallic=0.18, roughness=0.32, emission=BLUE_SOFT, emission_strength=2.2)
    MAT_BLUE_INLAY = material("CF_BlueTurfInlay", (0.01, 0.07, 0.24, 1), roughness=0.72, emission=BLUE, emission_strength=0.12)
    MAT_ORANGE = material("CF_Orange", ORANGE, metallic=0.20, roughness=0.28, emission=ORANGE, emission_strength=4.5)
    MAT_ORANGE_SOFT = material("CF_OrangeSoft", ORANGE_SOFT, metallic=0.18, roughness=0.32, emission=ORANGE_SOFT, emission_strength=2.2)
    MAT_ORANGE_INLAY = material("CF_OrangeTurfInlay", (0.24, 0.045, 0.005, 1), roughness=0.72, emission=ORANGE, emission_strength=0.12)
    MAT_GOLD = material("CF_ChampionshipGold", (0.95, 0.52, 0.08, 1), metallic=0.85, roughness=0.20, emission=(1.0, 0.18, 0.02, 1), emission_strength=0.35)
    MAT_DARK = material("CF_DeepNavy", (0.028, 0.052, 0.095, 1), metallic=0.34, roughness=0.38)
    MAT_STEEL = material("CF_Steel", STEEL, metallic=0.86, roughness=0.24)
    MAT_SEAT_BLUE = material("CF_CrowdBlue", (0.03, 0.32, 1.0, 1), roughness=0.42, emission=(0.03, 0.25, 1.0, 1), emission_strength=1.55)
    MAT_SEAT_ORANGE = material("CF_CrowdOrange", (1.0, 0.22, 0.025, 1), roughness=0.42, emission=(1.0, 0.14, 0.01, 1), emission_strength=1.45)
    MAT_SEAT_WHITE = material("CF_CrowdWhite", (0.65, 0.78, 0.92, 1), roughness=0.5, emission=(0.45, 0.6, 0.8, 1), emission_strength=0.85)
    MAT_SCREEN = material("CF_Screen", (0.003, 0.008, 0.018, 1), metallic=0.15, roughness=0.18)


def rounded_rect_points(
    half_width: float,
    half_length: float,
    radius: float,
    straight_steps: int = STRAIGHT_STEPS,
    arc_steps: int = ARC_STEPS,
) -> list[tuple[float, float]]:
    """Counter-clockwise rounded rectangle, starting on the top-right edge."""
    radius = min(radius, half_width - 0.01, half_length - 0.01)
    points: list[tuple[float, float]] = []
    # Top: right to left.
    for i in range(straight_steps):
        t = i / straight_steps
        points.append((half_width - radius - 2 * (half_width - radius) * t, half_length))
    # Top-left arc.
    for i in range(arc_steps):
        a = math.pi / 2 + (math.pi / 2) * (i / arc_steps)
        points.append((-half_width + radius + radius * math.cos(a), half_length - radius + radius * math.sin(a)))
    # Left: top to bottom.
    for i in range(straight_steps):
        t = i / straight_steps
        points.append((-half_width, half_length - radius - 2 * (half_length - radius) * t))
    # Bottom-left arc.
    for i in range(arc_steps):
        a = math.pi + (math.pi / 2) * (i / arc_steps)
        points.append((-half_width + radius + radius * math.cos(a), -half_length + radius + radius * math.sin(a)))
    # Bottom: left to right.
    for i in range(straight_steps):
        t = i / straight_steps
        points.append((-half_width + radius + 2 * (half_width - radius) * t, -half_length))
    # Bottom-right arc.
    for i in range(arc_steps):
        a = 3 * math.pi / 2 + (math.pi / 2) * (i / arc_steps)
        points.append((half_width - radius + radius * math.cos(a), -half_length + radius + radius * math.sin(a)))
    # Right: bottom to top.
    for i in range(straight_steps):
        t = i / straight_steps
        points.append((half_width, -half_length + radius + 2 * (half_length - radius) * t))
    # Top-right arc.
    for i in range(arc_steps):
        a = (math.pi / 2) * (i / arc_steps)
        points.append((half_width - radius + radius * math.cos(a), half_length - radius + radius * math.sin(a)))
    return points


def playable_ring(inward: float) -> list[tuple[float, float]]:
    """Rounded arena ring with exact goal-post vertices inserted at both ends."""
    half_width = HALF_WIDTH - inward
    half_length = HALF_LENGTH - inward
    radius = max(0.5, CORNER_RADIUS - inward)
    source = rounded_rect_points(half_width, half_length, radius)
    result: list[tuple[float, float]] = []
    goal_edges = (-GOAL_HALF_WIDTH, GOAL_HALF_WIDTH)
    for i, p0 in enumerate(source):
        p1 = source[(i + 1) % len(source)]
        result.append(p0)
        on_end_wall = abs(abs(p0[1]) - half_length) < 1e-6 and abs(p1[1] - p0[1]) < 1e-6
        if not on_end_wall:
            continue
        inserts = [x for x in goal_edges if min(p0[0], p1[0]) < x < max(p0[0], p1[0])]
        inserts.sort(reverse=p1[0] < p0[0])
        result.extend((x, p0[1]) for x in inserts)
    return result


def add_mesh(
    name: str,
    vertices: list[tuple[float, float, float]],
    faces: list[tuple[int, ...]],
    target: bpy.types.Collection,
    materials: list[bpy.types.Material],
    face_materials: list[int] | None = None,
    smooth: bool = False,
) -> bpy.types.Object:
    mesh = bpy.data.meshes.new(f"{name}_Mesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    target.objects.link(obj)
    for mat in materials:
        mesh.materials.append(mat)
    if face_materials:
        for poly, index in zip(mesh.polygons, face_materials):
            poly.material_index = index
    if smooth:
        for poly in mesh.polygons:
            poly.use_smooth = True
    return obj


def add_flat_arc(
    name: str,
    center: tuple[float, float],
    radius: float,
    start_angle: float,
    end_angle: float,
    width: float,
    mat: bpy.types.Material,
    target: bpy.types.Collection,
    segments: int = 56,
) -> bpy.types.Object:
    """Create a flat annular strip for a field marking, never a raised tube."""
    verts: list[tuple[float, float, float]] = []
    faces: list[tuple[int, ...]] = []
    inner = radius - width * 0.5
    outer = radius + width * 0.5
    z = 0.012
    for i in range(segments + 1):
        a = start_angle + (end_angle - start_angle) * (i / segments)
        ca, sa = math.cos(a), math.sin(a)
        verts.append((center[0] + inner * ca, center[1] + inner * sa, z))
        verts.append((center[0] + outer * ca, center[1] + outer * sa, z))
    for i in range(segments):
        base = i * 2
        faces.append((base, base + 1, base + 3, base + 2))
    obj = add_mesh(name, verts, faces, target, [mat])
    obj["collision_enabled"] = False
    obj["marking_type"] = "flat_decal_geometry"
    return obj


def add_box(
    name: str,
    location: tuple[float, float, float],
    scale: tuple[float, float, float],
    mat: bpy.types.Material,
    target: bpy.types.Collection,
    bevel: float = 0.0,
) -> bpy.types.Object:
    bpy.ops.mesh.primitive_cube_add(location=location)
    obj = bpy.context.object
    obj.name = name
    obj.scale = (scale[0] / 2, scale[1] / 2, scale[2] / 2)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    move_to_collection(obj, target)
    obj.data.materials.append(mat)
    if bevel > 0:
        mod = obj.modifiers.new("Rounded_Edges", "BEVEL")
        mod.width = bevel
        mod.segments = 4
    return obj


def add_cylinder(
    name: str,
    location: tuple[float, float, float],
    radius: float,
    depth: float,
    mat: bpy.types.Material,
    target: bpy.types.Collection,
    vertices: int = 32,
) -> bpy.types.Object:
    bpy.ops.mesh.primitive_cylinder_add(vertices=vertices, radius=radius, depth=depth, location=location)
    obj = bpy.context.object
    obj.name = name
    move_to_collection(obj, target)
    obj.data.materials.append(mat)
    for poly in obj.data.polygons:
        poly.use_smooth = True
    bevel = obj.modifiers.new("Edge_Round", "BEVEL")
    bevel.width = min(radius * 0.12, depth * 0.22)
    bevel.segments = 3
    return obj


def add_beam(
    name: str,
    start: tuple[float, float, float],
    end: tuple[float, float, float],
    radius: float,
    mat: bpy.types.Material,
    target: bpy.types.Collection,
    vertices: int = 12,
) -> bpy.types.Object:
    p1, p2 = Vector(start), Vector(end)
    direction = p2 - p1
    midpoint = (p1 + p2) * 0.5
    bpy.ops.mesh.primitive_cylinder_add(vertices=vertices, radius=radius, depth=direction.length, location=midpoint)
    obj = bpy.context.object
    obj.name = name
    obj.rotation_mode = "QUATERNION"
    obj.rotation_quaternion = direction.to_track_quat("Z", "Y")
    move_to_collection(obj, target)
    obj.data.materials.append(mat)
    for poly in obj.data.polygons:
        poly.use_smooth = True
    return obj


def add_curve(
    name: str,
    points: list[tuple[float, float, float]],
    bevel: float,
    mat: bpy.types.Material,
    target: bpy.types.Collection,
    cyclic: bool = False,
    resolution: int = 2,
) -> bpy.types.Object:
    data = bpy.data.curves.new(f"{name}_Curve", "CURVE")
    data.dimensions = "3D"
    data.resolution_u = resolution
    data.bevel_depth = bevel
    data.bevel_resolution = 3
    spline = data.splines.new("NURBS")
    spline.points.add(len(points) - 1)
    for p, co in zip(spline.points, points):
        p.co = (*co, 1.0)
    spline.use_cyclic_u = cyclic
    if len(points) >= 4:
        spline.order_u = min(3, len(points))
        spline.use_endpoint_u = not cyclic
    obj = bpy.data.objects.new(name, data)
    target.objects.link(obj)
    data.materials.append(mat)
    return obj


def add_polyline_group(
    name: str,
    paths: list[list[tuple[float, float, float]]],
    bevel: float,
    mat: bpy.types.Material,
    target: bpy.types.Collection,
) -> bpy.types.Object:
    data = bpy.data.curves.new(f"{name}_Curve", "CURVE")
    data.dimensions = "3D"
    data.bevel_depth = bevel
    data.bevel_resolution = 2
    for path in paths:
        spline = data.splines.new("POLY")
        spline.points.add(len(path) - 1)
        for p, co in zip(spline.points, path):
            p.co = (*co, 1.0)
    obj = bpy.data.objects.new(name, data)
    target.objects.link(obj)
    data.materials.append(mat)
    return obj


def add_ring_surface(
    name: str,
    inner_offset: float,
    outer_offset: float,
    inner_z: float,
    outer_z: float,
    mat: bpy.types.Material,
    target: bpy.types.Collection,
    gap_east: bool = False,
) -> bpy.types.Object:
    inner = rounded_rect_points(
        HALF_WIDTH + inner_offset,
        HALF_LENGTH + inner_offset,
        CORNER_RADIUS + inner_offset,
    )
    outer = rounded_rect_points(
        HALF_WIDTH + outer_offset,
        HALF_LENGTH + outer_offset,
        CORNER_RADIUS + outer_offset,
    )
    n = len(inner)
    verts = [(x, y, inner_z) for x, y in inner] + [(x, y, outer_z) for x, y in outer]
    faces = []
    for i in range(n):
        j = (i + 1) % n
        if gap_east:
            xmid = (inner[i][0] + inner[j][0] + outer[i][0] + outer[j][0]) * 0.25
            ymid = (inner[i][1] + inner[j][1] + outer[i][1] + outer[j][1]) * 0.25
            if xmid > HALF_WIDTH + inner_offset - 1.0 and abs(ymid) < 14.0:
                continue
        faces.append((i, j, n + j, n + i))
    return add_mesh(name, verts, faces, target, [mat], smooth=True)


def build_playable_shell(playable: bpy.types.Collection) -> bpy.types.Object:
    # Quarter-round floor fillet, tall transparent wall, quarter-round roof transition.
    profile: list[tuple[float, float]] = []
    for i in range(9):
        angle = (i / 8) * (math.pi / 2)
        inward = FLOOR_FILLET - FLOOR_FILLET * math.sin(angle)
        z = FLOOR_FILLET - FLOOR_FILLET * math.cos(angle)
        profile.append((inward, z))
    profile.extend([(0.0, 6.45), (0.0, 11.0), (0.0, CEILING - FLOOR_FILLET)])
    for i in range(1, 9):
        angle = (i / 8) * (math.pi / 2)
        inward = FLOOR_FILLET - FLOOR_FILLET * math.cos(angle)
        z = CEILING - FLOOR_FILLET + FLOOR_FILLET * math.sin(angle)
        profile.append((inward, z))

    rings = []
    for inward, _ in profile:
        rings.append(playable_ring(inward))
    # Goal-mouth ownership is determined on the fixed outer footprint, not on
    # each inward-offset ramp row. Using an offset row here leaves the lower
    # fillet in front of the goal because its Y coordinate is 2.56 m infield.
    goal_test_ring = playable_ring(0.0)
    n = len(rings[0])
    verts = []
    for ring, (_, z) in zip(rings, profile):
        verts.extend((x, y, z) for x, y in ring)
    faces: list[tuple[int, ...]] = []
    face_mats: list[int] = []
    for row in range(len(profile) - 1):
        zmid = (profile[row][1] + profile[row + 1][1]) * 0.5
        mat_index = 0 if zmid < 3.1 else (1 if zmid < CEILING - 2.0 else 2)
        for i in range(n):
            j = (i + 1) % n
            xmid = (goal_test_ring[i][0] + goal_test_ring[j][0]) * 0.5
            ymid = (goal_test_ring[i][1] + goal_test_ring[j][1]) * 0.5
            is_goal_span = (
                abs(abs(ymid) - HALF_LENGTH) < 0.12
                and abs(xmid) < GOAL_HALF_WIDTH + 0.08
                and max(profile[row][1], profile[row + 1][1]) <= GOAL_HEIGHT + 0.08
            )
            if is_goal_span:
                continue
            a = row * n + i
            b = row * n + j
            c = (row + 1) * n + j
            d = (row + 1) * n + i
            faces.append((a, b, c, d))
            face_mats.append(mat_index)
    shell = add_mesh(
        "CF_PlayableShell",
        verts,
        faces,
        playable,
        [MAT_WALL, MAT_GLASS, MAT_ROOF],
        face_mats,
        smooth=True,
    )
    shell["collision_role"] = "continuous_floor_wall_ceiling"
    shell["units"] = "metres"
    shell["unreal_scale"] = 100.0

    # Flat playable ceiling closes the central opening exactly where the upper
    # quarter-round ends. It remains visually transparent but is real geometry.
    ceiling_ring = rings[-1]
    ceiling_verts = [(0, 0, CEILING)] + [(x, y, CEILING) for x, y in ceiling_ring]
    ceiling_faces = []
    for i in range(len(ceiling_ring)):
        # Reverse winding so the visible normal faces into the arena.
        ceiling_faces.append((0, (i + 1) % len(ceiling_ring) + 1, i + 1))
    ceiling = add_mesh(
        "CF_PlayableCeiling",
        ceiling_verts,
        ceiling_faces,
        playable,
        [MAT_GLASS],
        smooth=True,
    )
    ceiling["collision_role"] = "ceiling"
    ceiling["seam_offset_m"] = FLOOR_FILLET
    return shell


def build_field(playable: bpy.types.Collection, markings: bpy.types.Collection) -> None:
    points = playable_ring(FLOOR_FILLET)
    verts = [(0, 0, 0.0)] + [(x, y, 0.0) for x, y in points]
    faces = []
    for i in range(len(points)):
        faces.append((0, i + 1, (i + 1) % len(points) + 1))
    floor = add_mesh("CF_TurfFloor", verts, faces, playable, [MAT_TURF], smooth=True)
    floor["collision_role"] = "floor"

    z = 0.045
    # Split-color championship medallion beneath the white center markings.
    for name, start_angle, mat in [
        ("CenterMedallion_Blue", math.pi, MAT_BLUE_INLAY),
        ("CenterMedallion_Orange", 0.0, MAT_ORANGE_INLAY),
    ]:
        radius = 5.35
        disc_verts = [(0, 0, z - 0.02)]
        for i in range(49):
            a = start_angle + math.pi * (i / 48)
            disc_verts.append((radius * math.cos(a), radius * math.sin(a), z - 0.02))
        disc_faces = [(0, i, i + 1) for i in range(1, 49)]
        add_mesh(name, disc_verts, disc_faces, markings, [mat])

    # Midline and outer field guide.
    add_curve("Marking_Midline", [(-38.2, 0, z), (38.2, 0, z)], 0.055, MAT_WHITE, markings)
    outer = [(x, y, z) for x, y in rounded_rect_points(38.4, 48.7, 9.6)]
    add_curve("Marking_Outer", outer, 0.055, MAT_WHITE, markings, cyclic=True)

    def circle(name: str, center: tuple[float, float], radius: float, mat: bpy.types.Material, bevel: float = 0.055):
        pts = []
        for i in range(96):
            a = i / 96 * math.tau
            pts.append((center[0] + radius * math.cos(a), center[1] + radius * math.sin(a), z))
        add_curve(name, pts, bevel, mat, markings, cyclic=True)

    circle("Marking_CenterCircle", (0, 0), 9.15, MAT_WHITE)
    circle("Marking_CenterSpot", (0, 0), 0.55, MAT_WHITE, 0.085)
    # Goal-area arcs are flat visual markings only. The old beveled curves read
    # like ramps from gameplay cameras, so they deliberately have no height or
    # collision now and only occupy the field-facing semicircle.
    add_flat_arc(
        "Marking_BlueGoalArc",
        (0, -HALF_LENGTH + 2.4),
        11.7,
        0.0,
        math.pi,
        0.12,
        MAT_BLUE_SOFT,
        markings,
    )
    add_flat_arc(
        "Marking_OrangeGoalArc",
        (0, HALF_LENGTH - 2.4),
        11.7,
        math.pi,
        math.tau,
        0.12,
        MAT_ORANGE_SOFT,
        markings,
    )

    # Directional team inlays.
    for side, mat, label in [(-1, MAT_BLUE_SOFT, "Blue"), (1, MAT_ORANGE_SOFT, "Orange")]:
        y0 = side * 18.0
        for i in range(-3, 4):
            x = i * 5.2
            pts = [
                (x - 1.55, y0 - side * 0.45, z + 0.002),
                (x, y0 + side * 1.15, z + 0.002),
                (x + 1.55, y0 - side * 0.45, z + 0.002),
            ]
            add_mesh(f"Inlay_{label}_{i:+d}", pts, [(0, 1, 2)], markings, [mat])


def build_goals(playable: bpy.types.Collection, decor: bpy.types.Collection) -> None:
    for side, team_name, team_mat, soft_mat in [
        (-1, "Blue", MAT_BLUE, MAT_BLUE_SOFT),
        (1, "Orange", MAT_ORANGE, MAT_ORANGE_SOFT),
    ]:
        front_y = side * HALF_LENGTH
        back_y = side * (HALF_LENGTH + GOAL_DEPTH)
        frame_points: list[tuple[float, float, float]] = []
        r = 0.72
        # Left post to top-left round, across top, down right post.
        frame_points.append((-GOAL_HALF_WIDTH, front_y, 0.12))
        frame_points.append((-GOAL_HALF_WIDTH, front_y, GOAL_HEIGHT - r))
        for i in range(7):
            a = math.pi - (math.pi / 2) * (i / 6)
            frame_points.append(
                (
                    -GOAL_HALF_WIDTH + r + r * math.cos(a),
                    front_y,
                    GOAL_HEIGHT - r + r * math.sin(a),
                )
            )
        frame_points.append((GOAL_HALF_WIDTH - r, front_y, GOAL_HEIGHT))
        for i in range(7):
            a = math.pi / 2 - (math.pi / 2) * (i / 6)
            frame_points.append(
                (
                    GOAL_HALF_WIDTH - r + r * math.cos(a),
                    front_y,
                    GOAL_HEIGHT - r + r * math.sin(a),
                )
            )
        frame_points.append((GOAL_HALF_WIDTH, front_y, 0.12))
        add_curve(f"Goal_{team_name}_FrontFrame", frame_points, 0.24, team_mat, decor)

        # Rear frame and depth rails make the net read as a true tunnel.
        rear_points = [(x, back_y, z) for x, _, z in frame_points]
        add_curve(f"Goal_{team_name}_RearFrame", rear_points, 0.11, soft_mat, decor)
        for x, z in [
            (-GOAL_HALF_WIDTH, 0.16),
            (GOAL_HALF_WIDTH, 0.16),
            (-GOAL_HALF_WIDTH, GOAL_HEIGHT - r),
            (GOAL_HALF_WIDTH, GOAL_HEIGHT - r),
            (0, GOAL_HEIGHT),
        ]:
            add_beam(
                f"Goal_{team_name}_DepthRail_{x:.1f}_{z:.1f}",
                (x, front_y, z),
                (x, back_y, z),
                0.065,
                soft_mat,
                decor,
                10,
            )

        # Goal floor is team-colored but subdued.
        floor_center_y = side * (HALF_LENGTH + GOAL_DEPTH / 2)
        floor = add_box(
            f"Goal_{team_name}_Floor",
            (0, floor_center_y, -0.035),
            (GOAL_HALF_WIDTH * 2, GOAL_DEPTH, 0.07),
            soft_mat,
            playable,
            0.04,
        )
        floor["collision_role"] = "goal_floor"

        # The arena fillet is intentionally cut out across the goal opening.
        # This flat apron bridges the turf boundary directly into the goal
        # floor, preventing either a ramp or a hole in front of the net.
        apron_center_y = side * (HALF_LENGTH - FLOOR_FILLET * 0.5)
        apron = add_box(
            f"Goal_{team_name}_MouthApron",
            (0, apron_center_y, -0.035),
            (GOAL_HALF_WIDTH * 2, FLOOR_FILLET + 0.08, 0.07),
            MAT_TURF,
            playable,
            0.02,
        )
        apron["collision_role"] = "flat_goal_mouth_floor"
        apron["surface_height_m"] = 0.0
        apron["ramp_allowed"] = False

        # Solid goal tunnel surfaces behind the frame/net. The front remains
        # completely open; sharp corners are confined to the goal structure.
        tunnel_verts = [
            (-GOAL_HALF_WIDTH, front_y, 0.0),
            (GOAL_HALF_WIDTH, front_y, 0.0),
            (-GOAL_HALF_WIDTH, front_y, GOAL_HEIGHT),
            (GOAL_HALF_WIDTH, front_y, GOAL_HEIGHT),
            (-GOAL_HALF_WIDTH, back_y, 0.0),
            (GOAL_HALF_WIDTH, back_y, 0.0),
            (-GOAL_HALF_WIDTH, back_y, GOAL_HEIGHT),
            (GOAL_HALF_WIDTH, back_y, GOAL_HEIGHT),
        ]
        tunnel_faces = [
            (0, 4, 6, 2),  # left wall
            (1, 3, 7, 5),  # right wall
            (2, 6, 7, 3),  # roof
            (4, 5, 7, 6),  # back wall
        ]
        tunnel = add_mesh(
            f"Goal_{team_name}_TunnelShell",
            tunnel_verts,
            tunnel_faces,
            playable,
            [MAT_DARK],
        )
        tunnel["collision_role"] = "goal_tunnel"

        # Back-wall net grid.
        paths: list[list[tuple[float, float, float]]] = []
        net_y = back_y - side * 0.035
        for x in [(-GOAL_HALF_WIDTH + 0.45) + i * 0.95 for i in range(18)]:
            if x < GOAL_HALF_WIDTH:
                paths.append([(x, net_y, 0.2), (x, net_y, GOAL_HEIGHT - 0.2)])
        for zi in range(1, 10):
            zz = zi * (GOAL_HEIGHT / 10)
            paths.append([(-GOAL_HALF_WIDTH + 0.2, net_y, zz), (GOAL_HALF_WIDTH - 0.2, net_y, zz)])
        add_polyline_group(f"Goal_{team_name}_BackNet", paths, 0.025, soft_mat, decor)

        # Goal volume metadata helper, hidden from renders.
        volume = add_box(
            f"Goal_{team_name}_TriggerGuide",
            (0, side * (HALF_LENGTH + GOAL_DEPTH * 0.5), GOAL_HEIGHT * 0.5),
            (GOAL_HALF_WIDTH * 2, GOAL_DEPTH, GOAL_HEIGHT),
            MAT_DARK,
            playable,
        )
        volume.display_type = "WIRE"
        volume.hide_render = True
        volume["gameplay_role"] = "goal_trigger"
        volume["team"] = team_name.lower()


BIG_PADS = [
    (35.84, 0),
    (-35.84, 0),
    (30.72, 40.96),
    (-30.72, 40.96),
    (30.72, -40.96),
    (-30.72, -40.96),
]

SMALL_PADS = [
    (0, -42.40), (-17.92, -41.84), (17.92, -41.84), (-9.40, -33.08), (9.40, -33.08),
    (0, -28.16), (-35.84, -24.84), (35.84, -24.84), (-17.88, -23.00), (17.88, -23.00),
    (-20.48, -10.36), (0, -10.24), (20.48, -10.36), (-10.24, 0), (10.24, 0),
    (-20.48, 10.36), (0, 10.24), (20.48, 10.36), (-17.88, 23.00), (17.88, 23.00),
    (-35.84, 24.84), (35.84, 24.84), (0, 28.16), (-9.40, 33.08), (9.40, 33.08),
    (-17.92, 41.84), (17.92, 41.84), (0, 42.40),
]


def build_boost_pads(decor: bpy.types.Collection, lighting: bpy.types.Collection) -> None:
    for big, positions in [(True, BIG_PADS), (False, SMALL_PADS)]:
        for i, (x, y) in enumerate(positions):
            radius = 0.86 if big else 0.42
            name = f"Boost_{'Big' if big else 'Small'}_{i:02d}"
            add_cylinder(name, (x, y, 0.055), radius, 0.11, MAT_STEEL, decor, 32)
            bpy.ops.mesh.primitive_torus_add(
                major_radius=radius * 0.72,
                minor_radius=0.075 if big else 0.04,
                major_segments=28,
                minor_segments=8,
                location=(x, y, 0.15),
            )
            ring = bpy.context.object
            ring.name = f"{name}_Glow"
            move_to_collection(ring, decor)
            ring.data.materials.append(MAT_GOLD)
            add_cylinder(
                f"{name}_Core",
                (x, y, 0.13),
                radius * 0.30,
                0.13,
                MAT_ORANGE_SOFT,
                decor,
                24,
            )
            if big:
                add_point_light(
                    f"{name}_Light",
                    (x, y, 1.0),
                    (1.0, 0.26, 0.02),
                    320.0,
                    lighting,
                    radius=2.5,
                )
                # Full-boost pickup: a clearly floating energy orb with two
                # canted orbit rings, matching the readable Rocket League cue.
                bpy.ops.mesh.primitive_ico_sphere_add(
                    subdivisions=3,
                    radius=0.44,
                    location=(x, y, 1.30),
                )
                orb = bpy.context.object
                orb.name = f"{name}_FloatingOrb"
                move_to_collection(orb, decor)
                orb.data.materials.append(MAT_GOLD)
                orb["gameplay_role"] = "full_boost_orb"
                bpy.ops.mesh.primitive_ico_sphere_add(
                    subdivisions=2,
                    radius=0.17,
                    location=(x, y, 1.30),
                )
                core = bpy.context.object
                core.name = f"{name}_FloatingOrb_Core"
                move_to_collection(core, decor)
                core.data.materials.append(MAT_WHITE)
                for ring_index, rotation in enumerate(
                    [(math.radians(64), 0, math.radians(22)), (math.radians(112), math.radians(28), 0)]
                ):
                    bpy.ops.mesh.primitive_torus_add(
                        major_radius=0.62,
                        minor_radius=0.040,
                        major_segments=32,
                        minor_segments=8,
                        location=(x, y, 1.30),
                        rotation=rotation,
                    )
                    orbit = bpy.context.object
                    orbit.name = f"{name}_OrbitalRing_{ring_index}"
                    move_to_collection(orbit, decor)
                    orbit.data.materials.append(MAT_ORANGE)


def build_stands(architecture: bpy.types.Collection, decor: bpy.types.Collection) -> None:
    # Three tiers, each separated by a strong illuminated fascia.
    tiers = [
        (4.6, 10.8, 2.8, 7.3),
        (10.0, 17.0, 8.0, 13.2),
        (16.0, 24.0, 14.0, 20.2),
    ]
    for idx, (inner, outer, low, high) in enumerate(tiers, 1):
        add_ring_surface(
            f"Stand_Tier_{idx}",
            inner,
            outer,
            low,
            high,
            MAT_DARK,
            architecture,
            gap_east=True,
        )
        boundary = rounded_rect_points(
            HALF_WIDTH + inner,
            HALF_LENGTH + inner,
            CORNER_RADIUS + inner,
        )
        # Build each ribbon from local edge segments. This follows the bowl
        # exactly and never interpolates a shortcut across the pitch.
        blue_paths = []
        orange_paths = []
        for i, (x0, y0) in enumerate(boundary):
            x1, y1 = boundary[(i + 1) % len(boundary)]
            path = [(x0, y0, high + 0.15), (x1, y1, high + 0.15)]
            if (y0 + y1) * 0.5 <= 0:
                blue_paths.append(path)
            else:
                orange_paths.append(path)
        add_polyline_group(f"Tier_{idx}_BlueRibbon", blue_paths, 0.13, MAT_BLUE, decor)
        add_polyline_group(f"Tier_{idx}_OrangeRibbon", orange_paths, 0.13, MAT_ORANGE, decor)

        # Low-poly crowd lights: one combined octahedron mesh per tier so they
        # read from every camera angle without creating thousands of objects.
        verts: list[tuple[float, float, float]] = []
        faces: list[tuple[int, ...]] = []
        mats: list[int] = []
        rows = 7
        for row in range(rows):
            t = row / max(1, rows - 1)
            row_offset = inner + 0.65 + (outer - inner - 1.2) * t
            pts = rounded_rect_points(
                HALF_WIDTH + row_offset,
                HALF_LENGTH + row_offset,
                CORNER_RADIUS + row_offset,
                straight_steps=28,
                arc_steps=16,
            )
            z = low + 0.48 + (high - low) * t
            for i, (x, y) in enumerate(pts):
                if x > HALF_WIDTH + row_offset - 0.8 and abs(y) < 14.0:
                    continue
                # Keep every spectator completely outside the goal tunnel and
                # its immediate sightline. Seating can remain above the goal,
                # but never inside the net volume.
                if (
                    abs(y) > HALF_LENGTH + 0.75
                    and abs(x) < GOAL_HALF_WIDTH + 3.2
                    and z < GOAL_HEIGHT + 3.0
                ):
                    continue
                if (i + row) % 4 == 0:
                    continue
                p = Vector((x, y, z))
                outward = Vector((x, y, 0)).normalized()
                tangent = Vector((-outward.y, outward.x, 0))
                w = 0.19 + random.random() * 0.10
                h = 0.29 + random.random() * 0.18
                base = len(verts)
                verts.extend(
                    [
                        tuple(p + tangent * w),
                        tuple(p - tangent * w),
                        tuple(p + outward * w),
                        tuple(p - outward * w),
                        tuple(p + Vector((0, 0, h))),
                        tuple(p - Vector((0, 0, h * 0.45))),
                    ]
                )
                faces.extend(
                    [
                        (base, base + 2, base + 4),
                        (base + 2, base + 1, base + 4),
                        (base + 1, base + 3, base + 4),
                        (base + 3, base, base + 4),
                        (base + 2, base, base + 5),
                        (base + 1, base + 2, base + 5),
                        (base + 3, base + 1, base + 5),
                        (base, base + 3, base + 5),
                    ]
                )
                r = random.random()
                mat_index = 0 if r < 0.44 else (1 if r < 0.88 else 2)
                mats.extend([mat_index] * 8)
        add_mesh(
            f"Crowd_Tier_{idx}",
            verts,
            faces,
            decor,
            [MAT_SEAT_BLUE, MAT_SEAT_ORANGE, MAT_SEAT_WHITE],
            mats,
        )

    # Upper canopy and lower wall surround.
    add_ring_surface("Canopy_Main", 21.0, 26.2, 21.2, 23.3, MAT_ROOF, architecture, gap_east=True)
    add_ring_surface("Concourse_Lower", 2.8, 5.2, 2.5, 3.4, MAT_STEEL, architecture, gap_east=True)

    # Repeated structural ribs tie the bowl together.
    rib_points = rounded_rect_points(HALF_WIDTH + 3.0, HALF_LENGTH + 3.0, CORNER_RADIUS + 3.0, 10, 7)
    for i, (x, y) in enumerate(rib_points):
        if i % 4:
            continue
        direction = Vector((x, y, 0)).normalized()
        outer = Vector((x, y, 0)) + direction * 18.0
        add_beam(
            f"Stadium_Rib_{i:02d}",
            (x, y, 2.4),
            (outer.x, outer.y, 22.0),
            0.22,
            MAT_STEEL,
            architecture,
            10,
        )


def add_text(
    name: str,
    text: str,
    location: tuple[float, float, float],
    rotation: tuple[float, float, float],
    size: float,
    extrude: float,
    mat: bpy.types.Material,
    target: bpy.types.Collection,
    align: str = "CENTER",
) -> bpy.types.Object:
    data = bpy.data.curves.new(f"{name}_Font", "FONT")
    data.body = text
    data.align_x = align
    data.align_y = "CENTER"
    data.size = size
    data.extrude = extrude
    data.bevel_depth = extrude * 0.18
    obj = bpy.data.objects.new(name, data)
    target.objects.link(obj)
    obj.location = location
    obj.rotation_euler = rotation
    data.materials.append(mat)
    return obj


def orient_flat_object(obj: bpy.types.Object, normal: tuple[float, float, float]) -> None:
    """Orient a flat +Z-facing object toward normal while keeping local Y upright."""
    obj.rotation_mode = "QUATERNION"
    obj.rotation_quaternion = Vector(normal).normalized().to_track_quat("Z", "Y")


def build_scoreboards_and_identity(architecture: bpy.types.Collection, decor: bpy.types.Collection) -> None:
    # Four end/side video structures, deliberately original branding.
    boards = [
        ("West", (-50.2, 0, 13.3), (8.0, 0.55, 6.8), (1, 0, 0)),
        ("East", (50.2, 0, 13.3), (8.0, 0.55, 6.8), (-1, 0, 0)),
        ("Blue", (0, -60.6, 14.2), (12.5, 0.55, 6.4), (0, 1, 0)),
        ("Orange", (0, 60.6, 14.2), (12.5, 0.55, 6.4), (0, -1, 0)),
    ]
    for label, loc, dims, normal in boards:
        panel = add_box(f"Scoreboard_{label}", loc, dims, MAT_SCREEN, architecture, 0.38)
        if label in {"West", "East"}:
            panel.rotation_euler[2] = math.pi / 2
        text_loc = list(loc)
        if label == "West":
            text_loc[0] += 0.31
        elif label == "East":
            text_loc[0] -= 0.31
        elif label == "Blue":
            text_loc[1] += 0.31
        else:
            text_loc[1] -= 0.31
        title = add_text(
            f"Scoreboard_{label}_Title",
            "APEX  CHAMPIONSHIP",
            tuple(text_loc),
            (0, 0, 0),
            0.78,
            0.045,
            MAT_WHITE,
            decor,
        )
        orient_flat_object(title, normal)

    # Championship monument: an opened side terrace and crown-like trophy,
    # echoing Champions Field's iconic statue without copying its shield mark.
    base_x = 72.0
    for i in range(6):
        step_x = 46.5 + i * 4.1
        step_width = 4.3
        step_y = 29.0 - i * 2.6
        step_z = 1.1 + i * 1.05
        add_box(
            f"Monument_Terrace_{i}",
            (step_x, 0, step_z * 0.5),
            (step_width, step_y, step_z),
            MAT_DARK,
            architecture,
            0.22,
        )
        add_box(
            f"Monument_Terrace_{i}_Edge",
            (step_x - step_width * 0.5 + 0.05, 0, step_z + 0.04),
            (0.10, step_y, 0.12),
            MAT_GOLD,
            decor,
            0.02,
        )
    add_cylinder("Monument_Pedestal", (base_x, 0, 14.0), 5.2, 28.0, MAT_STEEL, architecture, 48)
    add_cylinder("Monument_GoldBand", (base_x, 0, 25.2), 5.35, 1.1, MAT_GOLD, decor, 48)
    spiral = []
    for i in range(72):
        a = i / 71 * math.tau * 2.25
        radius = 5.55
        spiral.append((base_x + radius * math.cos(a), radius * math.sin(a), 20.0 + i / 71 * 13.5))
    add_curve("Monument_AscendingRibbon", spiral, 0.26, MAT_GOLD, decor)
    for i, a in enumerate([-0.9, -0.45, 0, 0.45, 0.9]):
        start = (base_x + math.cos(a) * 2.2, math.sin(a) * 2.2, 26.0)
        end = (base_x + math.cos(a) * 5.2, math.sin(a) * 5.2, 37.5 if i in {0, 4} else 40.0)
        add_beam(f"Monument_Crown_{i}", start, end, 0.34, MAT_GOLD, decor, 16)
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=3, radius=2.65, location=(base_x, 0, 38.7))
    orb = bpy.context.object
    orb.name = "Monument_ChampionOrb"
    move_to_collection(orb, decor)
    orb.data.materials.append(MAT_GOLD)

    # Suspended center halo gives the stadium a recognizable original silhouette.
    for radius, z, mat in [(10.5, 25.8, MAT_STEEL), (9.8, 25.8, MAT_BLUE_SOFT), (8.9, 25.8, MAT_ORANGE_SOFT)]:
        bpy.ops.mesh.primitive_torus_add(
            major_radius=radius,
            minor_radius=0.16 if mat == MAT_STEEL else 0.08,
            major_segments=96,
            minor_segments=10,
            location=(0, 0, z),
        )
        halo = bpy.context.object
        halo.name = f"Center_Halo_{radius:.1f}"
        move_to_collection(halo, decor)
        halo.data.materials.append(mat)


def build_roof_trusses_and_banners(architecture: bpy.types.Collection, decor: bpy.types.Collection) -> None:
    # Broad arched roof trusses are one of Champions Field's strongest
    # silhouettes. These sit beyond the playable ceiling and do not affect play.
    for arch_index, y in enumerate((-37.0, 0.0, 37.0)):
        paths = []
        for y_offset in (-0.7, 0.7):
            path = []
            for i in range(25):
                x = -66.0 + i * (132.0 / 24)
                z = 22.6 + 10.5 * (1.0 - (x / 66.0) ** 2)
                path.append((x, y + y_offset, z))
            paths.append(path)
        for rail_index, path in enumerate(paths):
            add_curve(
                f"RoofTruss_{arch_index}_{rail_index}",
                path,
                0.22,
                MAT_STEEL,
                architecture,
            )
        for i in range(0, 25, 3):
            x = -66.0 + i * (132.0 / 24)
            z = 22.6 + 10.5 * (1.0 - (x / 66.0) ** 2)
            add_beam(
                f"RoofTruss_Brace_{arch_index}_{i:02d}",
                (x, y - 0.7, z),
                (x, y + 0.7, z),
                0.10,
                MAT_STEEL,
                architecture,
                8,
            )

    # Vertical finals banners punctuate the three seating decks.
    banner_specs = []
    for y in (-34.0, -16.0, 16.0, 34.0):
        banner_specs.extend([(-48.7, y), (48.7, y)])
    for i, (x, y) in enumerate(banner_specs):
        trim_mat = MAT_BLUE_SOFT if y < 0 else MAT_ORANGE_SOFT
        banner = add_box(
            f"Finals_Banner_{i:02d}",
            (x, y, 12.2),
            (0.20, 2.8, 6.5),
            MAT_DARK,
            decor,
            0.12,
        )
        field_side_x = x + (0.12 if x < 0 else -0.12)
        for strip_y in (y - 1.16, y + 1.16):
            add_box(
                f"Finals_Banner_{i:02d}_Trim_{strip_y:+.1f}",
                (field_side_x, strip_y, 12.2),
                (0.08, 0.12, 5.9),
                trim_mat,
                decor,
                0.025,
            )
        add_box(
            f"Finals_Banner_{i:02d}_GoldBar",
            (field_side_x, y, 14.8),
            (0.08, 2.30, 0.13),
            MAT_GOLD,
            decor,
            0.02,
        )

    # Subtle glass uprights around the playable bowl.
    boundary = rounded_rect_points(HALF_WIDTH, HALF_LENGTH, CORNER_RADIUS, 12, 8)
    for i, (x, y) in enumerate(boundary):
        if i % 4:
            continue
        add_beam(
            f"Glass_Upright_{i:02d}",
            (x, y, 2.7),
            (x, y, 17.7),
            0.055,
            MAT_STEEL,
            architecture,
            8,
        )


def add_point_light(
    name: str,
    location: tuple[float, float, float],
    color: tuple[float, float, float],
    energy: float,
    target: bpy.types.Collection,
    radius: float = 1.0,
) -> bpy.types.Object:
    data = bpy.data.lights.new(name, "POINT")
    data.color = color
    data.energy = energy
    data.shadow_soft_size = radius
    obj = bpy.data.objects.new(name, data)
    target.objects.link(obj)
    obj.location = location
    return obj


def add_area_light(
    name: str,
    location: tuple[float, float, float],
    target_point: tuple[float, float, float],
    color: tuple[float, float, float],
    energy: float,
    size: float,
    target: bpy.types.Collection,
) -> bpy.types.Object:
    data = bpy.data.lights.new(name, "AREA")
    data.color = color
    data.energy = energy
    data.shape = "DISK"
    data.size = size
    obj = bpy.data.objects.new(name, data)
    target.objects.link(obj)
    obj.location = location
    obj.rotation_euler = (Vector(target_point) - obj.location).to_track_quat("-Z", "Y").to_euler()
    return obj


def build_lighting(lighting: bpy.types.Collection, architecture: bpy.types.Collection) -> None:
    # Tournament floodlights.
    banks = [
        (-35, -52, 24), (0, -57, 25), (35, -52, 24),
        (-35, 52, 24), (0, 57, 25), (35, 52, 24),
        (-48, -23, 23), (-48, 23, 23), (48, -23, 23), (48, 23, 23),
    ]
    for i, loc in enumerate(banks):
        team_color = (0.55, 0.72, 1.0) if loc[1] <= 0 else (1.0, 0.63, 0.38)
        add_area_light(f"Flood_{i:02d}", loc, (0, loc[1] * 0.18, 2.0), team_color, 2600.0, 8.0, lighting)
        bank = add_box(
            f"FloodBank_{i:02d}",
            loc,
            (6.5, 1.1, 0.55),
            MAT_WHITE,
            architecture,
            0.18,
        )
        if abs(loc[0]) > 40:
            bank.rotation_euler[2] = math.pi / 2
    add_area_light("Field_Key", (0, 0, 30), (0, 0, 0), (0.72, 0.82, 1.0), 8200.0, 34.0, lighting)
    add_area_light("Stand_Fill_Blue", (0, -22, 18), (0, -58, 11), (0.12, 0.38, 1.0), 4200.0, 28.0, lighting)
    add_area_light("Stand_Fill_Orange", (0, 22, 18), (0, 58, 11), (1.0, 0.30, 0.06), 4200.0, 28.0, lighting)
    sun_data = bpy.data.lights.new("Stadium_MoonFill", "SUN")
    sun_data.energy = 1.15
    sun_data.color = (0.28, 0.42, 0.70)
    sun = bpy.data.objects.new("Stadium_MoonFill", sun_data)
    lighting.objects.link(sun)
    sun.rotation_euler = (math.radians(28), math.radians(-18), math.radians(32))
    add_point_light("Blue_Goal_Light", (0, -47.0, 5.3), (0.01, 0.18, 1.0), 1100, lighting, 5)
    add_point_light("Orange_Goal_Light", (0, 47.0, 5.3), (1.0, 0.13, 0.01), 1100, lighting, 5)


def add_camera(
    name: str,
    location: tuple[float, float, float],
    target_point: tuple[float, float, float],
    target: bpy.types.Collection,
    lens: float = 24.0,
    ortho: float | None = None,
) -> bpy.types.Object:
    data = bpy.data.cameras.new(name)
    data.lens = lens
    data.sensor_width = 36
    if ortho is not None:
        data.type = "ORTHO"
        data.ortho_scale = ortho
    obj = bpy.data.objects.new(name, data)
    target.objects.link(obj)
    obj.location = location
    obj.rotation_euler = (Vector(target_point) - obj.location).to_track_quat("-Z", "Y").to_euler()
    return obj


def build_cameras(cameras: bpy.types.Collection) -> dict[str, bpy.types.Object]:
    cams = {
        "hero": add_camera("CF_Camera_Hero", (36, -43, 15.5), (0, 4, 4.2), cameras, 23),
        "field": add_camera("CF_Camera_Field", (23, -40, 3.4), (0, 18, 4.2), cameras, 21),
        "goal": add_camera("CF_Camera_Goal", (0, -44.5, 2.6), (0, 34, 3.8), cameras, 19),
        "corner": add_camera("CF_Camera_Corner", (35.5, -41, 6.3), (-2, -4, 4.0), cameras, 22),
        "top": add_camera("CF_Camera_Top", (0, 0, 130), (0, 0, 0), cameras, 50, 142),
        "orange": add_camera("CF_Camera_Orange", (-35, 43, 15.0), (0, -4, 4.2), cameras, 23),
        "monument": add_camera("CF_Camera_Monument", (125, -75, 50.0), (58, 0, 24.0), cameras, 40),
        "goal_close": add_camera("CF_Camera_GoalClose", (16.0, 31.5, 3.4), (0, 53.8, 2.3), cameras, 21),
        "wall": add_camera("CF_Camera_Wall", (19.0, -22.0, 4.2), (40.4, -4.0, 7.5), cameras, 24),
    }
    return cams


def configure_scene(cameras: dict[str, bpy.types.Object]) -> None:
    scene = bpy.context.scene
    scene.name = "Champions_Field_Arena"
    scene.unit_settings.system = "METRIC"
    scene.unit_settings.scale_length = 1.0
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 1280
    scene.render.resolution_y = 720
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.film_transparent = False
    scene.render.image_settings.color_mode = "RGBA"
    if hasattr(scene, "eevee"):
        scene.eevee.taa_render_samples = 64
    scene.camera = cameras["hero"]

    world = scene.world or bpy.data.worlds.new("CF_NightWorld")
    scene.world = world
    world.use_nodes = True
    bg = world.node_tree.nodes.get("Background")
    bg.inputs["Color"].default_value = (0.006, 0.016, 0.055, 1.0)
    bg.inputs["Strength"].default_value = 0.48

    # Mild cinematic contrast.
    scene.view_settings.look = "AgX - Medium High Contrast"
    scene.view_settings.exposure = 0.8

    # Blender 5 moved compositor node access away from Scene.node_tree.
    # Keep the source asset version-agnostic; emissive materials and real lights
    # provide the glow, while Unreal can add the final bloom pass.


def build_metadata(markers: bpy.types.Collection) -> None:
    markers.hide_render = True
    marker_specs = [
        ("Spawn_Ball", (0, 0, 0.93), "ball_spawn"),
        ("Spawn_Blue_Center", (0, -46.08, 0.1), "car_spawn"),
        ("Spawn_Orange_Center", (0, 46.08, 0.1), "car_spawn"),
        ("Spawn_Blue_Diagonal_L", (-20.48, -25.60, 0.1), "car_spawn"),
        ("Spawn_Blue_Diagonal_R", (20.48, -25.60, 0.1), "car_spawn"),
        ("Spawn_Orange_Diagonal_L", (-20.48, 25.60, 0.1), "car_spawn"),
        ("Spawn_Orange_Diagonal_R", (20.48, 25.60, 0.1), "car_spawn"),
    ]
    for name, location, role in marker_specs:
        obj = bpy.data.objects.new(name, None)
        markers.objects.link(obj)
        obj.location = location
        obj.empty_display_type = "ARROWS"
        obj.empty_display_size = 1.0
        obj["gameplay_role"] = role


def main() -> dict:
    RENDER_DIR.mkdir(parents=True, exist_ok=True)
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)

    clear_scene()
    create_materials()

    playable = bpy.data.collections.get("ARENA_PLAYABLE")
    architecture = collection("STADIUM_ARCHITECTURE")
    decor = collection("ARENA_DECOR")
    markings = collection("FIELD_MARKINGS")
    lighting = collection("LIGHTING")
    cameras = collection("CAMERAS")
    markers = collection("GAMEPLAY_MARKERS")

    build_playable_shell(playable)
    build_field(playable, markings)
    build_goals(playable, decor)
    build_boost_pads(decor, lighting)
    build_stands(architecture, decor)
    build_scoreboards_and_identity(architecture, decor)
    build_roof_trusses_and_banners(architecture, decor)
    build_lighting(lighting, architecture)
    cam_map = build_cameras(cameras)
    build_metadata(markers)
    configure_scene(cam_map)

    root = bpy.data.objects.new("Champions_Field_Root", None)
    playable.objects.link(root)
    root["asset_name"] = "Apex Champions Field"
    root["inspiration"] = "Rocket League Champions Field"
    root["playable_width_m"] = HALF_WIDTH * 2
    root["playable_length_m"] = HALF_LENGTH * 2
    root["ceiling_m"] = CEILING
    root["goal_width_m"] = GOAL_HALF_WIDTH * 2
    root["goal_height_m"] = GOAL_HEIGHT
    root["goal_depth_m"] = GOAL_DEPTH
    root["boost_pad_count"] = len(BIG_PADS) + len(SMALL_PADS)
    root["rounded_shell"] = True

    bpy.context.scene.camera = cam_map["hero"]
    for datablocks in (
        bpy.data.meshes,
        bpy.data.curves,
        bpy.data.materials,
        bpy.data.lights,
        bpy.data.cameras,
    ):
        for datablock in list(datablocks):
            if datablock.users == 0:
                datablocks.remove(datablock)
    bpy.ops.wm.save_as_mainfile(filepath=str(OUTPUT))

    return {
        "file": str(OUTPUT),
        "objects": len(bpy.context.scene.objects),
        "meshes": len(bpy.data.meshes),
        "materials": len(bpy.data.materials),
        "boost_pads": len(BIG_PADS) + len(SMALL_PADS),
        "cameras": list(cam_map.keys()),
        "scene": bpy.context.scene.name,
    }


result = main()
