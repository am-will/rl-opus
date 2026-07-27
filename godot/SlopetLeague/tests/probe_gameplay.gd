extends SceneTree
## The rules, not the physics: boost pads, goals, demolitions and the kickoff
## reset. The trace suite proves the car moves like the TS build; none of it
## touches any of this.
##
##   godot --path godot/SlopetLeague --headless --script tests/probe_gameplay.gd

var _game: Game = null
var _ready_done := false
var _stage := 0
var _wait := 0
var _fails := 0
var _checks := 0
var _demo_z := 0.0


func _initialize() -> void:
	var ps := load("res://scenes/game.tscn") as PackedScene
	_game = ps.instantiate() as Game
	_game.external_input = true  # no keyboard, no bot; we place everything
	root.add_child(_game)


func _physics_process(_dt: float) -> bool:
	if not _ready_done:
		if _game == null or _game.player_car == null:
			return false
		current_scene = _game
		_ready_done = true
		return false
	if _wait > 0:
		_wait -= 1
		return false
	return _run_stage()


func _run_stage() -> bool:
	var car := _game.player_car
	match _stage:
		# --- big boost pad -----------------------------------------------------
		0:
			print("\n-- boost pads")
			var pad: Vector2 = Feel.BIG_PAD_POSITIONS[0]
			car.respawn(pad.x, pad.y, 0.0, 0.0)
			_game.ball.reset(Vector3(0.0, 40.0, 0.0))
			_wait = 4
		1:
			_check("big pad fills the tank", car.boost, 100.0)
			var pad: Vector2 = Feel.SMALL_PAD_POSITIONS[13]
			car.respawn(pad.x, pad.y, 0.0, 0.0)
			_wait = 4
		2:
			_check("small pad gives 12", car.boost, 12.0)
			# A full tank must drive straight through without eating the pad.
			var pad: Vector2 = Feel.BIG_PAD_POSITIONS[1]
			car.boost = Feel.BOOST_MAX
			car.respawn(pad.x, pad.y, 0.0, Feel.BOOST_MAX)
			_wait = 4
		3:
			# Count only the pad we just drove over — two earlier pads are still
			# on their respawn timers.
			_check_true("a full tank leaves the pad alive",
				_game.pads.pads[1]["cooldown"] <= 0.0)
			_check("...and does not overfill", car.boost, Feel.BOOST_MAX)

		# --- goals -------------------------------------------------------------
		4:
			print("\n-- goals")
			car.set_active(false)
			_resume()
			_game.score = [0, 0]
			_game.ball.reset(
				Vector3(0.0, 1.5, Feel.ARENA_HALF_LENGTH - 1.0), Vector3(0.0, 0.0, 22.0)
			)
			_wait = 60
		5:
			_check("ball into the orange net scores for blue", float(_game.score[0]), 1.0)
			_check("and only once", float(_game.score[1]), 0.0)
			_resume()
			_game.score = [0, 0]
			_game.ball.reset(
				Vector3(0.0, 1.5, -Feel.ARENA_HALF_LENGTH + 1.0), Vector3(0.0, 0.0, -22.0)
			)
			_wait = 60
		6:
			_check("ball into the blue net scores for orange", float(_game.score[1]), 1.0)
			# Wide of the post is not a goal.
			_resume()
			_game.score = [0, 0]
			_game.ball.reset(
				Vector3(Feel.GOAL_HALF_WIDTH + 2.0, 1.5, Feel.ARENA_HALF_LENGTH - 4.0),
				Vector3(0.0, 0.0, 20.0)
			)
			_wait = 90
		7:
			_check("wide of the post is not a goal", float(_game.score[0] + _game.score[1]), 0.0)

		# --- demolition --------------------------------------------------------
		8:
			print("\n-- demolitions")
			_resume()
			if _game.cars.size() < 2:
				print("  (no second car; skipped)")
				_stage = 98
				return false
			_game.ball.reset(Vector3(0.0, 40.0, 30.0))
			var victim := _game.cars[1]
			victim.respawn(0.0, 6.0, PI, Feel.BOOST_START)
			car.respawn(0.0, -6.0, 0.0, Feel.BOOST_MAX)
			# Below supersonic: contact must NOT wreck anyone. Coast braking eats
			# 5.25 m/s^2, so start well clear of the threshold and hold nothing.
			car.linear_velocity = car.forward * (Feel.DEMO_MIN_SPEED - 4.0)
			_wait = 120
		9:
			_check_true("a sub-supersonic bump is not a demolition",
				not _game.cars[1].wrecked and _game.cars[1].active)
			var victim := _game.cars[1]
			victim.respawn(0.0, 6.0, PI, Feel.BOOST_START)
			car.respawn(0.0, -6.0, 0.0, Feel.BOOST_MAX)
			_game.demolition_count = 0
			car.linear_velocity = car.forward * Feel.CAR_MAX_SPEED
			# Hold throttle and boost so it is still supersonic on contact.
			car.infinite_boost = true
			car.input.throttle = 1.0
			car.input.boost = true
			_wait = 120
		10:
			# Count, not `wrecked`: the wreck respawns after a second, and the
			# first draft of this test slept straight past the window.
			_check("supersonic contact demolishes the other car",
				float(_game.demolition_count), 1.0)
			car.infinite_boost = false
			car.input.clear()
			_wait = 240
		11:
			_check_true("the wreck respawns", _game.cars[1].active)
			_check_true("...at its own end",
				signf(_game.cars[1].pos.z)
					== (1.0 if _game.cars[1].team == Feel.TEAM_ORANGE else -1.0))
			# Freezing a parked car is what keeps a benched one off Jolt's
			# velocity ceiling; forgetting to thaw it on respawn would leave a
			# demolished car immovable for the rest of the match.
			_game.cars[1].input.throttle = 1.0
			_wait = 60
		12:
			_check_true("...and can drive again", _game.cars[1].speed > 2.0)
			_game.cars[1].input.clear()

		# --- kickoff -----------------------------------------------------------
		13:
			print("\n-- kickoff")
			_game.kickoff()
			_wait = 2
		14:
			_check("the ball returns to the centre spot",
				Vector2(_game.ball.pos.x, _game.ball.pos.z).length(), 0.0)
			_check_true("...at rest", _game.ball.vel.length() < 0.2)
			_check_true("the player is on its own half", _game.player_car.pos.z < 0.0)
			# The second car is benched while external_input is set, so check the
			# mirror on the rule rather than on where it happens to be parked.
			for spot in Feel.KICKOFF_SPOTS:
				var a := Feel.kickoff_spawn(Feel.TEAM_BLUE, spot)
				var b := Feel.kickoff_spawn(Feel.TEAM_ORANGE, spot)
				_check_true("kickoff spawns mirror through the centre spot",
					absf(a.x + b.x) < 1e-6 and absf(a.y + b.y) < 1e-6)
		_:
			print("\n%s  (%d checks, %d failed)" % [
				"FAIL" if _fails > 0 else "PASS", _checks, _fails
			])
			quit(1 if _fails > 0 else 0)
			return true
	_stage += 1
	return false


## Scoring leaves free play mid-celebration, and it kicks off out of that 1.8 s
## later — which would both stop the next goal registering and respawn the cars
## under the demolition setup.
func _resume() -> void:
	_game.phase = Game.Phase.PLAYING
	_game.goal_timer = 0.0


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
