extends GutTest
## Pixel contract for the end-of-dialogue marker under a real renderer.

const INDICATOR_TEXTURE_PATH := \
	"res://tests/integration/fixtures/advance_indicator_4x4.svg"


func before_all() -> void:
	assert_ne(
		DisplayServer.get_name(),
		"headless",
		"render regressions require a real display server",
	)
	var expected_method := OS.get_environment("STELLA_EXPECT_RENDERING_METHOD")
	if not expected_method.is_empty():
		assert_eq(RenderingServer.get_current_rendering_method(), expected_method)


func test_indicator_pixels_follow_the_final_rendered_glyph() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(180, 64)
	viewport.transparent_bg = true
	viewport.disable_3d = true
	viewport.use_hdr_2d = false
	viewport.canvas_item_default_texture_filter = (
		Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	)
	viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child_autoqfree(viewport)

	var host := Control.new()
	host.size = Vector2(viewport.size)
	viewport.add_child(host)
	var label := RichTextLabel.new()
	label.position = Vector2(12.0, 8.0)
	label.size = Vector2(150.0, 48.0)
	label.bbcode_enabled = true
	label.threaded = false
	label.fit_content = false
	label.scroll_active = false
	label.autowrap_mode = TextServer.AUTOWRAP_OFF
	label.add_theme_font_size_override(&"normal_font_size", 20)
	label.add_theme_color_override(&"default_color", Color(0.0, 1.0, 0.0, 1.0))
	label.add_theme_color_override(&"font_color", Color(0.0, 1.0, 0.0, 1.0))
	label.text = "PIXEL"
	label.visible_characters = -1
	host.add_child(label)

	var indicator := DialogueAdvanceIndicator.new()
	host.add_child(indicator)
	assert_eq(indicator.configure(
		load(INDICATOR_TEXTURE_PATH) as Texture2D, "none"), "")
	await get_tree().process_frame
	await get_tree().process_frame
	indicator.prepare_layout_probe(label)
	await get_tree().process_frame
	indicator.sync_layout_probe_scroll()
	await get_tree().process_frame
	assert_true(indicator.isolate_layout_probe_endpoint())
	await get_tree().process_frame
	assert_true(indicator.position_after(label, Vector2.ZERO))
	indicator.show_ready()

	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	var pink_pixels: Array[Vector2i] = []
	var glyph_pixels: Array[Vector2i] = []
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var pixel := image.get_pixel(x, y)
			if pixel.r > 0.75 and pixel.b > 0.35 \
				and pixel.g < 0.5 and pixel.a > 0.25:
				pink_pixels.append(Vector2i(x, y))
			if pixel.g > 0.75 and pixel.r < 0.3 \
				and pixel.b < 0.3 and pixel.a > 0.25:
				glyph_pixels.append(Vector2i(x, y))

	assert_gte(pink_pixels.size(), 4,
		"the framebuffer must contain the configured pink marker")
	assert_gte(glyph_pixels.size(), 8,
		"the framebuffer must independently contain the green dialogue glyphs")
	if pink_pixels.is_empty() or glyph_pixels.is_empty():
		return
	var min_x := pink_pixels[0].x
	var max_x := pink_pixels[0].x
	var min_y := pink_pixels[0].y
	var max_y := pink_pixels[0].y
	for point in pink_pixels:
		min_x = mini(min_x, point.x)
		max_x = maxi(max_x, point.x)
		min_y = mini(min_y, point.y)
		max_y = maxi(max_y, point.y)
	assert_lte(max_x - min_x, 4)
	assert_lte(max_y - min_y, 4)
	var glyph_max_x := glyph_pixels[0].x
	var glyph_min_y := glyph_pixels[0].y
	var glyph_max_y := glyph_pixels[0].y
	for point in glyph_pixels:
		glyph_max_x = maxi(glyph_max_x, point.x)
		glyph_min_y = mini(glyph_min_y, point.y)
		glyph_max_y = maxi(glyph_max_y, point.y)
	var horizontal_gap := min_x - glyph_max_x
	assert_gte(horizontal_gap, 0,
		"marker framebuffer pixels must not overlap the final glyph")
	assert_lte(horizontal_gap, 4,
		"marker framebuffer pixels must stay adjacent to the final glyph")
	var glyph_mid_y := (glyph_min_y + glyph_max_y) / 2.0
	var marker_mid_y := (min_y + max_y) / 2.0
	assert_almost_eq(marker_mid_y, glyph_mid_y, 3.0,
		"marker pixels are vertically centered against independently drawn glyphs")
