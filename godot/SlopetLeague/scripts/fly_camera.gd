extends Camera3D
## Free-fly camera for inspecting the arena, plus a ball you can fire at the
## pitch to confirm nothing catches.
##
##   click        capture mouse      esc     release
##   W A S D      move               Q / E   down / up
##   shift        4x speed           R       fire a ball
##   G            drop a ball straight down from the camera

@export var speed := 25.0
@export var boost := 4.0
@export var sensitivity := 0.0022

const BALL_R := 0.9125          # Rocket League ball, in metres

var _captured := false
var _yaw := 0.0
var _pitch := 0.0


func _ready() -> void:
	current = true          # beat any camera the glb brought in
	near = 0.1
	far = 4000.0
	# Aim at the middle of the pitch, then decompose into yaw/pitch so mouse
	# look can't accumulate roll.
	look_at(Vector3(0.0, 1.0, 0.0), Vector3.UP)
	_yaw = rotation.y
	_pitch = rotation.x


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		_captured = true
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventMouseMotion and _captured:
		_yaw -= event.relative.x * sensitivity
		_pitch = clamp(_pitch - event.relative.y * sensitivity, -1.5, 1.5)
		rotation = Vector3(_pitch, _yaw, 0.0)
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ESCAPE:
				_captured = false
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			KEY_R:
				_spawn_ball(-global_transform.basis.z * 30.0)
			KEY_G:
				_spawn_ball(Vector3.ZERO)


func _process(delta: float) -> void:
	var dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): dir -= global_transform.basis.z
	if Input.is_key_pressed(KEY_S): dir += global_transform.basis.z
	if Input.is_key_pressed(KEY_A): dir -= global_transform.basis.x
	if Input.is_key_pressed(KEY_D): dir += global_transform.basis.x
	if Input.is_key_pressed(KEY_E): dir += Vector3.UP
	if Input.is_key_pressed(KEY_Q): dir -= Vector3.UP
	if dir == Vector3.ZERO:
		return
	var s: float = speed * (boost if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	global_position += dir.normalized() * s * delta


func _spawn_ball(velocity: Vector3) -> void:
	var body := RigidBody3D.new()

	var shape := SphereShape3D.new()
	shape.radius = BALL_R
	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)

	var sphere := SphereMesh.new()
	sphere.radius = BALL_R
	sphere.height = BALL_R * 2.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.85, 0.87, 0.9)
	mat.metallic = 0.1
	mat.roughness = 0.35
	sphere.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = sphere
	body.add_child(mi)

	var bounce := PhysicsMaterial.new()
	bounce.bounce = 0.6            # RL's coefficient of restitution
	bounce.friction = 0.4
	body.physics_material_override = bounce
	body.mass = 30.0

	body.position = global_position - global_transform.basis.z * 3.0
	get_parent().add_child(body)
	body.linear_velocity = velocity
