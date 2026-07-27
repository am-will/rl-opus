extends SceneTree
## Drive the game through the REAL input path — InputMap actions, deadzones and
## PlayerInput.poll — rather than writing car.input directly the way the trace
## harness does. If a binding is missing or an axis is inverted, only this
## catches it.
##
##   godot --path godot/SlopetLeague --headless --script tests/probe_input.gd

var _game: Game = null
var _tick := 0
var _ready_done := false
var _held: Array[int] = []
var _results: Array[String] = []
var _fails := 0

## {at tick, keys held from here on, and what it should have done by `check`}
const SCRIPT := [
	{"at": 10, "keys": [KEY_W], "label": "W accelerates forward"},
	{"at": 130, "check": "forward_speed", "want": 5.0, "cmp": ">"},
	{"at": 131, "keys": [KEY_W, KEY_D], "label": "D steers right"},
	{"at": 220, "check": "yaw_rate", "want": -0.2, "cmp": "<"},
	{"at": 221, "keys": [KEY_W, KEY_A], "label": "A steers left"},
	{"at": 310, "check": "yaw_rate", "want": 0.2, "cmp": ">"},
	{"at": 311, "keys": [KEY_W, KEY_SHIFT], "label": "Shift boosts"},
	{"at": 330, "check": "boosting", "want": 0.5, "cmp": ">"},
	{"at": 331, "keys": [KEY_SPACE], "label": "Space jumps"},
	{"at": 360, "check": "airborne", "want": 0.5, "cmp": ">"},
	{"at": 361, "keys": [], "label": "release"},
	{"at": 380, "keys": [KEY_SPACE, KEY_W], "label": "Space + W dodges forward"},
	{"at": 392, "keys": [KEY_W], "label": "release jump"},
	{"at": 400, "check": "flipping_seen", "want": 0.5, "cmp": ">"},
	{"at": 470, "keys": [], "label": "coast"},
	{"at": 520, "check": "boost_spent", "want": 0.5, "cmp": ">"},
]

var _flipping_seen := 0.0
var _boost_at_start := 0.0


func _initialize() -> void:
	var ps := load("res://scenes/game.tscn") as PackedScene
	_game = ps.instantiate() as Game
	root.add_child(_game)


func _physics_process(_dt: float) -> bool:
	if not _ready_done:
		if _game == null or _game.player_car == null:
			return false
		current_scene = _game
		# Put the car somewhere with room to run and no ball in the way.
		_game.player_car.respawn(0.0, -40.0, 0.0, Feel.BOOST_MAX)
		_game.ball.reset(Vector3(30.0, Feel.BALL_RADIUS, 40.0))
		_boost_at_start = _game.player_car.boost
		_ready_done = true
		return false

	var car := _game.player_car
	if car.flipping:
		_flipping_seen = 1.0

	for step in SCRIPT:
		if int(step["at"]) != _tick:
			continue
		if step.has("keys"):
			_set_keys(step["keys"])
			if step.has("label"):
				print("  t=%4d  %s" % [_tick, step["label"]])
		if step.has("check"):
			_assert(step["check"], float(step["want"]), step["cmp"])

	_tick += 1
	if _tick > 560:
		print("\n%s  (%d checks, %d failed)" % [
			"FAIL" if _fails > 0 else "PASS", SCRIPT.size(), _fails
		])
		quit(1 if _fails > 0 else 0)
		return true
	return false


func _value(name: String) -> float:
	var car := _game.player_car
	match name:
		"forward_speed": return car.forward_speed
		"yaw_rate": return car.angular_velocity.y
		"boosting": return 1.0 if car.is_boosting else 0.0
		"airborne": return 0.0 if car.grounded else 1.0
		"flipping_seen": return _flipping_seen
		"boost_spent": return 1.0 if car.boost < _boost_at_start - 1.0 else 0.0
	return NAN


func _assert(name: String, want: float, cmp: String) -> void:
	var got := _value(name)
	var ok := got > want if cmp == ">" else got < want
	if not ok:
		_fails += 1
	print("    %-14s %s %-7.3f  got %8.3f   %s" % [
		name, cmp, want, got, "ok" if ok else "FAILED"
	])


## Release everything currently held, then press the new set. Injecting through
## Input is the point: it exercises the InputMap actions PlayerInput reads.
func _set_keys(keys: Array) -> void:
	for k in _held:
		_send(k, false)
	_held.clear()
	for k in keys:
		_send(int(k), true)
		_held.append(int(k))


func _send(keycode: int, pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = keycode
	ev.pressed = pressed
	Input.parse_input_event(ev)
