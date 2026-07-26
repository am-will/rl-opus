extends Node3D
## Fixes up the imported arena at runtime.
##
## Two things glTF gets wrong on the way out of Blender:
##
## 1. Light intensity is exported in photometric units, so Blender's 105 kW
##    floodlights arrive as light_energy ~5.7 million. Godot's default is 1.0,
##    which clips the whole frame to white.
## 2. glTF has no area lights at all, so the 21 fill / team-wash / cove / bowl
##    lights in the Blender scene simply do not survive. They get rebuilt here
##    as native Godot lights.
##
## Pass `-- --capture <path>` on the command line to save a frame and quit,
## which is how this was tuned without a human in the loop.

const FLOOD_ENERGY := 6.0
const FLOOD_ATTEN := 0.6

# Metres. Blender is Z-up and glTF is Y-up, so Blender (x, y, z) lands at
# Godot (x, z, -y): the pitch runs along Godot's Z.
const HALF_LEN := 51.2       # was Blender Y = +/-5120 uu
const HALF_WID := 40.96      # was Blender X = +/-4096 uu
const CEIL := 20.44

var _capture_path := ""
var _frames := 0


func _ready() -> void:
	_release_imported_cameras()
	_tame_imported_lights()
	_fix_materials()
	_rebuild_missing_lights()

	var args := OS.get_cmdline_user_args()
	var i := args.find("--capture")
	if i != -1 and i + 1 < args.size():
		_capture_path = args[i + 1]


func _release_imported_cameras() -> void:
	# The glb carries the eight Blender cameras, and the importer marks one
	# current -- which silently hijacks the viewport from the fly cam.
	for n in _all(self):
		if n is Camera3D:
			n.current = false


func _fix_materials() -> void:
	# Godot ignores COLOR_0 unless the material opts in, so the crowd and the
	# bunting arrive white. Emission strength also lands hot enough to bloom
	# the jumbotron into a solid block.
	for n in _all(self):
		if not (n is MeshInstance3D) or n.mesh == null:
			continue
		var vertex_coloured: bool = n.name.begins_with("CF_Crowd") \
			or n.name.begins_with("CF_Bunting")
		for i in n.mesh.get_surface_count():
			var m: Material = n.mesh.surface_get_material(i)
			if m is StandardMaterial3D:
				# The ball's albedo came from a ColorRamp driven by the hex
				# map's alpha; that node graph has no glTF equivalent, so it
				# arrives near-black.
				if n.name.begins_with("CF_Ball"):
					m.albedo_color = Color(0.72, 0.75, 0.78)
					m.roughness = 0.35
					m.metallic = 0.1
				if vertex_coloured:
					m.vertex_color_use_as_albedo = true
				if m.emission_enabled:
					m.emission_energy_multiplier = minf(
						m.emission_energy_multiplier, 1.6)


func _tame_imported_lights() -> void:
	for n in _all(self):
		if n is Light3D:
			n.light_energy = FLOOD_ENERGY
			n.shadow_enabled = n.shadow_enabled and true
			if n is SpotLight3D:
				n.spot_attenuation = FLOOD_ATTEN
				n.spot_range = 260.0
				n.shadow_bias = 0.06
				n.shadow_normal_bias = 1.5


func _rebuild_missing_lights() -> void:
	# Broad bowl fill, standing in for Blender's big area lights.
	_omni(Vector3(0, CEIL + 34, 0), Color(0.80, 0.87, 1.0), 6.0, 300.0)

	# Team wash at each end. Blue defends -Y in Blender, which is +Z here.
	_omni(Vector3(0, 22, HALF_LEN * 0.86), Color(0.30, 0.62, 1.0), 5.0, 150.0)
	_omni(Vector3(0, 22, -HALF_LEN * 0.86), Color(1.0, 0.55, 0.20), 5.0, 150.0)

	# Warm cove under the roof so the stands separate from the night sky.
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_omni(Vector3(sx * HALF_WID * 1.35, 62.0, sz * HALF_LEN * 1.2),
				  Color(1.0, 0.93, 0.84), 4.5, 190.0)


func _omni(pos: Vector3, colour: Color, energy: float, rng: float) -> void:
	var l := OmniLight3D.new()
	l.position = pos
	l.light_color = colour
	l.light_energy = energy
	l.omni_range = rng
	l.omni_attenuation = 0.7
	l.shadow_enabled = false
	add_child(l)


func _all(n: Node, out: Array = []) -> Array:
	out.append(n)
	for c in n.get_children():
		_all(c, out)
	return out


func _process(_delta: float) -> void:
	if _capture_path == "":
		return
	_frames += 1
	if _frames < 45:                       # let TAA/glow settle
		return
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(_capture_path)
	print("[capture] wrote %s" % _capture_path)
	get_tree().quit()
