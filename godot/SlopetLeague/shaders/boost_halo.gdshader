shader_type spatial;
render_mode blend_add, depth_draw_never, cull_disabled, unshaded,
	shadows_disabled, fog_disabled;

// The bloom a pad throws on the turf around it: one radial quad, so it has no
// edge and costs two triangles.
//
// It is doing a real job, not just decoration. An emissive material lights
// nothing in Godot unless a GI volume picks it up, and the VoxelGI here is
// baked -- so between bakes this is the only thing that puts the pad's own
// light back on the grass it is sitting on.

uniform vec3 colour : source_color = vec3(1.0, 0.42, 0.07);
uniform float strength = 1.0;
uniform float falloff = 2.2;
uniform float core = 0.06;            // UV radius held at full brightness
uniform float breathe_rate = 1.7;
uniform float breathe_depth = 0.06;

void fragment() {
	float d = length(UV - vec2(0.5));
	float a = pow(clamp((0.5 - d) / (0.5 - core), 0.0, 1.0), falloff);
	ALBEDO = colour * strength * (1.0 + breathe_depth * sin(TIME * breathe_rate));
	ALPHA = a;
}
