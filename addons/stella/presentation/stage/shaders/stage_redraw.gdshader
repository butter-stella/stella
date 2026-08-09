shader_type canvas_item;
render_mode unshaded;

// CanvasGroup children are already present in the screen backbuffer. This
// shader mirrors CanvasGroup's built-in un-premultiplication step, then applies
// the small set of redraw operations exposed by Stella's stage state.
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;
uniform float grayscale_amount : hint_range(0.0, 1.0) = 0.0;
uniform vec2 blur_radius = vec2(0.0);
uniform vec4 tint_color : source_color = vec4(1.0);

void fragment() {
	vec2 radius = SCREEN_PIXEL_SIZE * max(abs(blur_radius), vec2(0.0));
	vec4 c = textureLod(screen_texture, SCREEN_UV, 0.0) * 0.2;
	c += textureLod(screen_texture, SCREEN_UV + vec2(radius.x, 0.0), 0.0) * 0.1;
	c += textureLod(screen_texture, SCREEN_UV - vec2(radius.x, 0.0), 0.0) * 0.1;
	c += textureLod(screen_texture, SCREEN_UV + vec2(0.0, radius.y), 0.0) * 0.1;
	c += textureLod(screen_texture, SCREEN_UV - vec2(0.0, radius.y), 0.0) * 0.1;
	c += textureLod(screen_texture, SCREEN_UV + radius, 0.0) * 0.1;
	c += textureLod(screen_texture, SCREEN_UV - radius, 0.0) * 0.1;
	c += textureLod(screen_texture, SCREEN_UV + vec2(radius.x, -radius.y), 0.0) * 0.1;
	c += textureLod(screen_texture, SCREEN_UV + vec2(-radius.x, radius.y), 0.0) * 0.1;

	if (c.a > 0.0001) {
		c.rgb /= c.a;
	}
	float gray = dot(c.rgb, vec3(0.299, 0.587, 0.114));
	c.rgb = mix(c.rgb, vec3(gray), clamp(grayscale_amount, 0.0, 1.0));
	c *= tint_color;
	COLOR *= c;
}
