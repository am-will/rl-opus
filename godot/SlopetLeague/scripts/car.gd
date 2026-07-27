class_name Car
extends RigidBody3D
## The car. A line-by-line port of src/physics/Car.ts, which is the build the
## user has played and signed off on.
##
## Deliberately NOT a VehicleBody3D. RL — and the TypeScript build — model the
## car as a plain rigid box with four suspension raycasts and velocities driven
## by hand. VehicleBody3D is a different and worse model.
##
## Forward is local +Z. In a right-handed frame that puts the driver's right at
## local -X (looking down +Z, +X is on your left), so every steer / yaw / roll /
## dodge sign below is derived from that.
##
## `tick()` is called by Game once per physics step, BEFORE the solver runs.

const TEAM_BLUE := Feel.TEAM_BLUE
const TEAM_ORANGE := Feel.TEAM_ORANGE

@export var team: int = TEAM_BLUE

## The forward-component term of the Psyonix impulse (see try_hit_ball). The TS
## build omits it; the trace harness sets this to 0 to compare like for like.
var hit_forward_squash := Feel.HIT_FORWARD_SQUASH

var input := CarInput.new()

# Cached transform, refreshed by sync() -------------------------------------
var pos := Vector3.ZERO
var vel := Vector3.ZERO
var basis_cache := Basis.IDENTITY
var forward := Vector3(0, 0, 1)
var right := Vector3(1, 0, 0)
var up := Vector3(0, 1, 0)

# Ground state ---------------------------------------------------------------
var grounded := false
var wheels_down := 0
var ground_normal := Vector3(0, 1, 0)
var _time_since_grounded := 999.0
## Per wheel: {local_y, grounded, compression, spin}. Drives the visual squat.
var wheels: Array[Dictionary] = []

# Jump / flip ----------------------------------------------------------------
var _has_jumped := false
var _has_second_jump := false
var _jump_held_time := 0.0
var _jump_hold_active := false
var _air_timer := 0.0
var _prev_jump := false
## The jump impulse alone doesn't lift the wheels out of suspension range in a
## single step, so without this the very next step re-reports "grounded" and
## clears the double jump. Blind the rays briefly after take-off.
var _jump_lockout := 0.0
var flipping := false
var _flip_timer := 0.0
var _flip_axis := Vector3.ZERO
var _flip_cooldown := 0.0
var _unstick_cooldown := 0.0

# Boost ----------------------------------------------------------------------
var boost := Feel.BOOST_START
var infinite_boost := false
var is_boosting := false
var _boost_tap_remaining := 0.0

## Parked out of play — demolished, or a bot benched in practice mode.
var active := true
## True only while waiting to respawn from a demolition (not when benched).
var wrecked := false
var demo_timer := 0.0

# Feedback out ---------------------------------------------------------------
var supersonic := false
var _ball_hit_cooldown := 0.0
## Set on the frame the car strikes the ball. {point: Vector3, strength: float}
var ball_hit_event: Dictionary = {}
var landed_hard := 0.0
## One-frame flags for audio / VFX.
var just_jumped := false
var just_flipped := false

## Visual steering lock, in radians. Purely cosmetic — the physics steers by
## curvature, not by a wheel angle.
const STEER_LOCK := 0.52
## Where the wheel centre sits with the suspension at rest, in car-local space.
const WHEEL_REST_LOCAL_Y := 0.02 - (Feel.WHEEL_REST_LEN - Feel.WHEEL_RADIUS)

var _wheel_pivots: Array[Node3D] = [null, null, null, null]
var _wheel_rest: Array[Vector3] = [
	Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO
]
var _steer_visual := 0.0
var fx: CarFx = null

var _space: PhysicsDirectSpaceState3D = null
var _ray := PhysicsRayQueryParameters3D.new()
## Diagonal of the inverse inertia tensor in the body frame. Godot computes the
## same numbers from the BoxShape3D; we hold our own copy because the suspension
## has to integrate its impulses by hand — see _update_suspension.
var _inv_inertia := Vector3.ONE


func _ready() -> void:
	mass = Feel.CAR_MASS
	can_sleep = false
	continuous_cd = true
	custom_integrator = false
	gravity_scale = 1.0
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3.ZERO

	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	linear_damp = 0.0
	angular_damp = 0.04

	# Tyre forces are simulated by hand below, so the shell itself is slippery.
	# See the surface-response block in rl_feel.gd for why these are not simply
	# config.ts's numbers.
	var mat := PhysicsMaterial.new()
	mat.friction = Feel.CAR_FRICTION_GODOT
	mat.bounce = Feel.CAR_BOUNCE_GODOT
	mat.absorbent = false
	physics_material_override = mat

	collision_layer = Layers.CAR
	collision_mask = Layers.ARENA | Layers.BALL | Layers.CAR

	# Not (only) for the contact list: Jolt turns OFF manifold reduction for a
	# body that reports contacts, and manifold reduction is what breaks wall
	# driving. Entering the floor->wall fillet at 20 m/s, the reduced manifold
	# collapsed contacts from several ramp facets into one bad normal and threw
	# the car back down the pitch at -3.9 m/s — a clean e=0.2 bounce off a
	# surface that isn't there. With reporting on, the car rides up the fillet
	# and reaches the ceiling, matching the TS build's wall_ride trace.
	contact_monitor = true
	max_contacts_reported = 6

	_ray.collision_mask = Layers.ARENA
	_ray.collide_with_areas = false
	_ray.collide_with_bodies = true
	_ray.hit_back_faces = false
	_ray.hit_from_inside = false

	# Solid box, principal axes aligned with the body frame.
	var s := Feel.CAR_HALF * 2.0
	var k := Feel.CAR_MASS / 12.0
	_inv_inertia = Vector3(
		1.0 / (k * (s.y * s.y + s.z * s.z)),
		1.0 / (k * (s.x * s.x + s.z * s.z)),
		1.0 / (k * (s.x * s.x + s.y * s.y))
	)

	_fit_model()

	wheels.clear()
	for i in Feel.WHEEL_OFFSETS.size():
		wheels.append({
			"local_y": -0.03,
			"grounded": false,
			"compression": 0.0,
			"spin": 0.0,
		})
	_build_wheel_pivots()

	fx = CarFx.new()
	fx.name = "Fx"
	add_child(fx)
	fx.setup(self)

	sync()


## Visual-only, once per rendered frame. Nothing here touches physics state.
func _process(dt: float) -> void:
	_steer_visual = lerpf(_steer_visual, input.steer, clampf(dt * 14.0, 0.0, 1.0))
	_update_wheels()


# ---------------------------------------------------------------------------
# Visual model
# ---------------------------------------------------------------------------

## Scale and orient the Octane mesh from its own wheel positions.
##
## Not a hard-coded transform, because the exported glTF carries a scale and a
## rotation on `Octane_Root` that nothing else in the repo agrees on — measuring
## the mesh AABBs suggests raw Blender units, measuring the rendered result says
## 0.337. Reading it off the tyres removes the argument: whatever the exporter
## did, the wheelbase ends up at the suspension's wheelbase and the tyres end up
## exactly where the four rays put them, so the car cannot look like it is
## hovering or sunk.
##
## The car is deliberately a 1.32x Octane: config.ts's BODY_STRETCH of 1.35 sets
## the hitbox at 1.593 m long against a stock 1.205, and the model follows it
## UNIFORMLY rather than being stretched along one axis, which would leave round
## wheels on a long body.
func _fit_model() -> void:
	var model := get_node_or_null("Model") as Node3D
	if model == null:
		return
	model.transform = Transform3D.IDENTITY

	var fl := _tire(model, "Front_Left")
	var fr := _tire(model, "Front_Right")
	var rl := _tire(model, "Rear_Left")
	var rr := _tire(model, "Rear_Right")
	if fl == null or fr == null or rl == null or rr == null:
		push_warning("car: Octane tyre meshes not found; model left unscaled")
		return

	# Positions in the model's own space, with our transform taken out.
	var inv := model.global_transform.affine_inverse()
	var p_fl := inv * fl.global_position
	var p_fr := inv * fr.global_position
	var p_rl := inv * rl.global_position
	var p_rr := inv * rr.global_position

	var front := (p_fl + p_fr) * 0.5
	var rear := (p_rl + p_rr) * 0.5
	var fwd := front - rear
	var wheelbase := fwd.length()
	if wheelbase < 1e-4:
		return
	fwd /= wheelbase

	var lateral := (p_fl - p_fr).normalized()
	var up_v := lateral.cross(fwd).normalized()
	# The body sits above the wheels; use that to settle the sign.
	var body := model.find_child("*Body_0*", true, false) as Node3D
	if body:
		if up_v.dot(inv * body.global_position - front) < 0.0:
			up_v = -up_v
	# Re-orthogonalise in case the four tyres aren't perfectly coplanar.
	var side := up_v.cross(fwd).normalized()
	up_v = fwd.cross(side).normalized()

	# The suspension's wheelbase, so the tyres land on the rays.
	var target: float = absf(Feel.WHEEL_OFFSETS[0].z - Feel.WHEEL_OFFSETS[2].z)
	var s := target / wheelbase

	# M maps model-local axes to (side, up, fwd); its inverse turns the model to
	# face +Z with +Y up, which is the convention the physics uses.
	var m := Basis(side, up_v, fwd)
	var rot := m.transposed()
	var pivot := (front + rear) * 0.5
	# Wheel centres sit at the suspension's rest height, so the car rides on its
	# tyres rather than through them.
	var rest_y: float = Feel.WHEEL_OFFSETS[0].y - (Feel.WHEEL_REST_LEN - Feel.WHEEL_RADIUS)
	model.transform = Transform3D(
		rot.scaled(Vector3(s, s, s)),
		Vector3(0.0, rest_y, 0.0) - (rot * pivot) * s
	)


func _tire(model: Node3D, corner: String) -> Node3D:
	return model.find_child("*%s_Tire*" % corner, true, false) as Node3D


## Gather each corner's six meshes (tyre, rim, axle, disc, caliper, hub) under a
## pivot at the axle centre, so suspension travel, steering and wheel spin cost
## one transform each instead of twenty-four.
##
## The pivots hang off the CAR, not off the model, so their transforms are in
## the same space the suspension reports travel in and the spin axis is just
## local X. Reparenting preserves each mesh's world transform, which bakes the
## model's scale into the child and keeps the pivot itself unscaled.
func _build_wheel_pivots() -> void:
	var model := get_node_or_null("Model") as Node3D
	if model == null:
		return
	# Local +X is the driver's LEFT (forward is local +Z), so Feel.WHEEL_OFFSETS
	# reads front-left, front-right, rear-left, rear-right.
	var corners := ["Front_Left", "Front_Right", "Rear_Left", "Rear_Right"]
	for i in 4:
		var tire := _tire(model, corners[i])
		if tire == null:
			push_warning("car: %s tyre not found; wheels will not animate" % corners[i])
			return
		var centre := to_local(tire.global_position)
		# Match the corner to the suspension slot by sign rather than by name, so
		# a mirrored export still drives the right wheel.
		var slot := (0 if centre.z > 0.0 else 2) + (0 if centre.x > 0.0 else 1)

		var pivot := Node3D.new()
		pivot.name = "Wheel_%s" % corners[i]
		add_child(pivot)
		pivot.position = centre
		_wheel_rest[slot] = centre
		_wheel_pivots[slot] = pivot

		var group := tire.get_parent()
		for n in group.get_children():
			if not (n is Node3D):
				continue
			if not String(n.name).contains(corners[i]):
				continue
			var t := (n as Node3D).global_transform
			group.remove_child(n)
			pivot.add_child(n)
			(n as Node3D).global_transform = t


## Suspension travel, steering lock and wheel spin. Visual only.
func _update_wheels() -> void:
	for i in 4:
		var pivot: Node3D = _wheel_pivots[i]
		if pivot == null:
			continue
		var travel: float = float(wheels[i]["local_y"]) - WHEEL_REST_LOCAL_Y
		var b := Basis()
		if i < 2:  # front axle steers
			b = Basis(Vector3(0, 1, 0), -_steer_visual * STEER_LOCK)
		# Rolling forward puts the top of the wheel forward. Solving
		# v_cm + w x r_contact = 0 for forward = +Z gives w = +X * (v/R), and
		# Basis(+X, t) sends (0, r, 0) to (0, r cos t, r sin t) — so POSITIVE.
		b = b * Basis(Vector3(1, 0, 0), float(wheels[i]["spin"]))
		pivot.transform = Transform3D(b, _wheel_rest[i] + Vector3(0.0, travel, 0.0))


# ---------------------------------------------------------------------------
# State cache
# ---------------------------------------------------------------------------

func sync() -> void:
	var t := global_transform
	pos = t.origin
	basis_cache = t.basis
	vel = linear_velocity
	right = -basis_cache.x
	up = basis_cache.y
	forward = basis_cache.z


func _sync_velocity() -> void:
	vel = linear_velocity


var speed: float:
	get: return vel.length()

var forward_speed: float:
	get: return vel.dot(forward)


## Takes the car out of the simulation entirely: no collisions with the ball,
## the arena or the other car, and parked well below the pitch.
func set_active(a: bool) -> void:
	if active == a:
		return
	active = a
	collision_layer = Layers.CAR if a else 0
	collision_mask = (Layers.ARENA | Layers.BALL | Layers.CAR) if a else 0
	if not a:
		_teleport(Transform3D(global_transform.basis, Vector3(0.0, -80.0, 0.0)))
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO
		is_boosting = false
		supersonic = false
		sync()
	# The TS build lets a parked car keep falling; here that runs it into Jolt's
	# 500 m/s ceiling within seconds and shows up in every soak report. Freezing
	# is unobservable in play and keeps the numbers honest.
	freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	freeze = not a


# ---------------------------------------------------------------------------
# One physics step
# ---------------------------------------------------------------------------

func tick(dt: float) -> void:
	if not active:
		if demo_timer > 0.0:
			demo_timer = maxf(0.0, demo_timer - dt)
		return

	_space = get_world_3d().direct_space_state
	sync()
	ball_hit_event = {}
	just_jumped = false
	just_flipped = false
	_ball_hit_cooldown = maxf(0.0, _ball_hit_cooldown - dt)
	_flip_cooldown = maxf(0.0, _flip_cooldown - dt)
	_jump_lockout = maxf(0.0, _jump_lockout - dt)
	_unstick_cooldown = maxf(0.0, _unstick_cooldown - dt)
	landed_hard *= maxf(0.0, 1.0 - dt * 8.0)

	var was_grounded := grounded
	var prev_vertical_speed := vel.dot(up)

	_update_suspension(dt)
	# Suspension impulses land immediately, so refresh the cache before the
	# drive step writes velocity back.
	_sync_velocity()

	if grounded:
		if not was_grounded and prev_vertical_speed < -6.0:
			landed_hard = minf(1.0, -prev_vertical_speed / 18.0)
		_time_since_grounded = 0.0
		_air_timer = 0.0
		if not flipping:
			_has_jumped = false
			_has_second_jump = false
	else:
		_time_since_grounded += dt
		_air_timer += dt

	if grounded and not flipping:
		_drive_ground(dt)
	elif not grounded:
		_air_control(dt)

	_update_jump(dt)
	_update_flip(dt)
	_update_boost(dt)
	_clamp_speed()

	supersonic = vel.length() >= Feel.CAR_SUPERSONIC
	_prev_jump = input.jump


# ---------------------------------------------------------------------------
# Suspension: four rays, spring force applied at each contact point so the
# chassis squats, dives and leans on its own.
# ---------------------------------------------------------------------------

func _update_suspension(dt: float) -> void:
	var locked := _jump_lockout > 0.0
	var down := 0
	var normal_sum := Vector3.ZERO
	# Jolt QUEUES RigidBody3D.apply_impulse until the solver runs, and a later
	# `linear_velocity = ...` assignment throws the queue away — which is exactly
	# what the drive step does two calls further down. Rapier's equivalent lands
	# on the velocity immediately, so we integrate the impulses ourselves and
	# keep the semantics the TypeScript build was tuned against.
	# (tests/probe_impulse.gd is the experiment that establishes this.)
	var lin_impulse := Vector3.ZERO
	var ang_impulse := Vector3.ZERO

	# Both of these are snapshots taken before the loop: the TS build reads them
	# once and lets all four wheels see the same pre-suspension state, even
	# though the impulses land immediately.
	var av0 := angular_velocity
	var v0 := vel
	var fwd_speed := v0.dot(forward)

	for i in Feel.WHEEL_OFFSETS.size():
		var off: Vector3 = Feel.WHEEL_OFFSETS[i]
		var o := basis_cache * off + pos
		var state: Dictionary = wheels[i]

		var hit: Dictionary = {}
		if not locked:
			hit = _cast_arena_ray(o, -up, Feel.WHEEL_MAX_LEN)

		if hit.is_empty():
			state["grounded"] = false
			state["compression"] = 0.0
			# Spring extends back out over ~0.15 s so wheels don't snap.
			state["local_y"] = lerpf(
				state["local_y"],
				off.y - (Feel.WHEEL_MAX_LEN - Feel.WHEEL_RADIUS),
				minf(1.0, dt * 12.0)
			)
			continue

		var toi: float = hit["toi"]
		down += 1
		state["grounded"] = true
		var compression: float = Feel.WHEEL_MAX_LEN - toi
		state["compression"] = minf(
			1.0, compression / (Feel.WHEEL_MAX_LEN - Feel.WHEEL_RADIUS * 0.5)
		)
		state["local_y"] = off.y - (toi - Feel.WHEEL_RADIUS)

		var n: Vector3 = hit["normal"]
		normal_sum += n

		# Velocity of this specific point on the chassis: v + omega x r
		var r := o - pos
		var point_vel := av0.cross(r) + v0
		var along_spring := -point_vel.dot(up)

		var force := Feel.WHEEL_STIFFNESS * compression + Feel.WHEEL_DAMPING * along_spring
		if force < 0.0:
			force = 0.0

		# Push along the surface normal rather than the car's up, so wall driving works.
		var impulse := n * (force * dt)
		lin_impulse += impulse
		ang_impulse += r.cross(impulse)

		# Wrapped: this is only ever a visual angle, and left to run it reaches
		# six figures in a long session and starts losing precision.
		state["spin"] = fmod(
			float(state["spin"]) + (fwd_speed / Feel.WHEEL_RADIUS) * dt, TAU
		)

	if lin_impulse != Vector3.ZERO or ang_impulse != Vector3.ZERO:
		linear_velocity += lin_impulse / Feel.CAR_MASS
		angular_velocity += _world_inv_inertia(ang_impulse)

	wheels_down = down
	# Two wheels is enough to count as driving — lets you ride the wall seam.
	grounded = down >= 2
	if down > 0:
		ground_normal = normal_sum.normalized()
	else:
		ground_normal = Vector3(0, 1, 0)


# ---------------------------------------------------------------------------
# Ground driving
# ---------------------------------------------------------------------------

func _drive_ground(dt: float) -> void:
	var n := ground_normal

	# Ground-plane basis.
	var fwd := forward - n * forward.dot(n)
	if fwd.length_squared() < 1e-6:
		return
	fwd = fwd.normalized()
	var rt := fwd.cross(n).normalized()

	var v := vel
	var fwd_speed := v.dot(fwd)
	var abs_fwd := absf(fwd_speed)

	# --- Throttle / brake / coast -------------------------------------------
	var accel := 0.0
	if absf(input.throttle) > 0.02:
		var opposing := fwd_speed * input.throttle < -0.01
		if opposing and abs_fwd > 0.2:
			accel = Feel.CAR_BRAKE_ACCEL * signf(input.throttle)
		else:
			var reverse_cap := Feel.CAR_MAX_DRIVE_SPEED * 0.5
			if input.throttle < 0.0 and fwd_speed < -reverse_cap:
				accel = 0.0
			else:
				accel = Feel.curve(Feel.THROTTLE_CURVE, abs_fwd) * input.throttle
	elif abs_fwd > 0.05:
		# Engine braking when you let go of the stick.
		accel = -signf(fwd_speed) * minf(Feel.CAR_COAST_ACCEL, abs_fwd / dt)
	if accel != 0.0:
		v += fwd * (accel * dt)

	# --- Steering: RL models this as curvature, not torque -------------------
	# yaw rate = curvature(speed) * signed forward speed * steer
	var kappa := Feel.curve(Feel.STEER_CURVE, minf(v.length(), Feel.CAR_MAX_SPEED))
	# Negative because a right turn is a negative rotation about world up.
	# Steering also inverts in reverse, since the rate uses *signed* speed.
	var target_yaw := -kappa * fwd_speed * input.steer
	var av := angular_velocity
	var cur_yaw := av.dot(n)
	var blend := 1.0 - exp(-Feel.CAR_STEER_RESPONSE * dt)
	var new_yaw := cur_yaw + (target_yaw - cur_yaw) * blend

	# --- Chassis alignment: snap flat to the surface, damped ----------------
	var axis := up.cross(n)
	var perp := av - n * cur_yaw
	perp *= exp(-Feel.CAR_GROUND_ALIGN_DAMP * dt)
	perp += axis * (Feel.CAR_GROUND_ALIGN * dt)
	angular_velocity = perp + n * new_yaw

	# --- Tyre grip ----------------------------------------------------------
	var grip_accel := Feel.CAR_DRIFT_GRIP_ACCEL if input.drift else Feel.CAR_GRIP_ACCEL
	var lateral := v.dot(rt)
	var max_dv := grip_accel * dt
	v += rt * clampf(-lateral, -max_dv, max_dv)

	if input.drift:
		v += fwd * (-fwd_speed * Feel.CAR_DRIFT_DRAG * dt * 0.15)

	# --- Sticky force: what lets you drive walls and the ceiling -------------
	v += n * (-Feel.CAR_STICKY_ACCEL * dt)

	vel = v
	linear_velocity = v


# ---------------------------------------------------------------------------
# Air control — RL's published torque/damping coefficients, applied in the car's
# local frame. Roll is fast, pitch is heavy, yaw is in between.
# ---------------------------------------------------------------------------

func _air_control(dt: float) -> void:
	if flipping:
		return

	# Holding the air-roll modifier turns steering into roll (RL's directional
	# air roll).
	var roll_input := clampf(input.roll + (input.steer if input.drift else 0.0), -1.0, 1.0)
	var yaw_input := 0.0 if input.drift else input.steer
	# Pitch is its own axis, not the throttle — holding accelerate through an
	# aerial must not drop the nose.
	var pitch_input := input.pitch

	var local_av := basis_cache.transposed() * angular_velocity

	# Damping fades out while you hold an input, so held inputs keep accelerating.
	# +X pitches the nose down, -Y yaws right, +Z rolls right (see sync()).
	var ax := Feel.AIR_TORQUE_PITCH * pitch_input \
		- Feel.AIR_DAMP_PITCH * local_av.x * (1.0 - absf(pitch_input))
	var ay := -Feel.AIR_TORQUE_YAW * yaw_input \
		- Feel.AIR_DAMP_YAW * local_av.y * (1.0 - absf(yaw_input))
	var az := Feel.AIR_TORQUE_ROLL * roll_input - Feel.AIR_DAMP_ROLL * local_av.z

	local_av.x += ax * dt
	local_av.y += ay * dt
	local_av.z += az * dt

	var mag := local_av.length()
	if mag > Feel.AIR_MAX_ANGULAR:
		local_av *= Feel.AIR_MAX_ANGULAR / mag

	angular_velocity = basis_cache * local_av


# ---------------------------------------------------------------------------
# Jump, double jump, flip
# ---------------------------------------------------------------------------

func _update_jump(dt: float) -> void:
	var pressed := input.jump and not _prev_jump
	var v := vel

	# Upside down or on your side: jump just hops you clear of the surface.
	# Deliberately no auto-righting — the player rotates with air roll (Q/E or
	# Ctrl+steer) and pitch. Scripted correction fought the player's input.
	if pressed and not flipping and up.y < 0.4 and _unstick_cooldown <= 0.0 and _near_surface():
		v.y += Feel.UNSTICK_HOP
		vel = v
		linear_velocity = v
		_unstick_cooldown = Feel.UNSTICK_COOLDOWN
		_jump_lockout = 0.14
		just_jumped = true
		_prev_jump = true
		return

	# Coyote time: a jump pressed just after leaving a ledge still counts.
	var can_ground_jump := grounded \
		or (_time_since_grounded < Feel.CAR_COYOTE_TIME and not _has_jumped)

	if pressed and can_ground_jump and not flipping and _flip_cooldown <= 0.0:
		v += up * Feel.JUMP_IMPULSE
		_has_jumped = true
		_has_second_jump = true
		_jump_held_time = 0.0
		_jump_hold_active = true
		_air_timer = 0.0
		grounded = false
		_jump_lockout = 0.13
		just_jumped = true
		vel = v
		linear_velocity = v
		return

	# Holding jump keeps pushing for up to 0.2 s — this is the difference
	# between a tap-hop and a full jump in RL.
	if _jump_hold_active:
		if input.jump and _jump_held_time < Feel.JUMP_MAX_HOLD:
			_jump_held_time += dt
			v += up * (Feel.JUMP_HOLD_ACCEL * dt)
			vel = v
			linear_velocity = v
		else:
			_jump_hold_active = false

	if pressed and not grounded and _has_second_jump and not flipping \
			and _air_timer < Feel.JUMP_WINDOW:
		_has_second_jump = false
		var dir_x := input.steer
		# Dodges follow the same axis as pitch, the way the stick does in RL.
		var dir_z := input.pitch
		var mag := sqrt(dir_x * dir_x + dir_z * dir_z)
		if mag > Feel.JUMP_DEADZONE:
			_start_flip(dir_x / mag, dir_z / mag)
		else:
			v += up * Feel.JUMP_DOUBLE_IMPULSE
			just_jumped = true
			vel = v
			linear_velocity = v


func _start_flip(dx: float, dz: float) -> void:
	flipping = true
	_flip_timer = 0.0
	just_flipped = true

	# Dodge impulse is horizontal in world space — that's why you can't dodge upward.
	var flat_f := Vector3(forward.x, 0.0, forward.z)
	if flat_f.length_squared() < 1e-5:
		flat_f = Vector3(up.x, 0.0, up.z)
	flat_f = flat_f.normalized()
	var flat_r := Vector3(-flat_f.z, 0.0, flat_f.x)

	var dir := (flat_f * dz + flat_r * dx).normalized()

	var impulse := Feel.FLIP_IMPULSE
	# Forward flips convert speed into more speed — the RL speed-flip.
	if dz > 0.3:
		impulse += maxf(0.0, vel.dot(forward)) * Feel.FLIP_FORWARD_SPEED_GAIN

	var v := vel
	v += dir * impulse
	# Kill downward velocity slightly so flips feel like they carry.
	if v.y < 0.0:
		v.y *= 0.75
	vel = v
	linear_velocity = v

	# Rotation axis in car-local space: forward dodge -> pitch, side dodge -> roll.
	_flip_axis = Vector3(dz, 0.0, dx).normalized()


func _update_flip(dt: float) -> void:
	if not flipping:
		return
	_flip_timer += dt

	# Drive the rotation at exactly one revolution per spinTime, then stop dead.
	# Leaving the angular velocity in place is what made dodges tumble.
	if _flip_timer < Feel.FLIP_SPIN_TIME and not grounded:
		var rate := TAU / Feel.FLIP_SPIN_TIME
		angular_velocity = basis_cache * (_flip_axis * rate)
		return

	angular_velocity = Vector3.ZERO
	flipping = false
	_flip_cooldown = Feel.FLIP_COOLDOWN
	# Jump flags stay spent until we actually touch down — no free third jump.


func _near_surface() -> bool:
	return not _cast_arena_ray(pos, Vector3(0, -1, 0), 1.8).is_empty()


# ---------------------------------------------------------------------------

func _update_boost(dt: float) -> void:
	var want := input.boost
	if want and _boost_tap_remaining <= 0.0 and (boost > 0.0 or infinite_boost):
		_boost_tap_remaining = Feel.BOOST_MIN_TAP

	var can_boost := infinite_boost or boost > 0.0 or _boost_tap_remaining > 0.0
	is_boosting = want and can_boost

	if is_boosting:
		var v := vel
		v += forward * (Feel.BOOST_ACCEL * dt)
		vel = v
		linear_velocity = v
		if not infinite_boost:
			boost = maxf(0.0, boost - Feel.BOOST_DRAIN_PER_SEC * dt)
			_boost_tap_remaining = maxf(0.0, _boost_tap_remaining - dt)
	else:
		_boost_tap_remaining = 0.0


func _clamp_speed() -> void:
	var s := vel.length()
	if s > Feel.CAR_MAX_SPEED:
		vel *= Feel.CAR_MAX_SPEED / s
		linear_velocity = vel


# ---------------------------------------------------------------------------
# The "Psyonix impulse". On top of the normal rigid-body bounce, RL adds a kick
# along the car->ball axis with the vertical component squashed and part of the
# forward component removed. It is the single biggest reason RL hits feel
# powerful and aimable rather than like two objects clattering off each other.
#
# https://www.smish.dev/rocket_league/ball_simulation_3/
# ---------------------------------------------------------------------------

func try_hit_ball(ball: Ball) -> void:
	if _ball_hit_cooldown > 0.0 or not active:
		return

	var d := ball.pos - pos
	var lx := clampf(d.dot(right), -Feel.CAR_HALF.x, Feel.CAR_HALF.x)
	var ly := clampf(d.dot(up), -Feel.CAR_HALF.y, Feel.CAR_HALF.y)
	var lz := clampf(d.dot(forward), -Feel.CAR_HALF.z, Feel.CAR_HALF.z)

	var closest := pos + right * lx + up * ly + forward * lz

	if ball.pos.distance_to(closest) > Feel.BALL_RADIUS:
		return

	var bv := ball.linear_velocity
	var closing := (bv - vel).length()
	if closing < Feel.HIT_MIN_CLOSING_SPEED:
		return

	var dir := ball.pos - pos
	# RL is Z-up; in Godot that axis is .y. Squash it so low hits drive the ball
	# forward instead of scooping under it.
	dir.y *= Feel.HIT_VERTICAL_SQUASH
	# Remove 35% of the component along the car's nose. This is the term the TS
	# build is missing; it biases the impulse toward where you were POINTING
	# rather than merely where you stood relative to the ball.
	dir -= forward * (hit_forward_squash * dir.dot(forward))
	if dir.length_squared() < 1e-6:
		return
	dir = dir.normalized()

	var scale := Feel.curve(Feel.HIT_SCALE_CURVE, closing)
	var dv := minf(closing * scale, Feel.HIT_MAX_DELTA_V)

	ball.linear_velocity = bv + dir * dv

	_ball_hit_cooldown = Feel.HIT_COOLDOWN
	var strength := clampf(dv / 18.0, 0.0, 1.0)
	ball.last_hit_strength = maxf(ball.last_hit_strength, strength)
	ball_hit_event = {"point": closest, "strength": strength}


# ---------------------------------------------------------------------------

## Angular impulse -> change in world angular velocity, for a body whose inertia
## tensor is diagonal in its own frame.
func _world_inv_inertia(ang_impulse: Vector3) -> Vector3:
	return basis_cache * ((basis_cache.transposed() * ang_impulse) * _inv_inertia)


## Ray against arena geometry only. Returns {} or {toi, normal, position}.
func _cast_arena_ray(origin: Vector3, dir: Vector3, max_toi: float) -> Dictionary:
	_ray.from = origin
	_ray.to = origin + dir * max_toi
	var hit := _space.intersect_ray(_ray)
	if hit.is_empty():
		return {}
	var p: Vector3 = hit["position"]
	return {
		"toi": origin.distance_to(p),
		"normal": hit["normal"] as Vector3,
		"position": p,
	}


func _teleport(t: Transform3D) -> void:
	PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, t)
	global_transform = t


func respawn(x: float, z: float, yaw: float, new_boost := Feel.RESPAWN_BOOST) -> void:
	# set_active handles the freeze; going through it is what stops a demolished
	# car respawning frozen and immovable.
	set_active(true)
	demo_timer = 0.0
	wrecked = false
	_teleport(Transform3D(Basis(Vector3(0, 1, 0), yaw), Vector3(x, 0.21, z)))
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	boost = new_boost
	is_boosting = false
	supersonic = false
	_has_jumped = false
	_has_second_jump = false
	flipping = false
	_jump_hold_active = false
	_flip_cooldown = 0.0
	_unstick_cooldown = 0.0
	_jump_lockout = 0.0
	_ball_hit_cooldown = 0.0
	_time_since_grounded = 999.0
	_air_timer = 0.0
	landed_hard = 0.0
	sync()
