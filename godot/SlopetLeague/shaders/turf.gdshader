shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// The pitch, with the parts of cf/materials.py `turf()` that glTF cannot carry.
//
// What survives the export is a baked albedo, a baked emission mask and a
// single roughness number. What does not survive is everything that made the
// surface vary per square metre: a two-octave noise bump (coarse clumping at
// Blender scale 220 mixed 0.45 with per-blade tufting at 1400, strength 0.42,
// distance 0.012), a roughness ramp driven by that same coarse noise and
// remapped to 0.66-0.92 so the mow bands catch the floodlights differently
// across the pitch, and sheen at weight 0.06 for the forward scattering real
// grass has under lights. A perfectly uniform surface under strong lights is
// precisely what reads as cartoon, and the baked albedo is a smooth gradient.
//
// The noise is a tiling FastNoiseLite texture built at import rather than fBm
// evaluated per fragment: the procedural version needed ~240 hash evaluations
// per pixel for the height field and its gradient, which took a capture from
// 25 seconds to over five minutes. Six texture taps do the same job, and the
// mip chain fades the fine octave out with distance for free instead of
// shimmering.
//
// Blender fed those noise nodes Generated coordinates -- the object's
// normalised bounding box -- so the frequencies are its scales over the
// pitch's ~102 m span, applied to world XZ.

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D emission_tex : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D noise_tex : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform float emission_strength = 0.55;

group_uniforms bump;
// UV repeats per metre. The tile holds 10.24 noise wavelengths (FastNoiseLite
// frequency 0.02 over 512 px), so a Blender scale of N over the pitch's ~102 m
// span wants 10.24 * N / 102 repeats per metre.
uniform float clump_freq = 0.217;     // Blender scale 220 -> 0.46 m features
uniform float blade_freq = 1.34;      // Blender scale 1400 -> 7 cm tufting
uniform float blade_mix = 0.45;       // the Mix node's Factor
uniform float bump_strength = 0.42;   // the Bump node's Strength
// The Bump node's Distance, and the reason this used to look like coral. It
// is the height the 0..1 field stands for, in METRES -- so the fine octave's
// gradient is about 13/m of height, 0.16 of slope, and under two degrees of
// normal once Strength and the mix factor are in. Without it the field was
// read as a metre of relief per unit and the pitch turned into a relief map.
uniform float bump_distance = 0.012;
// Central-difference step. Must resolve the 7 cm fine octave: at the old
// 0.25 m the two taps landed three wavelengths apart and the "gradient" was
// pure aliasing, which is what the coral pattern actually was.
uniform float bump_epsilon = 0.01;

group_uniforms roughness;
uniform float rough_min = 0.66;       // Map Range To Min / To Max
uniform float rough_max = 0.92;

group_uniforms sheen;
uniform float sheen_weight = 0.06;
uniform float sheen_roughness = 0.5;

varying vec3 world_pos;
varying vec3 world_normal;


float height_at(vec2 p) {
	float clump = texture(noise_tex, p * clump_freq).r;
	float blade = texture(noise_tex, p * blade_freq + vec2(0.37, 0.11)).r;
	return mix(clump, blade, blade_mix);
}


void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	ALBEDO = texture(albedo_tex, UV).rgb;
	METALLIC = 0.0;
	SPECULAR = 0.5;

	// Central differences on the height field, then perturb along the part of
	// the gradient tangential to the surface -- which keeps working on the
	// ramps up into the wall fillets, not just on the flat of the pitch.
	// Scaling by bump_distance turns the 0..1 field into metres of relief, so
	// what comes out is a slope and `bump_strength` means what it means in
	// Blender. The mip chain fades the fine octave with distance for free:
	// far enough away both taps land in the same texel and the gradient goes
	// to zero, which is exactly the right answer.
	float e = bump_epsilon;
	vec2 p = world_pos.xz;
	float hx = height_at(p + vec2(e, 0.0)) - height_at(p - vec2(e, 0.0));
	float hz = height_at(p + vec2(0.0, e)) - height_at(p - vec2(0.0, e));
	vec3 grad = vec3(hx, 0.0, hz) * bump_distance / (2.0 * e);
	grad -= world_normal * dot(grad, world_normal);
	vec3 n = normalize(world_normal - grad * bump_strength);
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);

	// Roughness rides the coarse octave only, so whole clumps of grass catch
	// the floodlights together instead of speckling.
	ROUGHNESS = mix(rough_min, rough_max,
		clamp(texture(noise_tex, p * clump_freq).r, 0.0, 1.0));

	// Godot has no sheen lobe; rim is the closest thing to the forward
	// scattering the Principled sheen was doing at weight 0.06.
	RIM = sheen_weight;
	RIM_TINT = sheen_roughness;

	EMISSION = texture(emission_tex, UV).rgb * emission_strength;
}
