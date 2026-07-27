class_name CarFx
extends Node3D
## Boost flame, supersonic streaks and the team paint.
##
## Built in code and parented to the car, so a car scene stays two nodes and a
## script. Everything here is presentation — it reads car state and never writes
## any, which keeps it out of the physics path entirely.

const TEAM_PAINT := [
	Color(0.20, 0.52, 0.95),  # blue
	Color(1.0, 0.45, 0.10),  # orange
]
const TEAM_GLOW := [
	Color(0.4, 0.8, 1.0),
	Color(1.0, 0.69, 0.4),
]
## Flame is RL's blue-white core rather than the team colour — it reads as heat.
const FLAME_HOT := Color(0.75, 0.88, 1.0)
const FLAME_COOL := Color(0.25, 0.55, 1.0)

var _car: Car
var _flame: GPUParticles3D
var _streaks: GPUParticles3D
var _light: OmniLight3D
var _light_energy := 0.0


func setup(car: Car) -> void:
	_car = car
	position = Vector3(0.0, 0.02, -Feel.CAR_HALF.z * 0.92)
	_build_flame()
	_build_streaks()

	_light = OmniLight3D.new()
	_light.light_color = Color(0.6, 0.8, 1.0)
	_light.omni_range = 4.5
	_light.light_energy = 0.0
	_light.shadow_enabled = false
	add_child(_light)

	_paint(car)


# ---------------------------------------------------------------------------

func _build_flame() -> void:
	_flame = GPUParticles3D.new()
	_flame.amount = 34
	_flame.lifetime = 0.13
	_flame.explosiveness = 0.0
	_flame.local_coords = false
	_flame.emitting = false
	_flame.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.045
	# Local -Z is behind the car (forward is +Z).
	pm.direction = Vector3(0, 0, -1)
	pm.spread = 8.0
	pm.initial_velocity_min = 2.6
	pm.initial_velocity_max = 4.4
	pm.gravity = Vector3.ZERO
	pm.damping_min = 8.0
	pm.damping_max = 12.0
	pm.scale_min = 0.35
	pm.scale_max = 0.8
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 0.35))
	curve.add_point(Vector2(0.25, 1.0))
	curve.add_point(Vector2(1.0, 0.0))
	var ct := CurveTexture.new()
	ct.curve = curve
	pm.scale_curve = ct
	var grad := Gradient.new()
	grad.set_color(0, FLAME_HOT)
	grad.set_color(1, Color(FLAME_COOL.r, FLAME_COOL.g, FLAME_COOL.b, 0.0))
	grad.add_point(0.35, Color(0.45, 0.72, 1.0, 0.85))
	var gt := GradientTexture1D.new()
	gt.gradient = grad
	pm.color_ramp = gt
	_flame.process_material = pm

	var quad := QuadMesh.new()
	quad.size = Vector2(0.15, 0.15)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	mat.disable_receive_shadows = true
	mat.albedo_color = Color(1, 1, 1, 0.42)
	quad.material = mat
	_flame.draw_pass_1 = quad
	add_child(_flame)


## Thin streaks off the rear wheels once the car is supersonic — the read for
## "you are at the speed that demolishes people".
func _build_streaks() -> void:
	_streaks = GPUParticles3D.new()
	_streaks.amount = 26
	_streaks.lifetime = 0.35
	_streaks.local_coords = false
	_streaks.emitting = false

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(0.42, 0.02, 0.05)
	pm.direction = Vector3(0, 0, -1)
	pm.spread = 4.0
	pm.initial_velocity_min = 1.0
	pm.initial_velocity_max = 2.0
	pm.gravity = Vector3(0, 0.4, 0)
	pm.scale_min = 0.5
	pm.scale_max = 1.1
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 1, 0.3))
	grad.set_color(1, Color(1, 1, 1, 0.0))
	var gt := GradientTexture1D.new()
	gt.gradient = grad
	pm.color_ramp = gt
	_streaks.process_material = pm

	var quad := QuadMesh.new()
	quad.size = Vector2(0.09, 0.09)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	quad.material = mat
	_streaks.draw_pass_1 = quad
	add_child(_streaks)


## Team paint on the shell. The Octane's body texture is a light grey base, so a
## straight albedo multiply reads as a paint job rather than a colour wash, and
## the rim of emission picks the car out against the pitch at distance.
func _paint(car: Car) -> void:
	var model := car.get_node_or_null("Model")
	if model == null:
		return
	var paint: Color = TEAM_PAINT[clampi(car.team, 0, 1)]
	var glow: Color = TEAM_GLOW[clampi(car.team, 0, 1)]
	for n in model.find_children("*Body*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		for s in mi.mesh.get_surface_count():
			# get_active_material resolves overrides; surface_get_material alone
			# comes back null on some glTF imports and we would paint over the
			# body texture with flat colour.
			var base := mi.get_active_material(s)
			var mat: StandardMaterial3D = (
				base.duplicate() if base is StandardMaterial3D else StandardMaterial3D.new()
			)
			mat.albedo_color = paint
			mat.metallic = 0.35
			mat.roughness = 0.35
			mat.emission_enabled = true
			mat.emission = glow
			mat.emission_energy_multiplier = 0.12
			mi.set_surface_override_material(s, mat)


# ---------------------------------------------------------------------------

func _process(dt: float) -> void:
	if _car == null:
		return
	var boosting := _car.is_boosting and _car.active
	if _flame.emitting != boosting:
		_flame.emitting = boosting
	var supersonic := _car.supersonic and _car.active
	if _streaks.emitting != supersonic:
		_streaks.emitting = supersonic

	# The light lags the flame slightly so a tap reads as a flare, not a strobe.
	var want := 2.6 if boosting else 0.0
	_light_energy = lerpf(_light_energy, want, clampf(dt * (18.0 if boosting else 9.0), 0.0, 1.0))
	_light.light_energy = _light_energy
	_light.visible = _light_energy > 0.02
