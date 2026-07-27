class_name BoostPadFx
extends Node3D
## Per-pad visual state: a pad that has been taken goes out, and lights back up
## when it respawns.
##
## Without this every pad looks live at all times, which is impossible to tell
## apart from a pad that simply does not work — you drive through one the bot
## cleared two seconds ago, nothing happens, and the honest conclusion is that
## boost pads are broken. They are not: `boost_pads.gd` is on a 4 s (small) and
## 10 s (big) respawn, exactly like RL, and the only thing missing was any way
## to see it. The TS build gets this for free because it builds its own discs
## (`BoostPadMesh` in src/render/Effects.ts).
##
## The work is in the split. The arena arrives from Blender as four MERGED
## meshes — one holding all 34 plates, one all 34 plumes, one the halos, one the
## orbs — so a single pad has no node of its own and there is nothing to hide.
## Each merged mesh is cut back into its 34 clusters once at load by sorting
## triangles onto the nearest pad centre, which keeps the arena import (a 41 MB
## reimport per edit) out of it entirely.

## Everything that floats above the plate and vanishes with the pad.
const FLOAT_MESHES := ["CF_BoostOrb", "CF_BoostGlow", "CF_BoostBeam"]
## The plate is painted on the pitch, so it stays put and only its glow goes out.
const PLATE_MESH := "CF_BoostDecal"

## Shrink out fast when taken, spring back more slowly on respawn — the rates
## in BoostPadMesh.update().
const OUT_RATE := 22.0
const IN_RATE := 9.0
## Below this the floats are switched off rather than drawn at a sliver.
const HIDE_BELOW := 0.02

## A taken plate keeps a trace of the emissive so the hexagon still reads as a
## pad rather than a scuff on the turf.
const PLATE_DARK_ENERGY := 0.08
const PLATE_DARK_ALBEDO := Color(0.30, 0.31, 0.34)

## The pickup pop: a brief overshoot on the way out, so a pad you took yourself
## registers as a pickup and not as a pad that happened to blink.
const FLASH_TIME := 0.14
const FLASH_SCALE := 0.4
const FLASH_ENERGY := 2.5

var _pads: Array[Dictionary] = []
## One entry per pad: {floats: [MeshInstance3D], plate: MeshInstance3D,
## plate_mat: StandardMaterial3D, lit_energy: float, s: float, live: bool,
## flash: float}
var _state: Array[Dictionary] = []


## `pads` is BoostPads.pads — read for its positions here and its cooldowns
## every frame after that.
func setup(arena: Node3D, pads: Array[Dictionary]) -> void:
	_pads = pads
	var centres := PackedVector2Array()
	for pad in pads:
		var p: Vector2 = pad["pos"]
		centres.append(p)

	for i in pads.size():
		_state.append({
			"floats": [] as Array[MeshInstance3D],
			"plate": null,
			"plate_mat": null,
			"lit_energy": 0.0,
			"s": 1.0,
			"live": true,
			"flash": 0.0,
		})

	for mesh_name in FLOAT_MESHES:
		_split(arena, mesh_name, centres, false)
	_split(arena, PLATE_MESH, centres, true)


## Cooldowns are the source of truth rather than `BoostPads.events`, which is
## drained per physics tick and would drop pickups between frames.
func update(dt: float) -> void:
	for i in _state.size():
		var st: Dictionary = _state[i]
		var live: bool = _pads[i]["cooldown"] <= 0.0
		if st["live"] and not live:
			st["flash"] = FLASH_TIME
		st["live"] = live

		var flash: float = maxf(0.0, st["flash"] - dt)
		st["flash"] = flash
		var pop := flash / FLASH_TIME

		var target := 1.0 if live else 0.0
		var s: float = st["s"]
		s += (target - s) * minf(1.0, dt * (IN_RATE if live else OUT_RATE))
		st["s"] = s

		var shown := s + pop * FLASH_SCALE
		for mi in st["floats"]:
			var m := mi as MeshInstance3D
			m.visible = shown > HIDE_BELOW
			if m.visible:
				m.scale = Vector3.ONE * shown

		var mat: StandardMaterial3D = st["plate_mat"]
		if mat != null:
			var lit: float = st["lit_energy"]
			mat.emission_energy_multiplier = lerpf(PLATE_DARK_ENERGY, lit, s) \
				+ pop * lit * FLASH_ENERGY
			mat.albedo_color = PLATE_DARK_ALBEDO.lerp(Color.WHITE, minf(1.0, s + pop))


## Cut one merged pad mesh into 34, one node per pad, and hide the original.
func _split(arena: Node3D, mesh_name: String, centres: PackedVector2Array, plate: bool) -> void:
	var src := arena.find_child(mesh_name, true, false) as MeshInstance3D
	if src == null or src.mesh == null:
		push_warning("boost pads: %s not found, its pads will not react" % mesh_name)
		return

	# Pads are given in world metres; the merged mesh is in its own local space.
	var to_local := src.global_transform.affine_inverse()
	var local_centres: Array[Vector3] = []
	for c in centres:
		local_centres.append(to_local * Vector3(c.x, 0.0, c.y))

	for i in src.mesh.get_surface_count():
		var arrays: Array = src.mesh.surface_get_arrays(i)
		var material: Material = src.get_surface_override_material(i)
		if material == null:
			material = src.mesh.surface_get_material(i)
		var buckets := _bucket(arrays, local_centres)
		for pad_i in buckets.size():
			var bucket: Array = buckets[pad_i]
			if bucket[0].is_empty():  # nothing of this mesh belongs to that pad
				continue
			_build_node(src, mesh_name, pad_i, local_centres[pad_i], bucket, material, plate)

	src.visible = false


## Sort the surface's triangles onto the nearest pad and rebuild each group as
## its own vertex arrays, recentred on that pad so the node scales about it.
func _bucket(arrays: Array, centres: Array[Vector3]) -> Array:
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals := PackedVector3Array()
	if arrays[Mesh.ARRAY_NORMAL] != null:
		normals = arrays[Mesh.ARRAY_NORMAL]
	var tangents := PackedFloat32Array()
	if arrays[Mesh.ARRAY_TANGENT] != null:
		tangents = arrays[Mesh.ARRAY_TANGENT]
	var uvs := PackedVector2Array()
	if arrays[Mesh.ARRAY_TEX_UV] != null:
		uvs = arrays[Mesh.ARRAY_TEX_UV]
	var index: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]

	var out: Array = []
	var remap: Array = []
	for _i in centres.size():
		out.append([PackedVector3Array(), PackedVector3Array(), PackedFloat32Array(),
			PackedVector2Array(), PackedInt32Array()])
		remap.append({})

	var tri := 0
	while tri < index.size():
		var a := index[tri]
		var b := index[tri + 1]
		var c := index[tri + 2]
		var mid := (verts[a] + verts[b] + verts[c]) / 3.0
		var best := -1
		var best_d := INF
		for k in centres.size():
			var d := Vector2(mid.x - centres[k].x, mid.z - centres[k].z).length_squared()
			if d < best_d:
				best_d = d
				best = k
		var bucket: Array = out[best]
		var seen: Dictionary = remap[best]
		for v in [a, b, c]:
			if not seen.has(v):
				seen[v] = bucket[0].size()
				bucket[0].append(verts[v] - centres[best])
				if not normals.is_empty():
					bucket[1].append(normals[v])
				if not tangents.is_empty():
					for t in 4:
						bucket[2].append(tangents[v * 4 + t])
				if not uvs.is_empty():
					bucket[3].append(uvs[v])
			bucket[4].append(seen[v])
		tri += 3
	return out


func _build_node(src: MeshInstance3D, mesh_name: String, pad_i: int, centre: Vector3,
		bucket: Array, material: Material, plate: bool) -> void:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = bucket[0]
	if not bucket[1].is_empty():
		arrays[Mesh.ARRAY_NORMAL] = bucket[1]
	if not bucket[2].is_empty():
		arrays[Mesh.ARRAY_TANGENT] = bucket[2]
	if not bucket[3].is_empty():
		arrays[Mesh.ARRAY_TEX_UV] = bucket[3]
	arrays[Mesh.ARRAY_INDEX] = bucket[4]

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mi := MeshInstance3D.new()
	mi.name = "%s_%02d" % [mesh_name, pad_i]
	mi.mesh = mesh
	mi.cast_shadow = src.cast_shadow
	mi.layers = src.layers
	# Already in the bake; a runtime copy asking to be baked again would only
	# fight it if the arena is ever rebaked with the game running.
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(mi)
	mi.global_transform = src.global_transform * Transform3D(Basis(), centre)

	var st: Dictionary = _state[pad_i]
	if plate:
		# Its own copy of the material, because dimming is per pad.
		var mat := (material as StandardMaterial3D).duplicate() as StandardMaterial3D
		mi.set_surface_override_material(0, mat)
		st["plate"] = mi
		st["plate_mat"] = mat
		st["lit_energy"] = mat.emission_energy_multiplier
	else:
		mi.set_surface_override_material(0, material)
		var floats: Array = st["floats"]
		floats.append(mi)
