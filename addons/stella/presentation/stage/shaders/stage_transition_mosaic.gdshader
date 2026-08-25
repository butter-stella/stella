shader_type canvas_item;
render_mode unshaded;

uniform sampler2D source_texture : filter_nearest, repeat_disable;
uniform sampler2D target_texture : filter_nearest, repeat_disable;
uniform vec2 viewport_size = vec2(1.0);
uniform float max_cell = 32.0;
uniform float progress : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	if (progress <= 0.0) {
		COLOR = texture(source_texture, UV);
	} else if (progress >= 1.0) {
		COLOR = texture(target_texture, UV);
	} else {
		bool target_half = progress >= 0.5;
		float phase = target_half ? (2.0 - progress * 2.0) : (progress * 2.0);
		float cell = mix(1.0, max_cell, phase);
		vec2 safe_size = max(viewport_size, vec2(1.0));
		vec2 pixel = floor(UV * safe_size / cell) * cell + vec2(cell * 0.5);
		vec2 sample_uv = clamp(pixel / safe_size, vec2(0.0), vec2(1.0));
		if (target_half) {
			COLOR = texture(target_texture, sample_uv);
		} else {
			COLOR = texture(source_texture, sample_uv);
		}
	}
}
