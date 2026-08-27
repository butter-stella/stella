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
		StellaRuntime.config.game_title,
		"CI_LOCAL_CONFIG_POISON",
		"rendering startup must not resolve CI's root poison local config",
	)
	assert_false(
		StellaRuntime.get_applied_config_sources().has(
			StellaRuntime.LOCAL_CONFIG_PATH,
		),
		"rendering startup must skip the implicit root local source",
	)
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
	var expected_method := OS.get_environment("STELLA_EXPECT_RENDERING_METHOD")
	if not expected_method.is_empty():
		assert_eq(
			rendering_method,
			expected_method,
			"CI must not silently fall back to a different renderer",
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
		"transition_params": {},
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


func _show_image(
	presenter: StagePresenter,
	layer_id: String,
	image: Image,
	redraw: Array,
) -> void:
	_show(presenter, layer_id, SOURCE_PATH, redraw)
	var record: Dictionary = presenter._layers[layer_id]
	var sprite := (record["sprites"] as Dictionary)["asset"] as Sprite2D
	sprite.texture = ImageTexture.create_from_image(image)
	(record["asset_ids"] as Dictionary)["asset"] = "synthetic:%s" % layer_id
	presenter._apply_redraw(record, presenter._states[layer_id], true)


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


func _update_depth(
	presenter: StagePresenter,
	layer_id: String,
	depth_origin: float,
) -> void:
	presenter._apply_operations([{
		"action": "update",
		"id": layer_id,
		"properties": {
			"z_index": 25,
			"depth_scale": 1.0,
			"depth_origin": depth_origin,
		},
		"transition_params": {},
		"transition": "cut",
		"duration": 0.0,
	}], true)


func test_depth_origin_changes_occlusion_without_changing_depth_scale() -> void:
	var harness := await _make_harness(Vector2i(4, 4))
	var red := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	red.fill(Color.RED)
	var blue := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	blue.fill(Color.BLUE)
	_show_image(harness.presenter, "effect", red, [])
	_show_image(harness.presenter, "character", blue, [])
	# The synthetic textures stand in for already-resolved authored assets. Keep
	# their resident channel identity stable while transform-only updates run.
	for layer_id in ["effect", "character"]:
		var record: Dictionary = harness.presenter._layers[layer_id]
		(record["asset_ids"] as Dictionary)["asset"] = (
			harness.presenter._states[layer_id] as Dictionary).get("asset", "")
	_update_depth(harness.presenter, "effect", -8000.0)
	_update_depth(harness.presenter, "character", -9000.0)

	var image := await _render(harness.viewport)
	_assert_pixel(image, Vector2i(2, 2), Color.RED, BYTE_EXACT_TOLERANCE)
	assert_eq(harness.presenter._states["effect"]["depth_scale"], 1.0)
	assert_eq(harness.presenter._states["character"]["depth_scale"], 1.0)

	_update_depth(harness.presenter, "character", -7000.0)
	image = await _render(harness.viewport)
	_assert_pixel(image, Vector2i(2, 2), Color.BLUE, BYTE_EXACT_TOLERANCE)


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


func test_grayscale_uses_integer_coefficients_and_defined_partial_mix() -> void:
	var primaries := Image.create(3, 1, false, Image.FORMAT_RGBA8)
	primaries.set_pixel(0, 0, Color8(255, 0, 0, 255))
	primaries.set_pixel(1, 0, Color8(0, 255, 0, 255))
	primaries.set_pixel(2, 0, Color8(0, 0, 255, 255))

	var full := await _make_harness(Vector2i(4, 2))
	_show_image(full.presenter, "gray", primaries, [
		{"type": "grayscale", "amount": 1.0},
	])
	var full_image := await _render(full.viewport)
	# Coefficients 54/183/19 are shifted by 8, so pure primaries become
	# 53/182/18 rather than the coefficient values themselves.
	_assert_pixel(
		full_image, Vector2i(0, 0), Color8(53, 53, 53, 255), BYTE_EXACT_TOLERANCE
	)
	_assert_pixel(
		full_image, Vector2i(1, 0), Color8(182, 182, 182, 255), BYTE_EXACT_TOLERANCE
	)
	_assert_pixel(
		full_image, Vector2i(2, 0), Color8(18, 18, 18, 255), BYTE_EXACT_TOLERANCE
	)

	var partial := await _make_harness(Vector2i(4, 2))
	_show_image(partial.presenter, "partial_gray", primaries, [
		{"type": "grayscale", "amount": 0.5},
	])
	var partial_image := await _render(partial.viewport)
	# Partial grayscale mixes source and integer gray in byte space, rounding
	# the final channel to nearest.
	_assert_pixel(
		partial_image,
		Vector2i(1, 0),
		Color8(91, 219, 91, 255),
		BYTE_EXACT_TOLERANCE,
	)

	var green_square := Image.create(3, 3, false, Image.FORMAT_RGBA8)
	green_square.fill(Color8(0, 255, 0, 255))
	for redraw in [
		[
			{"type": "grayscale", "amount": 1.0},
			{"type": "blur", "radius": [1, 1]},
		],
		[
			{"type": "blur", "radius": [1, 1]},
			{"type": "grayscale", "amount": 1.0},
		],
	]:
		var ordered := await _make_harness(Vector2i(5, 5))
		_show_image(ordered.presenter, "ordered_gray", green_square, redraw)
		var ordered_image := await _render(ordered.viewport)
		_assert_pixel(
			ordered_image,
			Vector2i(1, 1),
			Color8(182, 182, 182, 255),
			BYTE_EXACT_TOLERANCE,
		)


func test_zero_radius_blur_is_a_true_pointwise_noop() -> void:
	var translucent := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	translucent.fill(Color8(201, 103, 57, 137))
	var pointwise: Array = [
		{"type": "tint", "color": "#7fbf41a3"},
		{"type": "grayscale", "amount": 0.37},
	]
	var baseline := await _make_harness(Vector2i(4, 4))
	_show_image(baseline.presenter, "baseline", translucent, pointwise)
	var baseline_image := await _render(baseline.viewport)

	var with_marker := await _make_harness(Vector2i(4, 4))
	_show_image(with_marker.presenter, "with_marker", translucent, [
		pointwise[0],
		{"type": "blur", "radius": [0, 0]},
		pointwise[1],
	])
	var marker_image := await _render(with_marker.viewport)
	for position in [Vector2i(0, 0), Vector2i(1, 1)]:
		_assert_pixel(
			marker_image,
			position,
			baseline_image.get_pixelv(position),
			BYTE_EXACT_TOLERANCE,
		)
	var record: Dictionary = with_marker.presenter._layers["with_marker"]
	assert_null(record["redraw_pipeline_root"])


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


func test_radius_one_blur_is_the_full_rectangular_box_average() -> void:
	var harness := await _make_harness(Vector2i(12, 12))
	_show(harness.presenter, "blurred", BLUR_SOURCE_PATH, [
		{"type": "blur", "radius": [1, 1]},
	])
	var image := await _render(harness.viewport)
	# Every pixel in the inclusive 3x3 rectangle has the same 1/9 weight.
	_assert_pixel(
		image, Vector2i(4, 4), Color8(28, 28, 28, 28), BYTE_EXACT_TOLERANCE
	)
	_assert_pixel(
		image, Vector2i(3, 4), Color8(28, 28, 28, 28), BYTE_EXACT_TOLERANCE
	)
	_assert_pixel(
		image, Vector2i(3, 3), Color8(28, 28, 28, 28), BYTE_EXACT_TOLERANCE
	)
	_assert_pixel(
		image,
		Vector2i(2, 4),
		Color(0.0, 0.0, 0.0, 0.0),
		BYTE_EXACT_TOLERANCE,
	)


func test_radius_two_blur_averages_every_pixel_in_the_five_by_five_box() -> void:
	var harness := await _make_harness(Vector2i(12, 12))
	_show(harness.presenter, "radius_two", BLUR_SOURCE_PATH, [
		{"type": "blur", "radius": [2, 2]},
	])
	var image := await _render(harness.viewport)
	# round(255 / 25) = 10 at the center, an axis edge, and a corner.
	for position in [Vector2i(4, 4), Vector2i(2, 4), Vector2i(2, 2)]:
		_assert_pixel(
			image, position, Color8(10, 10, 10, 10), BYTE_EXACT_TOLERANCE
		)
	_assert_pixel(
		image,
		Vector2i(1, 4),
		Color(0.0, 0.0, 0.0, 0.0),
		BYTE_EXACT_TOLERANCE,
	)


func test_two_authored_blurs_remain_two_quantized_ordered_passes() -> void:
	var harness := await _make_harness(Vector2i(12, 12))
	_show(harness.presenter, "twice", BLUR_SOURCE_PATH, [
		{"type": "blur", "radius": [1, 1]},
		{"type": "blur", "radius": [2, 0]},
	])
	var image := await _render(harness.viewport)
	# First pass writes byte 28 across its 3x3 support. The second pass reads
	# those bytes: round(3*28/5)=17 at center and round(28/5)=6 at x=1.
	_assert_pixel(
		image, Vector2i(4, 4), Color8(17, 17, 17, 17), BYTE_EXACT_TOLERANCE
	)
	_assert_pixel(
		image, Vector2i(1, 4), Color8(6, 6, 6, 6), BYTE_EXACT_TOLERANCE
	)
	_assert_pixel(
		image,
		Vector2i(0, 4),
		Color(0.0, 0.0, 0.0, 0.0),
		BYTE_EXACT_TOLERANCE,
	)
	_assert_pixel(
		image,
		Vector2i(4, 2),
		Color(0.0, 0.0, 0.0, 0.0),
		BYTE_EXACT_TOLERANCE,
	)
	var record: Dictionary = harness.presenter._layers["twice"]
	assert_eq((record["redraw_pipeline_passes"] as Array).size(), 2)


func test_pointwise_and_clip_between_blurs_match_the_integer_oracle() -> void:
	var source := Image.create(9, 5, false, Image.FORMAT_RGBA8)
	for y in range(5):
		for x in range(9):
			source.set_pixel(x, y, Color8(
				(x * 31 + y * 17 + 9) % 256,
				(x * 47 + y * 29 + 21) % 256,
				(x * 61 + y * 13 + 37) % 256,
				255,
			))

	var harness := await _make_harness(Vector2i(12, 8))
	_show_image(harness.presenter, "interleaved", source, [
		{"type": "blur", "radius": [1, 1]},
		{"type": "grayscale", "amount": 1.0},
		{
			"type": "clip",
			"asset": MASK_PATH,
			"offset": [0.0, 0.0],
			"fit": "native",
		},
		{"type": "blur", "radius": [1, 0]},
	])
	var rendered := await _render(harness.viewport)

	# CPU oracle for global (4,2). The second box samples x=3..5 from
	# byte-quantized 3x3 averages. Grayscale and the synthetic 255/128 alpha
	# mask are then applied independently to each of those three pixels.
	var second_sum := Vector4i.ZERO
	for center_x in range(3, 6):
		var first_sum := Vector4i.ZERO
		for sample_y in range(1, 4):
			for sample_x in range(center_x - 1, center_x + 2):
				first_sum += Vector4i(
					(sample_x * 31 + sample_y * 17 + 9) % 256,
					(sample_x * 47 + sample_y * 29 + 21) % 256,
					(sample_x * 61 + sample_y * 13 + 37) % 256,
					255,
				)
		var first_average := Vector4i(
			int((first_sum.x + 4) / 9),
			int((first_sum.y + 4) / 9),
			int((first_sum.z + 4) / 9),
			255,
		)
		var gray := (
			54 * first_average.x
			+ 183 * first_average.y
			+ 19 * first_average.z
		) >> 8
		var alpha := 255 if center_x < 4 else 128
		var premultiplied_gray := floori(
			float(gray * alpha) / 255.0 + 0.5
		)
		second_sum += Vector4i(
			premultiplied_gray,
			premultiplied_gray,
			premultiplied_gray,
			alpha,
		)
	var expected := Color8(
		int((second_sum.x + 1) / 3),
		int((second_sum.y + 1) / 3),
		int((second_sum.z + 1) / 3),
		int((second_sum.w + 1) / 3),
	)
	_assert_pixel(
		rendered,
		Vector2i(4, 2),
		expected,
		BYTE_EXACT_TOLERANCE,
	)


func test_radius_thirty_two_losslessly_round_trips_large_two_axis_sums() -> void:
	var varied_square := Image.create(65, 65, false, Image.FORMAT_RGBA8)
	var sums := Vector4i.ZERO
	for y in range(65):
		for x in range(65):
			var pixel := Vector4i(
				(x * 37 + y * 17 + 11) % 256,
				(x * 73 + y * 29 + 29) % 256,
				(x * 109 + y * 43 + 47) % 256,
				255,
			)
			varied_square.set_pixel(
				x,
				y,
				Color8(pixel.x, pixel.y, pixel.z, pixel.w),
			)
			sums += pixel
	var harness := await _make_harness(Vector2i(72, 72))
	_show_image(harness.presenter, "max_radius", varied_square, [
		{"type": "blur", "radius": [32, 32]},
	])
	var image := await _render(harness.viewport)
	# Every per-row encoded sum is well above binary16's consecutive integer
	# range, then the second axis accumulates all 65 decoded rows. Compare the
	# complete 65x65 pass against the direct integer box oracle.
	var sample_count := 65 * 65
	var half_count := sample_count >> 1
	var expected := Color8(
		int((sums.x + half_count) / sample_count),
		int((sums.y + half_count) / sample_count),
		int((sums.z + half_count) / sample_count),
		int((sums.w + half_count) / sample_count),
	)
	_assert_pixel(image, Vector2i(32, 32), expected, BYTE_EXACT_TOLERANCE)


func test_numeric_update_reuses_the_complete_blur_pipeline_and_resources() -> void:
	var harness := await _make_harness()
	_show(harness.presenter, "reused", SOURCE_PATH, [
		{
			"type": "clip",
			"asset": MASK_PATH,
			"offset": [0.0, 0.0],
			"fit": "native",
		},
		{"type": "blur", "radius": [1, 1]},
		{"type": "blur", "radius": [2, 0]},
	])
	var record: Dictionary = harness.presenter._layers["reused"]
	var source := record["source"] as Node2D
	var source_texture := (
		(record["sprites"] as Dictionary)["asset"] as Sprite2D
	).texture
	var mask_texture := record["redraw_mask_texture"] as Texture2D
	var material := record["redraw_material"] as ShaderMaterial
	var pipeline_root := record["redraw_pipeline_root"] as SubViewport
	var output := record["redraw_pipeline_output"] as Sprite2D
	var pass_materials: Array = []
	for pass_value in record["redraw_pipeline_passes"]:
		var pass_data: Dictionary = pass_value
		pass_materials.append(pass_data["horizontal_material"])
		pass_materials.append(pass_data["vertical_material"])

	harness.presenter._apply_operations([{
		"action": "update",
		"id": "reused",
		"properties": {"position": [3.0, 2.0], "opacity": 0.75},
		"transition": "cut",
		"transition_params": {},
		"duration": 0.0,
	}], true)
	var updated: Dictionary = harness.presenter._layers["reused"]
	assert_eq(
		harness.presenter.get_layer_state("reused")["position"],
		[3.0, 2.0],
		"the canonical numeric update must apply before reuse is inspected",
	)
	assert_eq(
		(updated["root"] as Node2D).position,
		Vector2(3.0, 2.0),
		"the live layer must project the canonical numeric update",
	)
	assert_same(updated["source"], source)
	assert_same(
		((updated["sprites"] as Dictionary)["asset"] as Sprite2D).texture,
		source_texture,
	)
	assert_same(updated["redraw_mask_texture"], mask_texture)
	assert_same(updated["redraw_material"], material)
	assert_same(updated["redraw_pipeline_root"], pipeline_root)
	assert_same(updated["redraw_pipeline_output"], output)
	var updated_passes := updated["redraw_pipeline_passes"] as Array
	assert_eq(updated_passes.size(), 2)
	for index in range(updated_passes.size()):
		assert_same(
			(updated_passes[index] as Dictionary)["horizontal_material"],
			pass_materials[index * 2],
		)
		assert_same(
			(updated_passes[index] as Dictionary)["vertical_material"],
			pass_materials[index * 2 + 1],
		)


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
	# Local x=-2 maps to global x=6 and receives one of five equal samples.
	_assert_pixel(
		image,
		Vector2i(6, 13),
		Color8(51, 51, 51, 51),
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
	# At x=4 the full box contains two left pixels and one right pixel.
	_assert_pixel(prefix_image, Vector2i(4, 2), Color8(72, 80, 139, 255))

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
	_assert_pixel(suffix_image, Vector2i(4, 2), Color8(62, 80, 140, 255))


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
		Color8(21, 32, 43, 85),
		BYTE_EXACT_TOLERANCE,
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
		{"type": "blur", "radius": [1, 1]},
		{"type": "brightness_contrast", "brightness": 11, "contrast": -19},
		{
			"type": "clip",
			"asset": MASK_PATH,
			"offset": [2.0, 0.0],
			"fit": "native",
		},
		{"type": "blur", "radius": [2, 0]},
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
