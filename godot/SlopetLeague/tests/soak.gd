extends SceneTree
## Long random-input soak. Nothing about a scripted trace proves the game
## survives a player, so this drives it with changing random input for minutes
## of simulated time and asserts the invariants that would ruin a match:
## tunnelling out of the shell, a solver blow-up, NaN, or a speed cap breach.
##
##   godot --path godot/SlopetLeague --headless --script tests/soak.gd -- --ticks 60000
##
## Deterministic: the seed is fixed unless --seed is passed.

var _game: Game = null
var _tick := 0
var _max_ticks := 60000
var _ready_done := false
var _rng := RandomNumberGenerator.new()
var _next_change := 0
var _fails: Array[String] = []
var _worst_speed := 0.0
var _worst_ball_speed := 0.0
var _min_y := 999.0
var _serves := 0

## Generous — the shell is 40.96 x 51.2 plus 8.8 m of goal, and a car legally
## reaches the 20.44 m ceiling. Anything past this is out of the world.
const X_LIMIT := 44.0
const Z_LIMIT := 62.0
const Y_MIN := -1.5
const Y_MAX := 24.0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	_max_ticks = int(_arg(args, "--ticks", "60000"))
	_rng.seed = int(_arg(args, "--seed", "20260727"))
	var ps := load("res://scenes/game.tscn") as PackedScene
	_game = ps.instantiate() as Game
	_game.external_input = true
	root.add_child(_game)


func _physics_process(_dt: float) -> bool:
	if not _ready_done:
		if _game == null or _game.player_car == null:
			return false
		current_scene = _game
		# The bot car is benched while external_input is set (that is what keeps
		# the trace harness to one car); a soak wants both of them moving.
		for c in _game.cars:
			if not c.active:
				c.respawn(_rng.randf_range(-20.0, 20.0), _rng.randf_range(-40.0, 40.0), 0.0)
		_game.post_step.connect(_on_post)
		_ready_done = true
	return false


func _on_post(_dt: float) -> void:
	if _tick >= _max_ticks:
		_report()
		quit(1 if _fails.size() > 0 else 0)
		return

	# Random driving alone almost never finds the ball, so serve it at the car
	# every few seconds. That is what puts try_hit_ball, the Psyonix impulse and
	# ball-vs-shell contact under the soak rather than just the car.
	if _tick % 500 == 0:
		var c: Car = _game.player_car
		_serves += 1
		var at := c.pos + c.forward * 6.0 + Vector3(0.0, _rng.randf_range(0.5, 6.0), 0.0)
		_game.ball.reset(_inside(at), -c.forward * _rng.randf_range(0.0, 25.0))

	if _tick >= _next_change:
		_next_change = _tick + _rng.randi_range(20, 200)
		for c in _game.cars:
			_roll(c.input)

	# A goal blast deliberately overshoots the cap — the TS build's blastCars
	# does the same, and Car._clamp_speed pulls it back on the very next tick.
	# Sampling here is between the two, so don't call it a fault.
	var celebrating := _game.phase == Game.Phase.GOAL
	for c in _game.cars:
		if not c.active:
			continue
		_check("car", c.pos, c.vel, INF if celebrating else Feel.CAR_MAX_SPEED)
		if not celebrating:
			_worst_speed = maxf(_worst_speed, c.vel.length())
		_min_y = minf(_min_y, c.pos.y)
	_check("ball", _game.ball.pos, _game.ball.vel, Feel.BALL_MAX_SPEED)
	_worst_ball_speed = maxf(_worst_ball_speed, _game.ball.vel.length())

	_tick += 1
	if _tick % 6000 == 0:
		print("  %6d ticks  car|v|max=%.2f  ball|v|max=%.2f  car y min=%.3f  faults=%d" % [
			_tick, _worst_speed, _worst_ball_speed, _min_y, _fails.size()
		])


## Pull a point back inside the shell, including the 45-degree corner cuts.
## Serving the ball through a wall is the harness's bug, not the game's, and it
## is exactly what the first run of this soak reported 1100 times.
func _inside(p: Vector3) -> Vector3:
	var margin := Feel.BALL_RADIUS + 1.0
	p.x = clampf(p.x, -Feel.ARENA_HALF_WIDTH + margin, Feel.ARENA_HALF_WIDTH - margin)
	p.z = clampf(p.z, -Feel.ARENA_HALF_LENGTH + margin, Feel.ARENA_HALF_LENGTH - margin)
	p.y = clampf(p.y, Feel.BALL_RADIUS + 0.05, Feel.ARENA_CEILING - margin)
	var total := absf(p.x) + absf(p.z)
	var limit := Feel.ARENA_CORNER_SUM - margin * 1.5
	if total > limit:
		var excess := (total - limit) * 0.5
		p.x -= signf(p.x) * excess
		p.z -= signf(p.z) * excess
	return p


func _roll(i: CarInput) -> void:
	i.throttle = _rng.randf_range(-1.0, 1.0)
	i.steer = _rng.randf_range(-1.0, 1.0)
	i.pitch = _rng.randf_range(-1.0, 1.0)
	i.roll = _rng.randf_range(-1.0, 1.0)
	i.jump = _rng.randf() < 0.35
	i.boost = _rng.randf() < 0.45
	i.drift = _rng.randf() < 0.25


func _check(what: String, p: Vector3, v: Vector3, cap: float) -> void:
	if is_nan(p.x) or is_nan(p.y) or is_nan(p.z) or is_nan(v.x) or is_nan(v.y) or is_nan(v.z):
		_fail("%s NaN at tick %d: p=%v v=%v" % [what, _tick, p, v])
		return
	# A parked car sits at y = -80 on purpose.
	if p.y < -50.0:
		return
	if absf(p.x) > X_LIMIT or absf(p.z) > Z_LIMIT or p.y < Y_MIN or p.y > Y_MAX:
		_fail("%s left the arena at tick %d: p=%v" % [what, _tick, p])
	if v.length() > cap * 1.02 + 0.5:
		_fail("%s over its speed cap at tick %d: |v|=%.2f > %.2f" % [
			what, _tick, v.length(), cap
		])


func _fail(msg: String) -> void:
	# One line per distinct fault; a blow-up would otherwise print thousands.
	if _fails.size() < 12:
		print("  FAULT ", msg)
	_fails.append(msg)


func _report() -> void:
	print("\nsoak: %d ticks (%.1f simulated minutes), seed %d" % [
		_tick, _tick / 120.0 / 60.0, _rng.seed
	])
	print("  peak car speed  %.2f m/s (cap %.2f)" % [_worst_speed, Feel.CAR_MAX_SPEED])
	print("  peak ball speed %.2f m/s (cap %.2f)" % [_worst_ball_speed, Feel.BALL_MAX_SPEED])
	print("  lowest car y    %.3f" % _min_y)
	print("  ball serves     %d" % _serves)
	print("%s  %d faults" % ["FAIL" if _fails.size() > 0 else "PASS", _fails.size()])


func _arg(args: PackedStringArray, key: String, dflt: String) -> String:
	var i := args.find(key)
	if i != -1 and i + 1 < args.size():
		return args[i + 1]
	return dflt
