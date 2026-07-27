class_name GoalFx
extends Node3D
## The goal explosion. Port of `explodeGoal` / `blastCars` in src/core/Game.ts.
##
## The blast is not decoration: it throws every car in a 28 m radius, which is
## what makes a goal read as an event rather than a scoreline change. The rest —
## the flash, the shockwave, the debris — hangs off the same moment.

const BLAST_RADIUS := 28.0
## dv at the centre, falling to 5 m/s at the edge. TS applies this as an impulse
## of CAR.mass * (5 + 30 * falloff), which is the same thing.
const BLAST_BASE := 5.0
const BLAST_PEAK := 30.0
## Random tumble, scaled by the same falloff.
const BLAST_SPIN := 4.5

var _light: OmniLight3D
var _burst: GPUParticles3D
var _ring: MeshInstance3D
var _ring_mat: StandardMaterial3D
var _t := -1.0
var _colour := Color.WHITE


func _ready() -> void:
	_light = OmniLight3D.new()
	_light.omni_range = 44.0
	_light.light_energy = 0.0
	_light.shadow_enabled = false
	add_child(_light)

	_ring = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 32
	sphere.rings = 16
	_ring_mat = StandardMaterial3D.new()
	_ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ring_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ring_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_ring_mat.albedo_color = Color(1, 1, 1, 0)
	sphere.material = _ring_mat
	_ring.mesh = sphere
	_ring.visible = false
	add_child(_ring)

	_burst = GPUParticles3D.new()
	_burst.amount = 220
	_burst.lifetime = 1.6
	_burst.one_shot = true
	_burst.explosiveness = 1.0
	_burst.local_coords = false
	_burst.emitting = false
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 1.2
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 180.0
	pm.initial_velocity_min = 6.0
	pm.initial_velocity_max = 26.0
	pm.gravity = Vector3(0, -Feel.GRAVITY, 0)
	pm.damping_min = 0.5
	pm.damping_max = 2.0
	pm.scale_min = 0.4
	pm.scale_max = 1.4
	pm.angular_velocity_min = -8.0
	pm.angular_velocity_max = 8.0
	_burst.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(0.34, 0.34)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	quad.material = mat
	_burst.draw_pass_1 = quad
	add_child(_burst)


## `at` is where the ball crossed; `cars` all get thrown.
func fire(at: Vector3, colour: Color, cars: Array, rng: RandomNumberGenerator) -> void:
	global_position = at
	_colour = colour
	_t = 0.0
	_light.light_color = colour
	var pm := _burst.process_material as ParticleProcessMaterial
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 1, 1))
	grad.add_point(0.25, colour)
	grad.set_color(1, Color(colour.r, colour.g, colour.b, 0.0))
	var gt := GradientTexture1D.new()
	gt.gradient = grad
	pm.color_ramp = gt
	_burst.restart()
	_burst.emitting = true
	_ring.visible = true
	_blast(at, cars, rng)


## Throw every car away from the blast. Velocity-space rather than an impulse,
## because Jolt queues impulses and the car writes its velocity by hand.
func _blast(at: Vector3, cars: Array, rng: RandomNumberGenerator) -> void:
	for c in cars:
		var car := c as Car
		if car == null or not car.active:
			continue
		var d := car.pos.distance_to(at)
		if d > BLAST_RADIUS:
			continue
		var falloff := pow(1.0 - d / BLAST_RADIUS, 1.5)
		# Normalise FIRST, then lift, then renormalise — raising y on the raw
		# displacement instead would make the lift negligible at range: 24
		# degrees at 20 m becomes 1.3. Game.ts:873-875.
		var dir := Vector3(0, 1, 0)
		if d >= 0.4:
			dir = (car.pos - at) / d
			dir.y = maxf(dir.y, 0.45)  # never a pure sideways shove
			dir = dir.normalized()
		car.linear_velocity += dir * (BLAST_BASE + BLAST_PEAK * falloff)
		car.angular_velocity += Vector3(
			rng.randf_range(-1.0, 1.0),
			rng.randf_range(-1.0, 1.0),
			rng.randf_range(-1.0, 1.0)
		) * (BLAST_SPIN * falloff)
		car.sync()


func _process(dt: float) -> void:
	if _t < 0.0:
		return
	_t += dt
	# ~5 m/s^-ish shell, fading out over 0.9 s.
	var k := clampf(_t / 0.9, 0.0, 1.0)
	_light.light_energy = (1.0 - k) * (1.0 - k) * 60.0
	var r := 1.0 + k * 16.0
	_ring.scale = Vector3(r, r, r)
	_ring_mat.albedo_color = Color(_colour.r, _colour.g, _colour.b, (1.0 - k) * 0.5)
	if k >= 1.0:
		_t = -1.0
		_light.light_energy = 0.0
		_ring.visible = false
