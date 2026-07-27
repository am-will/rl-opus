extends Node3D
## Runtime harness for the arena.
##
## Every light / camera / material fix now happens at import time in
## import/arena_post_import.gd, so the editor viewport is correct too. What is
## left here is the offscreen capture harness and the two look toggles.
##
## Pass `-- --capture <path>` to save a frame and quit, which is how this is
## tuned without a human in the loop; `-- --fog <0..1>` to scale the volumetric
## haze (0 turns it off outright); `-- --streaks <0..1>` to scale the
## anamorphic glare. Interactively, F toggles the fog and G the streaks.

## The haze is what would give the floodlights visible beams, but it is also
## the fastest way to grey out a whole frame, and it greyed out this one. It
## ships OFF. The Environment still carries a (very light) density and F still
## toggles it, so turning it back on later is one key, not a rebuild.
const FOG_DEFAULT := 0.0

var _capture_path := ""
var _frames := 0
var _env: Environment = null
var _fog_density := 0.0
var _fog_on := true
var _streaks: ShaderMaterial = null
var _streaks_on := true


func _ready() -> void:
	var args := OS.get_cmdline_user_args()

	var i := args.find("--capture")
	if i != -1 and i + 1 < args.size():
		_capture_path = args[i + 1]

	var we := get_tree().current_scene.find_child("WorldEnvironment", true, false)
	if we is WorldEnvironment:
		_env = we.environment
		_fog_density = _env.volumetric_fog_density

	var scale := FOG_DEFAULT
	i = args.find("--fog")
	if i != -1 and i + 1 < args.size():
		scale = float(args[i + 1])
	_set_fog(scale)

	var rect := get_tree().current_scene.find_child("Streaks", true, false)
	if rect is ColorRect and rect.material is ShaderMaterial:
		_streaks = rect.material
	var streaks := 1.0
	i = args.find("--streaks")
	if i != -1 and i + 1 < args.size():
		streaks = float(args[i + 1])
	_set_streaks(streaks)

	# Light energies live in the import script, so finding the right overall
	# level by editing them costs a reimport per guess. Exposure is a plain
	# linear multiplier in front of the tonemapper, so sweeping it here finds
	# the level in one pass; the winning factor then gets folded back into the
	# energies and this returns to 1.
	i = args.find("--exposure")
	if i != -1 and i + 1 < args.size() and _env != null:
		_env.tonemap_exposure *= float(args[i + 1])

	i = args.find("--lights")
	if i != -1 and i + 1 < args.size():
		_scale_lights(args[i + 1])


## `--lights BOWL=0.6,TEAM=1.3` scales the energy of every light whose node
## name starts with the given prefix.
##
## Every light lives in the import script, so finding a level by editing it
## costs a full reimport per guess. The groups are exactly the ones in
## `_rebuild_area_lights` plus `FLOOD`, so a sweep over one group is one 25 s
## capture per value, and the winner gets folded back into the import script.
func _scale_lights(spec: String) -> void:
	var mult := {}
	for pair in spec.split(",", false):
		var kv := pair.split("=")
		if kv.size() == 2:
			mult[kv[0].strip_edges()] = float(kv[1])

	var scaled := 0
	for n in _all_nodes(get_tree().current_scene):
		if not (n is Light3D):
			continue
		for prefix in mult:
			if n.name.begins_with(prefix):
				n.light_energy *= mult[prefix]
				scaled += 1
				break
	print("[lights] %s -> %d lights scaled" % [spec, scaled])


func _all_nodes(n: Node, out: Array = []) -> Array:
	out.append(n)
	for c in n.get_children():
		_all_nodes(c, out)
	return out


func _set_fog(scale: float) -> void:
	if _env == null:
		return
	_fog_on = scale > 0.0
	_env.volumetric_fog_enabled = _fog_on
	_env.volumetric_fog_density = _fog_density * scale


func _set_streaks(scale: float) -> void:
	if _streaks == null:
		return
	_streaks_on = scale > 0.0
	_streaks.set_shader_parameter("enabled", 1.0 if _streaks_on else 0.0)


func _unhandled_key_input(e: InputEvent) -> void:
	if not (e is InputEventKey and e.pressed and not e.echo):
		return
	if e.keycode == KEY_F:
		_set_fog(0.0 if _fog_on else 1.0)
		print("[fog] %s" % ("on" if _fog_on else "off"))
	elif e.keycode == KEY_G:
		_set_streaks(0.0 if _streaks_on else 1.0)
		print("[streaks] %s" % ("on" if _streaks_on else "off"))


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
