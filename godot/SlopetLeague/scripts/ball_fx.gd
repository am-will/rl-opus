class_name BallFx
extends Node3D
## The ball's glow, its speed trail and its ground read.
##
## Four jobs, all readability rather than decoration: a light that flares on a
## hit so you can see across the pitch that the ball has been struck hard, a
## smoke plume above ~14 m/s so a fast ball reads as fast against the crowd, a
## contact shadow so the ball is attached to the pitch instead of floating over
## it, and a landing marker so a ball in the air can be met rather than chased.
##
## Presentation only — reads ball state, writes none.

## Speed at which the trail starts, and where it is at full strength.
const TRAIL_MIN := 14.0
const TRAIL_FULL := 34.0
## Above this the plume gets a hot core through it.
const HEAT_MIN := 26.0

## Ball height at which the contact shadow has faded to nothing. Past this the
## shadow is doing no work and the landing marker is carrying the read.
const SHADOW_FADE_HEIGHT := 14.0
## The landing marker only appears once the ball is properly airborne — under
## this it is inside its own shadow and just clutters the deck.
const MARKER_MIN_HEIGHT := 2.2

## Landing prediction: fixed-step forward integration of gravity plus the same
## linear damping Godot applies to the body, which is cheap enough to redo every
## frame and exact enough that the marker sits under the bounce.
const PREDICT_STEP := 1.0 / 45.0
const PREDICT_MAX_TIME := 4.0

var _ball: Ball
var _light: OmniLight3D
var _smoke: GPUParticles3D
var _heat: GPUParticles3D
var _shadow: GroundMark
var _marker: GroundMark
var _energy := 0.0
## Seconds until the predicted touchdown, or -1 when there is no prediction.
var _land_time := -1.0
var _marker_pulse := 0.0


func setup(ball: Ball) -> void:
	_ball = ball

	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.93, 0.82)
	_light.omni_range = 14.0
	_light.light_energy = 0.0
	_light.shadow_enabled = false
	add_child(_light)

	_build_smoke()
	_build_heat()
	_build_ground()


# ---------------------------------------------------------------------------
# Trail
# ---------------------------------------------------------------------------

## The plume. Everything here used to be one 0.9 m untextured quad per particle
## at 30% additive, which is why a fast ball trailed literal beige rectangles:
## an untextured quad has no alpha falloff, so its silhouette IS the mesh. The
## fixes are a real sprite, a per-particle spin so no two are the same square,
## and turbulence, which is what turns a cone of dots into something with wisps.
func _build_smoke() -> void:
	_smoke = GPUParticles3D.new()
	_smoke.amount = 40
	_smoke.lifetime = 0.62
	_smoke.local_coords = false
	_smoke.emitting = false
	_smoke.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = Feel.BALL_RADIUS * 0.55
	pm.direction = Vector3(0, 0, 0)
	pm.spread = 180.0
	pm.initial_velocity_min = 0.3
	pm.initial_velocity_max = 1.3
	# Smoke rises and slows; without the damping the puffs keep the ball's own
	# expansion speed for their whole life and the plume comes out as a cone.
	pm.gravity = Vector3(0, 0.9, 0)
	pm.damping_min = 1.4
	pm.damping_max = 2.6
	pm.scale_min = 0.35
	pm.scale_max = 0.75
	pm.angle_min = -180.0
	pm.angle_max = 180.0
	pm.angular_velocity_min = -55.0
	pm.angular_velocity_max = 55.0
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 0.9
	pm.turbulence_noise_scale = 2.2
	pm.turbulence_influence_min = 0.05
	pm.turbulence_influence_max = 0.35

	# Grows as it dissipates, which is what a puff of anything does.
	var scale_curve := Curve.new()
	scale_curve.add_point(Vector2(0.0, 0.35))
	scale_curve.add_point(Vector2(0.35, 0.85))
	scale_curve.add_point(Vector2(1.0, 1.15))
	var ct := CurveTexture.new()
	ct.curve = scale_curve
	pm.scale_curve = ct

	# Warm at birth, cooling to a neutral grey. The alpha peaks early and has a
	# long tail: a trail whose head is its brightest point reads as coming FROM
	# the ball, which is the whole point of it. Kept thin deliberately — this is
	# a contrail behind a ball, not a smoke screen, and the first pass at it was
	# dense enough to hide the half of the pitch the ball had just crossed.
	var grad := Gradient.new()
	grad.set_color(0, Color(1.0, 0.90, 0.74, 0.0))
	grad.set_color(1, Color(0.72, 0.74, 0.80, 0.0))
	grad.add_point(0.10, Color(1.0, 0.93, 0.82, 0.24))
	grad.add_point(0.45, Color(0.88, 0.87, 0.88, 0.12))
	var gt := GradientTexture1D.new()
	gt.gradient = grad
	pm.color_ramp = gt
	_smoke.process_material = pm

	_smoke.draw_pass_1 = _sprite(
		0.95, FxSprites.puff(0.85, 7), BaseMaterial3D.BLEND_MODE_MIX
	)
	add_child(_smoke)


## A hot core threaded through the plume, additive, only once the ball is really
## moving. Cheap way to make 34 m/s look different from 20 without changing the
## silhouette of the trail.
func _build_heat() -> void:
	_heat = GPUParticles3D.new()
	_heat.amount = 26
	_heat.lifetime = 0.3
	_heat.local_coords = false
	_heat.emitting = false

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = Feel.BALL_RADIUS * 0.35
	pm.spread = 180.0
	pm.initial_velocity_min = 0.0
	pm.initial_velocity_max = 0.7
	pm.gravity = Vector3.ZERO
	pm.damping_min = 3.0
	pm.damping_max = 5.0
	pm.scale_min = 0.4
	pm.scale_max = 0.9

	var scale_curve := Curve.new()
	scale_curve.add_point(Vector2(0.0, 1.0))
	scale_curve.add_point(Vector2(1.0, 0.0))
	var ct := CurveTexture.new()
	ct.curve = scale_curve
	pm.scale_curve = ct

	var grad := Gradient.new()
	grad.set_color(0, Color(1.0, 0.86, 0.55, 0.38))
	grad.set_color(1, Color(1.0, 0.42, 0.12, 0.0))
	var gt := GradientTexture1D.new()
	gt.gradient = grad
	pm.color_ramp = gt
	_heat.process_material = pm

	_heat.draw_pass_1 = _sprite(
		0.7, FxSprites.glow(3.2), BaseMaterial3D.BLEND_MODE_ADD
	)
	add_child(_heat)


## One textured billboard, the shape every particle system here draws.
func _sprite(size: float, tex: Texture2D, blend: int) -> QuadMesh:
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.blend_mode = blend
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.particles_anim_h_frames = 1
	mat.particles_anim_v_frames = 1
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = tex
	mat.disable_receive_shadows = true
	# Without this every puff cuts a hard line across the deck where its quad
	# intersects it, which is the other half of what read as "blocks".
	mat.proximity_fade_enabled = true
	mat.proximity_fade_distance = 0.5
	quad.material = mat
	return quad


# ---------------------------------------------------------------------------
# Ground read
# ---------------------------------------------------------------------------

func _build_ground() -> void:
	_shadow = GroundMark.shadow(1.5)
	add_child(_shadow)
	_marker = GroundMark.glow_ring(0.70, 0.95, 0.10)
	add_child(_marker)


## Where the ball meets the deck if nothing interferes, and how long that takes.
## Integrated rather than solved: `linear_damp` in REPLACE mode is applied by the
## solver as v *= (1 - damp*dt) every step, and pairing that with the closed-form
## ballistic arc lands the marker a metre or so long on a high ball.
func _predict_landing() -> Dictionary:
	var p := _ball.pos
	var v := _ball.vel
	var floor_y := Feel.BALL_RADIUS
	if p.y <= floor_y:
		return {}
	var g := Feel.GRAVITY
	var damp: float = _ball.linear_damp
	var t := 0.0
	while t < PREDICT_MAX_TIME:
		var prev := p
		v.y -= g * PREDICT_STEP
		v *= maxf(0.0, 1.0 - damp * PREDICT_STEP)
		p += v * PREDICT_STEP
		t += PREDICT_STEP
		if p.y <= floor_y:
			# Land on the crossing, not on the step that overshot it.
			var span := prev.y - p.y
			var f := clampf((prev.y - floor_y) / span, 0.0, 1.0) if span > 1e-5 else 1.0
			return {"pos": prev.lerp(p, f), "time": t - PREDICT_STEP * (1.0 - f)}
	return {}


## True while the point is over the playable deck. The marker is a floor read;
## painted onto a wall or over the goal mouth it is worse than nothing.
func _over_pitch(p: Vector3) -> bool:
	if absf(p.x) > Feel.ARENA_HALF_WIDTH - 1.0:
		return false
	if absf(p.z) > Feel.ARENA_HALF_LENGTH - 1.0:
		return false
	return absf(p.x) + absf(p.z) < Feel.ARENA_CORNER_SUM - 1.5


# ---------------------------------------------------------------------------

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
	if _smoke.emitting != emitting:
		_smoke.emitting = emitting
	if emitting:
		_smoke.amount_ratio = 0.3 + fast * 0.7

	var hot := clampf((speed - HEAT_MIN) / (Feel.BALL_MAX_SPEED * 0.5 - HEAT_MIN), 0.0, 1.0)
	var heating := hot > 0.01
	if _heat.emitting != heating:
		_heat.emitting = heating
	if heating:
		_heat.amount_ratio = 0.25 + hot * 0.75

	_update_ground(dt)


func _update_ground(dt: float) -> void:
	var p := _ball.pos
	var height := maxf(0.0, p.y - Feel.BALL_RADIUS)
	var over := _over_pitch(p)

	# --- contact shadow ------------------------------------------------------
	# Spreads and thins with height, the way a real penumbra does.
	var t := clampf(height / SHADOW_FADE_HEIGHT, 0.0, 1.0)
	var spread := Feel.BALL_RADIUS * 2.0 * (1.0 + t * 1.5)
	_shadow.place(
		Vector3(p.x, 0.0, p.z), Vector3.UP, Vector3.BACK, spread, spread,
		Color(0, 0, 0, (0.62 - 0.48 * t) * (1.0 if over else 0.0))
	)

	# --- landing marker ------------------------------------------------------
	var land := _predict_landing() if height > MARKER_MIN_HEIGHT else {}
	if land.is_empty() or not _over_pitch(land["pos"]):
		_land_time = -1.0
		_marker.visible = false
		return

	_land_time = land["time"]
	var at: Vector3 = land["pos"]

	# The ring closes on the ball's own footprint as the touchdown nears, so the
	# marker answers "when" as well as "where" without a number on it...
	var closing := clampf(_land_time / 1.6, 0.0, 1.0)
	var ring := Feel.BALL_RADIUS * 2.0 * (1.0 + closing * 1.1)
	# ...and pulses faster the closer it gets, for the same reason.
	_marker_pulse = fmod(_marker_pulse + dt * lerpf(7.0, 2.2, closing), TAU)
	var beat := 0.78 + 0.22 * sin(_marker_pulse)
	# Fades in over the first half second of flight so a scuffed ball that pops
	# up for a moment does not strobe a marker onto the deck.
	var fade := clampf((height - MARKER_MIN_HEIGHT) / 1.4, 0.0, 1.0)
	_marker.place(
		Vector3(at.x, 0.0, at.z), Vector3.UP, Vector3.BACK, ring, ring,
		Color(1.0, 0.93, 0.66, 0.5 * beat * fade)
	)
