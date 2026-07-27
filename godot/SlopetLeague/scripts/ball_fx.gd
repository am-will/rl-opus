class_name BallFx
extends Node3D
## The ball's glow and speed trail.
##
## Two jobs, both readability rather than decoration: a light that flares on a
## hit so you can see across the pitch that the ball has been struck hard, and a
## trail above ~14 m/s so a fast ball reads as fast even against the crowd.
##
## Presentation only — reads ball state, writes none.

## Speed at which the trail starts, and where it is at full strength.
const TRAIL_MIN := 14.0
const TRAIL_FULL := 34.0

var _ball: Ball
var _light: OmniLight3D
var _trail: GPUParticles3D
var _energy := 0.0


func setup(ball: Ball) -> void:
	_ball = ball

	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.93, 0.82)
	_light.omni_range = 14.0
	_light.light_energy = 0.0
	_light.shadow_enabled = false
	add_child(_light)

	_trail = GPUParticles3D.new()
	_trail.amount = 60
	_trail.lifetime = 0.5
	_trail.local_coords = false
	_trail.emitting = false
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = Feel.BALL_RADIUS * 0.8
	pm.direction = Vector3(0, 0, 0)
	pm.spread = 180.0
	pm.initial_velocity_min = 0.0
	pm.initial_velocity_max = 0.6
	pm.gravity = Vector3.ZERO
	pm.scale_min = 0.5
	pm.scale_max = 1.0
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 1.0))
	curve.add_point(Vector2(1.0, 0.0))
	var ct := CurveTexture.new()
	ct.curve = curve
	pm.scale_curve = ct
	var grad := Gradient.new()
	grad.set_color(0, Color(1.0, 0.85, 0.6, 0.30))
	grad.set_color(1, Color(1.0, 0.5, 0.2, 0.0))
	var gt := GradientTexture1D.new()
	gt.gradient = grad
	pm.color_ramp = gt
	_trail.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(0.9, 0.9)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	quad.material = mat
	_trail.draw_pass_1 = quad
	add_child(_trail)


func _process(dt: float) -> void:
	if _ball == null:
		return
	var speed := _ball.vel.length()
	var fast := clampf((speed - TRAIL_MIN) / (TRAIL_FULL - TRAIL_MIN), 0.0, 1.0)
	var want := _ball.last_hit_strength * 9.0 + fast * 1.6
	# Rises fast, falls slowly: a hit should flash, not blink.
	_energy = lerpf(_energy, want, clampf(dt * (26.0 if want > _energy else 5.0), 0.0, 1.0))
	_light.light_energy = _energy
	_light.visible = _energy > 0.02

	var emitting := fast > 0.01
	if _trail.emitting != emitting:
		_trail.emitting = emitting
	if emitting:
		_trail.amount_ratio = 0.25 + fast * 0.75
