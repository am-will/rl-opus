class_name ChaseCamera
extends Camera3D
## Port of src/render/ChaseCamera.ts.
##
## The camera direction comes from world-space car->ball (ball cam) or from the
## car's velocity (standard cam) — never from the car's own basis, and the up
## vector is always world up. That is why it neither rolls nor flips when the
## car does, which is what keeps wall and ceiling play readable.
##
## Runs once per RENDERED frame, on the scaled frame dt.

enum Mode { BALL, STANDARD }

var mode: Mode = Mode.BALL

var _dir := Vector3(0, 0, 1)
var _pos := Vector3.ZERO
var _target := Vector3.ZERO
var _fov := Feel.CAM_FOV
var _shake_amount := 0.0
var _shake_time := 0.0


func _ready() -> void:
	keep_aspect = Camera3D.KEEP_HEIGHT
	fov = Feel.CAM_FOV
	near = 0.1
	far = 900.0
	current = true


func toggle_mode() -> void:
	mode = Mode.STANDARD if mode == Mode.BALL else Mode.BALL


func add_shake(a: float) -> void:
	_shake_amount = minf(1.6, _shake_amount + a)


func update(car: Car, ball: Ball, dt: float, immediate := false) -> void:
	var ball_cam := mode == Mode.BALL

	# --- Desired look direction --------------------------------------------
	var want: Vector3
	if ball_cam:
		want = ball.pos - car.pos
		want.y = clampf(want.y * 0.35, -6.0, 9.0)
	else:
		want = Vector3(car.vel.x, 0.0, car.vel.z)
		# Below 3 m/s the velocity is noise, so fall back to the heading.
		if want.length_squared() < 9.0:
			want = Vector3(car.forward.x, 0.0, car.forward.z)
	if want.length_squared() < 1e-4:
		want = Vector3(0, 0, 1)
	want = want.normalized()

	var swivel := 1.0 if immediate else 1.0 - exp(-Feel.CAM_SWIVEL_SPEED * dt)
	_dir = _dir.lerp(want, swivel).normalized()

	# --- Position -----------------------------------------------------------
	var dist := Feel.CAM_BALL_DISTANCE if ball_cam else Feel.CAM_DISTANCE
	var height := Feel.CAM_BALL_HEIGHT if ball_cam else Feel.CAM_HEIGHT
	var speed_t := clampf(car.vel.length() / Feel.CAR_MAX_SPEED, 0.0, 1.0)
	var back := dist * (1.0 + speed_t * 0.16)

	var desired := car.pos - _dir * back
	# Assigned, not accumulated: the camera height is always tied to the car's,
	# which is what stops it orbiting when the car is on a wall.
	desired.y = car.pos.y + height + speed_t * 0.35
	desired = _clamp_to_arena(desired)

	var follow := 1.0 if immediate else 1.0 - exp(-Feel.CAM_STIFFNESS * 18.0 * dt)
	_pos = _clamp_to_arena(_pos.lerp(desired, follow))

	# --- Look target --------------------------------------------------------
	var look := car.pos + Vector3(0.0, 0.55, 0.0)
	if ball_cam:
		var w := clampf(car.pos.distance_to(ball.pos) / 55.0, 0.12, 0.38)
		look = look.lerp(ball.pos, w)
	_target = _target.lerp(look, 1.0 if immediate else 1.0 - exp(-9.0 * dt))

	# --- Shake --------------------------------------------------------------
	_shake_time += dt
	_shake_amount = maxf(0.0, _shake_amount - dt * 2.6)
	var s := _shake_amount * _shake_amount
	var shake := Vector3(
		sin(_shake_time * 47.3) * s * 0.55,
		sin(_shake_time * 39.1 + 1.7) * s * 0.50,
		sin(_shake_time * 53.7 + 3.1) * s * 0.40
	)

	# --- Pose ---------------------------------------------------------------
	var eye := _pos + shake
	global_position = eye
	if eye.distance_squared_to(_target) > 1e-6:
		look_at(_target, Vector3.UP)
		rotate_object_local(Vector3.RIGHT, Feel.CAM_ANGLE)

	# --- FOV ----------------------------------------------------------------
	var target_fov := Feel.CAM_FOV
	if car.is_boosting:
		target_fov += Feel.CAM_BOOST_FOV
	if car.supersonic:
		target_fov += Feel.CAM_SUPERSONIC_FOV
	_fov += (target_fov - _fov) * minf(1.0, dt * 6.0)
	if absf(fov - _fov) > 0.01:
		fov = _fov


## Used on kickoff, on "GO!", on a car reset and after a demolition respawn.
func snap(car: Car, ball: Ball) -> void:
	var d := Vector3(car.forward.x, 0.0, car.forward.z)
	if d.length_squared() < 1e-4:
		d = Vector3(0, 0, 1)
	d = d.normalized()
	_dir = d
	var ball_cam := mode == Mode.BALL
	_pos = car.pos - d * (Feel.CAM_BALL_DISTANCE if ball_cam else Feel.CAM_DISTANCE)
	_pos.y = car.pos.y + (Feel.CAM_BALL_HEIGHT if ball_cam else Feel.CAM_HEIGHT)
	_pos = _clamp_to_arena(_pos)
	_target = car.pos
	_shake_amount = 0.0
	update(car, ball, 1.0 / 60.0, true)


## Keeps the camera inside the playable shell, including the 45-degree corner
## cuts and the two goal pockets.
func _clamp_to_arena(p: Vector3) -> Vector3:
	var half_w := Feel.ARENA_HALF_WIDTH - 0.6
	var half_l := Feel.ARENA_HALF_LENGTH - 0.6
	var gw := Feel.GOAL_HALF_WIDTH - 0.8

	if absf(p.z) > half_l:
		var limit := half_l
		if absf(p.x) < gw:
			limit = Feel.ARENA_HALF_LENGTH + Feel.GOAL_DEPTH - 1.0
		p.z = clampf(p.z, -limit, limit)
	p.x = clampf(p.x, -half_w, half_w)
	if absf(p.z) < half_l:
		var max_sum := Feel.ARENA_CORNER_SUM - 0.9
		var total := absf(p.x) + absf(p.z)
		if total > max_sum:
			var excess := (total - max_sum) * 0.5
			p.x -= signf(p.x) * excess
			p.z -= signf(p.z) * excess
	p.y = clampf(p.y, Feel.CAM_MIN_HEIGHT_ABOVE_FLOOR, Feel.ARENA_CEILING - 0.8)
	return p
