shader_type canvas_item;

// The 4-way anamorphic streak glare from cf/shots.py `add_glare` -- a second
// Glare node stacked on the bloom at strength 0.12, threshold +0.6, 4 streaks,
// 3 iterations, fade 0.88, colour modulation 0.22.
//
// Godot's glow has bloom but no streak mode, so this is a full-screen pass.
// It is a large part of why the Blender floodlights read as broadcast rather
// than as an engine: bloom alone says "bright", streaks say "lens".
//
// One honest difference from Blender: its compositor runs on linear HDR
// before the view transform, whereas a canvas_item shader only ever sees the
// tonemapped image. Highlights here are already rolled off, so the threshold
// is in display terms and the effect is softer than an HDR-side streak would
// be. Running it as a real HDR pass would mean a custom viewport chain, which
// is a lot of machinery for the last few percent.

uniform sampler2D screen : hint_screen_texture, filter_linear_mipmap;

// High, and deliberately so. Blender's Streaks node ran on a sparse HDR
// highlights buffer; on a tonemapped image a low threshold catches the entire
// crowd and smears the frame into haze instead of drawing a star. Only the
// genuinely blown sources -- lenses, jumbo screen, boost cores -- qualify.
uniform float threshold : hint_range(0.0, 1.0) = 0.90;
uniform float strength : hint_range(0.0, 24.0) = 8.0;   // Blender ran 0.12, but on
                                                       // HDR values that reached 20+;
                                                       // this operates on a rolled-off
                                                       // display image where nothing
                                                       // exceeds the threshold by much
uniform float arm_length : hint_range(0.0, 600.0) = 220.0;  // pixels at 1600 wide
uniform float decay : hint_range(0.5, 8.0) = 3.0;       // stands in for fade 0.88
uniform float colour_modulation : hint_range(0.0, 1.0) = 0.22;
uniform float angle_offset : hint_range(0.0, 1.6) = 0.7854;  // 45 deg: a diagonal star
uniform int taps : hint_range(4, 32) = 16;
uniform float enabled : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	vec3 base = texture(screen, SCREEN_UV).rgb;
	if (enabled < 0.001) {
		COLOR = vec4(base, 1.0);
	} else {
		// Streaks are measured in pixels of a 1600-wide frame so the star keeps
		// its proportions when the window is resized.
		vec2 step_uv = SCREEN_PIXEL_SIZE * arm_length
			/ max(float(taps), 1.0) * (1.0 / (SCREEN_PIXEL_SIZE.x * 1600.0));

		vec3 acc = vec3(0.0);
		for (int a = 0; a < 4; a++) {
			float th = angle_offset + float(a) * PI * 0.5;
			vec2 dir = vec2(cos(th), sin(th));
			for (int i = 1; i <= taps; i++) {
				float t = float(i) / float(taps);
				vec3 c = textureLod(screen, SCREEN_UV + dir * step_uv * float(i), 1.0).rgb;
				vec3 hi = max(c - vec3(threshold), vec3(0.0));
				// Colour modulation: the arm disperses cool as it runs out.
				vec3 tint = mix(vec3(1.0),
					vec3(1.0 - t * 0.6, 1.0 - t * 0.15, 1.0 + t * 0.35),
					colour_modulation);
				// Averaged, not summed: without this a broad bright region
				// accumulates once per tap and veils the whole frame.
				acc += hi * exp(-t * decay) * tint / float(taps);
			}
		}
		COLOR = vec4(base + acc * strength, 1.0);
	}
}
