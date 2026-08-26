shader_type canvas_item;
render_mode unshaded, blend_mul;

uniform sampler2D mask_texture_nearest : filter_nearest, repeat_disable;
uniform sampler2D mask_texture_linear : filter_linear, repeat_disable;
uniform bool use_mask = false;
uniform bool inverse_mask = false;
uniform bool linear_mask = true;
uniform vec4 mask_rect = vec4(0.0);
uniform vec2 target_size = vec2(1.0);
uniform vec2 fit_scale = vec2(1.0);
uniform vec2 fit_offset = vec2(0.0);

void fragment() {
	vec4 particle = COLOR;
	if (use_mask) {
		vec2 logical_position = (SCREEN_UV * target_size - fit_offset) / fit_scale;
		vec2 mask_uv = (logical_position - mask_rect.xy) / mask_rect.zw;
		float mask_alpha = 0.0;
		if (all(greaterThanEqual(mask_uv, vec2(0.0))) && all(lessThanEqual(mask_uv, vec2(1.0)))) {
			mask_alpha = linear_mask ? texture(mask_texture_linear, mask_uv).a : texture(mask_texture_nearest, mask_uv).a;
		}
		particle.a *= inverse_mask ? (1.0 - mask_alpha) : mask_alpha;
	}
	particle.rgb = mix(vec3(1.0), particle.rgb, particle.a);
	particle.a = 1.0;
	COLOR = particle;
}
