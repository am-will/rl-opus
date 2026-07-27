"""Small helpers shared by every builder module.

Everything that takes coordinates takes them in Unreal units; `mesh_object`
applies the uu -> metre scale exactly once, on the way into Blender.
"""

import math

import bpy

from . import const

TAU = math.pi * 2


# --- scene plumbing ---------------------------------------------------------

def wipe_scene():
    """Factory-fresh scene without relying on --factory-startup."""
    for coll in list(bpy.data.collections):
        bpy.data.collections.remove(coll)
    for ob in list(bpy.data.objects):
        bpy.data.objects.remove(ob, do_unlink=True)
    for block in (
        bpy.data.meshes, bpy.data.materials, bpy.data.images, bpy.data.lights,
        bpy.data.cameras, bpy.data.node_groups, bpy.data.curves,
        bpy.data.worlds, bpy.data.textures,
    ):
        for item in list(block):
            block.remove(item)


def collection(name, parent=None):
    coll = bpy.data.collections.get(name)
    if coll is None:
        coll = bpy.data.collections.new(name)
    host = parent.children if parent else bpy.context.scene.collection.children
    if coll.name not in host:
        host.link(coll)
    return coll


def mesh_object(name, verts, faces, coll, materials=(), mat_index=None,
                uvs=None, shade_smooth=False, scale=const.S):
    """Build a mesh from uu-space data.

    `mat_index` is either None, an int applied to every face, or a per-face
    sequence. `uvs` is a per-loop sequence of (u, v) matching `faces` order.
    `shade_smooth` is either a bool for the whole mesh or a per-face sequence,
    for meshes that want smooth surfaces meeting at a hard edge.
    """
    me = bpy.data.meshes.new(name)
    me.from_pydata([(x * scale, y * scale, z * scale) for x, y, z in verts], [], list(faces))
    me.update()

    for mat in materials:
        me.materials.append(mat)

    if mat_index is not None and len(me.polygons):
        if isinstance(mat_index, int):
            for poly in me.polygons:
                poly.material_index = mat_index
        else:
            for poly, idx in zip(me.polygons, mat_index):
                poly.material_index = idx

    if uvs is not None:
        layer = me.uv_layers.new(name="UVMap")
        flat = [c for uv in uvs for c in uv]
        layer.data.foreach_set("uv", flat)

    if shade_smooth is not False and shade_smooth is not None:
        if isinstance(shade_smooth, bool):
            flags = [True] * len(me.polygons)
        else:
            flags = list(shade_smooth)
        for poly, sm in zip(me.polygons, flags):
            poly.use_smooth = bool(sm)

    me.validate(verbose=False)
    ob = bpy.data.objects.new(name, me)
    coll.objects.link(ob)
    return ob


def grid_faces(rows, cols, closed_cols=False, flip=False):
    """Quad indices for a (rows x cols) vertex grid stored row-major."""
    out = []
    span = cols if closed_cols else cols - 1
    for r in range(rows - 1):
        for c in range(span):
            c1 = (c + 1) % cols
            a = r * cols + c
            b = r * cols + c1
            d = (r + 1) * cols + c
            e = (r + 1) * cols + c1
            out.append((a, d, e, b) if flip else (a, b, e, d))
    return out


# --- materials --------------------------------------------------------------

def _nodes(mat):
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    out.location = (600, 0)
    return nt, out


def principled(name, base=(0.5, 0.5, 0.5), roughness=0.5, metallic=0.0,
               emission=None, emission_strength=0.0, alpha=1.0,
               ior=1.45, blend=None, coat=0.0):
    mat = bpy.data.materials.new(name)
    nt, out = _nodes(mat)
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    bsdf.location = (250, 0)
    bsdf.inputs["Base Color"].default_value = (*base, 1.0)
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["IOR"].default_value = ior
    bsdf.inputs["Alpha"].default_value = alpha
    if "Coat Weight" in bsdf.inputs:
        bsdf.inputs["Coat Weight"].default_value = coat
    if emission is not None:
        bsdf.inputs["Emission Color"].default_value = (*emission, 1.0)
        bsdf.inputs["Emission Strength"].default_value = emission_strength
    nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
    if blend:
        mat.surface_render_method = blend
    elif alpha < 1.0:
        mat.surface_render_method = "BLENDED"
    mat["_bsdf"] = bsdf.name
    return mat


def emissive(name, colour=(1, 1, 1), strength=10.0, alpha=1.0, blend=None):
    mat = bpy.data.materials.new(name)
    nt, out = _nodes(mat)
    emit = nt.nodes.new("ShaderNodeEmission")
    emit.location = (250, 0)
    emit.inputs["Color"].default_value = (*colour, 1.0)
    emit.inputs["Strength"].default_value = strength
    if alpha >= 1.0:
        nt.links.new(emit.outputs["Emission"], out.inputs["Surface"])
    else:
        mix = nt.nodes.new("ShaderNodeMixShader")
        mix.location = (420, 0)
        trans = nt.nodes.new("ShaderNodeBsdfTransparent")
        trans.location = (250, -160)
        mix.inputs[0].default_value = alpha
        nt.links.new(trans.outputs["BSDF"], mix.inputs[1])
        nt.links.new(emit.outputs["Emission"], mix.inputs[2])
        nt.links.new(mix.outputs["Shader"], out.inputs["Surface"])
        mat.surface_render_method = blend or "BLENDED"
    return mat


def bsdf_of(mat):
    return mat.node_tree.nodes[mat["_bsdf"]]


def image_texture(mat, image, socket="Base Color", interpolation="Smart",
                  extension="EXTEND", location=(-350, 200), non_color=False):
    """Wire `image` into the material's Principled node."""
    nt = mat.node_tree
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = image
    tex.interpolation = interpolation
    tex.extension = extension
    tex.location = location
    if non_color:
        image.colorspace_settings.name = "Non-Color"
    if socket:
        nt.links.new(tex.outputs["Color"], bsdf_of(mat).inputs[socket])
    return tex


# --- geometry primitives ----------------------------------------------------

def tube(p0, p1, radius, segments=12, cap=True):
    """Cylinder between two uu-space points. Returns (verts, faces)."""
    ax = tuple(b - a for a, b in zip(p0, p1))
    length = math.sqrt(sum(c * c for c in ax))
    if length < 1e-9:
        return [], []
    ax = tuple(c / length for c in ax)
    up = (0.0, 0.0, 1.0) if abs(ax[2]) < 0.95 else (1.0, 0.0, 0.0)
    u = _cross(ax, up)
    u = _normalise(u)
    v = _cross(ax, u)

    verts, faces = [], []
    for end, base in ((0, p0), (1, p1)):
        for i in range(segments):
            a = TAU * i / segments
            c, s = math.cos(a) * radius, math.sin(a) * radius
            verts.append(tuple(base[k] + u[k] * c + v[k] * s for k in range(3)))
    for i in range(segments):
        j = (i + 1) % segments
        faces.append((i, j, segments + j, segments + i))
    if cap:
        verts.append(p0)
        verts.append(p1)
        c0, c1 = len(verts) - 2, len(verts) - 1
        for i in range(segments):
            j = (i + 1) % segments
            faces.append((c0, j, i))
            faces.append((c1, segments + i, segments + j))
    return verts, faces


def sweep_planar(path, axis_value, radius, axis="y", segments=10, closed=False):
    """Sweep a circle along a path that lies in a coordinate plane.

    `path` is [(a, b), ...] in the two in-plane axes; `axis_value` fixes the
    third. Because the path is planar the frame never twists, so the tube comes
    out clean without parallel transport.
    """
    n = len(path)
    rings = []
    for i in range(n):
        p = path[i]
        prev = path[i - 1] if (i > 0 or closed) else path[0]
        nxt = path[(i + 1) % n] if (i < n - 1 or closed) else path[-1]
        tx, ty = nxt[0] - prev[0], nxt[1] - prev[1]
        L = math.hypot(tx, ty) or 1.0
        nx, ny = -ty / L, tx / L          # in-plane normal
        ring = []
        for k in range(segments):
            a = TAU * k / segments
            c, s = math.cos(a) * radius, math.sin(a) * radius
            u = (p[0] + nx * c, p[1] + ny * c)
            if axis == "y":
                ring.append((u[0], axis_value + s, u[1]))
            elif axis == "x":
                ring.append((axis_value + s, u[0], u[1]))
            else:
                ring.append((u[0], u[1], axis_value + s))
        rings.append(ring)

    verts = [v for ring in rings for v in ring]
    faces = grid_faces(n, segments, closed_cols=True)
    if closed:
        for k in range(segments):
            k2 = (k + 1) % segments
            a = (n - 1) * segments + k
            b = (n - 1) * segments + k2
            faces.append((a, b, k2, k))
    return verts, faces


def sweep_tube_3d(path, radius, segments=12, cap=True):
    """Sweep a circle along an arbitrary 3D polyline.

    Uses rotation-minimising frames (each ring's reference vector is the
    previous one projected back perpendicular to the new tangent) so the tube
    never twists, which a fixed up-vector would do as the path turns.
    """
    n = len(path)
    if n < 2:
        return [], []

    tangents = []
    for i in range(n):
        a = path[max(i - 1, 0)]
        b = path[min(i + 1, n - 1)]
        tangents.append(_normalise((b[0] - a[0], b[1] - a[1], b[2] - a[2])))

    ref = (0.0, 0.0, 1.0) if abs(tangents[0][2]) < 0.9 else (1.0, 0.0, 0.0)
    u = _normalise(_cross(tangents[0], ref))

    verts = []
    for i in range(n):
        t = tangents[i]
        if i:
            d = sum(u[k] * t[k] for k in range(3))
            u = _normalise(tuple(u[k] - d * t[k] for k in range(3)))
        v = _cross(t, u)
        for s in range(segments):
            a = TAU * s / segments
            c, sn = math.cos(a) * radius, math.sin(a) * radius
            verts.append(tuple(path[i][k] + u[k] * c + v[k] * sn for k in range(3)))

    faces = grid_faces(n, segments, closed_cols=True)
    if cap:
        for end, base in ((0, path[0]), (n - 1, path[-1])):
            centre = len(verts)
            verts.append(tuple(base))
            off = end * segments
            for s in range(segments):
                s2 = (s + 1) % segments
                if end:
                    faces.append((centre, off + s, off + s2))
                else:
                    faces.append((centre, off + s2, off + s))
    return verts, faces


def arc_points(cx, cz, radius, a0, a1, samples):
    return [(cx + radius * math.cos(a0 + (a1 - a0) * k / samples),
             cz + radius * math.sin(a0 + (a1 - a0) * k / samples))
            for k in range(samples + 1)]


def rounded_rect_path(cx, cz, w, h, radius, arch=0.0, samples=8):
    """Closed rounded-rectangle path in (x, z), optionally bowed at the top."""
    hw, hh = w / 2 - radius, h / 2 - radius
    pts = []
    quads = [(hw, hh, 0.0), (-hw, hh, math.pi / 2),
             (-hw, -hh, math.pi), (hw, -hh, 3 * math.pi / 2)]
    for ox, oz, a0 in quads:
        for k in range(samples + 1):
            a = a0 + (math.pi / 2) * k / samples
            pts.append((cx + ox + radius * math.cos(a), cz + oz + radius * math.sin(a)))
    if arch:
        top = max(p[1] for p in pts)
        span = w / 2
        pts = [(x, z + arch * max(0.0, 1.0 - (abs(x - cx) / span) ** 2)
                * (1.0 if z > cz else 0.0)) for x, z in pts]
    return pts


def box(cx, cy, cz, sx, sy, sz):
    hx, hy, hz = sx / 2, sy / 2, sz / 2
    v = [
        (cx - hx, cy - hy, cz - hz), (cx + hx, cy - hy, cz - hz),
        (cx + hx, cy + hy, cz - hz), (cx - hx, cy + hy, cz - hz),
        (cx - hx, cy - hy, cz + hz), (cx + hx, cy - hy, cz + hz),
        (cx + hx, cy + hy, cz + hz), (cx - hx, cy + hy, cz + hz),
    ]
    f = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4),
         (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]
    return v, f


def merge(*parts):
    """Concatenate (verts, faces) pairs with index remapping."""
    verts, faces = [], []
    for pv, pf in parts:
        off = len(verts)
        verts.extend(pv)
        faces.extend([tuple(i + off for i in f) for f in pf])
    return verts, faces


def _cross(a, b):
    return (a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0])


def _normalise(a):
    n = math.sqrt(sum(c * c for c in a)) or 1.0
    return tuple(c / n for c in a)


def lerp(a, b, t):
    return a + (b - a) * t


def smoothstep(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)
