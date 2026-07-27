@tool
extends EditorScenePostImport
## Fixes the Blender -> glTF -> Godot round-trip at IMPORT time, so the editor
## viewport and the running game both look right. Doing this in a _ready()
## handler instead only fixes play mode and leaves the editor blown out.
##
## Three things glTF gets wrong:
##
## 1. Light intensity is exported photometrically. Blender's 105 kW floodlights
##    arrive as light_energy ~5.7 million against a Godot default of 1.0, which
##    clips every pixel to white.
## 2. All eight Blender cameras come along and the importer marks one current,
##    hijacking the viewport from whatever camera the scene actually wants.
## 3. Godot ignores COLOR_0 unless the material opts in (crowd and bunting
##    arrive white), and node-graph-driven colour has no equivalent at all.
##
## glTF also has no area light type, so the 21 fill / team / bowl / cove /
## exterior lights in `cf/lighting.py` are simply absent. They are rebuilt here
## from the same positions, aim targets and colours, as spots rather than the
## omnis that used to stand in for them -- an omni radiates in every direction,
## which is exactly how a scene loses its lighting structure.

# --- floodlights ------------------------------------------------------------
# The 18 spots do survive glTF; what does not survive is any sense of falloff.
#
# Godot's attenuation is not the curve it looks like. The shader computes
#
#     window(d / range) * pow(d, -attenuation)
#
# so `spot_attenuation` is a decay exponent applied to the raw distance in
# METRES, and `spot_range` only supplies a soft cutoff window. That matters
# enormously at stadium scale: the floodlight ring sits 136-149 m from the
# pitch centre and 74.5 m up, and at 148 m an exponent of 1.6 divides the
# light by 3000. The old 0.6 lit the near boards and the far corner within
# 20% of each other, which is why the bowl read flat; anything close to
# physical needs the energy scaled up to match, hence the large number below.
# 2.0 is true inverse-square, the same falloff Blender's 105 kW spots use.
const FLOOD_ENERGY := 1650.0
const FLOOD_RANGE := 420.0
const FLOOD_ATTEN := 2.0
const FLOOD_FOG := 1.6            # beam contribution to the volumetric fog
const SHADOW_FLOODS := 12         # of 18; multi-source shadowing is the look

# --- emission ---------------------------------------------------------------
# Blender ran the wall strips at 3.2 and the floodlight lenses at 26.0, at
# exposure 0 EV. The old 1.6 cap was a defensive measure from when the scene
# blew out to white, and it flattened precisely the elements that should be
# the brightest things in frame. With tonemap_exposure back at 1.0 these can
# now be Blender's own numbers, so the cap only exists as a safety rail.
const EMISSION_CAP := 8.0
const LENS_EMISSION := 26.0

const S := 0.01                   # uu -> metres, matches cf/const.py

# Blender is Z-up, glTF is Y-up: Blender (x, y, z) -> Godot (x, z, -y), so the
# pitch runs along Godot's Z and blue defends +Z.
const CEIL_Z := 2044.0            # cf/const.py
const BACK_Y := 5120.0

# Alpha-blended in Blender, alpha-to-coverage here -- see _to_alpha_coverage.
const CUTOUT_MATERIALS := ["CF_Wall", "CF_Ceiling", "CF_GoalNet"]

const BLUE_HOT := Color(0.35, 0.72, 1.00)
const ORANGE_HOT := Color(1.00, 0.66, 0.24)

# cf/lighting.py: arena.ring(-(stands.TIERS[0][0] + 300.0)) sampled at 10 even
# steps. Evaluated once and inlined rather than reimplementing the ring solver.
const BOWL_RING := [
	Vector2(5098.7, -5298.7), Vector2(5746.0, 339.6), Vector2(5023.8, 5373.7),
	Vector2(3082.2, 6738.8), Vector2(-3203.8, 6714.6), Vector2(-5098.7, 5298.7),
	Vector2(-5746.0, -339.6), Vector2(-5023.8, -5373.7),
	Vector2(-3082.2, -6738.8), Vector2(3203.8, -6714.6),
]


static func to_godot(uu: Vector3) -> Vector3:
	return Vector3(uu.x * S, uu.z * S, -uu.y * S)


func _post_import(scene: Node) -> Object:
	var nodes: Array = []
	_walk(scene, nodes)

	var flood := 0
	for n in nodes:
		if n is Light3D:
			n.light_energy = FLOOD_ENERGY
			if n is SpotLight3D:
				n.spot_attenuation = FLOOD_ATTEN
				n.spot_range = FLOOD_RANGE
				n.shadow_bias = 0.06
				n.shadow_normal_bias = 1.5
				n.light_volumetric_fog_energy = FLOOD_FOG
				n.shadow_enabled = flood < SHADOW_FLOODS
				flood += 1
		elif n is Camera3D:
			n.current = false
		elif n is MeshInstance3D and n.mesh != null:
			_fix_materials(n)

	_rebuild_area_lights(scene)
	return scene


func _fix_materials(mi: MeshInstance3D) -> void:
	var vertex_coloured: bool = mi.name.begins_with("CF_Crowd") \
		or mi.name.begins_with("CF_Bunting")
	var lens: bool = mi.name.begins_with("CF_FloodLenses")
	for i in mi.mesh.get_surface_count():
		var m: Material = mi.mesh.surface_get_material(i)
		if not (m is StandardMaterial3D):
			continue
		if m.resource_name == "CF_Turf":
			mi.set_surface_override_material(i, _turf_material(m))
			continue
		if m.resource_name in CUTOUT_MATERIALS:
			_to_alpha_coverage(m)
		if vertex_coloured:
			m.vertex_color_use_as_albedo = true
		if m.emission_enabled:
			var ceiling := LENS_EMISSION if lens else EMISSION_CAP
			m.emission_energy_multiplier = minf(
				m.emission_energy_multiplier, ceiling)


## Alpha blending is where a real-time renderer looks worst, and the three
## meshes using it here are all fine lattices seen edge-on through each other:
## the containment net above the boards, the hex canopy and the goal net. They
## do not write depth, so they sort against each other by draw order and the
## net reads as a heavy white grid instead of thin wire.
##
## Alpha-to-coverage resolves them through MSAA instead. With msaa_3d already
## at 4x that keeps soft edges, fixes the sorting outright, and lets them write
## depth so SSAO and SSR see them.
func _to_alpha_coverage(m: StandardMaterial3D) -> void:
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	m.alpha_scissor_threshold = 0.5
	m.alpha_antialiasing_mode = \
		BaseMaterial3D.ALPHA_ANTIALIASING_ALPHA_TO_COVERAGE_AND_TO_ONE
	m.alpha_antialiasing_edge = 0.3


## Swap the pitch onto shaders/turf.gdshader, keeping the baked maps.
##
## glTF delivers the turf as a flat albedo, a flat emission mask and one
## uniform roughness -- no trace of the two-octave bump, the noise-driven
## roughness ramp or the sheen that cf/materials.py gave it. A perfectly
## uniform surface under strong lights is exactly what reads as cartoon.
func _turf_material(src: StandardMaterial3D) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/turf.gdshader")
	m.resource_name = "CF_Turf"
	m.set_shader_parameter("albedo_tex", src.albedo_texture)
	m.set_shader_parameter("emission_tex", src.emission_texture)
	m.set_shader_parameter("noise_tex", _turf_noise())
	# glTF carries Blender's 0.55 emission strength as the emissive factor.
	m.set_shader_parameter("emission_strength",
		src.emission.r * src.emission_energy_multiplier if src.emission_enabled else 0.0)
	return m


## One seamless fBm tile, sampled at two frequencies for the two octaves.
## Baking it beats evaluating fBm per fragment by two orders of magnitude, and
## the mip chain fades the fine octave out with distance instead of shimmering.
func _turf_noise() -> NoiseTexture2D:
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = 0.02
	n.fractal_octaves = 4
	n.fractal_gain = 0.65          # Blender's Noise Roughness
	var t := NoiseTexture2D.new()
	t.noise = n
	t.width = 512
	t.height = 512
	t.seamless = true
	t.generate_mipmaps = true
	return t


# --- the 21 lights glTF cannot carry ----------------------------------------

func _rebuild_area_lights(scene: Node) -> void:
	# FILL: a 140 m disk 72 m up. The one light here that really is omni-ish;
	# everything else below is aimed and belongs in a cone.
	_omni(scene, "FILL", Vector3(0, 0, CEIL_Z + 5200), Color(0.86, 0.91, 1.0),
		8.0, 300.0, 1.0)

	# TEAM: 90 x 26 rectangles at each end, aimed back at the pitch. This is
	# what tints the two halves. Blue defends Blender -Y, which is Godot +Z.
	for sy in [-1.0, 1.0]:
		var col := BLUE_HOT if sy < 0.0 else ORANGE_HOT
		_spot(scene, "TEAM_%d" % int(sy),
			Vector3(0, sy * (BACK_Y + 1400), 2600), Vector3(0, sy * 1200, 0),
			col, 19.0, 130.0, 200.0, 1.0)

	# BOWL: ten strips on the lower-tier lip, aimed up and out across the
	# seating. The pitch fill has to stay low for contrast, so the crowd needs
	# its own light or the bowl goes muddy.
	for b in BOWL_RING.size():
		var p: Vector2 = BOWL_RING[b]
		_spot(scene, "BOWL_%d" % b,
			Vector3(p.x, p.y, CEIL_Z + 500), Vector3(p.x * 1.5, p.y * 1.5, 3000),
			Color(1.0, 0.95, 0.87), 60.0, 165.0, 150.0, 1.2)

	# COVE: warm under-roof strips that separate the bowl from the night sky.
	for sy in [-1.0, 1.0]:
		for sx in [-1.0, 1.0]:
			_spot(scene, "COVE_%d%d" % [int(sx), int(sy)],
				Vector3(sx * 5600, sy * 6200, 7000),
				Vector3(sx * 1800, sy * 2200, 1200),
				Color(0.95, 0.93, 0.92), 16.0, 140.0, 160.0, 1.0)

	# EXT: top light on the roof so the bowl reads from outside. Only the
	# aerial shot ever sees these.
	for sy in [-1.0, 1.0]:
		for sx in [-1.0, 1.0]:
			_spot(scene, "EXT_%d%d" % [int(sx), int(sy)],
				Vector3(sx * 12000, sy * 14000, 26000),
				Vector3(sx * 8600, sy * 10400, 9900),
				Color(0.62, 0.72, 1.0), 95.0, 44.0, 600.0, 1.0)


func _spot(scene: Node, name: String, pos_uu: Vector3, aim_uu: Vector3,
		colour: Color, energy: float, angle: float, rng: float,
		atten: float) -> void:
	var l := SpotLight3D.new()
	l.name = name
	l.light_color = colour
	l.light_energy = energy
	# Blender's spot_size is a full cone; Godot's spot_angle is the half angle.
	# Every light rebuilt here was a RECTANGLE or DISK area light, though, and
	# an area light emits over the whole hemisphere in front of it rather than
	# down a cone. Ported at their nominal widths these lit the upper deck in
	# ten tight pools and left the lower tiers black, so the angles below are
	# opened up towards hemispherical and the attenuation kept soft.
	l.spot_angle = minf(angle * 0.5, 89.0)
	l.spot_angle_attenuation = 0.4
	l.spot_range = rng
	l.spot_attenuation = atten
	l.shadow_enabled = false        # every one of these was use_shadow=False
	l.light_volumetric_fog_energy = 0.2
	_attach(scene, l, pos_uu)
	# look_at() needs the node inside a tree; nothing is, during import.
	l.look_at_from_position(l.position, to_godot(aim_uu), Vector3.UP)


func _omni(scene: Node, name: String, pos_uu: Vector3, colour: Color,
		energy: float, rng: float, atten: float) -> void:
	var l := OmniLight3D.new()
	l.name = name
	l.light_color = colour
	l.light_energy = energy
	l.omni_range = rng
	l.omni_attenuation = atten
	l.shadow_enabled = false
	l.light_volumetric_fog_energy = 0.2
	_attach(scene, l, pos_uu)


func _attach(scene: Node, l: Light3D, pos_uu: Vector3) -> void:
	scene.add_child(l)
	l.owner = scene
	l.position = to_godot(pos_uu)


func _walk(n: Node, out: Array) -> void:
	out.append(n)
	for c in n.get_children():
		_walk(c, out)
