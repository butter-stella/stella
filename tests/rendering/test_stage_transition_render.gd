extends GutTest

const BYTE_TOLERANCE := 1.5 / 255.0


func before_all() -> void:
	assert_ne(
		DisplayServer.get_name(),
		"headless",
		"Stage transition pixels require a real display server",
	)
	var rendering_method := RenderingServer.get_current_rendering_method()
	assert_true(
		rendering_method in ["gl_compatibility", "mobile", "forward_plus"],
		"Stage transition pixels require a supported Godot renderer",
	)
	var expected_method := OS.get_environment("STELLA_EXPECT_RENDERING_METHOD")
	if not expected_method.is_empty():
		assert_eq(rendering_method, expected_method)


func _row_image(colors: Array[Color], height: int = 1) -> Image:
	var image := Image.create(colors.size(), height, false, Image.FORMAT_RGBA8)
	for y in range(height):
		for x in range(colors.size()):
			image.set_pixel(x, y, colors[x])
	return image


func _material_harness(
	material: ShaderMaterial,
	size: Vector2i,
) -> Dictionary:
	var viewport := SubViewport.new()
	viewport.size = size
	viewport.transparent_bg = true
	viewport.disable_3d = true
	viewport.use_hdr_2d = false
	viewport.canvas_item_default_texture_filter = (
		Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST)
	viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child_autoqfree(viewport)
	var rect := ColorRect.new()
	rect.size = Vector2(size)
	rect.color = Color.WHITE
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.material = material
	viewport.add_child(rect)
	return {"viewport": viewport, "material": material}


func _render(harness: Dictionary, progress: float) -> Image:
	var material := harness["material"] as ShaderMaterial
	var viewport := harness["viewport"] as SubViewport
	material.set_shader_parameter("progress", progress)
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()


func _assert_color(
	image: Image,
	position: Vector2i,
	expected: Color,
	tolerance: float = BYTE_TOLERANCE,
) -> void:
	var actual := image.get_pixelv(position)
	assert_almost_eq(actual.r, expected.r, tolerance, "%s red" % position)
	assert_almost_eq(actual.g, expected.g, tolerance, "%s green" % position)
	assert_almost_eq(actual.b, expected.b, tolerance, "%s blue" % position)
	assert_almost_eq(actual.a, expected.a, tolerance, "%s alpha" % position)


func _rule_harness(
	source: Image,
	target: Image,
	mask: Image,
	softness: float = 0.0,
	invert: bool = false,
) -> Dictionary:
	var source_texture := ImageTexture.create_from_image(source)
	var target_texture := ImageTexture.create_from_image(target)
	var mask_texture := ImageTexture.create_from_image(mask)
	var provider := RuleStageTransitionProvider.new()
	var material := provider.create_material({
		"mask": mask_texture,
		"params": {"softness": softness, "invert": invert},
	}, source_texture, target_texture, Vector2(source.get_size()))
	assert_not_null(material)
	return _material_harness(material, source.get_size())


func _mosaic_harness(
	source: Image,
	target: Image,
	cell: int,
) -> Dictionary:
	var provider := MosaicStageTransitionProvider.new()
	var material := provider.create_material({
		"params": {"cell": cell},
	}, ImageTexture.create_from_image(source), ImageTexture.create_from_image(target),
	Vector2(source.get_size()))
	assert_not_null(material)
	return _material_harness(material, source.get_size())


func test_rule_uses_byte_luminance_nearest_uv_and_exact_endpoints() -> void:
	var source := _row_image([
		Color8(240, 16, 16), Color8(240, 16, 16),
		Color8(240, 16, 16), Color8(240, 16, 16),
	], 2)
	var target := _row_image([
		Color8(16, 32, 240), Color8(16, 32, 240),
		Color8(16, 32, 240), Color8(16, 32, 240),
	], 2)
	# Luminance is exactly (54R + 183G + 19B) / 256 on stored bytes.
	# At p=.1 black and blue reveal; red and green remain source.
	var mask := _row_image([
		Color8(0, 0, 0),
		Color8(0, 0, 255),
		Color8(255, 0, 0),
		Color8(0, 255, 0),
	])
	var harness := _rule_harness(source, target, mask)
	var endpoint_zero := await _render(harness, 0.0)
	assert_eq(endpoint_zero.get_data(), source.get_data())
	var checkpoint := await _render(harness, 0.1)
	for y in range(2):
		_assert_color(checkpoint, Vector2i(0, y), target.get_pixel(0, y))
		_assert_color(checkpoint, Vector2i(1, y), target.get_pixel(1, y))
		_assert_color(checkpoint, Vector2i(2, y), source.get_pixel(2, y))
		_assert_color(checkpoint, Vector2i(3, y), source.get_pixel(3, y))
	var endpoint_one := await _render(harness, 1.0)
	assert_eq(endpoint_one.get_data(), target.get_data(),
		"progress=1 bypasses the mask and is byte-equivalent to the sealed target")


func test_rule_stretches_full_mask_uv_and_invert_reverses_luminance_only() -> void:
	var source := _row_image([
		Color8(224, 32, 32), Color8(224, 32, 32),
		Color8(224, 32, 32), Color8(224, 32, 32),
	], 2)
	var target := _row_image([
		Color8(32, 224, 64), Color8(32, 224, 64),
		Color8(32, 224, 64), Color8(32, 224, 64),
	], 2)
	var stretched_mask := _row_image([Color8(0, 0, 0), Color8(255, 255, 255)])
	var normal := _rule_harness(source, target, stretched_mask)
	var normal_mid := await _render(normal, 0.5)
	for y in range(2):
		_assert_color(normal_mid, Vector2i(0, y), target.get_pixel(0, y))
		_assert_color(normal_mid, Vector2i(1, y), target.get_pixel(1, y))
		_assert_color(normal_mid, Vector2i(2, y), source.get_pixel(2, y))
		_assert_color(normal_mid, Vector2i(3, y), source.get_pixel(3, y))
	var inverted := _rule_harness(source, target, stretched_mask, 0.0, true)
	var inverted_mid := await _render(inverted, 0.5)
	for y in range(2):
		_assert_color(inverted_mid, Vector2i(0, y), source.get_pixel(0, y))
		_assert_color(inverted_mid, Vector2i(1, y), source.get_pixel(1, y))
		_assert_color(inverted_mid, Vector2i(2, y), target.get_pixel(2, y))
		_assert_color(inverted_mid, Vector2i(3, y), target.get_pixel(3, y))


func test_rule_softness_uses_centered_smoothstep_formula() -> void:
	var source := _row_image([Color8(255, 0, 0)])
	var target := _row_image([Color8(0, 0, 255)])
	var mask := _row_image([Color8(128, 128, 128)])
	var harness := _rule_harness(source, target, mask, 0.2)
	# The coefficient sum is 256, so byte 128 has normalized luminance 128/255.
	# At p=luminance, 1-smoothstep(p-s/2,p+s/2,luminance) is exactly .5.
	var midpoint := await _render(harness, 128.0 / 255.0)
	_assert_color(midpoint, Vector2i.ZERO, Color8(128, 0, 128))


func test_mosaic_switches_source_to_target_at_midpoint_and_bypasses_endpoints() -> void:
	var source := _row_image([
		Color8(8, 16, 24), Color8(32, 40, 48),
		Color8(56, 64, 72), Color8(80, 88, 96),
		Color8(104, 112, 120), Color8(128, 136, 144),
		Color8(152, 160, 168), Color8(176, 184, 192),
	], 2)
	var target := _row_image([
		Color8(192, 184, 176), Color8(168, 160, 152),
		Color8(144, 136, 128), Color8(120, 112, 104),
		Color8(96, 88, 80), Color8(72, 64, 56),
		Color8(48, 40, 32), Color8(24, 16, 8),
	], 2)
	var harness := _mosaic_harness(source, target, 4)
	assert_eq((await _render(harness, 0.0)).get_data(), source.get_data())
	var source_half := await _render(harness, 0.499)
	var target_half := await _render(harness, 0.5)
	assert_ne(source_half.get_pixel(0, 0), target_half.get_pixel(0, 0),
		"the midpoint changes ownership from the pixelated source to target")
	_assert_color(source_half, Vector2i.ZERO, source.get_pixel(1, 0))
	_assert_color(target_half, Vector2i.ZERO, target.get_pixel(2, 0))
	assert_eq((await _render(harness, 1.0)).get_data(), target.get_data(),
		"progress=1 depixelates to the byte-equivalent sealed target")
