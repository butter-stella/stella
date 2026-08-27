extends GutTest
## Pixel contract for background-only dialogue-window opacity projection.

const FIXTURE := preload(
	"res://tests/integration/fixtures/dialogue_window_opacity.tscn")

var _original_opacity: float


func before_all() -> void:
	assert_ne(
		DisplayServer.get_name(),
		"headless",
		"dialogue opacity pixels require a real display server",
	)
	var expected_method := OS.get_environment("STELLA_EXPECT_RENDERING_METHOD")
	if not expected_method.is_empty():
		assert_eq(RenderingServer.get_current_rendering_method(), expected_method)


func before_each() -> void:
	_original_opacity = float(StellaRuntime.get_setting("text_window_opacity"))
	StellaRuntime.set_setting("text_window_opacity", 1.0)


func after_each() -> void:
	StellaRuntime.set_setting("text_window_opacity", _original_opacity)


func test_opacity_boundaries_change_only_background_pixels() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(320, 180)
	viewport.transparent_bg = true
	viewport.disable_3d = true
	viewport.use_hdr_2d = false
	viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child_autoqfree(viewport)
	var presenter := FIXTURE.instantiate() as Control
	viewport.add_child(presenter)
	presenter.visible = true
	(presenter.get_node("AvatarContainer") as Control).visible = true
	(presenter.get_node("Toolbar") as Control).visible = true
	await get_tree().process_frame

	var expected_background_alpha := {
		0.0: 0.0,
		0.5: 0.225,
		1.0: 0.45,
	}
	for opacity: float in [0.0, 0.5, 1.0]:
		assert_true(StellaRuntime.set_setting("text_window_opacity", opacity))
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		await RenderingServer.frame_post_draw
		var image := viewport.get_texture().get_image()
		var background_pixel := image.get_pixel(200, 124)
		assert_almost_eq(
			background_pixel.a,
			float(expected_background_alpha[opacity]),
			0.025,
			"the authored/profile alpha is multiplied once at opacity %s" % opacity,
		)
		var counts := _opaque_feature_counts(image)
		assert_gte(int(counts["name"]), 8,
			"opaque green speaker-name glyphs remain rendered")
		assert_gte(int(counts["text"]), 8,
			"opaque cyan dialogue-text glyphs remain rendered")
		assert_gte(int(counts["avatar"]), 256,
			"opaque blue avatar pixels remain rendered")
		assert_gte(int(counts["panel"]), 256,
			"opaque magenta panel pixels remain rendered")
		assert_gte(int(counts["toolbar"]), 8,
			"opaque orange toolbar pixels remain rendered")
		assert_gte(int(counts["control"]), 256,
			"opaque yellow focusable-control pixels remain rendered")


func _opaque_feature_counts(image: Image) -> Dictionary:
	var counts := {
		"name": 0,
		"text": 0,
		"avatar": 0,
		"panel": 0,
		"toolbar": 0,
		"control": 0,
	}
	for y: int in range(image.get_height()):
		for x: int in range(image.get_width()):
			var pixel := image.get_pixel(x, y)
			if pixel.a < 0.95:
				continue
			if pixel.g > 0.75 and pixel.r < 0.2 and pixel.b < 0.2:
				counts["name"] += 1
			elif pixel.g > 0.75 and pixel.b > 0.75 and pixel.r < 0.2:
				counts["text"] += 1
			elif pixel.b > 0.75 and pixel.r < 0.2 and pixel.g < 0.4:
				counts["avatar"] += 1
			elif pixel.r > 0.75 and pixel.b > 0.75 and pixel.g < 0.2:
				counts["panel"] += 1
			elif pixel.r > 0.75 and pixel.g > 0.3 and pixel.g < 0.8 and pixel.b < 0.2:
				counts["toolbar"] += 1
			elif pixel.r > 0.75 and pixel.g > 0.8 and pixel.b < 0.2:
				counts["control"] += 1
	return counts
