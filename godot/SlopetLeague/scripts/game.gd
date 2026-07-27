class_name Game
extends Node3D
## The match. Port of the fixed-step loop in src/core/Game.ts.
##
## Godot calls `_physics_process` BEFORE it steps the solver, so one call here
## holds the tail of the previous tick and the head of the next one:
##
##   [ball.tick, syncs, pads, demos, goal] | [input, car.tick, try_hit_ball] > step
##
## which is the same sequence as the TypeScript build's
##
##   [input, car.update, tryHitBall] > step > [ball.update, syncs, pads, demos, goal]
##
## just rotated by one call. Getting this order wrong is the single easiest way
## to lose physics parity — `tryHitBall` in particular must run on PRE-step
## velocities and is not a collision callback.

enum Phase { COUNTDOWN, PLAYING, GOAL, ENDED, PAUSED }

const CAR_SCENE := preload("res://scenes/car.tscn")
const BALL_SCENE := preload("res://scenes/ball.tscn")

@export var arena_root_name := "ChampionsField"
## Free play: no clock, no countdown, goals reset the ball and nothing else.
@export var practice := true
## Opponent difficulty, 0..1. 0.5 is "Pro" from BOT_SKILLS in src/config.ts.
@export_range(0.0, 1.0, 0.01) var bot_skill := 0.5
## Set by the headless harnesses: don't poll the keyboard, the caller writes
## `car.input` itself before each tick.
var external_input := false
## The trace harness turns these off so a scripted run isn't cut short by a
## kickoff reset or given boost it didn't ask for.
var enable_goals := true
var enable_pads := true

## Emitted once per physics tick, after the previous solver step has been
## post-processed and before this tick's input is read. This is the exact point
## the TypeScript recorder samples, so it is where the trace harness hooks in.
signal post_step(dt: float)

var ball: Ball
var cars: Array[Car] = []
var player_car: Car
var bot_car: Car
var bot: Bot
var cam: ChaseCamera
var pads := BoostPads.new()
var hud: HUD

var phase: Phase = Phase.COUNTDOWN
var score := [0, 0]
var clock := Feel.MATCH_DURATION
var countdown := Feel.MATCH_COUNTDOWN
var goal_timer := 0.0
var overtime := false
var last_scorer := -1

var _input := PlayerInput.new()
var _player_intent := CarInput.new()
var _bot_intent := CarInput.new()
var _empty_intent := CarInput.new()
var _role_timer := 0.0
var _arena: Node3D
var _fly_cam: Camera3D
var _free_cam := false
var _prev_ball_vel := Vector3.ZERO


func _ready() -> void:
	PlayerInput.setup_actions()

	_arena = get_node_or_null(NodePath(arena_root_name)) as Node3D
	if _arena == null:
		_arena = find_child(arena_root_name, true, false) as Node3D
	assert(_arena != null, "arena root '%s' not found" % arena_root_name)
	_prepare_arena()

	ball = BALL_SCENE.instantiate() as Ball
	add_child(ball)
	_attach_ball_mesh()

	player_car = _spawn_car(Feel.TEAM_BLUE)

	bot_car = _spawn_car(Feel.TEAM_ORANGE)
	# Blue defends -z and attacks +z; orange is the mirror image.
	bot = Bot.new(bot_car, Feel.ARENA_HALF_LENGTH, -Feel.ARENA_HALF_LENGTH, bot_skill)

	cam = ChaseCamera.new()
	cam.name = "ChaseCamera"
	add_child(cam)

	_fly_cam = find_child("FlyCam", true, false) as Camera3D
	if _fly_cam:
		_fly_cam.current = false
		_fly_cam.set_process(false)
		_fly_cam.set_process_input(false)

	hud = HUD.new()
	hud.name = "HUD"
	add_child(hud)

	kickoff()
	if practice:
		phase = Phase.PLAYING


# ---------------------------------------------------------------------------
# Arena wiring
# ---------------------------------------------------------------------------

## The play volume arrives from the glTF as four StaticBody3Ds (the exporter
## suffixes those meshes with `-col`). All this does is put them on the arena
## layer and give them RL's surface response.
func _prepare_arena() -> void:
	var surfaces := Feel.SURF_FRICTION
	var found := 0
	for name in surfaces.keys():
		var mesh := _arena.find_child(name, true, false)
		if mesh == null:
			push_warning("arena: %s not found" % name)
			continue
		for child in mesh.get_children():
			if child is StaticBody3D:
				var body := child as StaticBody3D
				body.collision_layer = Layers.ARENA
				body.collision_mask = 0
				var mat := PhysicsMaterial.new()
				mat.friction = surfaces[name]
				mat.bounce = Feel.SURF_BOUNCE
				mat.absorbent = false
				body.physics_material_override = mat
				found += 1
	assert(found >= 4, "arena collision bodies missing (found %d)" % found)


## The ball ships baked into the arena glTF as static decoration. Steal the mesh
## and hang it off the rigid body, centred on its own AABB.
func _attach_ball_mesh() -> void:
	var mi := _arena.find_child("CF_Ball", true, false) as MeshInstance3D
	if mi == null:
		push_warning("arena: CF_Ball mesh not found; the ball will be invisible")
		return
	var centre := mi.get_aabb().get_center()
	mi.get_parent().remove_child(mi)
	ball.add_child(mi)
	mi.owner = null
	mi.position = -centre
	mi.name = "BallMesh"


func _spawn_car(team: int) -> Car:
	var c := CAR_SCENE.instantiate() as Car
	c.team = team
	c.name = "Car%d" % cars.size()
	add_child(c)
	cars.append(c)
	return c


# ---------------------------------------------------------------------------
# Fixed step
# ---------------------------------------------------------------------------

func _physics_process(dt: float) -> void:
	# --- tail of the previous solver step -----------------------------------
	ball.tick(dt)
	ball.sync()
	for c in cars:
		c.sync()

	var live := phase == Phase.PLAYING
	if enable_pads:
		var active_cars: Array = cars.filter(func(c: Car) -> bool: return c.active)
		pads.update(dt, active_cars)
	_update_demolitions()
	if live and enable_goals:
		_check_goal()

	post_step.emit(dt)

	# --- head of the next one ------------------------------------------------
	if external_input:
		pass  # the harness has already written car.input
	elif live:
		_input.poll(_player_intent)
		player_car.input.copy_from(_player_intent)
		_drive_bots(dt)
	else:
		# Cars are frozen during the countdown and the goal replay, but the
		# world still settles.
		for c in cars:
			c.input.copy_from(_empty_intent)

	for c in cars:
		c.tick(dt)
	for c in cars:
		if c.active:
			c.try_hit_ball(ball)

	_prev_ball_vel = ball.vel


## Roles are re-decided on a timer rather than every step: at 120 Hz the closest
## car flips back and forth during a challenge and the bots dither on the spot.
func _drive_bots(dt: float) -> void:
	if bot == null:
		return
	_role_timer -= dt
	if _role_timer <= 0.0:
		_role_timer = 0.25
		_assign_roles()
	if not bot_car.active:
		return
	bot.update(dt, ball, pads, _bot_intent)
	bot_car.input.copy_from(_bot_intent)


## Closest car on the side takes the ball; the rest hold a support position.
func _assign_roles() -> void:
	var closest: Car = null
	var best := INF
	for c in cars:
		if not c.active or c.team != bot_car.team:
			continue
		var d := c.pos.distance_squared_to(ball.pos)
		if d < best:
			best = d
			closest = c
	# Alone on its side there is nobody to support, so it always attacks.
	bot.role = Bot.Role.SUPPORT if closest != null and closest != bot_car else Bot.Role.ATTACK


func _update_demolitions() -> void:
	for c in cars:
		if not c.wrecked or c.demo_timer > 0.0:
			continue
		var own := -1.0 if c.team == Feel.TEAM_BLUE else 1.0
		c.respawn(
			-3.5 if c.team == Feel.TEAM_BLUE else 3.5,
			own * (Feel.ARENA_HALF_LENGTH - 4.0),
			PI if own > 0.0 else 0.0,
			Feel.RESPAWN_BOOST
		)
		if c == player_car and cam:
			cam.snap(c, ball)
		if c == bot_car and bot:
			# Every timer it was holding describes a wreck that no longer exists.
			bot.reset()

	for i in cars.size():
		for j in range(i + 1, cars.size()):
			var a := cars[i]
			var b := cars[j]
			if a.team == b.team or not a.active or not b.active:
				continue
			if a.pos.distance_to(b.pos) > Feel.DEMO_RADIUS:
				continue
			var fast := a if a.speed >= b.speed else b
			var slow := b if fast == a else a
			if fast.speed < Feel.DEMO_MIN_SPEED:
				continue
			_demolish(slow)


func _demolish(victim: Car) -> void:
	victim.set_active(false)
	victim.wrecked = true
	victim.demo_timer = Feel.DEMO_RESPAWN_DELAY
	if cam:
		cam.add_shake(1.5 if victim == player_car else 0.7)
	if hud:
		hud.toast("Demolished!" if victim == player_car else "Demolition!")


# ---------------------------------------------------------------------------
# Goals, clock, kickoff
# ---------------------------------------------------------------------------

func _check_goal() -> void:
	var p := ball.pos
	if absf(p.x) > Feel.GOAL_HALF_WIDTH or p.y > Feel.GOAL_HEIGHT:
		return
	# "Fully across" — the ball's trailing edge has to clear the line.
	var line := Feel.ARENA_HALF_LENGTH + Feel.BALL_RADIUS
	if p.z > line:
		_on_goal(Feel.TEAM_BLUE)
	elif p.z < -line:
		_on_goal(Feel.TEAM_ORANGE)


func _on_goal(scorer: int) -> void:
	score[scorer] += 1
	last_scorer = scorer
	if practice:
		kickoff()
		if hud:
			hud.flash_goal(scorer)
		return
	phase = Phase.GOAL
	goal_timer = Feel.MATCH_GOAL_CELEBRATION
	Engine.time_scale = Feel.MATCH_SLOWMO_SCALE
	if cam:
		cam.add_shake(2.0)
	if hud:
		hud.flash_goal(scorer)


## Clock and phase timers. Runs once per RENDERED frame on the scaled dt, the
## same as the TS build — the match clock is deliberately not fixed-timestep.
func _advance_clock(dt: float) -> void:
	match phase:
		Phase.COUNTDOWN:
			countdown -= dt
			if countdown <= 0.0:
				countdown = 0.0
				phase = Phase.PLAYING
				if cam:
					cam.snap(player_car, ball)
		Phase.PLAYING:
			if practice:
				return
			clock -= dt
			if clock <= 0.0:
				clock = 0.0
				if score[0] == score[1]:
					overtime = true
				else:
					phase = Phase.ENDED
		Phase.GOAL:
			goal_timer -= dt
			if goal_timer <= 0.0:
				Engine.time_scale = 1.0
				if overtime or (clock <= 0.0 and score[0] != score[1]):
					phase = Phase.ENDED
				else:
					kickoff()
					phase = Phase.COUNTDOWN
					countdown = Feel.MATCH_COUNTDOWN
		_:
			pass


func kickoff() -> void:
	var spot_idx := randi() % Feel.KICKOFF_SPOTS.size()
	for i in cars.size():
		var c := cars[i]
		var spot: Vector2 = Feel.KICKOFF_SPOTS[spot_idx]
		var s := Feel.kickoff_spawn(c.team, spot)
		c.respawn(s.x, s.y, s.z, Feel.BOOST_START)
	ball.reset()
	pads.reset()
	Engine.time_scale = 1.0
	if bot:
		bot.reset()
	# The harnesses compare one car against a TS oracle that benches every racer
	# it isn't recording, so the opponent has to be out of the world there too.
	if external_input and bot_car:
		bot_car.set_active(false)
	if cam:
		cam.snap(player_car, ball)


func reset_player() -> void:
	var z := clampf(ball.pos.z - 18.0, -Feel.ARENA_HALF_LENGTH + 6.0, 0.0)
	var yaw := atan2(ball.pos.x, ball.pos.z - z)
	player_car.respawn(0.0, z, yaw, player_car.boost)
	if cam:
		cam.snap(player_car, ball)


func restart_match() -> void:
	score = [0, 0]
	clock = Feel.MATCH_DURATION
	countdown = Feel.MATCH_COUNTDOWN
	overtime = false
	phase = Phase.PLAYING if practice else Phase.COUNTDOWN
	kickoff()


# ---------------------------------------------------------------------------
# Frame
# ---------------------------------------------------------------------------

func _process(dt: float) -> void:
	_handle_one_shots()
	_advance_clock(dt)

	for c in cars:
		c.sync()
	ball.sync()

	if cam and not _free_cam:
		# The arena glTF ships eleven Camera3Ds and shot_cameras.gd adds more;
		# any of them can take the viewport back. Just keep claiming it.
		if not cam.current:
			cam.current = true
		cam.update(player_car, ball, dt)
	if hud:
		hud.update_from(self)


func _handle_one_shots() -> void:
	if Input.is_action_just_pressed("rl_camera") and cam:
		cam.toggle_mode()
	if Input.is_action_just_pressed("rl_reset_car"):
		reset_player()
	if Input.is_action_just_pressed("rl_restart"):
		restart_match()
	if Input.is_action_just_pressed("rl_infinite_boost"):
		player_car.infinite_boost = not player_car.infinite_boost
	if Input.is_action_just_pressed("rl_toggle_hud") and hud:
		hud.visible = not hud.visible
	if Input.is_action_just_pressed("rl_free_cam"):
		_toggle_free_cam()
	if Input.is_action_just_pressed("rl_menu"):
		get_tree().quit()


func _toggle_free_cam() -> void:
	if _fly_cam == null:
		return
	_free_cam = not _free_cam
	_fly_cam.current = _free_cam
	_fly_cam.set_process(_free_cam)
	_fly_cam.set_process_input(_free_cam)
	cam.current = not _free_cam
