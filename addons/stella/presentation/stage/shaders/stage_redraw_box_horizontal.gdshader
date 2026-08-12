shader_type canvas_item;
render_mode unshaded, blend_disabled;

// First half of an authored rectangular box average. Pointwise effects before
// this blur are evaluated for every input sample. Each channel's integer byte
// sum is stored losslessly as a finite half-float bit pattern in an HDR target;
// the vertical half decodes it and quantizes only at the authored pass boundary.
const int MAX_EFFECTS = 16;
const int MAX_RADIUS = 32;
const int EFFECT_COLOR_OVERLAY = 1;
const int EFFECT_BRIGHTNESS_CONTRAST = 2;
const int EFFECT_GRAYSCALE = 3;
const int EFFECT_TINT = 4;
const int EFFECT_CLIP = 5;
const int BLEND_SOFT_LIGHT = 1;

uniform sampler2D input_texture : repeat_disable, filter_nearest;
uniform vec2 render_size = vec2(1.0);
uniform vec2 render_origin = vec2(0.0);
uniform vec2 blur_axis = vec2(1.0, 0.0);
uniform int blur_radius = 0;
uniform int effect_count = 0;
uniform vec4 effect_parameters[MAX_EFFECTS];
uniform vec4 effect_colors[MAX_EFFECTS];
uniform sampler2D clip_texture : hint_default_transparent, repeat_disable, filter_linear;
uniform bool clip_available = false;
uniform vec4 clip_rect = vec4(0.0, 0.0, 1.0, 1.0);

int to_byte(float value) {
	return int(floor(clamp(value, 0.0, 1.0) * 255.0 + 0.5));
}

ivec3 to_bytes(vec3 value) {
	return ivec3(to_byte(value.r), to_byte(value.g), to_byte(value.b));
}

ivec4 to_bytes(vec4 value) {
	return ivec4(
		to_byte(value.r),
		to_byte(value.g),
		to_byte(value.b),
		to_byte(value.a)
	);
}

vec3 from_bytes(ivec3 value) {
	return vec3(value) / 255.0;
}

vec4 from_bytes(ivec4 value) {
	return vec4(value) / 255.0;
}

int alpha_blend_256(int destination, int blended, int alpha) {
	return clamp(
		destination + (((blended - destination) * alpha) >> 8),
		0,
		255
	);
}

int soft_light_table(int source, int destination) {
	float source_unit = float(source) / 255.0;
	float destination_unit = float(destination) / 255.0;
	float exponent;
	if (source >= 128) {
		exponent = 128.0 / float(source);
	} else {
		exponent = (1.0 - source_unit) / 0.5;
	}
	return int(floor(pow(destination_unit, exponent) * 255.0));
}

ivec3 apply_color_overlay(ivec3 destination, vec4 color, int blend_mode) {
	ivec3 source = to_bytes(color.rgb);
	int alpha = to_byte(color.a);
	ivec3 blended = source;
	if (blend_mode == BLEND_SOFT_LIGHT) {
		blended = ivec3(
			soft_light_table(source.r, destination.r),
			soft_light_table(source.g, destination.g),
			soft_light_table(source.b, destination.b)
		);
	}
	return ivec3(
		alpha_blend_256(destination.r, blended.r, alpha),
		alpha_blend_256(destination.g, blended.g, alpha),
		alpha_blend_256(destination.b, blended.b, alpha)
	);
}

ivec3 apply_brightness_contrast(ivec3 value, int brightness, int contrast) {
	float multiplier = float(100 + contrast) / 100.0;
	return clamp(
		ivec3(
			vec3(value - ivec3(128)) * multiplier
				+ vec3(float(brightness + 128))
		),
		ivec3(0),
		ivec3(255)
	);
}

ivec3 apply_grayscale(ivec3 value, float amount) {
	int gray = (54 * value.r + 183 * value.g + 19 * value.b) >> 8;
	return ivec3(floor(mix(
		vec3(value),
		vec3(float(gray)),
		clamp(amount, 0.0, 1.0)
	) + vec3(0.5)));
}

float clip_alpha(vec2 local_position) {
	if (!clip_available) {
		return 0.0;
	}
	vec2 rect_size = max(clip_rect.zw, vec2(0.0001));
	vec2 clip_uv = (local_position - clip_rect.xy) / rect_size;
	if (
		any(lessThan(clip_uv, vec2(0.0)))
		|| any(greaterThanEqual(clip_uv, vec2(1.0)))
	) {
		return 0.0;
	}
	return texture(clip_texture, clip_uv).a;
}

vec4 apply_effects(vec4 color, vec2 local_position) {
	for (int index = 0; index < MAX_EFFECTS; index++) {
		if (index >= effect_count) {
			break;
		}
		vec4 parameters = effect_parameters[index];
		vec4 effect_color = effect_colors[index];
		int effect_type = int(parameters.x + 0.5);
		if (effect_type == EFFECT_COLOR_OVERLAY) {
			color.rgb = from_bytes(apply_color_overlay(
				to_bytes(color.rgb),
				effect_color,
				int(parameters.y + 0.5)
			));
		} else if (effect_type == EFFECT_BRIGHTNESS_CONTRAST) {
			color.rgb = from_bytes(apply_brightness_contrast(
				to_bytes(color.rgb),
				int(parameters.y),
				int(parameters.z)
			));
		} else if (effect_type == EFFECT_GRAYSCALE) {
			color.rgb = from_bytes(apply_grayscale(
				to_bytes(color.rgb),
				parameters.y
			));
		} else if (effect_type == EFFECT_TINT) {
			color.rgb = from_bytes(to_bytes(color.rgb * effect_color.rgb));
			color.a *= clamp(effect_color.a, 0.0, 1.0);
		} else if (effect_type == EFFECT_CLIP) {
			color.a *= clip_alpha(local_position);
		}
	}
	return color;
}

uvec4 sample_premultiplied_bytes(vec2 uv, vec2 local_position) {
	vec4 premultiplied = textureLod(input_texture, uv, 0.0);
	if (effect_count == 0) {
		return uvec4(to_bytes(premultiplied));
	}
	vec4 straight = premultiplied;
	if (straight.a > 0.0001) {
		straight.rgb /= straight.a;
	} else {
		straight.rgb = vec3(0.0);
	}
	straight = apply_effects(straight, local_position);
	return uvec4(to_bytes(vec4(straight.rgb * straight.a, straight.a)));
}

float encode_sum(uint value) {
	// radius <= 32 means value <= 65 * 255 = 16575. Adding 0x0400
	// maps every possible integer to a distinct finite positive binary16 bit
	// pattern (0x0400..0x44bf), so an RGBA16F viewport round-trips it exactly.
	return unpackHalf2x16(value + 1024u).x;
}

void fragment() {
	int radius = clamp(blur_radius, 0, MAX_RADIUS);
	uvec4 sum = uvec4(0u);
	for (int offset = -radius; offset <= radius; offset++) {
		vec2 pixel_offset = blur_axis * float(offset);
		vec2 sample_uv = UV + pixel_offset / render_size;
		vec2 local_position = render_origin + UV * render_size + pixel_offset;
		sum += sample_premultiplied_bytes(sample_uv, local_position);
	}
	COLOR = vec4(
		encode_sum(sum.r),
		encode_sum(sum.g),
		encode_sum(sum.b),
		encode_sum(sum.a)
	);
}
