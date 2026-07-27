class_name Ball
extends RigidBody3D
## The match ball. Port of src/physics/Ball.ts.
##
## The engine does the collision response; this script only applies the parts RL
## has that a stock rigid body does not — rolling resistance on the deck, and
## hard caps on speed and spin.
##
## `tick()` is called by Game once per physics step, AFTER the solver has run,
## matching the TypeScript build's ordering.

## Set by Car when it strikes the ball; drives the impact VFX.
var last_hit_strength := 0.0

## Cached post-step state, refreshed by sync().
var pos := Vector3.ZERO
var vel := Vector3.ZERO


func _ready() -> void:
	mass = Feel.BALL_MASS
	can_sleep = false
	continuous_cd = true
	custom_integrator = false
	gravity_scale = 1.0

	# Rapier averages restitution with whatever it hits, which would drag the
	# bounce below RL's 0.6 on every surface; the TS build sets the combine rule
	# to Max for the same reason. Godot's non-absorbent material combines as max.
	var mat := PhysicsMaterial.new()
	mat.bounce = Feel.BALL_RESTITUTION
	mat.friction = Feel.BALL_FRICTION
	mat.absorbent = false
	mat.rough = false
	physics_material_override = mat

	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	linear_damp = Feel.BALL_DRAG
	angular_damp = 0.02

	collision_layer = Layers.BALL
	collision_mask = Layers.ARENA | Layers.CAR
	sync()


## Post-step corrections. Order matches Ball.update in the TS build.
func tick(dt: float) -> void:
	var v := linear_velocity

	# Rolling resistance, floor only. Without this the ball trickles forever and
	# dead-ball situations feel wrong.
	if global_position.y < Feel.BALL_RADIUS * 1.15:
		var horiz := sqrt(v.x * v.x + v.z * v.z)
		if horiz > 1e-4:
			var drop: float = min(horiz, Feel.BALL_GROUND_ROLL * dt)
			v.x -= (v.x / horiz) * drop
			v.z -= (v.z / horiz) * drop

	var speed := v.length()
	if speed > Feel.BALL_MAX_SPEED:
		v *= Feel.BALL_MAX_SPEED / speed
	linear_velocity = v

	var av := angular_velocity
	var spin := av.length()
	if spin > Feel.BALL_MAX_ANGULAR:
		angular_velocity = av * (Feel.BALL_MAX_ANGULAR / spin)

	last_hit_strength *= maxf(0.0, 1.0 - dt * 6.0)


## Copy simulation state into plain fields for the rest of the game to read.
func sync() -> void:
	pos = global_position
	vel = linear_velocity


var speed: float:
	get: return vel.length()


func reset(p := Vector3(0.0, Feel.BALL_RADIUS + 0.02, 0.0), v := Vector3.ZERO) -> void:
	# Teleporting a rigid body has to go through the physics server or the move
	# is undone by the next state sync.
	var t := global_transform
	t.origin = p
	t.basis = Basis.IDENTITY
	PhysicsServer3D.body_set_state(
		get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, t
	)
	global_transform = t
	linear_velocity = v
	angular_velocity = Vector3.ZERO
	last_hit_strength = 0.0
	sync()
