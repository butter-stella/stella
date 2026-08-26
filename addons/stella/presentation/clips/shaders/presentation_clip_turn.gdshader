shader_type canvas_item;
render_mode blend_disabled;

uniform sampler2D clip_texture : filter_nearest;
uniform sampler2D under_texture : filter_nearest;
uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform bool exiting = false;
uniform vec4 gap_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);

const int TILE_SIZE = 64;
const int TURN_WIDTH_FACTOR = 2;


ivec2 turn_diagonal_endpoints(int phase) {
	int curve_position;
	int curve_offset;
	int alpha_x;
	int alpha_y;
	if (phase < 32) {
		curve_position = int(floor(float(phase * phase) / 31.0));
		curve_offset = int(sin(float(curve_position) * PI / 64.0) * 4.0);
		alpha_x = curve_position - curve_offset;
		alpha_y = 63 - curve_position - curve_offset;
	} else {
		int remaining = 63 - phase;
		curve_position = 63 - int(floor(float(remaining * remaining) / 31.0));
		curve_offset = int(sin(float(63 - curve_position) * PI / 64.0) * 4.0);
		alpha_x = 63 - curve_position + curve_offset;
		alpha_y = curve_position + curve_offset;
	}
	return ivec2(alpha_x, alpha_y);
}


int turn_edge_x(int row, int point_x, int point_y, bool right_edge) {
	if (row <= point_y) {
		if (point_y == 0) {
			return right_edge ? 63 : 0;
		}
		return int(floor(float(point_x * row) / float(point_y)));
	}
	if (point_y == 63) {
		return 63;
	}
	return point_x + int(floor(
		float((63 - point_x) * (row - point_y)) / float(63 - point_y)));
}


ivec2 turn_source_start(int row, ivec2 alpha) {
	if (row <= alpha.y) {
		return ivec2(0, alpha.y == 0 ? 0
			: int(floor(float(63 * row) / float(alpha.y))));
	}
	return ivec2(
		int(floor(float(63 * (row - alpha.y)) / float(63 - alpha.y))),
		63);
}


ivec2 turn_source_end(int row, ivec2 beta) {
	if (row <= beta.y) {
		return ivec2(beta.y == 0 ? 63
			: int(floor(float(63 * row) / float(beta.y))), 0);
	}
	return ivec2(63,
		int(floor(float(63 * (row - beta.y)) / float(63 - beta.y))));
}


int turn_gloss(int phase) {
	if (phase == 4 || phase == 12) { return 16; }
	if (phase == 5 || phase == 11) { return 48; }
	if (phase == 6 || phase == 10) { return 80; }
	if (phase == 7 || phase == 9) { return 128; }
	if (phase == 8) { return 192; }
	return 0;
}


vec4 apply_turn_gloss(vec4 input_color, int amount) {
	if (amount == 0) {
		return input_color;
	}
	vec4 source_bytes = floor(input_color * 255.0 + 0.5);
	vec4 result_bytes = source_bytes + floor(
		(255.0 - source_bytes) * float(amount) / 256.0);
	return result_bytes / 255.0;
}


void fragment() {
	vec4 clip_color = texture(clip_texture, UV);
	vec4 under_color = texture(under_texture, UV);
	if (progress <= 0.0) {
		COLOR = exiting ? clip_color : under_color;
	} else if (progress >= 1.0) {
		COLOR = exiting ? under_color : clip_color;
	} else {
		ivec2 frame_size = textureSize(clip_texture, 0);
		ivec2 tile_count = (frame_size + ivec2(TILE_SIZE - 1)) / TILE_SIZE;
		ivec2 pixel = ivec2(floor(UV * vec2(frame_size)));
		ivec2 tile = pixel / TILE_SIZE;
		ivec2 local = pixel - tile * TILE_SIZE;
		int global_phase = int(floor(progress * float(
			64 + (tile_count.x + tile_count.y) * TURN_WIDTH_FACTOR)))
			- tile_count.y * TURN_WIDTH_FACTOR;
		int phase = clamp(global_phase
			- (tile.x - tile.y) * TURN_WIDTH_FACTOR, 0, 63);
		if (phase == 0) {
			COLOR = exiting ? clip_color : under_color;
		} else if (phase == 63) {
			COLOR = exiting ? under_color : clip_color;
		} else {
			ivec2 alpha = turn_diagonal_endpoints(phase);
			ivec2 beta = ivec2(63) - alpha;
			int left = turn_edge_x(local.y, alpha.x, alpha.y, false);
			int right = turn_edge_x(local.y, beta.x, beta.y, true);
			right = max(left, right);
			int length = right - left + 1;
			if (local.x < left || local.x >= left + length) {
				COLOR = gap_color;
			} else {
				ivec2 source_start = turn_source_start(local.y, alpha);
				ivec2 source_end = turn_source_end(local.y, beta);
				ivec2 fixed_step = ivec2(0);
				if (length >= 2) {
					fixed_step = ivec2(
						int(float(source_end.x - source_start.x)
							/ float(length - 1) * 65536.0),
						int(float(source_end.y - source_start.y)
							/ float(length - 1) * 65536.0));
				}
				ivec2 fixed_source = source_start * 65536
					+ fixed_step * (local.x - left);
				ivec2 source_pixel = tile * TILE_SIZE
					+ ivec2(floor(vec2(fixed_source) / 65536.0));
				if (any(lessThan(source_pixel, ivec2(0)))
						|| any(greaterThanEqual(source_pixel, frame_size))) {
					COLOR = gap_color;
				} else {
					vec2 sample_uv = (vec2(source_pixel) + vec2(0.5))
						/ vec2(frame_size);
					vec4 first = exiting ? texture(clip_texture, sample_uv)
						: texture(under_texture, sample_uv);
					vec4 second = exiting ? texture(under_texture, sample_uv)
						: texture(clip_texture, sample_uv);
					COLOR = apply_turn_gloss(
						phase < 32 ? first : second, turn_gloss(phase));
				}
			}
		}
	}
}
