shader_type canvas_item;
render_mode unshaded;

// CanvasGroup screen reads cannot be nested as a deterministic ping-pong
// pipeline. This stable pass evaluates authored effects in order. At the one
// allowed blur position it applies the prefix to every neighborhood sample,
// averages premultiplied values with Stella's nine-tap kernel, then applies the
// suffix to the result.
const int MAX_EFFECTS = 16;
const int EFFECT_COLOR_OVERLAY = 1;
const int EFFECT_BRIGHTNESS_CONTRAST = 2;
const int EFFECT_GRAYSCALE = 3;
const int EFFECT_TINT = 4;
const int EFFECT_CLIP = 5;
const int EFFECT_BLUR = 6;
const int BLEND_NORMAL = 0;
const int BLEND_SOFT_LIGHT = 1;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;
uniform int effect_count = 0;
uniform vec4 effect_parameters[MAX_EFFECTS];
uniform vec4 effect_colors[MAX_EFFECTS];
uniform int blur_effect_index = -1;
uniform vec2 blur_radius = vec2(0.0);

uniform sampler2D clip_texture : hint_default_transparent, repeat_disable, filter_linear;
uniform bool clip_available = false;
uniform vec4 clip_rect = vec4(0.0, 0.0, 1.0, 1.0);

varying vec2 layer_local_position;
varying vec2 local_x_screen_uv;
varying vec2 local_y_screen_uv;

int to_byte(float value) {
	return int(floor(clamp(value, 0.0, 1.0) * 255.0 + 0.5));
}

ivec3 to_bytes(vec3 value) {
	return ivec3(
		to_byte(value.r),
		to_byte(value.g),
		to_byte(value.b)
	);
}

vec3 from_bytes(ivec3 value) {
	return vec3(value) / 255.0;
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

vec4 sample_encoded_straight(vec2 screen_uv) {
	vec4 color = textureLod(screen_texture, screen_uv, 0.0);
	if (color.a > 0.0001) {
		color.rgb /= color.a;
	} else {
		color.rgb = vec3(0.0);
	}
	return color;
}

vec4 apply_effect_range(
	vec4 color,
	vec2 local_position,
	int first_effect,
	int after_last_effect
) {
	for (int index = 0; index < MAX_EFFECTS; index++) {
		if (index >= effect_count || index >= after_last_effect) {
			break;
		}
		if (index < first_effect) {
			continue;
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
			float gray = dot(color.rgb, vec3(0.299, 0.587, 0.114));
			color.rgb = from_bytes(to_bytes(mix(
				color.rgb,
				vec3(gray),
				clamp(parameters.y, 0.0, 1.0)
			)));
		} else if (effect_type == EFFECT_TINT) {
			color.rgb = from_bytes(to_bytes(color.rgb * effect_color.rgb));
			color.a *= clamp(effect_color.a, 0.0, 1.0);
		} else if (effect_type == EFFECT_CLIP) {
			color.a *= clip_alpha(local_position);
		} else if (effect_type == EFFECT_BLUR) {
			// The blur itself is evaluated between the prefix and suffix.
		}
	}
	return color;
}

vec4 prefix_sample(
	vec2 screen_uv,
	vec2 local_position,
	int prefix_end
) {
	vec4 color = sample_encoded_straight(screen_uv);
	color = apply_effect_range(color, local_position, 0, prefix_end);
	color.rgb *= color.a;
	return color;
}

void vertex() {
	layer_local_position = VERTEX;
	mat4 local_to_clip = SCREEN_MATRIX * CANVAS_MATRIX * MODEL_MATRIX;
	vec4 origin_clip = local_to_clip * vec4(0.0, 0.0, 0.0, 1.0);
	vec4 x_clip = local_to_clip * vec4(1.0, 0.0, 0.0, 1.0);
	vec4 y_clip = local_to_clip * vec4(0.0, 1.0, 0.0, 1.0);
	vec2 origin_uv = origin_clip.xy / origin_clip.w
		* vec2(0.5, -0.5) + vec2(0.5);
	vec2 x_uv = x_clip.xy / x_clip.w
		* vec2(0.5, -0.5) + vec2(0.5);
	vec2 y_uv = y_clip.xy / y_clip.w
		* vec2(0.5, -0.5) + vec2(0.5);
	local_x_screen_uv = x_uv - origin_uv;
	local_y_screen_uv = y_uv - origin_uv;
}

void fragment() {
	vec4 color;
	if (blur_effect_index >= 0 && blur_effect_index < effect_count) {
		vec2 radius = abs(blur_radius);
		vec2 radius_x_uv = local_x_screen_uv * radius.x;
		vec2 radius_y_uv = local_y_screen_uv * radius.y;
		vec2 radius_x_local = vec2(radius.x, 0.0);
		vec2 radius_y_local = vec2(0.0, radius.y);

		color = prefix_sample(
			SCREEN_UV,
			layer_local_position,
			blur_effect_index
		) * 0.2;
		color += prefix_sample(
			SCREEN_UV + radius_x_uv,
			layer_local_position + radius_x_local,
			blur_effect_index
		) * 0.1;
		color += prefix_sample(
			SCREEN_UV - radius_x_uv,
			layer_local_position - radius_x_local,
			blur_effect_index
		) * 0.1;
		color += prefix_sample(
			SCREEN_UV + radius_y_uv,
			layer_local_position + radius_y_local,
			blur_effect_index
		) * 0.1;
		color += prefix_sample(
			SCREEN_UV - radius_y_uv,
			layer_local_position - radius_y_local,
			blur_effect_index
		) * 0.1;
		color += prefix_sample(
			SCREEN_UV + radius_x_uv + radius_y_uv,
			layer_local_position + radius_x_local + radius_y_local,
			blur_effect_index
		) * 0.1;
		color += prefix_sample(
			SCREEN_UV - radius_x_uv - radius_y_uv,
			layer_local_position - radius_x_local - radius_y_local,
			blur_effect_index
		) * 0.1;
		color += prefix_sample(
			SCREEN_UV + radius_x_uv - radius_y_uv,
			layer_local_position + radius_x_local - radius_y_local,
			blur_effect_index
		) * 0.1;
		color += prefix_sample(
			SCREEN_UV - radius_x_uv + radius_y_uv,
			layer_local_position - radius_x_local + radius_y_local,
			blur_effect_index
		) * 0.1;

		if (color.a > 0.0001) {
			color.rgb /= color.a;
		} else {
			color.rgb = vec3(0.0);
		}
		color = apply_effect_range(
			color,
			layer_local_position,
			blur_effect_index + 1,
			effect_count
		);
	} else {
		color = sample_encoded_straight(SCREEN_UV);
		color = apply_effect_range(
			color,
			layer_local_position,
			0,
			effect_count
		);
	}

	COLOR *= color;
}
