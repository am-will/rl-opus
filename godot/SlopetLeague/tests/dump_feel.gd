extends SceneTree
## Dump every constant in rl_feel.gd as JSON so they can be diffed against
## src/config.ts mechanically. See tools/trace/compare_config.py.
##
##   godot --path godot/SlopetLeague --headless --script tests/dump_feel.gd \
##       -- --out /tmp/gd_feel.json
##
## Reads the script's own constant map rather than a hand-written list, so a
## constant cannot be added to rl_feel.gd and quietly escape the comparison.


func _initialize() -> void:
	var out := "/tmp/gd_feel.json"
	var args := OS.get_cmdline_user_args()
	var i := args.find("--out")
	if i != -1 and i + 1 < args.size():
		out = args[i + 1]

	var src := load("res://scripts/rl_feel.gd") as GDScript
	var d := {}
	for name in src.get_script_constant_map():
		d[name] = _plain(src.get_script_constant_map()[name])

	var f := FileAccess.open(out, FileAccess.WRITE)
	f.store_string(JSON.stringify(d, " "))
	f.close()
	print("wrote %s (%d constants)" % [out, d.size()])
	quit()


func _plain(v: Variant) -> Variant:
	match typeof(v):
		TYPE_VECTOR2:
			return [(v as Vector2).x, (v as Vector2).y]
		TYPE_VECTOR3:
			return [(v as Vector3).x, (v as Vector3).y, (v as Vector3).z]
		TYPE_ARRAY:
			var a := []
			for e in (v as Array):
				a.append(_plain(e))
			return a
		TYPE_DICTIONARY:
			var o := {}
			for k in (v as Dictionary):
				o[str(k)] = _plain((v as Dictionary)[k])
			return o
	return v
