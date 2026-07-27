extends SceneTree
## Match mode: countdown -> playing -> goal -> slow motion -> kickoff ->
## countdown, and the clock running out. Free play is the default so none of
## this is on the path a player takes by accident, but all of it is ported and
## none of it was exercised by anything else.
##
##   godot --path godot/SlopetLeague --headless --script tests/probe_match.gd

var _game: Game = null
var _ready_done := false
var _stage := 0
var _wait := 0
var _fails := 0
var _checks := 0
var _saw_slowmo := false


func _initialize() -> void:
	var ps := load("res://scenes/game.tscn") as PackedScene
	_game = ps.instantiate() as Game
	_game.practice = false
	_game.external_input = true
	root.add_child(_game)


func _physics_process(_dt: float) -> bool:
	if not _ready_done:
		if _game == null or _game.player_car == null:
			return false
		current_scene = _game
		_ready_done = true
		return false
	if Engine.time_scale < 0.9:
		_saw_slowmo = true
	if _wait > 0:
		_wait -= 1
		return false
	return _run()


func _run() -> bool:
	match _stage:
		0:
			print("\n-- match flow")
			_check_true("starts in countdown", _game.phase == Game.Phase.COUNTDOWN)
			_check_true("the clock is full",
				absf(_game.clock - Feel.MATCH_DURATION) < 0.01)
			# The clock advances on rendered frames, not physics ticks, so drive
			# the phase timers directly rather than waiting out three seconds.
			_game._advance_clock(Feel.MATCH_COUNTDOWN + 0.01)
			_wait = 2
		1:
			_check_true("countdown ends in play", _game.phase == Game.Phase.PLAYING)
			_game.score = [0, 0]
			_game.player_car.set_active(false)
			_game.ball.reset(
				Vector3(0.0, 1.5, Feel.ARENA_HALF_LENGTH - 1.0), Vector3(0.0, 0.0, 22.0)
			)
			_wait = 60
		2:
			_check("a goal scores", float(_game.score[0]), 1.0)
			_check_true("...and stops play", _game.phase == Game.Phase.GOAL)
			_check_true("...in slow motion", _saw_slowmo)
			_game._advance_clock(Feel.MATCH_GOAL_CELEBRATION + 0.01)
			_wait = 2
		3:
			_check_true("the celebration ends in a countdown",
				_game.phase == Game.Phase.COUNTDOWN)
			_check_true("...at normal speed", absf(Engine.time_scale - 1.0) < 0.001)
			_check("...with the ball on the centre spot",
				Vector2(_game.ball.pos.x, _game.ball.pos.z).length(), 0.0, 0.05)
			_game._advance_clock(Feel.MATCH_COUNTDOWN + 0.01)
			_wait = 2
		4:
			# Run the clock out with the score level: that is overtime, not the end.
			_game.score = [1, 1]
			_game.clock = 0.5
			_game._advance_clock(1.0)
			_check_true("a level scoreline at 0:00 goes to overtime", _game.overtime)
			_check_true("...and play continues", _game.phase == Game.Phase.PLAYING)
			# Now score in overtime.
			_game.score = [2, 1]
			_game._advance_clock(0.1)
			_game.phase = Game.Phase.GOAL
			_game.goal_timer = 0.01
			_game._advance_clock(0.02)
			_check_true("a goal in overtime ends the match",
				_game.phase == Game.Phase.ENDED)
		5:
			# Godot scales the dt handed to _process, so the celebration timer
			# ticks at a fifth speed too: without the ramp, 3.2 s of celebration
			# takes 14.5 real seconds at 1.8 ms physics steps.
			Engine.time_scale = Feel.MATCH_SLOWMO_SCALE
			var real := 0.0
			var frames := 0
			while Engine.time_scale < 1.0 and frames < 600:
				# What _process would be handed at 60 fps real.
				_game._recover_time_scale((1.0 / 60.0) * Engine.time_scale)
				real += 1.0 / 60.0
				frames += 1
			_check("slow motion ramps back over about a second", real, 1.04, 0.1)
			_check_true("...and reaches full speed", Engine.time_scale >= 1.0)
			_game.restart_match()
			_check("restart clears the score", float(_game.score[0] + _game.score[1]), 0.0)
			_check_true("...and resets the clock",
				absf(_game.clock - Feel.MATCH_DURATION) < 0.01)
			_check_true("...and drops overtime", not _game.overtime)
		_:
			print("\n%s  (%d checks, %d failed)" % [
				"FAIL" if _fails > 0 else "PASS", _checks, _fails
			])
			quit(1 if _fails > 0 else 0)
			return true
	_stage += 1
	return false


func _check(label: String, got: float, want: float, tol := 0.01) -> void:
	_checks += 1
	var ok := absf(got - want) <= tol
	if not ok:
		_fails += 1
	print("  %-46s got %8.3f want %8.3f  %s" % [label, got, want, "ok" if ok else "FAILED"])


func _check_true(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("  %-46s %s" % [label, "ok" if ok else "FAILED"])
