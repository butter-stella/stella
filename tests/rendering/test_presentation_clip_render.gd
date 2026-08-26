extends GutTest
## Pixel evidence for the generic presentation-clip fit and exact turn effect.

const SHADER_PATH := (
	"res://addons/stella/presentation/clips/shaders/presentation_clip_turn.gdshader")
const BYTE_TOLERANCE := 1.5 / 255.0
const TILE_SIZE := 64
const TURN_WIDTH_FACTOR := 2


func before_all() -> void:
	assert_ne(DisplayServer.get_name(), "headless")
	var rendering_method := RenderingServer.get_current_rendering_method()
	assert_true(rendering_method in ["mobile", "forward_plus", "gl_compatibility"])
	var expected := OS.get_environment("STELLA_EXPECT_RENDERING_METHOD")
	if not expected.is_empty():
		assert_eq(rendering_method, expected)


func _solid_image(size: Vector2i, color: Color) -> Image:
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return image


func _pattern_image(size: Vector2i, seed: int) -> Image:
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	for y in range(size.y):
		for x in range(size.x):
			image.set_pixel(x, y, Color8(
				(x * 7 + y * 3 + seed) % 256,
				(x * 5 + y * 11 + seed * 3) % 256,
				(x * 13 + y * 2 + seed * 5) % 256,
				255,
			))
	return image


func _turn_harness(source: Image, under: Image, exiting: bool = false) -> Dictionary:
	var viewport := SubViewport.new()
	viewport.size = source.get_size()
	viewport.transparent_bg = true
	viewport.disable_3d = true
	viewport.use_hdr_2d = false
	viewport.canvas_item_default_texture_filter = (
		Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST)
	viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child_autoqfree(viewport)
	var material := ShaderMaterial.new()
	material.shader = load(SHADER_PATH) as Shader
	material.set_shader_parameter("exiting", exiting)
	material.set_shader_parameter("gap_color", Color(1, 0, 1, 1))
	material.set_shader_parameter("clip_texture", ImageTexture.create_from_image(source))
	material.set_shader_parameter("under_texture", ImageTexture.create_from_image(under))
	var projector := ColorRect.new()
	projector.size = Vector2(source.get_size())
	projector.mouse_filter = Control.MOUSE_FILTER_IGNORE
	projector.material = material
	viewport.add_child(projector)
	return {
		"viewport": viewport,
		"projector": projector,
		"material": material,
		"source": source,
		"under": under,
		"exiting": exiting,
	}


func _render(harness: Dictionary, progress: float) -> Image:
	(harness.get("material") as ShaderMaterial).set_shader_parameter(
		"progress", progress)
	var viewport := harness.get("viewport") as SubViewport
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()


func _assert_color(actual: Color, expected: Color, label: String) -> void:
	assert_almost_eq(actual.r, expected.r, BYTE_TOLERANCE, label + " red")
	assert_almost_eq(actual.g, expected.g, BYTE_TOLERANCE, label + " green")
	assert_almost_eq(actual.b, expected.b, BYTE_TOLERANCE, label + " blue")
	assert_almost_eq(actual.a, expected.a, BYTE_TOLERANCE, label + " alpha")


func _turn_diagonal_endpoints(phase: int) -> Vector2i:
	var curve_position := 0
	var curve_offset := 0
	if phase < 32:
		curve_position = int(floor(float(phase * phase) / 31.0))
		curve_offset = int(sin(float(curve_position) * PI / 64.0) * 4.0)
		return Vector2i(
			curve_position - curve_offset,
			63 - curve_position - curve_offset,
		)
	var remaining := 63 - phase
	curve_position = 63 - int(floor(float(remaining * remaining) / 31.0))
	curve_offset = int(sin(float(63 - curve_position) * PI / 64.0) * 4.0)
	return Vector2i(
		63 - curve_position + curve_offset,
		curve_position + curve_offset,
	)


func _turn_edge_x(row: int, point: Vector2i, right_edge: bool) -> int:
	if row <= point.y:
		if point.y == 0:
			return 63 if right_edge else 0
		return int(floor(float(point.x * row) / float(point.y)))
	if point.y == 63:
		return 63
	return point.x + int(floor(
		float((63 - point.x) * (row - point.y)) / float(63 - point.y)))


func _turn_source_start(row: int, alpha: Vector2i) -> Vector2i:
	if row <= alpha.y:
		return Vector2i(
			0,
			0 if alpha.y == 0 else int(floor(float(63 * row) / float(alpha.y))),
		)
	return Vector2i(
		int(floor(float(63 * (row - alpha.y)) / float(63 - alpha.y))),
		63,
	)


func _turn_source_end(row: int, beta: Vector2i) -> Vector2i:
	if row <= beta.y:
		return Vector2i(
			63 if beta.y == 0 else int(floor(float(63 * row) / float(beta.y))),
			0,
		)
	return Vector2i(
		63,
		int(floor(float(63 * (row - beta.y)) / float(63 - beta.y))),
	)


func _turn_gloss(phase: int) -> int:
	match phase:
		4, 12:
			return 16
		5, 11:
			return 48
		6, 10:
			return 80
		7, 9:
			return 128
		8:
			return 192
	return 0


func _apply_gloss(color: Color, amount: int) -> Color:
	var bytes := [color.r8, color.g8, color.b8, color.a8]
	for index in range(bytes.size()):
		bytes[index] += int(floor(float(255 - bytes[index]) * amount / 256.0))
	return Color8(bytes[0], bytes[1], bytes[2], bytes[3])


func _reference_turn_color(harness: Dictionary, pixel: Vector2i, progress: float) -> Color:
	var source: Image = harness.get("source")
	var under: Image = harness.get("under")
	var exiting := bool(harness.get("exiting", false))
	if progress <= 0.0:
		return source.get_pixelv(pixel) if exiting else under.get_pixelv(pixel)
	if progress >= 1.0:
		return under.get_pixelv(pixel) if exiting else source.get_pixelv(pixel)
	var frame_size := source.get_size()
	var tile_count := Vector2i(
		ceili(float(frame_size.x) / TILE_SIZE),
		ceili(float(frame_size.y) / TILE_SIZE),
	)
	var tile := pixel / TILE_SIZE
	var local := pixel - tile * TILE_SIZE
	var global_phase := int(floor(progress * float(
		64 + (tile_count.x + tile_count.y) * TURN_WIDTH_FACTOR))) \
		- tile_count.y * TURN_WIDTH_FACTOR
	var phase := clampi(
		global_phase - (tile.x - tile.y) * TURN_WIDTH_FACTOR, 0, 63)
	if phase == 0:
		return source.get_pixelv(pixel) if exiting else under.get_pixelv(pixel)
	if phase == 63:
		return under.get_pixelv(pixel) if exiting else source.get_pixelv(pixel)
	var alpha := _turn_diagonal_endpoints(phase)
	var beta := Vector2i(63, 63) - alpha
	var left := _turn_edge_x(local.y, alpha, false)
	var right := maxi(left, _turn_edge_x(local.y, beta, true))
	var length := right - left + 1
	if local.x < left or local.x >= left + length:
		return Color(1, 0, 1, 1)
	var source_start := _turn_source_start(local.y, alpha)
	var source_end := _turn_source_end(local.y, beta)
	var fixed_step := Vector2i.ZERO
	if length >= 2:
		fixed_step = Vector2i(
			int(float(source_end.x - source_start.x) / float(length - 1) * 65536.0),
			int(float(source_end.y - source_start.y) / float(length - 1) * 65536.0),
		)
	var fixed_source := source_start * 65536 + fixed_step * (local.x - left)
	var source_pixel := tile * TILE_SIZE + Vector2i(
		int(floor(float(fixed_source.x) / 65536.0)),
		int(floor(float(fixed_source.y) / 65536.0)),
	)
	if (
		source_pixel.x < 0
		or source_pixel.y < 0
		or source_pixel.x >= frame_size.x
		or source_pixel.y >= frame_size.y
	):
		return Color(1, 0, 1, 1)
	var selected := (
		(source.get_pixelv(source_pixel) if exiting else under.get_pixelv(source_pixel))
		if phase < 32
		else (under.get_pixelv(source_pixel) if exiting else source.get_pixelv(source_pixel))
	)
	return _apply_gloss(selected, _turn_gloss(phase))


func test_turn_uses_locked_canonical_table_and_projection_vectors() -> void:
	# These values are independent golden vectors from the canonical 64x64 turn
	# table. They deliberately do not derive expected values by rerunning the
	# shader algorithm under test.
	assert_eq(_turn_diagonal_endpoints(8), Vector2i(2, 61))
	assert_eq(_turn_diagonal_endpoints(16), Vector2i(7, 54))
	assert_eq(_turn_diagonal_endpoints(31), Vector2i(28, 29))
	assert_eq(_turn_diagonal_endpoints(32), Vector2i(34, 35))
	assert_eq(_turn_diagonal_endpoints(47), Vector2i(9, 56))
	assert_eq(_turn_diagonal_endpoints(55), Vector2i(2, 61))
	assert_eq(_turn_edge_x(31, Vector2i(2, 61), false), 1)
	assert_eq(_turn_edge_x(31, Vector2i(61, 2), true), 61)
	assert_eq(_turn_source_start(31, Vector2i(2, 61)), Vector2i(0, 32))
	assert_eq(_turn_source_end(31, Vector2i(61, 2)), Vector2i(63, 29))
	assert_eq(_turn_gloss(8), 192)

	var size := Vector2i(64, 64)
	var harness := _turn_harness(
		_pattern_image(size, 7), _pattern_image(size, 41))
	var phase8 := await _render(harness, 10.5 / 68.0)
	_assert_color(
		phase8.get_pixel(31, 31),
		Color8(214, 215, 230, 255),
		"locked phase-8 row-31 projection and gloss",
	)
	var phase32 := await _render(harness, 34.5 / 68.0)
	_assert_color(
		phase32.get_pixel(30, 31),
		Color8(172, 114, 145, 255),
		"locked phase-32 row-31 left source",
	)
	_assert_color(
		phase32.get_pixel(31, 31),
		Color8(207, 135, 96, 255),
		"locked phase-32 row-31 right source",
	)


func test_turn_matches_fixed_table_vectors_and_non_1920_partial_tiles() -> void:
	var size := Vector2i(130, 70)
	var harness := _turn_harness(
		_pattern_image(size, 7), _pattern_image(size, 41))
	for progress: float in [0.17, 0.5, 0.83]:
		var rendered := await _render(harness, progress)
		for pixel: Vector2i in [
			Vector2i(0, 0), Vector2i(31, 17), Vector2i(63, 63),
			Vector2i(64, 0), Vector2i(127, 63), Vector2i(129, 69),
		]:
			_assert_color(
				rendered.get_pixelv(pixel),
				_reference_turn_color(harness, pixel, progress),
				"p=%s pixel=%s" % [progress, pixel],
			)


func test_turn_1920x1080_uses_the_bottom_partial_64_pixel_tile() -> void:
	var size := Vector2i(1920, 1080)
	var harness := _turn_harness(
		_solid_image(size, Color8(224, 24, 16)),
		_solid_image(size, Color8(16, 48, 224)),
	)
	var progress := 0.5
	var rendered := await _render(harness, progress)
	var fixed_pixels := {
		Vector2i(0, 1079): Color8(224, 24, 16),
		Vector2i(63, 1079): Color8(224, 24, 16),
		Vector2i(64, 1079): Color8(224, 24, 16),
		Vector2i(1919, 1079): Color8(255, 0, 255),
	}
	for pixel: Vector2i in fixed_pixels:
		_assert_color(
			rendered.get_pixelv(pixel),
			fixed_pixels[pixel],
			"1920x1080 bottom partial tile %s" % pixel,
		)


func test_turn_gloss_is_byte_exact_for_all_rgba_channels() -> void:
	var size := Vector2i(64, 64)
	var source_color := Color8(10, 20, 30, 64)
	var harness := _turn_harness(
		_solid_image(size, source_color),
		_solid_image(size, Color(0, 0, 0, 0)),
		true,
	)
	var progress := 10.0 / 68.0
	var rendered := await _render(harness, progress)
	var found := false
	for y in range(size.y):
		for x in range(size.x):
			var pixel := Vector2i(x, y)
			var expected := _reference_turn_color(harness, pixel, progress)
			if expected == _apply_gloss(source_color, 192):
				_assert_color(rendered.get_pixelv(pixel), expected, "phase-8 RGBA gloss")
				assert_gt(expected.a8, source_color.a8,
					"the exact gloss raises alpha as well as RGB")
				found = true
				break
		if found:
			break
	assert_true(found, "the fixed phase-8 ribbon contains a sampled pixel")


func _fit_image(fit_mode: StringName) -> Image:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(320, 180)
	viewport.transparent_bg = false
	viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child_autoqfree(viewport)
	var background := ColorRect.new()
	background.size = Vector2(320, 180)
	background.color = Color8(0, 0, 255)
	viewport.add_child(background)
	var group := CanvasGroup.new()
	group.fit_margin = 0.0
	group.clear_margin = 0.0
	viewport.add_child(group)
	var visual := ColorRect.new()
	visual.size = Vector2(100, 100)
	visual.color = Color8(255, 0, 0)
	group.add_child(visual)
	var presenter := PresentationClipPresenter.new()
	presenter.call(
		"_apply_clip_fit", group, Vector2i(100, 100), Vector2i(320, 180), fit_mode)
	presenter.free()
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()


func test_fit_modes_and_zero_canvas_group_margins_have_stable_pixels() -> void:
	var contain := await _fit_image(&"contain")
	_assert_color(contain.get_pixel(0, 90), Color8(0, 0, 255), "contain margin")
	_assert_color(contain.get_pixel(160, 90), Color8(255, 0, 0), "contain center")
	var cover := await _fit_image(&"cover")
	_assert_color(cover.get_pixel(0, 0), Color8(255, 0, 0), "cover top-left")
	_assert_color(cover.get_pixel(319, 179), Color8(255, 0, 0), "cover bottom-right")
	var stretch := await _fit_image(&"stretch")
	_assert_color(stretch.get_pixel(0, 0), Color8(255, 0, 0), "stretch top-left")
	_assert_color(stretch.get_pixel(319, 179), Color8(255, 0, 0), "stretch bottom-right")


func _particle_image(size: Vector2i, color: Color) -> ImageTexture:
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return ImageTexture.create_from_image(image)


func _particle_mask_texture() -> ImageTexture:
	var image := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	for y in range(64):
		for x in range(32):
			image.set_pixel(x, y, Color.WHITE)
	return ImageTexture.create_from_image(image)


func _particle_schedule(
	blend_mode: StringName,
	texture: Texture2D,
	texture_filter: StringName = &"nearest",
	mask_texture: Texture2D = null,
	mask_filter: StringName = &"nearest",
) -> Dictionary:
	return {
		"ordinal": 0,
		"id": &"pixel_layer",
		"texture": texture,
		"texture_filter": texture_filter,
		"mask_texture": mask_texture,
		"mask_filter": mask_filter,
		"mask_rect": Rect2(0, 0, 64, 64),
		"mask_mode": &"alpha" if mask_texture != null else &"none",
		"blend_mode": blend_mode,
		"z_index": 10,
		"color": Color.WHITE,
		"origin": Vector2.ZERO,
		"lifetime_seconds": 1.0,
		"maximum_live_particles": 1,
		"offset_motion_keys": PackedVector3Array([
			Vector3(0, 0, 0), Vector3(1, 0, 0),
		]),
		"scaled_motion_keys": PackedVector3Array([
			Vector3(0, 0, 0), Vector3(1, 0, 0),
		]),
		"opacity_keys": PackedVector2Array([
			Vector2(0, 1), Vector2(1, 1),
		]),
		"scale_keys": PackedVector2Array([
			Vector2(0, 1), Vector2(1, 1),
		]),
		"rotation_keys": PackedVector2Array([
			Vector2(0, 0), Vector2(1, 0),
		]),
		"spawn_times": PackedFloat64Array([0.0]),
		"spawn_x": PackedFloat64Array([16.0]),
		"spawn_y": PackedFloat64Array([24.0]),
		"motion_scales": PackedFloat64Array([1.0]),
		"initial_scales": PackedFloat64Array([1.0]),
		"initial_rotations": PackedFloat64Array([0.0]),
	}


func _particle_harness(schedule: Dictionary, background_color: Color) -> Dictionary:
	return _particle_schedules_harness([schedule], background_color, 0.5)


func _particle_schedules_harness(
	schedules: Array,
	background_color: Color,
	position: float,
) -> Dictionary:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(64, 64)
	viewport.transparent_bg = false
	viewport.disable_3d = true
	viewport.use_hdr_2d = false
	viewport.canvas_item_default_texture_filter = (
		Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST)
	viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child_autoqfree(viewport)
	var group := CanvasGroup.new()
	group.fit_margin = 0.0
	group.clear_margin = 0.0
	viewport.add_child(group)
	var background := ColorRect.new()
	background.size = Vector2(64, 64)
	background.color = background_color
	group.add_child(background)
	var particle_root := Node2D.new()
	group.add_child(particle_root)
	var presenter := PresentationClipPresenter.new()
	var projections: Array = presenter.call(
		"_install_particle_projections",
		schedules,
		particle_root,
		Vector2i(64, 64),
		Vector2i(64, 64),
		&"stretch",
	)
	for projection_value: Variant in projections:
		presenter.call("_project_particle_layer", projection_value, position)
	presenter.free()
	return {
		"viewport": viewport,
		"projection": projections[0] if projections.size() == 1 else {},
		"projections": projections,
	}


func _reproject_particle_harness(harness: Dictionary, position: float) -> void:
	var presenter := PresentationClipPresenter.new()
	for projection_value: Variant in (harness.get("projections", []) as Array):
		presenter.call("_project_particle_layer", projection_value, position)
	presenter.free()


func _render_particle_harness(harness: Dictionary) -> Image:
	var viewport := harness.get("viewport") as SubViewport
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()


func test_particle_alpha_mask_uses_logical_coordinates_and_authored_filter() -> void:
	var schedule := _particle_schedule(
		&"mix",
		_particle_image(Vector2i(32, 16), Color8(255, 0, 0)),
		&"nearest",
		_particle_mask_texture(),
		&"linear",
	)
	var harness := _particle_harness(schedule, Color8(0, 0, 255))
	var projection: Dictionary = harness.get("projection")
	var instance := projection.get("instance") as MultiMeshInstance2D
	var material := instance.material as ShaderMaterial
	assert_eq(instance.texture_filter, CanvasItem.TEXTURE_FILTER_NEAREST)
	assert_true(material.get_shader_parameter("linear_mask"))
	var rendered := await _render_particle_harness(harness)
	_assert_color(rendered.get_pixel(24, 32), Color8(255, 0, 0),
		"alpha mask visible half")
	_assert_color(rendered.get_pixel(40, 32), Color8(0, 0, 255),
		"alpha mask clipped half")


func test_particle_blend_modes_project_real_multimesh_pixels() -> void:
	var expected := {
		&"mix": Color8(64, 32, 16),
		&"add": Color8(192, 160, 144),
		&"sub": Color8(64, 96, 112),
		&"mul": Color8(32, 16, 8),
	}
	for blend_mode: StringName in [&"mix", &"add", &"sub", &"mul"]:
		var harness := _particle_harness(
			_particle_schedule(
				blend_mode,
				_particle_image(Vector2i(8, 8), Color8(64, 32, 16)),
			),
			Color8(128, 128, 128),
		)
		var rendered := await _render_particle_harness(harness)
		_assert_color(rendered.get_pixel(18, 26), expected[blend_mode],
			"%s particle blend" % blend_mode)


func test_particle_blend_modes_are_neutral_at_zero_opacity_and_zero_mask() -> void:
	var background := Color8(80, 96, 112)
	var transparent_mask := _particle_image(Vector2i(64, 64), Color(0, 0, 0, 0))
	for blend_mode: StringName in [&"mix", &"add", &"sub", &"mul"]:
		var opacity_schedule := _particle_schedule(
			blend_mode,
			_particle_image(Vector2i(8, 8), Color8(200, 160, 120)),
		)
		opacity_schedule["opacity_keys"] = PackedVector2Array([
			Vector2(0, 0), Vector2(1, 0),
		])
		var opacity_image := await _render_particle_harness(
			_particle_harness(opacity_schedule, background))
		_assert_color(opacity_image.get_pixel(18, 26), background,
			"%s zero-opacity neutral" % blend_mode)
		var mask_schedule := _particle_schedule(
			blend_mode,
			_particle_image(Vector2i(8, 8), Color8(200, 160, 120)),
			&"nearest",
			transparent_mask,
			&"nearest",
		)
		var mask_image := await _render_particle_harness(
			_particle_harness(mask_schedule, background))
		_assert_color(mask_image.get_pixel(18, 26), background,
			"%s zero-mask neutral" % blend_mode)


func test_public_sealed_particle_plan_has_seekable_start_curve_and_end_pixels() -> void:
	var definition := load(
		"res://tests/fixtures/presentation_clips/synthetic_particle_clip.tres"
	) as PresentationClipDefinition
	var presenter := PresentationClipPresenter.new()
	var plan: Dictionary = presenter.call("_prepare_plan", definition)
	assert_true(bool(plan.get("valid", false)), str(plan))
	if not bool(plan.get("valid", false)):
		presenter.free()
		return
	var schedules: Array = plan.get("particle_schedules", [])
	var harness := _particle_schedules_harness(schedules, Color.BLACK, 0.0)
	var start := await _render_particle_harness(harness)
	_reproject_particle_harness(harness, 0.4)
	var middle := await _render_particle_harness(harness)
	_reproject_particle_harness(harness, 0.55)
	var curve_boundary := await _render_particle_harness(harness)
	_reproject_particle_harness(harness, 1.0)
	var end := await _render_particle_harness(harness)
	_reproject_particle_harness(harness, 0.4)
	var reseek_middle := await _render_particle_harness(harness)
	var expected_start := _solid_image(Vector2i(64, 64), Color.BLACK)
	expected_start.convert(start.get_format())
	var start_is_black := start.get_data() == expected_start.get_data()
	var middle_changed := middle.get_data() != start.get_data()
	var curve_changed := curve_boundary.get_data() != middle.get_data()
	var end_is_black := end.get_data() == start.get_data()
	var reseek_is_exact := reseek_middle.get_data() == middle.get_data()
	assert_true(start_is_black, "clip start projects the sealed empty schedule")
	assert_true(middle_changed, "mid-life projects real public particle pixels")
	assert_true(curve_changed,
		"the authored curve boundary projects different opacity/motion pixels")
	assert_true(end_is_black, "bounded main end contains no late particle tail")
	assert_true(reseek_is_exact,
		"same main position reprojects byte-identical public particle pixels")
	presenter.call("_release_plan", plan)
	presenter.free()


func test_particle_texture_filter_is_an_explicit_visual_contract() -> void:
	var source := Image.create(2, 1, false, Image.FORMAT_RGBA8)
	source.set_pixel(0, 0, Color.BLACK)
	source.set_pixel(1, 0, Color.WHITE)
	var texture := ImageTexture.create_from_image(source)
	var nearest_schedule := _particle_schedule(&"mix", texture, &"nearest")
	nearest_schedule["initial_scales"] = PackedFloat64Array([8.0])
	var linear_schedule := _particle_schedule(&"mix", texture, &"linear")
	linear_schedule["initial_scales"] = PackedFloat64Array([8.0])
	var nearest_harness := _particle_harness(nearest_schedule, Color8(255, 0, 255))
	var linear_harness := _particle_harness(linear_schedule, Color8(255, 0, 255))
	var nearest := await _render_particle_harness(nearest_harness)
	var linear := await _render_particle_harness(linear_harness)
	var nearest_projection: Dictionary = nearest_harness.get("projection")
	var linear_projection: Dictionary = linear_harness.get("projection")
	var nearest_instance := nearest_projection.get("instance") as MultiMeshInstance2D
	var linear_instance := linear_projection.get("instance") as MultiMeshInstance2D
	assert_eq(nearest_instance.texture_filter, CanvasItem.TEXTURE_FILTER_NEAREST)
	assert_eq(linear_instance.texture_filter, CanvasItem.TEXTURE_FILTER_LINEAR)
	assert_ne(nearest.get_pixel(23, 28), linear.get_pixel(23, 28),
		"nearest and linear authored sampling produce distinct boundary pixels")
