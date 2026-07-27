shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley,
	specular_schlick_ggx;

// The orb over a 100 pad.
//
// Shaded and opaque, not an additive shell, which is the whole point: the
// reference orb is a polished thing with a light inside it, so it catches the
// floodlights as a hard specular highlight and picks up the arena around it.
// An unshaded additive sphere cannot do either -- it has no surface to reflect
// with, and it reads as a flat disc of colour however bright it is made.
//
// So the surface is a low-roughness dielectric-to-metal blend that the sky
// reflection and SSR both reach, and the light inside it is EMISSION shaped
// three ways: hot through the middle of the disc, sodium orange at the
// silhouette, and lifted again by a fresnel term so the rim reads as a shell
// around a source rather than the edge of a ball.
//
// glTF carries none of this (the Blender side is a Layer Weight graph in
// cf/props.py `boost_materials`), so it is rebuilt here rather than imported.

uniform vec3 core_colour : source_color = vec3(1.0, 0.86, 0.55);
uniform vec3 rim_colour : source_color = vec3(1.0, 0.24, 0.03);
// What the shell itself is made of. Dark, because everything bright about the
// orb should be light it is emitting or light it is reflecting.
uniform vec3 shell_colour : source_color = vec3(0.20, 0.07, 0.02);
uniform float emission_strength = 2.2;
uniform float rim_boost = 1.2;
uniform float metallic_v = 0.45;
uniform float roughness_v = 0.14;

uniform sampler2D noise_tex : hint_default_white, repeat_enable;
uniform float mottle_scale = 3.0;
uniform float mottle_depth = 0.22;
uniform float spin = 0.035;           // convection creep across the surface
uniform float pulse_rate = 2.3;
uniform float pulse_depth = 0.07;

void fragment() {
	float ndv = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);

	float n = texture(noise_tex,
		UV * mottle_scale + vec2(TIME * spin, TIME * spin * 0.6)).r;
	float mottle = 1.0 + mottle_depth * (n * 2.0 - 1.0);
	float pulse = 1.0 + pulse_depth * sin(TIME * pulse_rate);

	ALBEDO = shell_colour;
	METALLIC = metallic_v;
	ROUGHNESS = roughness_v;

	vec3 body = mix(rim_colour, core_colour, smoothstep(0.10, 0.92, ndv));
	float fresnel = pow(1.0 - ndv, 3.0);
	EMISSION = (body * mottle + rim_colour * fresnel * rim_boost)
		* emission_strength * pulse;
}
