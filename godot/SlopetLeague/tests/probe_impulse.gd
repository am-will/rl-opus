extends SceneTree
## What actually round-trips on a Jolt RigidBody3D from `_physics_process`?
##
## The suspension port depends on it: the TypeScript build applies four spring
## impulses, re-reads the velocity, and then WRITES that velocity back during
## the drive step. If the read does not already contain the impulses, the write
## silently deletes them and the car sits on its own collision box.
##
## Result on Godot 4.7.1 + Jolt: apply_impulse is QUEUED (invisible until after
## the step); linear_velocity / angular_velocity assignment IS immediate. So the
## port has to integrate the suspension impulses by hand.

var _body: RigidBody3D
var _n := 0


func _initialize() -> void:
	var b := RigidBody3D.new()
	b.mass = 180.0
	b.gravity_scale = 0.0
	b.can_sleep = false
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.842, 0.3616, 1.5931)
	cs.shape = box
	b.add_child(cs)
	root.add_child(b)
	_body = b
	print("engine: ", ProjectSettings.get_setting("physics/3d/physics_engine"))


func _physics_process(_delta: float) -> bool:
	_n += 1
	if _n == 3:
		_body.apply_impulse(Vector3(0, 180.0, 0))  # -> +1 m/s if immediate
		print("apply_impulse   read-back = %v   (want y=1)" % _body.linear_velocity)
		_body.linear_velocity = Vector3(0, 2, 0)
		print("set linear_vel  read-back = %v   (want y=2)" % _body.linear_velocity)
		_body.angular_velocity = Vector3(0, 3, 0)
		print("set angular_vel read-back = %v   (want y=3)" % _body.angular_velocity)
		print("inv_inertia = ", PhysicsServer3D.body_get_direct_state(_body.get_rid()).inverse_inertia)
		print("pos before step = %v" % _body.global_position)
	if _n == 4:
		print("pos after 1 step = %v  (want y ~ 2/120 + queued impulse 1/120)" % _body.global_position)
		print("vel after 1 step = %v" % _body.linear_velocity)
	return _n >= 5
