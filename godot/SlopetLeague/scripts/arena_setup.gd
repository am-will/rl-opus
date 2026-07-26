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


# Metres. Blender is Z-up and glTF is Y-up, so Blender (x, y, z) lands at
# Godot (x, z, -y): the pitch runs along Godot's Z.

var _capture_path := ""
var _frames := 0


func _ready() -> void:
	# Every light / camera / material fix now happens in
	# import/arena_post_import.gd so the editor viewport is correct too.
	# All that is left here is the offscreen capture harness.
	var args := OS.get_cmdline_user_args()
	var i := args.find("--capture")
	if i != -1 and i + 1 < args.size():
		_capture_path = args[i + 1]


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
