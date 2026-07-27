extends SceneTree
## Headless check that the ported opponent actually plays.
##
##   godot --path godot/SlopetLeague --headless --script tests/probe_bot.gd \
##       -- --ticks 900 [--skill 0.5] [--seed 1234]
##
## `external_input` stays FALSE on purpose — game.gd's own bot wiring is what is
## under test, not the Bot class in isolation. There is no keyboard here, so the
## player car sits on its kickoff spot and the bot has the pitch to itself.
##
## Passing means the gap to the ball closes to inside a car length AND the ball
## gets struck: a bot that drives into a wall fails the first, one that circles
## the ball forever fails the second.

var _ticks := 0
var _max_ticks := 900
var _game: Game = null
var _first_dist := 0.0
var _min_dist := INF
var _touches := 0
var _max_ball_travel := 0.0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	_max_ticks = int(_arg(args, "--ticks", "900"))
	# The kickoff spot and the bot's aim jitter both draw from the global RNG;
	# pin it so the printed numbers mean the same thing on every run.
	seed(int(_arg(args, "--seed", "1234")))

	var ps := load("res://scenes/game.tscn") as PackedScene
	_game = ps.instantiate() as Game
	_game.bot_skill = float(_arg(args, "--skill", "0.5"))
	root.add_child(_game)
	root.set_deferred("current_scene", _game)


func _arg(args: PackedStringArray, key: String, dflt: String) -> String:
	var i := args.find(key)
	if i != -1 and i + 1 < args.size():
		return args[i + 1]
	return dflt


func _physics_process(_delta: float) -> bool:
	if _game == null or _game.bot_car == null:
		return false

	var c := _game.bot_car
	var d := c.pos.distance_to(_game.ball.pos)
	_ticks += 1
	if _ticks == 1:
		_first_dist = d
		print("bot spawn %s  player spawn %s  skill %.2f" % [
			str(c.pos.snappedf(0.01)),
			str(_game.player_car.pos.snappedf(0.01)),
			_game.bot_skill,
		])
		print("tick  bot_pos                  dist_ball  speed  boost  thr  steer  bst  ball_pos")
	_min_dist = minf(_min_dist, d)
	# The ball starts on the centre spot, so any travel at all is the bot's doing.
	_max_ball_travel = maxf(_max_ball_travel, _game.ball.pos.length())
	if not c.ball_hit_event.is_empty():
		_touches += 1

	if _ticks % 60 == 0 or _ticks == 1:
		print("%4d  %-23s  %8.2f  %5.2f  %5.1f  %4.1f  %5.2f  %3s  %s" % [
			_ticks,
			str(c.pos.snappedf(0.01)),
			d,
			c.speed,
			c.boost,
			c.input.throttle,
			c.input.steer,
			str(c.input.boost),
			str(_game.ball.pos.snappedf(0.01)),
		])
	if _ticks < _max_ticks:
		return false
	_summarise()
	return true


## Printed from the last tick rather than `_finalize`, whose output the engine
## drops on the way out (probe_game.gd has the same hole).
func _summarise() -> void:
	print("first_dist=%.2f  min_dist=%.2f  closed=%.2f  touches=%d  ball_travel=%.2f  score=%s" % [
		_first_dist,
		_min_dist,
		_first_dist - _min_dist,
		_touches,
		_max_ball_travel,
		str(_game.score),
	])
	var ok := _min_dist < 4.0 and _touches > 0
	print("probe_bot: ", "PASS" if ok else "FAIL")
