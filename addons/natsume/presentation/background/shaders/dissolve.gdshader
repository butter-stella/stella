shader_type canvas_item;

uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D dissolve_noise;

void fragment() {
	vec4 tex_color = texture(TEXTURE, UV);
	float noise_val = texture(dissolve_noise, UV).r;
	float alpha = step(progress, noise_val);
	COLOR = vec4(tex_color.rgb, tex_color.a * alpha);
}
