shader_type canvas_item;
render_mode unshaded;

uniform sampler2D source_texture : filter_nearest, repeat_disable;
uniform sampler2D target_texture : filter_nearest, repeat_disable;
uniform sampler2D mask_texture : filter_nearest, repeat_disable;
uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform float softness : hint_range(0.0, 1.0) = 0.0;
uniform bool invert_mask = false;

void fragment() {
	vec4 from_color = texture(source_texture, UV);
	vec4 to_color = texture(target_texture, UV);
	if (progress <= 0.0) {
		COLOR = from_color;
	} else if (progress >= 1.0) {
		COLOR = to_color;
	} else {
		vec3 mask_rgb = texture(mask_texture, UV).rgb;
		// Stored sRGB bytes are treated as data. The coefficients match Stella's
		// byte-defined grayscale rule and are intentionally not linearized.
		float luminance = dot(mask_rgb, vec3(54.0, 183.0, 19.0)) / 256.0;
		if (invert_mask) {
			luminance = 1.0 - luminance;
		}
		float reveal = step(luminance, progress);
		if (softness > 0.0) {
			float half_width = softness * 0.5;
			reveal = 1.0 - smoothstep(
				progress - half_width,
				progress + half_width,
				luminance
			);
		}
		COLOR = mix(from_color, to_color, reveal);
	}
}
