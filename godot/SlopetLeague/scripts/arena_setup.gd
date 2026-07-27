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

## The haze used to ship OFF, because at full strength it greyed out the whole
## frame. It was also the wrong colour: `volumetric_fog_albedo` was
## (0.55, 0.68, 1.0), a strong blue, so what it mostly did was tint everything
## -- it was holding the dasher boards up by ~14/255 and supplying most of
## their apparent saturation, which is not what haze is for.
##
## With the albedo neutral it is doing the job it exists for. Blender's world
## carries a Volume Scatter at density 0.0016 (cf/world.py) and EEVEE renders
## it with volumetric shadows on, which is where the light shafts under the
## floodlight banks in the reference stills come from.
##
## 0.12 is where the two measures agree. Haze both fills the roof band and
## lifts the blacks, and those pull in opposite directions: at 0.3 the roof
## goes to -13.3 but the 5th-percentile shadow ratio drifts to 1.23 and
## tone_compare.py flips to "CURVE mismatch". At 0.12 the roof is -17.8 on
## `hero` and -23.4 on `kickoff` (against -21.0 and -30.7 with no haze at
## all), the boards and pitch lose over-saturation, and the shadow ratio
## stays at 1.12 -- still "level only" on both framings.
##
## `F` still toggles it and `--fog 0` still turns it off outright.
const FOG_DEFAULT := 0.12

## Baked into the VoxelGIData by `--bake-gi`; see _bake_gi.
const GI_ENERGY := 0.7

var _capture_path := ""
var _frames := 0
var _env: Environment = null
var _fog_density := 0.0
var _fog_on := true
var _streaks: ShaderMaterial = null
var _streaks_on := true


## The headless harnesses instantiate this scene by hand, so there may be no
## current_scene to search yet; the tree root always works.
func _scene() -> Node:
	var s: Node = get_tree().current_scene
	return s if s != null else get_tree().root


func _ready() -> void:
	var args := OS.get_cmdline_user_args()

	var i := args.find("--capture")
	if i != -1 and i + 1 < args.size():
		_capture_path = args[i + 1]

	var we := _scene().find_child("WorldEnvironment", true, false)
	if we is WorldEnvironment:
		_env = we.environment
		_fog_density = _env.volumetric_fog_density

	var scale := FOG_DEFAULT
	i = args.find("--fog")
	if i != -1 and i + 1 < args.size():
		scale = float(args[i + 1])
	_set_fog(scale)

	var rect := _scene().find_child("Streaks", true, false)
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

	# Godot's sky ambient is unoccluded: it lights the inside of a closed bowl
	# exactly as much as the open roof. Blender's world is the same blue night
	# sky, but EEVEE occludes it, so the boards there are near-black where
	# here they pick up a blue cast. Until baked GI supplies the indirect this
	# is standing in for, the honest move is to turn it down.
	i = args.find("--ambient")
	if i != -1 and i + 1 < args.size() and _env != null:
		var a := float(args[i + 1])
		if a <= 0.0:
			_env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
		else:
			_env.ambient_light_energy *= a
			_env.ambient_light_sky_contribution *= a
		print("[ambient] x%.2f -> source=%d energy=%.3f sky=%.3f" % [
			a, _env.ambient_light_source, _env.ambient_light_energy,
			_env.ambient_light_sky_contribution])

	i = args.find("--lights")
	if i != -1 and i + 1 < args.size():
		_scale_lights(args[i + 1])

	i = args.find("--env")
	if i != -1 and i + 1 < args.size():
		_set_env(args[i + 1])

	i = args.find("--gi")
	if i != -1 and i + 1 < args.size():
		var gi := _scene().find_child("VoxelGI", true, false)
		if gi is VoxelGI and gi.data != null:
			gi.data.energy *= float(args[i + 1])
			print("[gi] energy = %.3f" % gi.data.energy)

	i = args.find("--bake-gi")
	if i != -1 and i + 1 < args.size():
		_bake_gi(args[i + 1])


## Bake the VoxelGI and write the result out, then quit.
##
## Godot has three ways to get indirect light and only this one can be driven
## from a script: `LightmapGI.bake()` is not exposed to GDScript at all (it is
## an editor plugin), and SDFGI measured at +0.6/255 on the boards, which is
## nothing. VoxelGI also has the property the other two lack for this job --
## it never replaces direct lighting, it only adds bounce on top, so the
## direct rig that has just been matched to Blender's wattages survives intact.
##
## What it is actually here to carry is the emissive geometry. The wall
## strips, the chevrons, the ceiling coves, the 34 boost pads, the goal frame
## and the 18 floodlight lenses are all emissive, and in Blender they light
## the room. In Godot an emissive material lights nothing at all unless a GI
## volume picks it up, which is most of why the dasher boards read near-black
## here against a mid-grey in the reference.
func _bake_gi(path: String) -> void:
	var gi := _scene().find_child("VoxelGI", true, false)
	if not (gi is VoxelGI):
		push_error("[gi] no VoxelGI node in the scene")
		get_tree().quit(1)
		return
	var t0 := Time.get_ticks_msec()
	gi.bake(_scene(), false)
	print("[gi] baked in %.1f s" % ((Time.get_ticks_msec() - t0) / 1000.0))
	# Blender traces its indirect in screen space with clamp_surface_indirect
	# at 8.0, so its bounce is bounded in a way a voxel cone trace is not.
	# 0.7 is the measured level that puts the dasher boards at -0.8/255 of the
	# reference instead of +6.5.
	gi.data.energy = GI_ENERGY
	var err := ResourceSaver.save(gi.data, path)
	print("[gi] %s -> %s" % ["saved" if err == OK else "FAILED %d" % err, path])
	get_tree().quit(0 if err == OK else 1)


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
	for n in _all_nodes(_scene()):
		if not (n is Light3D):
			continue
		for prefix in mult:
			if n.name.begins_with(prefix):
				n.light_energy *= mult[prefix]
				scaled += 1
				break
	print("[lights] %s -> %d lights scaled" % [spec, scaled])


## `--env ssil_enabled=false,glow_intensity=0.4` sets Environment properties
## directly, so a hypothesis about the grade costs one capture rather than an
## edit to arena.tscn. Values parse as bool, then float, then string.
func _set_env(spec: String) -> void:
	if _env == null:
		return
	for pair in spec.split(",", false):
		var kv := pair.split("=")
		if kv.size() != 2:
			continue
		var key := kv[0].strip_edges()
		var raw := kv[1].strip_edges()
		var val: Variant = raw
		if raw == "true" or raw == "false":
			val = raw == "true"
		elif raw.is_valid_float():
			val = float(raw)
		_env.set(key, val)
		print("[env] %s = %s (now %s)" % [key, val, _env.get(key)])


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
