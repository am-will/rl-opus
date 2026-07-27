extends SceneTree
## Headless sanity probe: instantiate the game, hold an input, print state.
##
##   godot --path godot/SlopetLeague --headless --script tests/probe_game.gd \
##       -- --throttle 1 --steer 0 --ticks 600
##
## Prints every 60 ticks so the numbers can be eyeballed against the TS build.

var _ticks := 0
var _max_ticks := 600
var _game: Game = null
var _throttle := 1.0
var _steer := 0.0
var _boost := false
var _jump_at := -1


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	_max_ticks = int(_arg(args, "--ticks", "600"))
	_throttle = float(_arg(args, "--throttle", "1"))
	_steer = float(_arg(args, "--steer", "0"))
	_boost = args.has("--boost")
	_jump_at = int(_arg(args, "--jump-at", "-1"))

	var ps := load("res://scenes/game.tscn") as PackedScene
	_game = ps.instantiate() as Game
	_game.external_input = true
	root.add_child(_game)
	root.set_deferred("current_scene", _game)  # arena_setup looks it up
	print("physics engine: ", ProjectSettings.get_setting("physics/3d/physics_engine"))
	print("tick  car_pos                        speed  fwd_spd  grnd  wheels  ball_pos")


func _arg(args: PackedStringArray, key: String, dflt: String) -> String:
	var i := args.find(key)
	if i != -1 and i + 1 < args.size():
		return args[i + 1]
	return dflt


func _physics_process(_delta: float) -> bool:
	if _game == null:
		return true
	# Overwrite whatever the live poll produced — there is no keyboard here.
	var c := _game.player_car
	c.input.throttle = _throttle
	c.input.steer = _steer
	c.input.boost = _boost
	c.input.jump = _jump_at >= 0 and _ticks >= _jump_at and _ticks < _jump_at + 12
	c.infinite_boost = _boost

	_ticks += 1
	if _ticks % 60 == 0 or _ticks == 1:
		print("%4d  %-28s  %5.2f  %6.2f  %4s  %d  %s" % [
			_ticks,
			str(c.pos.snappedf(0.001)),
			c.vel.length(),
			c.forward_speed,
			str(c.grounded),
			c.wheels_down,
			str(_game.ball.pos.snappedf(0.001)),
		])
	return _ticks >= _max_ticks


func _finalize() -> void:
	if _game:
		print("final car y=%.4f  boost=%.1f" % [_game.player_car.pos.y, _game.player_car.boost])
