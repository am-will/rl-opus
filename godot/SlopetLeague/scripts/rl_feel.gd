class_name Feel
extends Object
## Tuning constants — a transcription of `src/config.ts` from the TypeScript
## build, which is the specification for how this game feels.
##
## Rocket League works in "unreal units" (uu) where 1 uu = 1 cm. We simulate in
## metres, so every length / speed / acceleration below is the published RL
## value divided by 100. Values marked (RL) are the real game's numbers; the
## rest are hand-tuned to make the arcade feel land.
##
## This file is deliberately SEPARATE from `rl_const.gd`, which transcribes
## RocketSim and is physically exact. Where the two disagree, this one wins:
## it is the version a human has played and signed off on. See
## docs/PHYSICS_PARITY_HANDOFF.md section 6.

## uu -> metres
const UU := 0.01
## curvature is 1/uu -> 1/m
const UU_INV := 100.0

# ---------------------------------------------------------------------------
# World
# ---------------------------------------------------------------------------

## (RL) 650 uu/s^2 -> 6.5 m/s^2. Deliberately sub-earth: this is what makes
## aerials work.
const GRAVITY := 650.0 * UU
const FIXED_DT := 1.0 / 120.0
const MAX_SUBSTEPS := 5

# ---------------------------------------------------------------------------
# Arena (RL "Soccar" / DFH Stadium footprint)
# ---------------------------------------------------------------------------

const ARENA_HALF_WIDTH := 4096.0 * UU   # 40.96 m, x
const ARENA_HALF_LENGTH := 5120.0 * UU  # 51.20 m, z (goal to goal)
const ARENA_CEILING := 2044.0 * UU      # 20.44 m
## Corners are cut at 45 degrees on the plane |x| + |z| = 8064 uu.
const ARENA_CORNER_SUM := 8064.0 * UU
## Radius of the curved floor->wall transition that lets you drive up walls.
const ARENA_RAMP_RADIUS := 256.0 * UU
## Matching wall->ceiling curve, so you can carry a wall ride onto the roof.
const ARENA_CEIL_RADIUS := 256.0 * UU

const GOAL_HALF_WIDTH := 892.755 * UU
const GOAL_HEIGHT := 642.775 * UU
const GOAL_DEPTH := 880.0 * UU

# ---------------------------------------------------------------------------
# Ball
# ---------------------------------------------------------------------------

const BALL_RADIUS := 91.25 * UU  # (RL)
## (RL) exactly 1/6 of the car — light enough to move, heavy enough to feel weighty.
const BALL_MASS := 30.0
const BALL_RESTITUTION := 0.6  # (RL)
const BALL_FRICTION := 0.35  # (RL)
const BALL_MAX_SPEED := 6000.0 * UU  # (RL)
const BALL_MAX_ANGULAR := 6.0  # (RL) rad/s
const BALL_DRAG := 0.0305  # (RL) v -= drag * v * dt
## Rolling resistance applied only while the ball is on the floor, so it settles
## instead of drifting forever. Not an RL value.
const BALL_GROUND_ROLL := 0.4

# The "Psyonix impulse": on top of the normal rigid-body collision, RL adds an
# extra impulse pushing the ball along the car->ball axis. This is the single
# most important thing about how RL feels — it's why you can aim shots by where
# on your car you strike the ball, and why hits punch instead of glancing off.

## Vertical component of the car->ball axis is squashed, so low hits drive the
## ball forward instead of scooping under it.
const HIT_VERTICAL_SQUASH := 0.35
## The published model also removes 35% of the FORWARD component, which is what
## makes the ball go where you pointed rather than merely where you stood.
## See https://www.smish.dev/rocket_league/ball_simulation_3/ — the TS build is
## missing this term; closing that gap is the one deliberate improvement over it.
const HIT_FORWARD_SQUASH := 0.35
## Extra speed given to the ball, as a fraction of the closing speed. Falls off
## on very fast hits (RL curve: .65 -> .30).
const HIT_SCALE_CURVE: Array[Vector2] = [
	Vector2(0.0, 0.65),
	Vector2(500.0 * UU, 0.65),
	Vector2(2300.0 * UU, 0.55),
	Vector2(4600.0 * UU, 0.30),
]
## Cap so a single touch can never be absurd.
const HIT_MAX_DELTA_V := 4600.0 * UU
## Re-arm time so a sustained dribble doesn't get impulsed every single step.
const HIT_COOLDOWN := 0.055
## Below this closing speed we don't add anything (lets you carry the ball).
const HIT_MIN_CLOSING_SPEED := 30.0 * UU

# ---------------------------------------------------------------------------
# Car
# ---------------------------------------------------------------------------

## Longer than the stock Octane, same width. Everything that depends on the
## car's length — hitbox, wheelbase, the visual shell, the demolition reach — is
## derived from this, so they can't drift apart.
const BODY_STRETCH := 1.35

const CAR_MASS := 180.0  # (RL)
## (RL) Octane hitbox 118.01 x 84.20 x 36.16 uu -> half extents,
## in (x = right, y = up, z = forward).
const CAR_HALF := Vector3(
	84.20 * UU * 0.5,
	36.16 * UU * 0.5,
	118.01 * UU * BODY_STRETCH * 0.5
)

const CAR_MAX_DRIVE_SPEED := 1410.0 * UU  # (RL) throttle-only top speed
## Trimmed ~6% below the RL numbers (2200 / 2300). Flat out on boost the car was
## quick enough to be a handful — the cap and the threshold move together so
## supersonic stays reachable, and normal throttle-only driving is untouched.
## Lower top speed also tightens the turn radius up there.
const CAR_SUPERSONIC := 2060.0 * UU  # threshold
const CAR_MAX_SPEED := 2160.0 * UU  # absolute cap

## (RL) throttle acceleration falls off linearly to zero at maxDriveSpeed.
const THROTTLE_CURVE: Array[Vector2] = [
	Vector2(0.0, 1600.0 * UU),
	Vector2(1400.0 * UU, 160.0 * UU),
	Vector2(1410.0 * UU, 0.0),
]
const CAR_BRAKE_ACCEL := 3500.0 * UU  # (RL)
const CAR_COAST_ACCEL := 525.0 * UU  # (RL) engine braking when you release throttle

## (RL) Steering is modelled as curvature, not torque:
## yaw rate = curvature(speed) * speed. This is why RL cars have a
## speed-dependent turn radius that you can feel. Scaled 1.18x above the stock
## table — the authentic radius felt a shade wide.
const STEER_SCALE := 1.18
const STEER_CURVE: Array[Vector2] = [
	Vector2(0.0, 0.0069 * UU_INV * STEER_SCALE),
	Vector2(500.0 * UU, 0.00398 * UU_INV * STEER_SCALE),
	Vector2(1000.0 * UU, 0.00235 * UU_INV * STEER_SCALE),
	Vector2(1500.0 * UU, 0.001375 * UU_INV * STEER_SCALE),
	Vector2(1750.0 * UU, 0.0011 * UU_INV * STEER_SCALE),
	Vector2(2300.0 * UU, 0.00088 * UU_INV * STEER_SCALE),
]
## How fast the yaw rate chases its target. Higher = twitchier.
const CAR_STEER_RESPONSE := 14.0

# Tyres ---------------------------------------------------------------------

## Max lateral acceleration the tyres can generate before they let go.
const CAR_GRIP_ACCEL := 34.0
## Same, while powersliding — low enough to drift, high enough to still steer.
const CAR_DRIFT_GRIP_ACCEL := 6.5
## Extra forward-axis drag while powersliding.
const CAR_DRIFT_DRAG := 1.6

# Suspension ----------------------------------------------------------------

## Mount points in car-local space, relative to the hitbox centre.
## Local +X is the driver's LEFT (see Car.sync — forward is local +Z), so this
## reads front-left, front-right, rear-left, rear-right.
const WHEEL_OFFSETS: Array[Vector3] = [
	Vector3(0.4, 0.02, 0.42 * BODY_STRETCH),
	Vector3(-0.4, 0.02, 0.42 * BODY_STRETCH),
	Vector3(0.4, 0.02, -0.42 * BODY_STRETCH),
	Vector3(-0.4, 0.02, -0.42 * BODY_STRETCH),
]
const WHEEL_RADIUS := 0.17
## Distance from mount to wheel bottom when fully extended / at rest.
const WHEEL_MAX_LEN := 0.27
const WHEEL_REST_LEN := 0.22
## Sized so the chassis rests ~2 cm off the deck under gravity + sticky force,
## stiff enough that landings don't bottom out through the floor.
const WHEEL_STIFFNESS := 9000.0
const WHEEL_DAMPING := 620.0

## How hard the car is pulled toward whatever surface it's driving on. Below
## gravity, so you still slide down walls.
const CAR_STICKY_ACCEL := 325.0 * UU  # (RL)
## Torque that snaps the chassis flat to the surface normal while grounded.
const CAR_GROUND_ALIGN := 62.0
const CAR_GROUND_ALIGN_DAMP := 9.5
## Grace period after leaving a surface before air control takes over
## (RL "coyote time" for jumps).
const CAR_COYOTE_TIME := 0.1

# Air -----------------------------------------------------------------------

## (RL) Aerial torque + damping coefficients, straight from the community
## reverse-engineering (RLUtilities). These are what make RL's air control feel
## the way it does: pitch is heavy, yaw is light, roll is very fast.
const AIR_TORQUE_PITCH := 12.146
const AIR_TORQUE_YAW := 8.9196
const AIR_TORQUE_ROLL := 36.0796
const AIR_DAMP_PITCH := 2.79819
const AIR_DAMP_YAW := 1.88649
const AIR_DAMP_ROLL := 4.47166
const AIR_MAX_ANGULAR := 5.5  # (RL) rad/s

# Jump / flip ---------------------------------------------------------------

const JUMP_IMPULSE := 291.667 * UU  # (RL) instant dv along car up
const JUMP_HOLD_ACCEL := 1458.333 * UU  # (RL) extra accel while jump is held
const JUMP_MAX_HOLD := 0.2  # (RL)
## (RL) window after the first jump in which a second jump / flip is available.
const JUMP_WINDOW := 1.25
const JUMP_DOUBLE_IMPULSE := 291.667 * UU  # (RL)
## Stick deflection needed to turn a second jump into a directional flip.
const JUMP_DEADZONE := 0.25

## dv applied in the flip direction.
const FLIP_IMPULSE := 500.0 * UU
## Forward flips convert some existing speed into more speed (the RL speed flip).
const FLIP_FORWARD_SPEED_GAIN := 0.06
## Time for exactly ONE revolution. The spin rate is derived from this
## (2*PI / spinTime) and killed at the end, so a dodge never tumbles.
const FLIP_SPIN_TIME := 0.6
## Can't flip again until this long after landing.
const FLIP_COOLDOWN := 0.12

## Jump while inverted just hops you off the surface — no scripted righting.
## The player rotates with air roll, which is what Rocket League does.
const UNSTICK_HOP := 3.4
const UNSTICK_COOLDOWN := 0.3

# Boost ---------------------------------------------------------------------

const BOOST_ACCEL := 991.667 * UU  # (RL)
const BOOST_DRAIN_PER_SEC := 33.3  # (RL)
const BOOST_MAX := 100.0
const BOOST_START := 34.0  # (RL) kickoff boost
## Minimum boost consumed per tap, so short taps still feel like something.
const BOOST_MIN_TAP := 0.1
const RESPAWN_BOOST := 34.0

# ---------------------------------------------------------------------------
# Demolition — supersonic contact wipes out the slower car
# ---------------------------------------------------------------------------

## Attacker must be at or above this to demolish — i.e. supersonic.
const DEMO_MIN_SPEED := CAR_SUPERSONIC
## Centre-to-centre distance counted as a hit. Has to clear two cars parked nose
## to nose (2 x half.z) or the colliders keep them apart and a head-on
## demolition can never land.
const DEMO_RADIUS := CAR_HALF.z * 2.0 + 0.36
## Seconds spent wrecked before respawning at your own goal.
const DEMO_RESPAWN_DELAY := 1.0

# ---------------------------------------------------------------------------
# Boost pads (RL soccar layout)
# ---------------------------------------------------------------------------

const PAD_BIG_AMOUNT := 100.0  # (RL)
const PAD_SMALL_AMOUNT := 12.0  # (RL)
const PAD_BIG_RESPAWN := 10.0  # (RL) seconds
const PAD_SMALL_RESPAWN := 4.0  # (RL)
const PAD_BIG_RADIUS := 208.0 * UU  # (RL)
const PAD_SMALL_RADIUS := 144.0 * UU  # (RL)
## Pads are picked up by driving through a cylinder, not by touching the disc.
const PAD_HEIGHT := 165.0 * UU

## (RL) The six 100-boost pads.
const BIG_PAD_POSITIONS: Array[Vector2] = [
	Vector2(3584.0 * UU, 0.0),
	Vector2(-3584.0 * UU, 0.0),
	Vector2(3072.0 * UU, 4096.0 * UU),
	Vector2(-3072.0 * UU, 4096.0 * UU),
	Vector2(3072.0 * UU, -4096.0 * UU),
	Vector2(-3072.0 * UU, -4096.0 * UU),
]

## (RL) The 12-boost pads, mirrored across both halves.
const SMALL_PAD_POSITIONS: Array[Vector2] = [
	Vector2(0.0, -4240.0 * UU),
	Vector2(-1792.0 * UU, -4184.0 * UU),
	Vector2(1792.0 * UU, -4184.0 * UU),
	Vector2(-940.0 * UU, -3308.0 * UU),
	Vector2(940.0 * UU, -3308.0 * UU),
	Vector2(0.0, -2816.0 * UU),
	Vector2(-3584.0 * UU, -2484.0 * UU),
	Vector2(3584.0 * UU, -2484.0 * UU),
	Vector2(-1788.0 * UU, -2300.0 * UU),
	Vector2(1788.0 * UU, -2300.0 * UU),
	Vector2(-2048.0 * UU, -1036.0 * UU),
	Vector2(0.0, -1024.0 * UU),
	Vector2(2048.0 * UU, -1036.0 * UU),
	Vector2(-1024.0 * UU, 0.0),
	Vector2(1024.0 * UU, 0.0),
	Vector2(-2048.0 * UU, 1036.0 * UU),
	Vector2(0.0, 1024.0 * UU),
	Vector2(2048.0 * UU, 1036.0 * UU),
	Vector2(-1788.0 * UU, 2300.0 * UU),
	Vector2(1788.0 * UU, 2300.0 * UU),
	Vector2(-3584.0 * UU, 2484.0 * UU),
	Vector2(3584.0 * UU, 2484.0 * UU),
	Vector2(0.0, 2816.0 * UU),
	Vector2(-940.0 * UU, 3308.0 * UU),
	Vector2(940.0 * UU, 3308.0 * UU),
	Vector2(-1792.0 * UU, 4184.0 * UU),
	Vector2(1792.0 * UU, 4184.0 * UU),
	Vector2(0.0, 4240.0 * UU),
]

# ---------------------------------------------------------------------------
# Camera (RL default / common pro settings)
# ---------------------------------------------------------------------------

const CAM_FOV := 100.0  # (RL) max setting is 110; 100 reads better on a laptop
const CAM_DISTANCE := 285.0 * UU  # (RL) default 270
const CAM_HEIGHT := 128.0 * UU  # (RL) ~110
const CAM_ANGLE := -4.0 * (PI / 180.0)  # (RL) downward pitch
const CAM_STIFFNESS := 0.55  # (RL) 0..1
const CAM_SWIVEL_SPEED := 5.5  # (RL)
## Ball cam pulls back a bit so both car and ball fit.
const CAM_BALL_DISTANCE := 340.0 * UU
const CAM_BALL_HEIGHT := 175.0 * UU
## FOV kick while boosting / supersonic.
const CAM_BOOST_FOV := 9.0
const CAM_SUPERSONIC_FOV := 7.0
## Camera never rolls with the car — keeps wall play readable.
const CAM_MIN_HEIGHT_ABOVE_FLOOR := 0.4

# ---------------------------------------------------------------------------
# Match
# ---------------------------------------------------------------------------

const MATCH_DURATION := 300.0  # 5:00
const MATCH_COUNTDOWN := 3.0
const MATCH_GOAL_CELEBRATION := 3.2
const MATCH_SLOWMO_SCALE := 0.22
const MATCH_SLOWMO_RECOVER := 0.75

# ---------------------------------------------------------------------------
# Kickoff
# ---------------------------------------------------------------------------

## (RL) The five kickoff spawns. Blue defends -z, so these are all negative z;
## orange mirrors through the centre spot, which is what keeps a kickoff fair —
## both cars are always the same distance from the ball.
const KICKOFF_SPOTS: Array[Vector2] = [
	Vector2(-2048.0 * UU, -2560.0 * UU),  # diagonal left
	Vector2(2048.0 * UU, -2560.0 * UU),   # diagonal right
	Vector2(-256.0 * UU, -3840.0 * UU),   # near left
	Vector2(256.0 * UU, -3840.0 * UU),    # near right
	Vector2(0.0, -4608.0 * UU),           # straight
]
const KICKOFF_SPOT_NAMES: Array[String] = [
	"diagonal left", "diagonal right", "near left", "near right", "straight",
]

const TEAM_BLUE := 0
const TEAM_ORANGE := 1

# ---------------------------------------------------------------------------
# Surface response — Godot numbers, not RL ones
# ---------------------------------------------------------------------------
#
# Rapier picks a restitution rule per collider (the ball asks for Max, so it
# always bounces at its own 0.6) and averages friction. Godot has no per-pair
# rule; measured on 4.7.1 + Jolt by tests/probe_material.gd it is
#
#     restitution = a + b        friction = min(a, b)
#
# so the raw config.ts values would have given the ball a restitution of 0.9 —
# it rebounded at 13.7 m/s off a 15.2 m/s drop instead of the TS build's 9.1.
# What follows is chosen so the COMBINED numbers land on what Rapier produces:
#
#   ball  vs any surface   0.5 + 0.1 = 0.60   (TS: Max(0.6, surface) = 0.60)
#   car   vs any surface   0.1 + 0.1 = 0.20   (TS: avg -> 0.20 / 0.225 / 0.15)
#   ball  vs car           0.5 + 0.1 = 0.60   (TS: Max(0.6, 0.1)     = 0.60)
#   ball  vs floor  friction min(0.475, 0.6)   = 0.475  (TS avg = 0.475)
#   ball  vs wall   friction min(0.475, 0.375) = 0.375  (TS avg = 0.375)
#
# The car's friction cannot be made to match all three of its pairs at once,
# because min() cannot rise above the smaller number. config.ts gives the shell
# 0.18 and Rapier averages it up: 0.39 on the floor, 0.29 on walls, 0.32 in the
# goals. Transcribing 0.18 literally would give 0.18 everywhere — half the
# intended grip on the two surfaces where a scraping shell is actually felt.
# 0.30 is the value closest to all four pairs at once:
#
#   car  vs floor  min(0.30, 0.6)   = 0.30   (TS 0.39)
#   car  vs wall   min(0.30, 0.375) = 0.30   (TS 0.29)
#   car  vs goal   min(0.30, 0.40)  = 0.30   (TS 0.32)
#   ball vs car    min(0.475, 0.30) = 0.30   (TS 0.265)
#
# Measured rather than argued: mean car-position error against the oracle over
# the six contact-heavy scenarios falls from 2.41 m to 1.29 m, and wall_ride —
# the most contact-dependent of them — from 2.01 m to 0.82 m. The one scenario
# it costs is ball_hit_offset, by 0.2 m.

const SURF_BOUNCE := 0.1
const BALL_BOUNCE_GODOT := 0.5
const BALL_FRICTION_GODOT := 0.475
const CAR_BOUNCE_GODOT := 0.1
const CAR_FRICTION_GODOT := 0.30
## surface name -> friction, chosen so min() with the ball's lands on the
## average Rapier would have produced.
const SURF_FRICTION := {
	"CF_Floor": 0.6,
	"CF_Walls": 0.375,
	"CF_Ceiling": 0.375,
	"CF_GoalPockets": 0.40,
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## Piecewise-linear lookup used by the throttle / steer / hit curves. `table` is
## an array of Vector2(x, y) sorted by x; flat outside the ends.
static func curve(table: Array[Vector2], x: float) -> float:
	if x <= table[0].x:
		return table[0].y
	for i in range(table.size() - 1):
		var a := table[i]
		var b := table[i + 1]
		if x <= b.x:
			return a.y + (b.y - a.y) * (x - a.x) / (b.x - a.x)
	return table[table.size() - 1].y


## Yaw that points a car spawned at (x, z) back at the ball on the centre spot.
static func face_ball(x: float, z: float) -> float:
	return atan2(-x, -z)


## Kickoff spawn for one team slot. Orange is the point mirror of blue.
## Returns Vector3(x, z, yaw).
static func kickoff_spawn(team: int, spot: Vector2) -> Vector3:
	var s := 1.0 if team == TEAM_BLUE else -1.0
	var x := spot.x * s
	var z := spot.y * s
	return Vector3(x, z, face_ball(x, z))
