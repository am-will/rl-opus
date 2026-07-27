extends Node3D
## Runtime harness for the arena.
##
## Every light / camera / material fix now happens at import time in
## import/arena_post_import.gd, so the editor viewport is correct too. What is
## left here is the offscreen capture harness and the volumetric fog toggle.
##
## Pass `-- --capture <path>` to save a frame and quit, which is how this is
## tuned without a human in the loop, and `-- --fog <0..1>` to scale the
## volumetric haze (0 turns it off outright). Interactively, F toggles it.

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

	# Light energies live in the import script, so finding the right overall
	# level by editing them costs a reimport per guess. Exposure is a plain
	# linear multiplier in front of the tonemapper, so sweeping it here finds
	# the level in one pass; the winning factor then gets folded back into the
	# energies and this returns to 1.
	i = args.find("--exposure")
	if i != -1 and i + 1 < args.size() and _env != null:
		_env.tonemap_exposure *= float(args[i + 1])


func _set_fog(scale: float) -> void:
	if _env == null:
		return
	_fog_on = scale > 0.0
	_env.volumetric_fog_enabled = _fog_on
	_env.volumetric_fog_density = _fog_density * scale


func _unhandled_key_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo and e.keycode == KEY_F:
		_set_fog(0.0 if _fog_on else 1.0)
		print("[fog] %s" % ("on" if _fog_on else "off"))


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
