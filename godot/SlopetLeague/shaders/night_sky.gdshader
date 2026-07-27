shader_type sky;
render_mode use_debanding;

// Port of the Blender world node graph in cf/world.py: a horizon -> zenith
// gradient, hard-thresholded Voronoi stars, and a noise cloud band lit from
// below by the stadium, summed and scaled by the background strength.
//
// This exists as much for the ambient light as for the backdrop. With
// ambient_light_source = Sky, every surface is filled according to which way
// it faces instead of by one constant colour, and a single constant fill is a
// large part of what makes a real-time scene read flat.
//
// Blender is Z-up: its Generated coordinate for a world shader is the view
// direction, so its Z is Godot's EYEDIR.y. Coordinates are converted before
// sampling so the star field sits where Blender put it.

group_uniforms gradient;
uniform vec3 horizon : source_color = vec3(0.055, 0.085, 0.170);
uniform vec3 zenith : source_color = vec3(0.010, 0.020, 0.055);
uniform float horizon_pos = 0.30;   // ColorRamp element positions
uniform float zenith_pos = 0.85;

group_uniforms stars;
uniform float star_scale = 260.0;
uniform float star_cutoff = 0.085;  // star_ramp's second element,
                                    // opened up: at Blender's 0.055 and scale
                                    // 420 the stars land sub-pixel and TAA
                                    // eats them entirely
uniform float star_mix = 0.55;      // add2's Factor

group_uniforms clouds;
uniform vec3 cloud_colour : source_color = vec3(0.075, 0.085, 0.115);
uniform float cloud_scale = 3.4;
uniform float cloud_roughness = 0.62;
uniform float cloud_low = 0.42;     // cramp element positions
uniform float cloud_high = 0.72;

group_uniforms output;
uniform float strength = 1.2;       // Background node Strength (3.0 in
                                    // Blender; lower here because Godot has no
                                    // atmospheric haze absorbing it)


vec3 hash33(vec3 p) {
	p = vec3(dot(p, vec3(127.1, 311.7, 74.7)),
			 dot(p, vec3(269.5, 183.3, 246.1)),
			 dot(p, vec3(113.5, 271.9, 124.6)));
	return fract(sin(p) * 43758.5453123);
}

float hash13(vec3 p) {
	return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453123);
}

// Blender's Voronoi F1 "Distance" output.
float voronoi_f1(vec3 p) {
	vec3 cell = floor(p);
	vec3 f = fract(p);
	float best = 8.0;
	for (int k = -1; k <= 1; k++) {
		for (int j = -1; j <= 1; j++) {
			for (int i = -1; i <= 1; i++) {
				vec3 g = vec3(float(i), float(j), float(k));
				vec3 o = hash33(cell + g);
				best = min(best, length(g + o - f));
			}
		}
	}
	return best;
}

float value_noise(vec3 p) {
	vec3 cell = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n = 0.0;
	for (int k = 0; k <= 1; k++) {
		for (int j = 0; j <= 1; j++) {
			for (int i = 0; i <= 1; i++) {
				vec3 g = vec3(float(i), float(j), float(k));
				float w = mix(1.0 - f.x, f.x, g.x)
						* mix(1.0 - f.y, f.y, g.y)
						* mix(1.0 - f.z, f.z, g.z);
				n += hash13(cell + g) * w;
			}
		}
	}
	return n;
}

// Blender's Noise Texture: fBm where Roughness is the per-octave gain.
float fbm(vec3 p, float roughness) {
	float sum = 0.0;
	float amp = 1.0;
	float norm = 0.0;
	for (int i = 0; i < 5; i++) {
		sum += value_noise(p) * amp;
		norm += amp;
		amp *= roughness;
		p *= 2.0;
	}
	return sum / norm;
}


void sky() {
	// Godot Y-up -> the Blender-space direction the node graph was authored in.
	vec3 d = normalize(vec3(EYEDIR.x, -EYEDIR.z, EYEDIR.y));

	// Horizon -> zenith gradient, driven by Blender's Z through a Map Range.
	float up = clamp((d.z - (-0.15)) / (1.0 - (-0.15)), 0.0, 1.0);
	float g = clamp((up - horizon_pos) / (zenith_pos - horizon_pos), 0.0, 1.0);
	vec3 col = mix(horizon, zenith, g);

	// Cloud band, added at full weight.
	float c = fbm(d * cloud_scale, cloud_roughness);
	col += cloud_colour * clamp((c - cloud_low) / (cloud_high - cloud_low), 0.0, 1.0);

	// Stars: sparse high-frequency Voronoi, thresholded hard so only the
	// points nearest a feature survive.
	float v = voronoi_f1(d * star_scale);
	col += vec3(1.0 - clamp(v / star_cutoff, 0.0, 1.0)) * star_mix;

	COLOR = col * strength;
}
