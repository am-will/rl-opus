extends SceneTree
## How does this engine combine two PhysicsMaterials?
##
## Rapier resolves restitution per collider rule (the ball asks for Max, so it
## always bounces at its own 0.6) and friction by averaging. Godot has no
## per-pair rule, so before the ball can be made to bounce like the TS build's
## we have to know what it actually does with the two numbers.
##
##   godot --path godot/SlopetLeague --headless --script tests/probe_material.gd

const DROP_FROM := 6.0
const CASES := [
	# ball bounce, floor bounce
	[0.6, 0.3], [0.6, 0.0], [0.0, 0.3], [0.6, 0.6], [0.3, 0.3],
]
const FRICTION_CASES := [
	# ball friction, floor friction
	[0.35, 0.6], [0.35, 0.0], [0.0, 0.6], [0.35, 0.35],
]

var _floor: StaticBody3D
var _ball: RigidBody3D
var _case := 0
var _phase := 0  # 0 = restitution, 1 = friction
var _n := 0
var _impact_speed := 0.0
var _prev_vy := 0.0
var _start_vx := 0.0


func _initialize() -> void:
	print("engine: ", ProjectSettings.get_setting("physics/3d/physics_engine"))
	print("bounce threshold: ", ProjectSettings.get_setting(
		"physics/jolt_physics_3d/simulation/bounce_velocity_threshold", "<unset>"))

	_floor = StaticBody3D.new()
	var fs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400, 2, 400)
	fs.shape = box
	fs.position = Vector3(0, -1, 0)
	_floor.add_child(fs)
	root.add_child(_floor)

	_ball = RigidBody3D.new()
	_ball.mass = 30.0
	_ball.can_sleep = false
	_ball.continuous_cd = true
	_ball.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	_ball.angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	_ball.linear_damp = 0.0
	_ball.angular_damp = 0.0
	var bs := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = 0.9125
	bs.shape = sph
	_ball.add_child(bs)
	root.add_child(_ball)

	print("\n-- restitution: drop from %.1f m, rebound / impact --" % DROP_FROM)
	_start_case()


func _mat(bounce: float, friction: float) -> PhysicsMaterial:
	var m := PhysicsMaterial.new()
	m.bounce = bounce
	m.friction = friction
	m.absorbent = false
	m.rough = false
	return m


func _start_case() -> void:
	_n = 0
	_impact_speed = 0.0
	_prev_vy = 0.0
	if _phase == 0:
		var c: Array = CASES[_case]
		_ball.physics_material_override = _mat(c[0], 0.5)
		_floor.physics_material_override = _mat(c[1], 0.5)
		_teleport(Vector3(0, DROP_FROM, 0))
		_ball.linear_velocity = Vector3.ZERO
	else:
		var c: Array = FRICTION_CASES[_case]
		_ball.physics_material_override = _mat(0.0, c[0])
		_floor.physics_material_override = _mat(0.0, c[1])
		_teleport(Vector3(0, 0.9125, 0))
		_start_vx = 15.0
		_ball.linear_velocity = Vector3(_start_vx, 0, 0)
	_ball.angular_velocity = Vector3.ZERO


func _teleport(p: Vector3) -> void:
	var t := Transform3D(Basis.IDENTITY, p)
	PhysicsServer3D.body_set_state(_ball.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, t)


func _physics_process(_dt: float) -> bool:
	_n += 1
	var v := _ball.linear_velocity

	if _phase == 0:
		if _prev_vy < -0.5 and v.y > 0.0:
			var c: Array = CASES[_case]
			print("  ball %.2f  floor %.2f  ->  impact %6.3f  rebound %6.3f  e = %.3f" % [
				c[0], c[1], -_prev_vy, v.y, v.y / -_prev_vy
			])
			return _next()
		_prev_vy = v.y
		if _n > 400:
			print("  (no bounce detected)")
			return _next()
	else:
		if _n == 24:  # 0.2 s of contact
			var c: Array = FRICTION_CASES[_case]
			var decel := (_start_vx - v.x) / (24.0 / 120.0)
			print("  ball %.2f  floor %.2f  ->  vx %6.3f  decel %6.3f m/s^2  mu = %.3f  spin %.2f" % [
				c[0], c[1], v.x, decel, decel / 6.5, _ball.angular_velocity.length()
			])
			return _next()
	return false


func _next() -> bool:
	_case += 1
	var limit: int = CASES.size() if _phase == 0 else FRICTION_CASES.size()
	if _case >= limit:
		if _phase == 1:
			return true
		_phase = 1
		_case = 0
		print("\n-- friction: roll at 15 m/s, decel over 0.2 s (gravity 6.5) --")
	_start_case()
	return false
