shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// The blue-to-orange team ramp, which glTF cannot carry.
//
// Blender drives these colours from a ColorRamp fed by world Y -- `_team_ramp`
// in cf/props.py and `_team_gradient` in cf/structure.py. A node graph has no
// glTF representation, so both materials arrive with the ramp collapsed to
// flat white: the LED fascia ribbon became a pure white band at emission 3.5
// that blew out the top of every frame, and the goal trim lost the warm glow
// that is one of the most recognisable things about the reference.
//
// Blender is Z-up and Godot is Y-up: Blender (x, y, z) -> Godot (x, z, -y),
// so Blender's +Y is Godot's -Z. Blue defends Blender -Y, which is Godot +Z.

uniform vec3 albedo_blue;
uniform vec3 albedo_orange;
uniform vec3 emission_blue;
uniform vec3 emission_orange;
uniform float emission_strength = 1.0;
uniform float roughness_v = 0.5;
uniform float metallic_v = 0.0;
// Half-width of the blend, in metres. Zero reproduces Blender's CONSTANT ramp
// interpolation, which is a hard switch on the halfway line rather than a
// gradient -- that is what the goal trim uses.
uniform float blend_m = 0.0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float t = blend_m > 0.0
		? clamp(0.5 - world_pos.z / (2.0 * blend_m), 0.0, 1.0)
		: step(world_pos.z, 0.0);
	ALBEDO = mix(albedo_blue, albedo_orange, t);
	EMISSION = mix(emission_blue, emission_orange, t) * emission_strength;
	ROUGHNESS = roughness_v;
	METALLIC = metallic_v;
}
