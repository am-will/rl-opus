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
## Free play has no celebration phase to borrow, so it gets a short one.
const PRACTICE_GOAL_PAUSE := 1.8

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
## Null headless and under the harnesses — see GameAudio.is_enabled().
var audio: GameAudio

var phase: Phase = Phase.COUNTDOWN
var score := [0, 0]
var clock := Feel.MATCH_DURATION
var countdown := Feel.MATCH_COUNTDOWN
var goal_timer := 0.0
var overtime := false
var last_scorer := -1
## Cumulative, for the harnesses: a demolished car respawns after a second, so
## `wrecked` is only true for a 120-tick window and is easy to sample past.
var demolition_count := 0
var goal_fx: GoalFx
## Lights the 34 pads out and back in as they are taken and respawn.
var pad_fx: BoostPadFx
## Public so a harness can make a run reproducible; see tests/soak.gd.
var rng := RandomNumberGenerator.new()

var _input := PlayerInput.new()
var _player_intent := CarInput.new()
var _bot_intent := CarInput.new()
var _empty_intent := CarInput.new()
var _role_timer := 0.0
var _arena: Node3D
var _fly_cam: Camera3D
var _free_cam := false
var _prev_ball_vel := Vector3.ZERO
## Reused every tick; the roster filter used to build a lambda and an Array at
## 120 Hz for a list that changes about twice a match.
var _active_cars: Array[Car] = []


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

	goal_fx = GoalFx.new()
	goal_fx.name = "GoalFx"
	add_child(goal_fx)

	# Splitting the four merged pad meshes into 34 is a few thousand triangles
	# of work at load, and headless (the trace suite, the soak) draws nothing.
	if DisplayServer.get_name() != "headless":
		pad_fx = BoostPadFx.new()
		pad_fx.name = "BoostPadFx"
		add_child(pad_fx)
		pad_fx.setup(_arena, pads.pads)

	# A scripted run must sound like nothing at all, so the trace suite and the
	# screenshot harness never see an audio node.
	if not external_input and GameAudio.is_enabled():
		audio = GameAudio.new()
		audio.name = "GameAudio"
		add_child(audio)
		post_step.connect(_audio_post_step)

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
		_active_cars.clear()
		for c in cars:
			if c.active:
				_active_cars.append(c)
		pads.update(dt, _active_cars)
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
	demolition_count += 1
	if audio:
		audio.explode()
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
	if audio:
		audio.goal()
	score[scorer] += 1
	last_scorer = scorer
	if hud:
		hud.flash_goal(scorer)
	if cam:
		cam.add_shake(2.0)
	# The blast throws every car within 28 m, so it has to happen before the
	# kickoff resets them.
	if goal_fx:
		goal_fx.fire(
			ball.pos,
			HUD.BLUE if scorer == Feel.TEAM_BLUE else HUD.ORANGE,
			cars,
			rng
		)
	phase = Phase.GOAL
	if practice:
		# Free play still pauses on a goal, or the blast and the banner are gone
		# before you have seen either — just a short one, and no slow motion.
		goal_timer = PRACTICE_GOAL_PAUSE
		return
	goal_timer = Feel.MATCH_GOAL_CELEBRATION
	Engine.time_scale = Feel.MATCH_SLOWMO_SCALE


## Ramp out of the goal replay. Godot scales the dt handed to _process, so the
## celebration timer ticks at a fifth speed too — left alone, 3.2 s of it takes
## 14.5 real seconds. Game.ts:398 ramps timeScale back over about a second of
## REAL time and lets the timer run out normally after that.
func _recover_time_scale(dt: float) -> void:
	if Engine.time_scale >= 1.0:
		return
	var real_dt := dt / maxf(Engine.time_scale, 0.01)
	Engine.time_scale = minf(
		1.0, Engine.time_scale + real_dt * Feel.MATCH_SLOWMO_RECOVER
	)


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
			if goal_timer <= 0.0 and practice:
				kickoff()
				phase = Phase.PLAYING
			elif goal_timer <= 0.0:
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
	if audio:
		audio.whistle()


# ---------------------------------------------------------------------------
# Frame
# ---------------------------------------------------------------------------

func _process(dt: float) -> void:
	_recover_time_scale(dt)
	_advance_clock(dt)
	if audio:
		# Phases are passed in rather than read back out, so game_audio.gd never
		# has to name this script's enum.
		audio.on_frame(
			self, dt, phase == Phase.COUNTDOWN, phase == Phase.PLAYING, countdown
		)

	for c in cars:
		c.sync()
	ball.sync()
	if pad_fx:
		pad_fx.update(dt)

	if cam and not _free_cam:
		# The arena glTF ships eleven Camera3Ds and shot_cameras.gd adds more;
		# any of them can take the viewport back. Just keep claiming it.
		if not cam.current:
			cam.current = true
		cam.update(player_car, ball, dt)
	if hud:
		hud.update_from(self)


## Driven by the event queue rather than polled from `_process`.
##
## `is_action_just_pressed` is true only on the frame the press arrived, so a
## tap that starts and ends between two rendered frames is simply lost — 33 ms
## was already enough to drop one here, and on a frame that takes 60 ms a normal
## press goes missing. That is what "B does nothing" looks like from the
## keyboard. The driving controls are unaffected: `player_input.gd` reads held
## state, which cannot be missed this way.
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("rl_camera") and cam:
		cam.toggle_mode()
	if event.is_action_pressed("rl_reset_car"):
		reset_player()
	if event.is_action_pressed("rl_restart"):
		restart_match()
	if event.is_action_pressed("rl_mode"):
		# Free play is the default because "drive around and hit the ball" is
		# what you want on the first run; N is how you get a real match with a
		# clock, a countdown and a celebration.
		practice = not practice
		restart_match()
		if hud:
			hud.toast("Free play" if practice else "5:00 match")
	if event.is_action_pressed("rl_infinite_boost"):
		# Only the player's car: the point of the mode is practising aerials and
		# kickoffs without a boost run, not handing the bot the same gift.
		var on := not player_car.infinite_boost
		player_car.infinite_boost = on
		# The dial reads ∞ either way, but with a full tank the change is a
		# single glyph in the corner and easy to miss.
		if hud:
			hud.toast("Infinite boost on" if on else "Infinite boost off")
	if event.is_action_pressed("rl_toggle_hud") and hud:
		hud.visible = not hud.visible
	if event.is_action_pressed("rl_free_cam"):
		_toggle_free_cam()
	if event.is_action_pressed("rl_menu"):
		get_tree().quit()
	if audio:
		if event.is_action_pressed("rl_mute"):
			var m := audio.toggle_mute()
			if hud:
				hud.toast("Sound off" if m else "Sound on")
		var step := 0
		if event.is_action_pressed("rl_volume_up"):
			step = 1
		elif event.is_action_pressed("rl_volume_down"):
			step = -1
		if step != 0:
			var pct := audio.change_volume(step)
			# A blip at the new level is the only way to hear where you landed.
			audio.ui_tick(true)
			if hud:
				hud.toast("Volume %d%%" % pct)


## `post_step` fires after the solver has been post-processed and before the
## next tick's `car.tick` clears the one-frame flags, which is the one moment
## where the ball impact, the jump/flip/land flags and the pad events are all
## readable at once.
func _audio_post_step(_dt: float) -> void:
	if audio:
		audio.on_post_step(self)


func _toggle_free_cam() -> void:
	if _fly_cam == null:
		return
	_free_cam = not _free_cam
	_fly_cam.current = _free_cam
	_fly_cam.set_process(_free_cam)
	_fly_cam.set_process_input(_free_cam)
	cam.current = not _free_cam
