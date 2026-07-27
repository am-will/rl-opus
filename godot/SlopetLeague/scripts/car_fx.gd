class_name CarFx
extends Node3D
## Boost flame, supersonic streaks and the team paint.
##
## Built in code and parented to the car, so a car scene stays two nodes and a
## script. Everything here is presentation — it reads car state and never writes
## any, which keeps it out of the physics path entirely.

## Body paint, LINEAR — `BaseMaterial3D.albedo_color` goes to the shader raw, so
## these are not the sRGB values a colour picker would show. Measured against
## the RL promo shot in `assets/octane_reference/`: its paint sits at sRGB
## #1054d3, hue 219, saturation 0.92, and these land within a degree of that
## once the sRGB conversion is undone. The old pair were both a good deal
## lighter and about 10 degrees toward cyan, which is most of why the car read
## as powder blue rather than as Rocket League blue.
const TEAM_PAINT := [
	Color(0.045, 0.130, 0.78),  # blue
	Color(0.85, 0.335, 0.012),  # orange
]
## Emission tint. Same hue as the paint rather than a pale wash of it: a
## desaturated glow over the panels is exactly what bleached the colour out.
const TEAM_GLOW := [
	Color(0.10, 0.42, 1.0),
	Color(1.0, 0.30, 0.03),
]

## The model's materials are addressed by name, because the mesh names lie —
## `Octane_Body_1` is the chassis. See _dress_model.
const MAT_PAINT := "Octane_Body_Blue"
const MAT_CHASSIS := "Octane_Chassis"
const MAT_RIM := "Octane_OEM_Rim"
const MAT_DISC := "Brake_Disc"
const MAT_HUB := "Hub_Steel"

## The OEM wheel's albedo map. It exists in the source model, but the .glb only
## carries three images — body, chassis, tyre — so the exporter dropped this one
## on the way out and the rim came through as bare metal. The mesh kept its UVs,
## so putting the map back is all it takes.
const RIM_ALBEDO := preload("res://assets/octane_rim_albedo.png")
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


## Team paint on the shell, and repairs to everything the export lost on the way
## out of Blender.
##
## Selection is by MATERIAL, not by node name. The glTF calls both shell meshes
## `Octane_Body_*`, but only `Octane_Body_0` is the painted shell —
## `Octane_Body_1` is the chassis: engine block, headers, roll cage, nudge bar,
## authored as a real albedo map of dark metals with a red block. The old
## `*Body*` name match painted that as well, and a red engine multiplied by team
## blue lands on near-black, so the entire back of the car collapsed into one
## flat blue-grey mass with no material separation left in it. Nothing was
## missing; it had been painted over.
##
## The shell's own texture is a MASK, not a colour map: white over the panels
## that take paint, black over the trim, the vents and the window surrounds. So
## the albedo multiply IS the paint job, and driving emission through the same
## mask keeps the trim from glowing along with the panels.
## Searched from the CAR, not from `Model`: `_build_wheel_pivots` has already
## reparented all twenty-four wheel meshes onto pivots hanging off the car by the
## time this runs, so anything looking under the model alone sees a body, a
## chassis and no wheels at all.
func _paint(car: Car) -> void:
	var paint: Color = TEAM_PAINT[clampi(car.team, 0, 1)]
	var glow: Color = TEAM_GLOW[clampi(car.team, 0, 1)]
	var painted := 0
	for n in car.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		for s in mi.mesh.get_surface_count():
			# get_active_material resolves overrides; surface_get_material alone
			# comes back null on some glTF imports.
			var base := mi.get_active_material(s) as BaseMaterial3D
			if base == null:
				continue
			match base.resource_name:
				MAT_PAINT:
					mi.set_surface_override_material(s, _shell_material(base, paint, glow))
					painted += 1
				MAT_CHASSIS:
					mi.set_surface_override_material(s, _chassis_material(base))
				MAT_RIM:
					mi.set_surface_override_material(s, _rim_material(base))
				MAT_DISC, MAT_HUB:
					mi.set_surface_override_material(s, _brake_material(base))
	if painted == 0:
		push_warning("car: no '%s' surface found; the car is unpainted" % MAT_PAINT)


## Automotive paint: a coloured dielectric under a clear coat, not a metal.
##
## The glTF authors the shell at metallic 0.48, which is a flake paint, and a
## metal takes its colour from what it reflects — under this arena's white
## floodlights that is most of why the panels came out closer to the sky than to
## the team. Dropping metallic to zero puts the colour back in the diffuse, and
## the gloss then comes from the coat, where it belongs.
##
## Godot's glTF importer drops KHR_materials_clearcoat outright (the .glb asks
## for 0.5), and the coat is most of what makes car paint read as car paint —
## the tight white highlight that slides along a fender is the coat, not the
## paint under it. Put it back, harder than authored: RL's cars are showroom.
func _shell_material(base: BaseMaterial3D, paint: Color, glow: Color) -> StandardMaterial3D:
	var mat := base.duplicate() as StandardMaterial3D
	mat.albedo_color = paint
	mat.metallic = 0.0
	mat.metallic_specular = 0.6
	mat.roughness = 0.26
	mat.clearcoat_enabled = true
	mat.clearcoat = 0.9
	mat.clearcoat_roughness = 0.04
	# Enough to hold the team colour at the far end of the pitch, no more. The
	# mask keeps it off the trim; MULTIPLY is what makes the texture a mask
	# rather than something added on top of it.
	mat.emission_enabled = true
	mat.emission = glow
	mat.emission_energy_multiplier = 0.09
	mat.emission_texture = mat.albedo_texture
	mat.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY
	return mat


## The chassis keeps its own texture and its own colours — it is not team
## coloured on a real Octane either. All this does is put back the clear coat
## the importer dropped, which is what lifts the headers and the tank off the
## block instead of leaving them one matte grey.
func _chassis_material(base: BaseMaterial3D) -> StandardMaterial3D:
	var mat := base.duplicate() as StandardMaterial3D
	mat.clearcoat_enabled = true
	mat.clearcoat = 0.3
	mat.clearcoat_roughness = 0.12
	return mat


## The OEM wheel with its albedo map back on it.
##
## Without the map the rim was one flat light metal at roughness 0.23, which
## under a lit stadium is a mirror: it took the sky's colour, filled the gaps
## between the spokes with a bright dish and lost the wheel's shape entirely.
## The map is mostly black with light spokes, which is what gives the real
## Octane its dark-between-the-spokes read. Roughness comes up with it — these
## are cast wheels, not chrome.
func _rim_material(base: BaseMaterial3D) -> StandardMaterial3D:
	var mat := base.duplicate() as StandardMaterial3D
	mat.albedo_texture = RIM_ALBEDO
	mat.albedo_color = Color(1.0, 1.0, 1.0)
	mat.metallic = 0.62
	mat.roughness = 0.36
	return mat


## Brake disc and hub collar, darkened. Both ship near half grey at roughness
## 0.2, and they sit directly behind the spokes — mirror-bright, they read as a
## solid disc and undo the gaps the rim map has just opened up.
func _brake_material(base: BaseMaterial3D) -> StandardMaterial3D:
	var mat := base.duplicate() as StandardMaterial3D
	mat.albedo_color = base.albedo_color * 0.34
	mat.roughness = 0.45
	return mat


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
