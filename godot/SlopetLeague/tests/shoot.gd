extends SceneTree
## Gameplay screenshot harness — drives the game with a scripted input program
## and saves frames at chosen ticks.
##
##   godot --path godot/SlopetLeague --rendering-driver metal \
##       --resolution 1600x900 --script tests/shoot.gd -- \
##       --plan kickoff --out /abs/path/to/renders/game
##
## Use this rather than arena_setup's `--capture`: that one is the visual-pass
## harness and hands the viewport to shot_cameras.gd, so it photographs a fixed
## studio angle instead of the game.
##
## A plan is a list of {tick, throttle, steer, pitch, roll, jump, boost, drift}
## segments plus a list of {tick, name} shots. Ticks are physics ticks at 120 Hz.

const PLANS := {
	# Kickoff, then drive at the ball and hit it.
	"kickoff": {
		"spawn": {"x": 0.0, "z": -25.0, "yaw": 0.0, "boost": 100.0},
		"ball": {"p": [0.0, 0.9325, 0.0]},
		"input": [
			{"from": 0, "to": 400, "throttle": 1.0, "boost": true},
		],
		"shots": [
			{"tick": 2, "name": "01_kickoff"},
			{"tick": 150, "name": "02_charge"},
			{"tick": 232, "name": "03_contact"},
			{"tick": 300, "name": "04_after"},
		],
	},
	# Powerslide round a corner.
	"drift": {
		"spawn": {"x": -18.0, "z": -20.0, "yaw": 0.0, "boost": 100.0},
		"ball": {"p": [30.0, 0.9325, 30.0]},
		"input": [
			{"from": 0, "to": 200, "throttle": 1.0, "boost": true},
			{"from": 200, "to": 400, "throttle": 1.0, "steer": 1.0, "drift": true},
		],
		"shots": [
			{"tick": 250, "name": "05_drift"},
			{"tick": 320, "name": "06_drift"},
		],
	},
	# Jump, then a front flip.
	"flip": {
		"spawn": {"x": 0.0, "z": -30.0, "yaw": 0.0, "boost": 100.0},
		"ball": {"p": [0.0, 0.9325, 0.0]},
		"input": [
			{"from": 0, "to": 400, "throttle": 1.0},
			{"from": 120, "to": 128, "throttle": 1.0, "jump": true},
			{"from": 140, "to": 148, "throttle": 1.0, "jump": true, "pitch": 1.0},
		],
		"shots": [
			{"tick": 130, "name": "07_jump"},
			{"tick": 152, "name": "08_flip"},
			{"tick": 166, "name": "09_flip"},
		],
	},
	# Up the side wall on boost.
	"wall": {
		"spawn": {"x": 18.0, "z": 0.0, "yaw": PI * 0.5, "boost": 100.0},
		"ball": {"p": [0.0, 0.9325, 30.0]},
		"input": [
			{"from": 0, "to": 500, "throttle": 1.0, "boost": true},
		],
		"shots": [
			{"tick": 200, "name": "10_wall"},
			{"tick": 260, "name": "11_wall"},
			{"tick": 330, "name": "12_ceiling"},
		],
	},
	# Jump, then boost up into an aerial with the nose held back.
	"aerial": {
		"spawn": {"x": 0.0, "z": -22.0, "yaw": 0.0, "boost": 100.0},
		"ball": {"p": [0.0, 6.0, 0.0]},
		"input": [
			{"from": 0, "to": 60, "throttle": 1.0, "boost": true},
			{"from": 60, "to": 78, "throttle": 1.0, "boost": true, "jump": true},
			{"from": 78, "to": 400, "boost": true, "pitch": -1.0},
		],
		"shots": [
			{"tick": 100, "name": "13_aerial"},
			{"tick": 140, "name": "14_aerial"},
			{"tick": 175, "name": "15_aerial"},
		],
	},
	# Score, and photograph the blast.
	"goal": {
		"spawn": {"x": 2.0, "z": 44.0, "yaw": 0.0, "boost": 100.0},
		"ball": {"p": [0.0, 1.2, 48.0], "v": [0.0, 1.0, 16.0]},
		"goals": true,
		"input": [{"from": 0, "to": 400, "throttle": 1.0, "boost": true}],
		"shots": [
			{"tick": 40, "name": "16_goal"},
			{"tick": 56, "name": "17_goal"},
			{"tick": 100, "name": "18_goal"},
		],
	},
	# Static three-quarter look at the car beside the ball, for judging scale.
	"scale": {
		"spawn": {"x": 3.4, "z": 0.0, "yaw": PI * 0.5, "boost": 100.0},
		"ball": {"p": [0.0, 0.9125, 0.0]},
		"input": [],
		"shots": [{"tick": 40, "name": "20_scale"}],
		"camera": {"pos": [7.0, 2.2, 7.5], "look": [1.2, 0.7, 0.0], "fov": 42.0},
	},
}

var _game: Game = null
var _plan: Dictionary = {}
var _out := ""
var _tick := 0
var _shots: Array = []
var _pending := -1
var _pending_name := ""
var _settle := 0
var _static_cam: Camera3D = null
var _connected := false


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var name := _arg(args, "--plan", "kickoff")
	_out = _arg(args, "--out", ProjectSettings.globalize_path("user://"))
	if not PLANS.has(name):
		push_error("no plan '%s'; have %s" % [name, ", ".join(PLANS.keys())])
		quit(2)
		return
	_plan = PLANS[name]
	_shots = (_plan.get("shots", []) as Array).duplicate()
	DirAccess.make_dir_recursive_absolute(_out)

	var ps := load("res://scenes/game.tscn") as PackedScene
	_game = ps.instantiate() as Game
	_game.external_input = true
	_game.enable_goals = bool(_plan.get("goals", false))
	root.add_child(_game)


func _physics_process(_dt: float) -> bool:
	if not _connected:
		if _game == null or _game.player_car == null:
			return false
		current_scene = _game
		_setup()
		_connected = true
	return false


func _setup() -> void:
	var s: Dictionary = _plan.get("spawn", {})
	var c := _game.player_car
	c.respawn(
		float(s.get("x", 0.0)), float(s.get("z", 0.0)),
		float(s.get("yaw", 0.0)), float(s.get("boost", 100.0))
	)
	var b: Dictionary = _plan.get("ball", {})
	var bp: Array = b.get("p", [0.0, Feel.BALL_RADIUS + 0.02, 0.0])
	var bv: Array = b.get("v", [0.0, 0.0, 0.0])
	_game.ball.reset(
		Vector3(bp[0], bp[1], bp[2]), Vector3(bv[0], bv[1], bv[2])
	)
	if _plan.has("camera"):
		var cs: Dictionary = _plan["camera"]
		_static_cam = Camera3D.new()
		_game.add_child(_static_cam)
		var p: Array = cs["pos"]
		var l: Array = cs["look"]
		_static_cam.global_position = Vector3(p[0], p[1], p[2])
		_static_cam.look_at(Vector3(l[0], l[1], l[2]), Vector3.UP)
		_static_cam.fov = float(cs.get("fov", 50.0))
		_static_cam.current = true
		_game.cam.queue_free()
		_game.cam = null
	if _game.cam:
		_game.cam.snap(c, _game.ball)
	_game.post_step.connect(_on_post)


func _on_post(_dt: float) -> void:
	_apply_input(_tick)
	for s in _shots:
		if int(s["tick"]) == _tick:
			_pending_name = s["name"]
			# One rendered frame has to go by before the viewport holds this pose.
			_settle = 2
			break
	_tick += 1


func _process(_dt: float) -> bool:
	if _pending_name == "":
		return false
	_settle -= 1
	if _settle > 0:
		return false
	var img := root.get_texture().get_image()
	var path := _out.path_join(_pending_name + ".png")
	img.save_png(path)
	print("[shot] ", path)
	_pending_name = ""
	if _shots.size() > 0 and int(_shots[_shots.size() - 1]["tick"]) < _tick:
		return true
	return false


func _apply_input(tick: int) -> void:
	var i := _game.player_car.input
	i.clear()
	for seg in _plan.get("input", []):
		if tick >= int(seg.get("from", 0)) and tick < int(seg.get("to", 0)):
			i.throttle = float(seg.get("throttle", 0.0))
			i.steer = float(seg.get("steer", 0.0))
			i.pitch = float(seg.get("pitch", 0.0))
			i.roll = float(seg.get("roll", 0.0))
			i.jump = bool(seg.get("jump", false))
			i.boost = bool(seg.get("boost", false))
			i.drift = bool(seg.get("drift", false))


func _arg(args: PackedStringArray, key: String, dflt: String) -> String:
	var i := args.find(key)
	if i != -1 and i + 1 < args.size():
		return args[i + 1]
	return dflt
