shader_type spatial;
render_mode blend_add, depth_draw_never, cull_disabled, unshaded,
	shadows_disabled, fog_disabled;

// The curtains of light standing in a boost pad's vents.
//
// glTF cannot carry any of what makes these read as fire. Blender drives their
// alpha from a ColorRamp on V, a fold on U and an eroding noise (`boost_materials`
// in cf/props.py); a node graph has no glTF representation, so the whole lot
// exports as ALPHA = 1 and the pads arrive as solid tapered cylinders -- which
// is exactly what they looked like here before this shader existed.
//
// Rebuilt rather than approximated: the geometry carries the same UVs Blender
// shapes the falloff along, so this is the same three curves plus the one thing
// a still cannot have, which is movement.
//
// Additive, not alpha-blended. Blender composites these over the frame; a
// real-time pass that does the same has to sort them against each other and
// against the plume, and any sorting error on a translucent sheet reads as a
// hard edge. Adding light has no order.

uniform vec3 hot : source_color = vec3(1.0, 0.78, 0.40);
uniform vec3 cool : source_color = vec3(1.0, 0.22, 0.02);
uniform float strength = 2.4;

uniform sampler2D noise_tex : hint_default_white, repeat_enable;
// U is stretched far harder than V so the noise is drawn out into strands
// running up the sheet instead of blotches sitting on it.
uniform vec2 noise_scale = vec2(7.0, 1.6);
uniform float scroll = 0.55;          // V per second, upward
uniform float rise = 0.78;            // V at which the sheet is gone
uniform float base_alpha = 0.42;
uniform float end_taper = 0.16;       // U fade at both ends of an arc
// Erosion thresholds. Remapping the noise through these clips it to nothing
// over part of the sheet, so the curtain tears into strands with a ragged
// edge; multiplying by it only makes an even sheet blotchy.
uniform float erode_lo = 0.34;
uniform float erode_hi = 0.78;
uniform float heat_span = 0.55;       // V over which hot cools to cool
// Fade where the sheet turns edge-on. A closed column is still a cylinder, and
// a cylinder has two dead-straight verticals for a silhouette; softening them
// by how squarely the surface faces the camera is what stops the plume reading
// as a block of fire with sides.
uniform float edge_soft = 0.38;

void fragment() {
	// Blender's V runs 0 at the deck to 1 at the tip; glTF's V origin is the
	// other corner and the exporter flips it, so in Godot the deck is V = 1.
	// Reading it unflipped hangs the fire upside down -- cool and thin at the
	// vent, white-hot and solid where it should be dissolving into air -- and
	// it is not obvious from a still that that is what you are looking at.
	float v = 1.0 - UV.y;

	// Falls off with height, and tapers at both ends of an arc. A closed
	// column is mapped into the middle of U by cf/props.py `_curtain` so it
	// never reaches the taper -- otherwise its seam draws a dark stripe.
	float body = 1.0 - smoothstep(0.0, rise, v);
	float ends = smoothstep(0.0, end_taper, min(UV.x, 1.0 - UV.x));

	vec2 nuv = vec2(UV.x, v) * noise_scale;
	nuv.y -= TIME * scroll;
	float n = texture(noise_tex, nuv).r;
	// A second, slower and coarser layer so the strands do not travel as one
	// rigid sheet of pattern.
	float n2 = texture(noise_tex,
		nuv * vec2(1.9, 0.7) + vec2(0.37, -TIME * scroll * 0.55)).r;
	n = mix(n, n2, 0.45);
	float shred = smoothstep(erode_lo, erode_hi, n);

	float facing = edge_soft > 0.0
		? smoothstep(0.0, edge_soft, abs(dot(normalize(NORMAL), normalize(VIEW))))
		: 1.0;

	ALBEDO = mix(hot, cool, smoothstep(0.0, heat_span, v)) * strength;
	ALPHA = clamp(base_alpha * body * ends * shred * facing, 0.0, 1.0);
}
