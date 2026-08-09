extends GutTest

const SOURCE_PATH := "res://tests/fixtures/stage/redraw_source.png"
const MASK_PATH := "res://tests/fixtures/stage/redraw_mask.png"
const BLUR_SOURCE_PATH := "res://tests/fixtures/stage/redraw_blur_source.png"
const BLUR_ORDER_PATH := "res://tests/fixtures/stage/redraw_blur_order.png"
const BLUR_EDGE_PATH := "res://tests/fixtures/stage/redraw_blur_edge.png"
const PIXEL_TOLERANCE := 2.5 / 255.0
const BYTE_EXACT_TOLERANCE := 0.25 / 255.0


func before_all() -> void:
	assert_ne(
		DisplayServer.get_name(),
		"headless",
		"render regressions require a real display server",
	)
	var rendering_method := RenderingServer.get_current_rendering_method()
	assert_true(
		rendering_method in ["gl_compatibility", "mobile", "forward_plus"],
		"render regressions require a supported Godot rendering method",
	)
	if rendering_method == "gl_compatibility":
		assert_true(
			RenderingServer.get_current_rendering_driver_name().begins_with("opengl3"),
			"Compatibility regressions require an OpenGL driver",
		)


func _operation(layer_id: String, properties: Dictionary) -> Dictionary:
	return {
		"action": "show",
		"id": layer_id,
		"properties": properties,
		"transition": "cut",
		"duration": 0.0,
	}


func _make_harness(size: Vector2i = Vector2i(24, 12)) -> Dictionary:
	var viewport := SubViewport.new()
	viewport.size = size
	viewport.transparent_bg = true
	viewport.disable_3d = true
	viewport.use_hdr_2d = false
	viewport.canvas_item_default_texture_filter = (
		Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	)
	viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child_autoqfree(viewport)

	var presenter := StagePresenter.new()
	viewport.add_child(presenter)
	await get_tree().process_frame
	return {"viewport": viewport, "presenter": presenter}


func _render(viewport: SubViewport) -> Image:
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()


func _show(
	presenter: StagePresenter,
	layer_id: String,
	asset_path: String,
	redraw: Array,
) -> void:
	presenter._apply_operations([
		_operation(layer_id, {"asset": asset_path, "redraw": redraw}),
	], true)


func _assert_pixel(
	image: Image,
	position: Vector2i,
	expected: Color,
	tolerance: float = PIXEL_TOLERANCE,
) -> void:
	var actual := image.get_pixelv(position)
	assert_almost_eq(actual.r, expected.r, tolerance, "%s red" % position)
	assert_almost_eq(actual.g, expected.g, tolerance, "%s green" % position)
	assert_almost_eq(actual.b, expected.b, tolerance, "%s blue" % position)
	assert_almost_eq(actual.a, expected.a, tolerance, "%s alpha" % position)


func test_noop_redraw_preserves_source_bytes_across_renderers() -> void:
	var harness := await _make_harness()
	_show(harness.presenter, "passthrough", SOURCE_PATH, [
		{"type": "grayscale", "amount": 0.0},
	])
	var image := await _render(harness.viewport)
	_assert_pixel(
		image,
		Vector2i(6, 4),
		Color8(64, 96, 128, 255),
		BYTE_EXACT_TOLERANCE,
	)


func test_authored_pointwise_order_changes_the_rendered_result() -> void:
	var first := await _make_harness()
	_show(first.presenter, "ordered", SOURCE_PATH, [
		{
			"type": "color_overlay",
			"color": "#c04080aa",
			"blend": "normal",
		},
		{"type": "brightness_contrast", "brightness": 17, "contrast": -24},
	])
	var first_image := await _render(first.viewport)
	# CPU byte semantics: color_overlay first yields (149, 74, 128), then brightness_contrast.
	_assert_pixel(first_image, Vector2i(6, 4), Color8(160, 103, 145, 255))

	var second := await _make_harness()
	_show(second.presenter, "reversed", SOURCE_PATH, [
		{"type": "brightness_contrast", "brightness": 17, "contrast": -24},
		{
			"type": "color_overlay",
			"color": "#c04080aa",
			"blend": "normal",
		},
	])
	var second_image := await _render(second.viewport)
	_assert_pixel(second_image, Vector2i(6, 4), Color8(159, 82, 133, 255))


func test_brightness_contrast_and_soft_light_keep_defined_8_bit_semantics() -> void:
	var adjustment_harness := await _make_harness()
	_show(adjustment_harness.presenter, "brightness_contrast", SOURCE_PATH, [
		{"type": "brightness_contrast", "brightness": 17, "contrast": -24},
	])
	var adjustment_image := await _render(adjustment_harness.viewport)
	_assert_pixel(
		adjustment_image,
		Vector2i(6, 4),
		Color8(96, 120, 145, 255),
		BYTE_EXACT_TOLERANCE,
	)

	var soft_harness := await _make_harness()
	_show(soft_harness.presenter, "soft", SOURCE_PATH, [{
		"type": "color_overlay",
		"color": "#a050e0ff",
		"blend": "soft_light",
	}])
	var soft_image := await _render(soft_harness.viewport)
	# The defined soft-light table produces (84, 66, 171), then alpha 255 blends /256.
	_assert_pixel(
		soft_image,
		Vector2i(6, 4),
		Color8(83, 66, 170, 255),
		BYTE_EXACT_TOLERANCE,
	)

	var normal_harness := await _make_harness()
	_show(normal_harness.presenter, "normal", SOURCE_PATH, [{
		"type": "color_overlay",
		"color": "#c0d0e0ff",
		"blend": "normal",
	}])
	var normal_image := await _render(normal_harness.viewport)
	# Normal shares the /256 alpha blend: even ff stays one byte short here.
	_assert_pixel(
		normal_image,
		Vector2i(6, 4),
		Color8(191, 207, 223, 255),
		BYTE_EXACT_TOLERANCE,
	)


func test_pointwise_and_clip_compose_with_local_offset_and_outside_zero() -> void:
	var harness := await _make_harness()
	_show(harness.presenter, "clipped", SOURCE_PATH, [
		{
			"type": "color_overlay",
			"color": "#c04080aa",
			"blend": "normal",
		},
		{
			"type": "clip",
			"asset": MASK_PATH,
			"offset": [3.0, 0.0],
			"fit": "native",
		},
		{"type": "brightness_contrast", "brightness": 17, "contrast": -24},
	])
	var image := await _render(harness.viewport)
	_assert_pixel(image, Vector2i(1, 4), Color(0.0, 0.0, 0.0, 0.0))
	_assert_pixel(image, Vector2i(4, 4), Color8(160, 103, 145, 255))
	# Render-target readback is premultiplied for translucent pixels.
	_assert_pixel(image, Vector2i(9, 4), Color8(80, 52, 73, 128))
	_assert_pixel(image, Vector2i(12, 4), Color(0.0, 0.0, 0.0, 0.0))


func test_synthetic_blur_fixture_is_one_opaque_pixel() -> void:
	var harness := await _make_harness(Vector2i(12, 12))
	_show(harness.presenter, "raw", BLUR_SOURCE_PATH, [])
	var image := await _render(harness.viewport)
	_assert_pixel(image, Vector2i(4, 4), Color.WHITE)
	_assert_pixel(image, Vector2i(3, 4), Color(0.0, 0.0, 0.0, 0.0))
	_assert_pixel(image, Vector2i(7, 4), Color(0.0, 0.0, 0.0, 0.0))


func test_blur_uses_the_stable_weighted_nine_tap_kernel() -> void:
	var harness := await _make_harness(Vector2i(12, 12))
	_show(harness.presenter, "blurred", BLUR_SOURCE_PATH, [
		{"type": "blur", "radius": [1, 1]},
	])
	var image := await _render(harness.viewport)
	_assert_pixel(image, Vector2i(4, 4), Color(0.2, 0.2, 0.2, 0.2))
	_assert_pixel(image, Vector2i(3, 4), Color(0.1, 0.1, 0.1, 0.1))
	_assert_pixel(image, Vector2i(3, 3), Color(0.1, 0.1, 0.1, 0.1))
	_assert_pixel(image, Vector2i(2, 4), Color(0.0, 0.0, 0.0, 0.0))


func test_scaled_blur_expands_past_the_global_source_bounds() -> void:
	var harness := await _make_harness(Vector2i(48, 36))
	harness.presenter._apply_operations([
		_operation("scaled_blur", {
			"asset": BLUR_EDGE_PATH,
			"position": [12.0, 0.0],
			"scale": [3.0, 3.0],
			"redraw": [{"type": "blur", "radius": [2, 0]}],
		}),
	], true)
	var image := await _render(harness.viewport)
	# Local x=-2 maps to global x=6 and receives the +radius tap (weight 0.3).
	_assert_pixel(
		image,
		Vector2i(6, 13),
		Color8(77, 77, 77, 77),
		BYTE_EXACT_TOLERANCE,
	)


func test_nonlinear_effect_keeps_its_authored_position_around_blur() -> void:
	var prefix := await _make_harness(Vector2i(12, 8))
	_show(prefix.presenter, "prefix", BLUR_ORDER_PATH, [
		{
			"type": "color_overlay",
			"color": "#3157b9ff",
			"blend": "soft_light",
		},
		{"type": "blur", "radius": [1, 0]},
	])
	var prefix_image := await _render(prefix.viewport)
	# At the color boundary the kernel is 0.3 left, 0.4 center, 0.3 right.
	_assert_pixel(prefix_image, Vector2i(4, 2), Color8(67, 80, 139, 255))

	var suffix := await _make_harness(Vector2i(12, 8))
	_show(suffix.presenter, "suffix", BLUR_ORDER_PATH, [
		{"type": "blur", "radius": [1, 0]},
		{
			"type": "color_overlay",
			"color": "#3157b9ff",
			"blend": "soft_light",
		},
	])
	var suffix_image := await _render(suffix.viewport)
	_assert_pixel(suffix_image, Vector2i(4, 2), Color8(58, 80, 140, 255))


func test_clip_position_around_blur_controls_boundary_spread() -> void:
	var prefix := await _make_harness()
	_show(prefix.presenter, "prefix_clip", SOURCE_PATH, [
		{
			"type": "clip",
			"asset": MASK_PATH,
			"offset": [3.0, 0.0],
			"fit": "native",
		},
		{"type": "blur", "radius": [1, 0]},
	])
	var prefix_image := await _render(prefix.viewport)
	_assert_pixel(
		prefix_image,
		Vector2i(2, 4),
		Color(0.3 * 64.0 / 255.0, 0.3 * 96.0 / 255.0, 0.3 * 128.0 / 255.0, 0.3),
	)

	var suffix := await _make_harness()
	_show(suffix.presenter, "suffix_clip", SOURCE_PATH, [
		{"type": "blur", "radius": [1, 0]},
		{
			"type": "clip",
			"asset": MASK_PATH,
			"offset": [3.0, 0.0],
			"fit": "native",
		},
	])
	var suffix_image := await _render(suffix.viewport)
	_assert_pixel(
		suffix_image,
		Vector2i(2, 4),
		Color(0.0, 0.0, 0.0, 0.0),
	)


func test_json_restored_state_renders_the_same_pixels() -> void:
	var redraw: Array = [
		{
			"type": "color_overlay",
			"color": "#7e3cb480",
			"blend": "soft_light",
		},
		{"type": "brightness_contrast", "brightness": 11, "contrast": -19},
		{
			"type": "clip",
			"asset": MASK_PATH,
			"offset": [2.0, 0.0],
			"fit": "native",
		},
	]
	var original := await _make_harness()
	_show(original.presenter, "restored", SOURCE_PATH, redraw)
	var original_image := await _render(original.viewport)
	var snapshot = JSON.parse_string(JSON.stringify({
		"restored": original.presenter.get_layer_state("restored"),
	}))

	var restored := await _make_harness()
	restored.presenter._on_stage_state_apply_requested(snapshot)
	var restored_image := await _render(restored.viewport)
	for position in [Vector2i(1, 4), Vector2i(3, 4), Vector2i(8, 4)]:
		_assert_pixel(
			restored_image,
			position,
			original_image.get_pixelv(position),
			1.0 / 255.0,
		)
