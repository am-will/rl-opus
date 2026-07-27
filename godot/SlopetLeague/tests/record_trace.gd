extends SceneTree
## Golden-trace recorder for the Godot build — the other half of
## tools/trace/record_ts.mjs.
##
##   godot --path godot/SlopetLeague --headless --script tests/record_trace.gd \
##       -- --scenario throttle
##
## Reads tools/trace/scenarios.json so both sides provably run the same input
## program, and writes traces/godot/<name>.json in the same record format. Then
##
##   python3 tools/trace/compare.py traces/ts/throttle.json traces/godot/throttle.json
##
## One scenario per process: a fresh arena every time, so nothing bleeds across.
##
## The Psyonix impulse's forward-squash term is switched OFF by default here.
## The TS build does not have it (see docs/PHYSICS_PARITY_HANDOFF.md 4a), so
## leaving it on would show up as a port bug rather than the deliberate
## improvement it is. `--with-forward-squash` records the shipping behaviour.

var _game: Game = null
var _spec: Dictionary = {}
var _defaults: Dictionary = {}
var _segments: Array = []
var _ticks := 0
var _tick := 0
var _records: Array = []
var _out := ""
var _dt := 1.0 / 120.0
var _done := false
var _setup_done := false
var _connected := false
var _with_forward_squash := false


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var name := _arg(args, "--scenario", "")
	if name == "":
		push_error("--scenario <name> is required")
		quit(2)
		return

	var repo := ProjectSettings.globalize_path("res://").path_join("../..").simplify_path()
	var doc := _read_json(repo.path_join("tools/trace/scenarios.json"))
	if doc.is_empty():
		quit(2)
		return

	_dt = doc.get("dt", 1.0 / 120.0)
	_defaults = doc.get("inputDefaults", {})
	for s in doc.get("scenarios", []):
		if s.get("name", "") == name:
			_spec = s
			break
	if _spec.is_empty():
		push_error("no scenario named '%s'" % name)
		quit(2)
		return

	_ticks = int(_spec.get("ticks", 600))
	_segments = _spec.get("input", [])
	_out = _arg(args, "--out", repo.path_join("traces/godot/%s.json" % name))

	_with_forward_squash = args.has("--with-forward-squash")

	var ps := load("res://scenes/game.tscn") as PackedScene
	_game = ps.instantiate() as Game
	_game.external_input = true
	_game.enable_goals = false
	_game.enable_pads = bool(_spec.get("boostPads", false))
	root.add_child(_game)
	print("recording %s: %d ticks -> %s" % [name, _ticks, _out])


## Godot defers a manually added scene's `_ready` past `_initialize`, so the
## scenario can only be placed once the game has actually built itself. One
## physics frame may go by first; `respawn` / `reset` wipe it out anyway.
func _setup_scenario() -> void:
	var car := _game.player_car
	if not _with_forward_squash:
		car.hit_forward_squash = 0.0

	var cs: Dictionary = _spec.get("car", {})
	car.respawn(
		float(cs.get("x", 0.0)),
		float(cs.get("z", 0.0)),
		float(cs.get("yaw", 0.0)),
		float(cs.get("boost", Feel.BOOST_START))
	)
	car.infinite_boost = bool(cs.get("infiniteBoost", false))
	if not bool(cs.get("active", true)):
		car.set_active(false)

	var bs: Dictionary = _spec.get("ball", {})
	_game.ball.reset(_vec(bs.get("p", [0, Feel.BALL_RADIUS + 0.02, 0])), _vec(bs.get("v", [0, 0, 0])))


func _physics_process(_dt_in: float) -> bool:
	if not _connected:
		if _game == null or _game.player_car == null:
			return false
		current_scene = _game
		_game.post_step.connect(_on_post_step)
		_connected = true
	return _done


func _on_post_step(_dt_in: float) -> void:
	if _done:
		return
	# post_step fires after the previous solver step has been post-processed and
	# before this tick's input is read, so placing the scenario here means the
	# very next step starts from exact initial conditions — no free-fall while
	# the scene was still building itself.
	if not _setup_done:
		_setup_scenario()
		_setup_done = true
	elif _tick > 0:
		# From here on it holds the state after step _tick-1, which is exactly
		# where the TS recorder samples.
		_records.append(_snapshot(_tick))
	if _tick >= _ticks:
		_done = true
		_write()
		quit()
		return
	_apply_input(_tick)
	_tick += 1


func _snapshot(tick: int) -> Dictionary:
	var c := _game.player_car
	var b := _game.ball
	var cq := c.global_transform.basis.get_rotation_quaternion()
	var bq := b.global_transform.basis.get_rotation_quaternion()
	return {
		"t": _r(tick * _dt),
		"car": {
			"p": _v3(c.global_position),
			"v": _v3(c.linear_velocity),
			"q": _v4(cq),
			"av": _v3(c.angular_velocity),
			"grounded": c.grounded,
			"wheelsDown": c.wheels_down,
			"boost": _r(c.boost),
			"flipping": c.flipping,
			"supersonic": c.supersonic,
		},
		"ball": {
			"p": _v3(b.global_position),
			"v": _v3(b.linear_velocity),
			"q": _v4(bq),
			"av": _v3(b.angular_velocity),
		},
	}


## Start from the defaults; the LAST segment covering this tick replaces them
## wholesale. Mirrors the rule stated in scenarios.json.
func _apply_input(tick: int) -> void:
	var i := _game.player_car.input
	i.throttle = float(_defaults.get("throttle", 0.0))
	i.steer = float(_defaults.get("steer", 0.0))
	i.pitch = float(_defaults.get("pitch", 0.0))
	i.roll = float(_defaults.get("roll", 0.0))
	i.jump = bool(_defaults.get("jump", false))
	i.boost = bool(_defaults.get("boost", false))
	i.drift = bool(_defaults.get("drift", false))
	for seg in _segments:
		if tick >= int(seg.get("fromTick", 0)) and tick < int(seg.get("toTick", 0)):
			i.throttle = float(seg.get("throttle", i.throttle))
			i.steer = float(seg.get("steer", i.steer))
			i.pitch = float(seg.get("pitch", i.pitch))
			i.roll = float(seg.get("roll", i.roll))
			i.jump = bool(seg.get("jump", i.jump))
			i.boost = bool(seg.get("boost", i.boost))
			i.drift = bool(seg.get("drift", i.drift))


func _write() -> void:
	var doc := {
		"scenario": _spec.get("name", ""),
		"source": "godot",
		"tickRate": int(round(1.0 / _dt)),
		"dt": _dt,
		"ticks": _records.size(),
		"records": _records,
	}
	DirAccess.make_dir_recursive_absolute(_out.get_base_dir())
	var f := FileAccess.open(_out, FileAccess.WRITE)
	if f == null:
		push_error("cannot write %s" % _out)
		return
	f.store_string(JSON.stringify(doc))
	f.close()
	print("wrote %d records" % _records.size())


# --- helpers ---------------------------------------------------------------

func _arg(args: PackedStringArray, key: String, dflt: String) -> String:
	var i := args.find(key)
	if i != -1 and i + 1 < args.size():
		return args[i + 1]
	return dflt


func _read_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("cannot read %s" % path)
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("%s is not a JSON object" % path)
		return {}
	return parsed


static func _r(v: float) -> float:
	return snappedf(v, 0.000001)


static func _v3(v: Vector3) -> Array:
	return [_r(v.x), _r(v.y), _r(v.z)]


static func _v4(q: Quaternion) -> Array:
	return [_r(q.x), _r(q.y), _r(q.z), _r(q.w)]


static func _vec(a) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))
