shader_type canvas_item;

uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform int direction : hint_range(0, 3) = 0; // 0=left, 1=right, 2=up, 3=down

void fragment() {
	vec4 tex_color = texture(TEXTURE, UV);
	float threshold = 0.0;
	if (direction == 0) {
		threshold = UV.x;
	} else if (direction == 1) {
		threshold = 1.0 - UV.x;
	} else if (direction == 2) {
		threshold = UV.y;
	} else {
		threshold = 1.0 - UV.y;
	}
	float alpha = step(progress, threshold);
	COLOR = vec4(tex_color.rgb, tex_color.a * alpha);
}
