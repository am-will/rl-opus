@tool
extends EditorScenePostImport
## Fixes the Blender -> glTF -> Godot round-trip at IMPORT time, so the editor
## viewport and the running game both look right. Doing this in a _ready()
## handler instead only fixes play mode and leaves the editor blown out.
##
## Three things glTF gets wrong:
##
## 1. Light intensity is exported photometrically. Blender's 105 kW floodlights
##    arrive as light_energy ~5.7 million against a Godot default of 1.0, which
##    clips every pixel to white.
## 2. All eight Blender cameras come along and the importer marks one current,
##    hijacking the viewport from whatever camera the scene actually wants.
## 3. Godot ignores COLOR_0 unless the material opts in (crowd and bunting
##    arrive white), and node-graph-driven colour has no equivalent at all
##    (the ball's albedo came from a ColorRamp, so it arrives near-black).
##
## glTF also has no area lights, so the 21 fill / team / cove / bowl lights in
## the Blender scene are simply absent; approximations are rebuilt here.

const FLOOD_ENERGY := 6.0
const EMISSION_CAP := 1.6

# Metres. Blender is Z-up, glTF is Y-up: Blender (x, y, z) -> Godot (x, z, -y),
# so the pitch runs along Godot's Z.
const HALF_LEN := 51.2
const HALF_WID := 40.96
const CEIL := 20.44


func _post_import(scene: Node) -> Object:
	var nodes: Array = []
	_walk(scene, nodes)

	for n in nodes:
		if n is Light3D:
			n.light_energy = FLOOD_ENERGY
			if n is SpotLight3D:
				n.spot_attenuation = 0.6
				n.spot_range = 260.0
				n.shadow_bias = 0.06
				n.shadow_normal_bias = 1.5
		elif n is Camera3D:
			n.current = false
		elif n is MeshInstance3D and n.mesh != null:
			_fix_materials(n)

	_rebuild_area_lights(scene)
	return scene


func _fix_materials(mi: MeshInstance3D) -> void:
	var vertex_coloured: bool = mi.name.begins_with("CF_Crowd") \
		or mi.name.begins_with("CF_Bunting")
	if mi.name.begins_with("CF_Ball"):
		# The hex map was a ColorRamp *input* in Blender, but glTF wires it
		# straight in as base colour -- and it is 94% transparent dark, so the
		# ball renders as a black hole. Clearing albedo_texture on the imported
		# material does not stick, so replace the material outright.
		var ball := StandardMaterial3D.new()
		ball.albedo_color = Color(0.74, 0.77, 0.80)
		ball.roughness = 0.32
		ball.metallic = 0.15
		for i in mi.mesh.get_surface_count():
			mi.mesh.surface_set_material(i, ball)
		return

	for i in mi.mesh.get_surface_count():
		var m: Material = mi.mesh.surface_get_material(i)
		if not (m is StandardMaterial3D):
			continue
		if vertex_coloured:
			m.vertex_color_use_as_albedo = true
		if m.emission_enabled:
			m.emission_energy_multiplier = minf(
				m.emission_energy_multiplier, EMISSION_CAP)


func _rebuild_area_lights(scene: Node) -> void:
	_omni(scene, Vector3(0, CEIL + 34, 0), Color(0.80, 0.87, 1.0), 6.0, 300.0)
	# Blue defends Blender -Y, which is Godot +Z.
	_omni(scene, Vector3(0, 22, HALF_LEN * 0.86), Color(0.30, 0.62, 1.0), 5.0, 150.0)
	_omni(scene, Vector3(0, 22, -HALF_LEN * 0.86), Color(1.0, 0.55, 0.20), 5.0, 150.0)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_omni(scene, Vector3(sx * HALF_WID * 1.35, 62.0, sz * HALF_LEN * 1.2),
				  Color(1.0, 0.93, 0.84), 4.5, 190.0)


func _omni(scene: Node, pos: Vector3, colour: Color, energy: float,
		   rng: float) -> void:
	var l := OmniLight3D.new()
	l.name = "FILL_%d" % scene.get_child_count()
	l.position = pos
	l.light_color = colour
	l.light_energy = energy
	l.omni_range = rng
	l.omni_attenuation = 0.7
	l.shadow_enabled = false
	scene.add_child(l)
	l.owner = scene


func _walk(n: Node, out: Array) -> void:
	out.append(n)
	for c in n.get_children():
		_walk(c, out)
