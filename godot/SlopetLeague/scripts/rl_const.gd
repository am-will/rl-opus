class_name RL
extends RefCounted
## Rocket League physics constants, transcribed from RocketSim.
##
## Source: ZealanL/RocketSim `src/RLConst.h` and
## `src/Sim/Car/CarConfig/CarConfig.cpp`. Names are kept identical to the
## originals so this file can be diffed against them when RocketSim moves.
## Nothing here is tuned by feel -- if a value looks wrong, fix it against the
## source, not against how it drives.
##
## UNITS. RocketSim works in Unreal units, 1 uu = 1 cm, and Godot's physics is
## tuned for metres, which is also how the arena is built. So the raw constants
## below are in uu exactly as published, and every value the simulation
## actually consumes is exposed in metres alongside with an `_M` suffix.
## Anything without a suffix is uu and must be converted before it touches a
## Transform3D. Velocities and accelerations convert by the same 0.01.
##
## Angles, torques-per-mass and times are unit-agnostic and carry no suffix.

const S := 0.01                          ## uu -> metres

# --- world ------------------------------------------------------------------
const TICKRATE := 120                    ## RL and RocketSim both step at 120 Hz
const GRAVITY_Z := -650.0
const GRAVITY_Z_M := GRAVITY_Z * S

const ARENA_EXTENT_X := 4096.0
const ARENA_EXTENT_Y := 5120.0           ## does not include inner-goal
const ARENA_HEIGHT := 2048.0

const ARENA_COLLISION_BASE_FRICTION := 0.6
const ARENA_COLLISION_BASE_RESTITUTION := 0.3

# --- masses and pair-wise collision response --------------------------------
const CAR_MASS_BT := 180.0
const BALL_MASS_BT := CAR_MASS_BT / 6.0

const CAR_COLLISION_FRICTION := 0.3
const CAR_COLLISION_RESTITUTION := 0.1
const CARBALL_COLLISION_FRICTION := 2.0
const CARBALL_COLLISION_RESTITUTION := 0.0
const CARWORLD_COLLISION_FRICTION := 0.3
const CARWORLD_COLLISION_RESTITUTION := 0.3
const CARCAR_COLLISION_FRICTION := 0.09
const CARCAR_COLLISION_RESTITUTION := 0.1

# --- ball -------------------------------------------------------------------
const BALL_COLLISION_RADIUS_SOCCAR := 91.25
const BALL_COLLISION_RADIUS_SOCCAR_M := BALL_COLLISION_RADIUS_SOCCAR * S
## Greater than the radius because of the arena mesh's collision margin.
const BALL_REST_Z := 93.15
const BALL_REST_Z_M := BALL_REST_Z * S
const BALL_MAX_SPEED := 6000.0
const BALL_MAX_SPEED_M := BALL_MAX_SPEED * S
const BALL_MAX_ANG_SPEED := 6.0          ## rad/s, unit-agnostic
const BALL_DRAG := 0.03                  ## net-velocity drag multiplier
const BALL_FRICTION := 0.35
const BALL_RESTITUTION := 0.6

# --- car --------------------------------------------------------------------
const CAR_MAX_SPEED := 2300.0
const CAR_MAX_SPEED_M := CAR_MAX_SPEED * S
const CAR_MAX_ANG_SPEED := 5.5           ## rad/s
const SUPERSONIC_START_SPEED := 2200.0
const SUPERSONIC_MAINTAIN_MIN_SPEED := SUPERSONIC_START_SPEED - 100.0
const SUPERSONIC_MAINTAIN_MAX_TIME := 1.0

const THROTTLE_TORQUE_AMOUNT := CAR_MASS_BT * 400.0
const BRAKE_TORQUE_AMOUNT := CAR_MASS_BT * (14.25 + 1.0 / 3.0)
## Coasting below this forward velocity full-brakes instead.
const STOPPING_FORWARD_VEL := 25.0
const COASTING_BRAKE_FACTOR := 0.15
const BRAKING_NO_THROTTLE_SPEED_THRESH := 0.01
const THROTTLE_DEADZONE := 0.001
const THROTTLE_AIR_ACCEL := 200.0 / 3.0

const POWERSLIDE_RISE_RATE := 5.0
const POWERSLIDE_FALL_RATE := 2.0

const CAR_SPAWN_REST_Z := 17.0
const CAR_SPAWN_REST_Z_M := CAR_SPAWN_REST_Z * S
const CAR_RESPAWN_Z := 36.0

# --- boost ------------------------------------------------------------------
const BOOST_MAX := 100.0
const BOOST_USED_PER_SECOND := BOOST_MAX / 3.0
const BOOST_MIN_TIME := 0.1              ## minimum time a boost tap lasts
const BOOST_ACCEL_GROUND := 2975.0 / 3.0
const BOOST_ACCEL_AIR := 3175.0 / 3.0
const BOOST_SPAWN_AMOUNT := BOOST_MAX / 3.0
const BOOST_AMOUNT_BIG := 100.0
const BOOST_AMOUNT_SMALL := 12.0

# --- jump -------------------------------------------------------------------
const JUMP_ACCEL := 4375.0 / 3.0
const JUMP_IMMEDIATE_FORCE := 875.0 / 3.0
const JUMP_MIN_TIME := 0.025
const JUMP_MAX_TIME := 0.2
const JUMP_RESET_TIME_PAD := 1.0 / 40.0
const DOUBLEJUMP_MAX_DELAY := 1.25

# --- flip / dodge -----------------------------------------------------------
const FLIP_Z_DAMP_120 := 0.35
const FLIP_Z_DAMP_START := 0.15
const FLIP_Z_DAMP_END := 0.21
const FLIP_TORQUE_TIME := 0.65
const FLIP_TORQUE_MIN_TIME := 0.41
const FLIP_PITCHLOCK_TIME := 1.0
const FLIP_PITCHLOCK_EXTRA_TIME := 0.3
const FLIP_INITIAL_VEL_SCALE := 500.0
const FLIP_TORQUE_X := 260.0             ## left/right
const FLIP_TORQUE_Y := 224.0             ## forward/backward
const FLIP_FORWARD_IMPULSE_MAX_SPEED_SCALE := 1.0
const FLIP_SIDE_IMPULSE_MAX_SPEED_SCALE := 1.9
const FLIP_BACKWARD_IMPULSE_MAX_SPEED_SCALE := 2.5
const FLIP_BACKWARD_IMPULSE_SCALE_X := 16.0 / 15.0

# --- air control ------------------------------------------------------------
## Angle order is PYR -- pitch, yaw, roll -- not Godot's XYZ.
const CAR_AIR_CONTROL_TORQUE := Vector3(130.0, 95.0, 400.0)
const CAR_AIR_CONTROL_DAMPING := Vector3(30.0, 20.0, 50.0)
const CAR_TORQUE_SCALE := 2.0 * PI / 65536.0 * 1000.0

const CAR_AUTOFLIP_IMPULSE := 200.0
const CAR_AUTOFLIP_TORQUE := 50.0
const CAR_AUTOFLIP_TIME := 0.4
const CAR_AUTOFLIP_NORMZ_THRESH := 0.70710678  ## RocketSim: M_SQRT1_2
const CAR_AUTOFLIP_ROLL_THRESH := 2.8
const CAR_AUTOROLL_FORCE := 100.0
const CAR_AUTOROLL_TORQUE := 80.0

# --- car / ball extra impulse ----------------------------------------------
## RL adds an impulse on top of the rigid-body response so shots carry.
const BALL_CAR_EXTRA_IMPULSE_Z_SCALE := 0.35
const BALL_CAR_EXTRA_IMPULSE_FORWARD_SCALE := 0.65
const BALL_CAR_EXTRA_IMPULSE_MAXDELTAVEL_UU := 4600.0

const BUMP_COOLDOWN_TIME := 0.25
const BUMP_MIN_FORWARD_DIST := 64.5
const DEMO_RESPAWN_TIME := 3.0

# --- suspension (RLConst::BTVehicle) ----------------------------------------
## RL is built on Bullet, so these are btRaycastVehicle settings.
const SUSPENSION_FORCE_SCALE_FRONT := 36.0 - 0.25
const SUSPENSION_FORCE_SCALE_BACK := 54.0 + 0.25 + 0.015
const SUSPENSION_STIFFNESS := 500.0
const WHEELS_DAMPING_COMPRESSION := 25.0
const WHEELS_DAMPING_RELAXATION := 40.0
const MAX_SUSPENSION_TRAVEL := 12.0
const SUSPENSION_SUBTRACTION := 0.05

# --- Octane (CarConfig.cpp, index 0) ---------------------------------------
## RocketSim's comment on these is worth repeating: every hitbox table you will
## find online is wrong. Rocket League's own GetLocalCollisionExtent() returns
## values slightly larger than what the simulation uses. These are the ones
## that reproduce real RL's inertia matrix -- 120.507, not the 118.01 that
## every wiki quotes.
const OCTANE_HITBOX := Vector3(120.507, 86.6994, 38.6591)
const OCTANE_HITBOX_M := Vector3(
	120.507 * S, 86.6994 * S, 38.6591 * S)
## Offset of the hitbox centre from the car's origin, in RL's (fwd, lat, up).
const OCTANE_HITBOX_OFFSET := Vector3(13.8757, 0.0, 20.755)

const OCTANE_FRONT_WHEEL_RAD := 12.50
const OCTANE_BACK_WHEEL_RAD := 15.00
const OCTANE_FRONT_SUS_REST := 38.755
const OCTANE_BACK_SUS_REST := 37.055
## (forward, lateral, up) from the car's origin. Lateral is mirrored per side.
const OCTANE_FRONT_WHEEL_OFFSET := Vector3(51.25, 25.90, 20.755)
const OCTANE_BACK_WHEEL_OFFSET := Vector3(-33.75, 29.50, 20.755)

# --- curves -----------------------------------------------------------------
## RocketSim's LinearPieceCurve: piecewise-linear, clamped at both ends.
## Stored as flat [in, out, in, out, ...] because GDScript consts cannot hold
## arrays of arrays cheaply.

## Forward speed (uu/s) -> maximum steering angle (radians).
const STEER_ANGLE_FROM_SPEED_CURVE := [
	0.0, 0.53356,
	500.0, 0.31930,
	1000.0, 0.18203,
	1500.0, 0.10570,
	1750.0, 0.08507,
	3000.0, 0.03454,
]

## Forward speed (uu/s) -> extended steering angle while powersliding.
const POWERSLIDE_STEER_ANGLE_FROM_SPEED_CURVE := [
	0.0, 0.39235,
	2500.0, 0.12610,
]

## Forward speed (uu/s) -> drive torque factor. This is what makes 1410 uu/s
## the throttle-only top speed: the factor hits zero there.
const DRIVE_SPEED_TORQUE_FACTOR_CURVE := [
	0.0, 1.0,
	1400.0, 0.1,
	1410.0, 0.0,
]

const NON_STICKY_FRICTION_FACTOR_CURVE := [
	0.0, 0.1,
	0.7075, 0.5,
	1.0, 1.0,
]

const LAT_FRICTION_CURVE := [
	0.0, 1.0,
	1.0, 0.2,
]

const HANDBRAKE_LAT_FRICTION_FACTOR_CURVE := [
	0.0, 0.1,
]

const HANDBRAKE_LONG_FRICTION_FACTOR_CURVE := [
	0.0, 0.5,
	1.0, 0.9,
]

const BALL_CAR_EXTRA_IMPULSE_FACTOR_CURVE := [
	0.0, 0.65,
	500.0, 0.65,
	2300.0, 0.55,
]


## Evaluate one of the flat [in, out, ...] tables above.
##
## Matches RocketSim's LinearPieceCurve: clamped to the first value below the
## first key and to the last value above the last key, linear between.
static func curve(table: Array, x: float) -> float:
	var n := table.size()
	if n == 0:
		return 1.0
	var first: float = table[0]
	if x <= first:
		return table[1]
	var i := 2
	while i < n:
		var x1: float = table[i]
		if x <= x1:
			var x0: float = table[i - 2]
			var y0: float = table[i - 1]
			var y1: float = table[i + 1]
			var t: float = 0.0 if is_equal_approx(x1, x0) else (x - x0) / (x1 - x0)
			return y0 + (y1 - y0) * t
		i += 2
	return table[n - 1]
