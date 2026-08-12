shader_type canvas_item;
render_mode unshaded, blend_disabled;

// Completes one authored rectangular box average. It decodes lossless integer
// sums from the HDR first-axis target, accumulates the second axis, then rounds
// exactly once at the authored 8-bit pass boundary.
const int MAX_RADIUS = 32;

uniform sampler2D input_texture : repeat_disable, filter_nearest;
uniform vec2 render_size = vec2(1.0);
uniform vec2 blur_axis = vec2(0.0, 1.0);
uniform int first_axis_sample_count = 1;
uniform int blur_radius = 0;

uint decode_sum(float value) {
	return (packHalf2x16(vec2(value, 0.0)) & 65535u) - 1024u;
}

uvec4 decode_sum(vec4 value) {
	return uvec4(
		decode_sum(value.r),
		decode_sum(value.g),
		decode_sum(value.b),
		decode_sum(value.a)
	);
}

void fragment() {
	int radius = clamp(blur_radius, 0, MAX_RADIUS);
	uvec4 sum = uvec4(0u);
	for (int offset = -radius; offset <= radius; offset++) {
		vec2 sample_uv = UV + blur_axis * float(offset) / render_size;
		sum += decode_sum(textureLod(input_texture, sample_uv, 0.0));
	}
	uint sample_count = uint(
		max(first_axis_sample_count, 1) * (radius * 2 + 1)
	);
	uvec4 average = (sum + uvec4(sample_count / 2u)) / sample_count;
	COLOR = vec4(average) / 255.0;
}
