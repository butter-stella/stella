extends GutTest
## Geometry and parsed-character regressions for the renderer-backed endpoint.

const FIXTURE := preload(
	"res://tests/integration/fixtures/dialogue_presentation_profile.tscn")
const INDICATOR_TEXTURE_PATH := \
	"res://tests/integration/fixtures/advance_indicator_4x4.svg"


class HideGlyphEffect:
	extends RichTextEffect

	var bbcode := "hide_glyph"


	func _process_custom_fx(char_fx: CharFXTransform) -> bool:
		char_fx.visible = false
		return true


var _presenter: Control


func before_each() -> void:
	_presenter = FIXTURE.instantiate()
	_configure_presenter(_presenter)
	add_child_autoqfree(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 0.0
	(_presenter.get_node("%TextLabel") as RichTextLabel).bbcode_enabled = true
	StellaRuntime.auto_play.is_active = false
	StellaRuntime.skip_controller.is_active = false
	StellaRuntime.game_state.current_state = GameStateMachine.State.PLAYING
	StellaRuntime.game_state.previous_state = GameStateMachine.State.PLAYING


func after_each() -> void:
	SignalBus.hide_dialogue.emit()
	StellaRuntime.auto_play.is_active = false
	StellaRuntime.skip_controller.is_active = false
	StellaRuntime.game_state.current_state = GameStateMachine.State.TITLE
	StellaRuntime.game_state.previous_state = GameStateMachine.State.TITLE
	await get_tree().process_frame


func test_renderer_probe_includes_indent_and_list_prefix_geometry() -> void:
	var fixture := _make_probe_fixture(Vector2(260.0, 120.0))
	var plain_x := await _place_source(fixture, "X")
	var indent_x := await _place_source(fixture, "[indent]X[/indent]")
	var unordered_x := await _place_source(fixture, "[ul]X[/ul]")
	var ordered_x := await _place_source(fixture, "[ol]X[/ol]")

	assert_gt(indent_x, plain_x + 5.0,
		"[indent] margin must be part of the rendered endpoint")
	assert_gt(unordered_x, indent_x + 2.0,
		"unordered-list bullet width must be part of the endpoint")
	assert_gt(ordered_x, indent_x + 2.0,
		"ordered-list prefix width must be part of the endpoint")


func test_stock_presenter_preserves_indent_and_list_endpoint_geometry() -> void:
	var plain_x := await _presenter_indicator_x("X")
	var indent_x := await _presenter_indicator_x("[indent]X[/indent]")
	var unordered_x := await _presenter_indicator_x("[ul]X[/ul]")
	var ordered_x := await _presenter_indicator_x("[ol]X[/ol]")

	assert_gt(indent_x, plain_x + 5.0,
		"the stock Presenter must retain [indent] for engine layout")
	assert_gt(unordered_x, indent_x + 2.0,
		"the stock Presenter must retain the unordered-list prefix")
	assert_gt(ordered_x, indent_x + 2.0,
		"the stock Presenter must retain the ordered-list prefix")


func test_renderer_probe_uses_logical_trailing_edge_for_mixed_rtl() -> void:
	var fixture := _make_probe_fixture(Vector2(260.0, 120.0))
	var endpoint_x := await _place_source(fixture, "abc אבג")
	var label: RichTextLabel = fixture["label"]
	var style_offset := label.get_theme_stylebox(&"normal").get_offset().x
	var visual_right := style_offset + label.get_line_width(0)

	assert_gt(endpoint_x, style_offset + 5.0)
	assert_lt(endpoint_x, visual_right - 5.0,
		"logical end of the final RTL run is its visual left edge, not line width")
	var listed_endpoint_x := await _place_source(
		fixture, "[ul]abc אבג[/ul]")
	assert_gt(listed_endpoint_x, endpoint_x + 5.0,
		"a mixed-RTL logical end must also retain its list prefix margin")


func test_renderer_probe_excludes_glyphs_hidden_by_custom_effect() -> void:
	var fixture := _make_probe_fixture(Vector2(260.0, 120.0))
	var label: RichTextLabel = fixture["label"]
	var helper: DialogueAdvanceIndicator = fixture["helper"]
	label.custom_effects = [HideGlyphEffect.new()]

	var visible_endpoint := await _place_source(fixture, "AB")
	var hidden_tail_endpoint := await _place_source(
		fixture, "AB[hide_glyph enabled=true]CD[/hide_glyph]")
	assert_almost_eq(
		hidden_tail_endpoint,
		visible_endpoint,
		2.0,
		"the endpoint must remain after B when a custom effect hides C and D",
	)

	helper.hide_indicator()
	label.text = "[hide_glyph enabled=true]AB[/hide_glyph]"
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(label.get_visible_content_rect().size, Vector2i.ZERO,
		"the custom effect fixture must hide every glyph from the live label")
	helper.prepare_layout_probe(label)
	await get_tree().process_frame
	helper.sync_layout_probe_scroll()
	await get_tree().process_frame
	var isolated := helper.isolate_layout_probe_endpoint()
	assert_false(isolated,
		"a line without a drawable glyph must not produce an endpoint target")
	await get_tree().process_frame
	assert_false(helper.position_after(label, Vector2.ZERO))
	helper.show_ready()
	assert_false(helper.visible,
		"an all-hidden line must not display an advance indicator")


func test_renderer_probe_handles_inline_images_at_bidi_endpoints() -> void:
	var fixture := _make_probe_fixture(Vector2(260.0, 120.0))
	var label: RichTextLabel = fixture["label"]
	var image_tag := "[img=32x16]%s[/img]" % INDICATOR_TEXTURE_PATH

	var rtl_image_endpoint := await _place_source(fixture, "אבג" + image_tag)
	assert_almost_eq(
		rtl_image_endpoint,
		float(label.get_visible_content_rect().position.x),
		1.0,
		"an inline image resolved at the RTL logical end uses its left edge",
	)

	var mixed_rtl_endpoint := await _place_source(fixture, "abc אבג")
	var prefixed_image_endpoint := await _place_source(
		fixture, image_tag + "abc אבג")
	assert_almost_eq(
		prefixed_image_endpoint,
		mixed_rtl_endpoint + 32.0,
		1.0,
		"a preceding image must not contaminate the isolated RTL text edge",
	)

	var ltr_image_endpoint := await _place_source(fixture, "A" + image_tag)
	assert_almost_eq(
		ltr_image_endpoint,
		float(label.get_visible_content_rect().end.x),
		1.0,
		"a normal LTR terminal image continues to use its right edge",
	)
	var mixed_image_endpoint := await _place_source(
		fixture, "abc אבג" + image_tag)
	assert_almost_eq(
		mixed_image_endpoint,
		float(label.get_visible_content_rect().end.x),
		1.0,
		"an image at the end of an LTR-base mixed line remains right-trailing",
	)


func test_godot_tag_boundary_and_top_of_stack_rules_drive_geometry() -> void:
	var fixture := _make_probe_fixture(Vector2(260.0, 120.0))
	var label: RichTextLabel = fixture["label"]

	var invalid_endpoint := await _place_source(
		fixture, "[right bogus]X[/right]")
	var normal_style := label.get_theme_stylebox(&"normal")
	assert_almost_eq(
		invalid_endpoint,
		normal_style.get_offset().x + label.get_line_width(0),
		2.0,
		"[right bogus] is literal text in Godot 4.6, not right alignment",
	)

	var quoted_endpoint := await _place_source(
		fixture, "[p note='a]b' align=right]Q[/p]")
	var paragraph_width := label.size.x - normal_style.get_minimum_size().x
	assert_almost_eq(
		quoted_endpoint,
		normal_style.get_offset().x + paragraph_width,
		2.0,
		"a ] inside a quoted option must not terminate the p tag",
	)

	var stacked_endpoint := await _place_source(
		fixture, "[right][center]X[/right]Y[/center]")
	var stacked_line := _last_nonempty_line(label)
	var line_width := float(label.get_line_width(stacked_line))
	var expected_center := (
		normal_style.get_offset().x
		+ floorf((paragraph_width - line_width) / 2.0)
		+ line_width
	)
	assert_almost_eq(
		stacked_endpoint,
		expected_center,
		2.0,
		"a mismatched close is literal and must not pop past the stack top",
	)

	var reset_endpoint := await _place_source(
		fixture, "[right]X[reset]Y[/right]")
	assert_almost_eq(
		reset_endpoint,
		normal_style.get_offset().x + paragraph_width,
		2.0,
		"an authored unknown [reset] tag must not pop the outer probe effect",
	)


func test_hidden_internal_scrollbar_keeps_right_and_center_shaping_width() -> void:
	for alignment_tag in ["right", "center"]:
		var fixture := _make_probe_fixture(Vector2(190.0, 58.0), true)
		var label: RichTextLabel = fixture["label"]
		var helper: DialogueAdvanceIndicator = fixture["helper"]
		label.text = "[%s]one\ntwo\nthree\nfour\nEND[/%s]" % [
			alignment_tag, alignment_tag]
		await get_tree().process_frame
		await get_tree().process_frame
		var scroll_bar := label.get_v_scroll_bar()
		assert_true(scroll_bar.visible,
			"fixture must reserve the internal scrollbar width")
		if not scroll_bar.visible:
			continue
		scroll_bar.value = scroll_bar.max_value
		await get_tree().process_frame
		var visible_x := await _place_current_layout(fixture)

		# Hide only the live internal node before constructing the second probe.
		# The mirror must reproduce RichTextLabel's reserved shaping width from the
		# content/layout state instead of treating VScrollBar.visible as width data.
		scroll_bar.hide()
		assert_false(scroll_bar.visible)
		helper.prepare_layout_probe(label)
		await get_tree().process_frame
		assert_true(helper._probe_mirror.get_v_scroll_bar().visible,
			"the isolated engine layout still reserves its own scrollbar width")
		helper.sync_layout_probe_scroll()
		await get_tree().process_frame
		assert_true(helper.isolate_layout_probe_endpoint())
		await get_tree().process_frame
		assert_false(scroll_bar.visible)
		assert_true(helper.position_after(label, Vector2.ZERO))
		helper.show_ready()
		assert_almost_eq(
			helper.position.x,
			visible_x,
			1.0,
			"%s endpoint must not jump when only VScrollBar.visible changes"
				% alignment_tag,
		)


func test_layout_probe_does_not_mutate_live_text_visibility_or_scroll() -> void:
	var fixture := _make_probe_fixture(Vector2(190.0, 58.0), true)
	var label: RichTextLabel = fixture["label"]
	var helper: DialogueAdvanceIndicator = fixture["helper"]
	label.selection_enabled = true
	label.scroll_following = false
	label.text = "one\ntwo\nthree\nfour\nfive\nsix"
	label.visible_characters = 7
	await get_tree().process_frame
	await get_tree().process_frame
	var scroll_bar := label.get_v_scroll_bar()
	assert_true(scroll_bar.visible)
	scroll_bar.value = scroll_bar.max_value * 0.4
	var before := {
		"text": label.text,
		"total": label.get_total_character_count(),
		"visible": label.visible_characters,
		"ratio": label.visible_ratio,
		"scroll": scroll_bar.value,
		"following": label.scroll_following,
		"selected": label.get_selected_text(),
		"children": label.get_child_count(),
	}

	helper.prepare_layout_probe(label)
	await get_tree().process_frame
	helper.sync_layout_probe_scroll()
	await get_tree().process_frame
	assert_true(helper.isolate_layout_probe_endpoint())
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(label.get_child_count(), int(before["children"]) + 1,
		"the temporary mirror is isolated as one child")
	helper.hide_indicator()

	assert_eq(label.text, before["text"])
	assert_eq(label.get_total_character_count(), before["total"])
	assert_eq(label.visible_characters, before["visible"])
	assert_eq(label.visible_ratio, before["ratio"])
	assert_almost_eq(scroll_bar.value, float(before["scroll"]), 0.01)
	assert_eq(label.scroll_following, before["following"])
	assert_eq(label.get_selected_text(), before["selected"])
	assert_eq(label.get_child_count(), before["children"])


func test_list_closing_newline_maps_following_expression_and_wait() -> void:
	_presenter._char_interval = 0.001
	var label := _presenter.get_node("%TextLabel") as RichTextLabel

	SignalBus.show_dialogue.emit("hero", [{
		"text": "[ul]A[/ul][expr:happy]B{wait:160}",
		"voice": "",
		"expression": "",
	}], "adv")
	var reached_wait: bool = await wait_until(
		func(): return _presenter._is_typing and label.visible_characters == 3,
		1.0,
		"typewriter reaches the wait after the list-generated newline",
	)
	assert_true(reached_wait)
	assert_eq(label.text, "[ul]A[/ul]B")
	assert_eq(label.get_total_character_count(), 3,
		"A, generated list newline, and B are the parsed character domain")
	assert_eq(_presenter._avatar_expressions.get("hero"), "happy",
		"the expression after [/ul] must switch at the final parsed boundary")
	await get_tree().create_timer(0.05).timeout
	assert_true(_presenter._is_typing,
		"the authored wait belongs after B, not before the list newline")
	_presenter.complete_typewriter()


func test_nvl_history_boundary_uses_previous_parsed_character_count() -> void:
	var label := _presenter.get_node("%TextLabel") as RichTextLabel
	SignalBus.emit_show_dialogue(
		"old", [_segment("[ol]AB[/ol]")], "nvl", _nvl_format_profile(),
		true, "page")
	if not await _wait_for_typing():
		return
	var previous_count := label.get_total_character_count()
	assert_eq(previous_count, 8,
		"plain entry/speaker prefixes and the generated list newline are parsed")

	_presenter._char_interval = 0.001

	SignalBus.emit_show_dialogue(
		"new", [_segment("[ul]C[/ul][expr:happy]D{wait:160}")], "nvl",
		_nvl_format_profile(), true, "page")
	assert_eq(label.visible_characters, previous_count,
		"the old parsed history must not be replayed while entry two types")
	assert_eq(
		label.text,
		"・old：[ol]AB[/ol]\n・new：[ul]C[/ul]D",
	)
	var reached_wait: bool = await wait_until(
		func(): return _presenter._is_typing \
			and label.visible_characters == previous_count + 8,
		1.0,
		"the second-entry wait follows its list-generated newline and D",
	)
	assert_true(reached_wait)
	assert_eq(_presenter._avatar_expressions.get("new"), "happy",
		"the second-entry expression uses the final combined parsed domain")
	await get_tree().create_timer(0.05).timeout
	assert_true(_presenter._is_typing,
		"the authored wait must not run before the final D")
	_presenter.complete_typewriter()


func test_presenter_preserves_quote_aware_paragraph_bbcode_end_to_end() -> void:
	var source := "[p note='a]b' align=right]Q[/p]"
	SignalBus.emit_show_dialogue(
		"", [_segment(source)], "adv", _texture_profile(), true)
	if not await _wait_for_typing():
		return
	var indicator := await _wait_for_indicator()
	if indicator == null:
		return
	var label := _presenter.get_node("%TextLabel") as RichTextLabel
	var normal_style := label.get_theme_stylebox(&"normal")
	var expected_x := (
		label.global_position.x
		+ normal_style.get_offset().x
		+ label.size.x
		- normal_style.get_minimum_size().x
	)
	assert_eq(label.text, source,
		"ExpressionTimeline must not split a tag at a quoted ]")
	assert_almost_eq(indicator.global_position.x, expected_x, 2.0)


func _make_probe_fixture(
	label_size: Vector2,
	scroll_active: bool = false,
) -> Dictionary:
	var host := Control.new()
	host.size = Vector2(320.0, 220.0)
	add_child_autoqfree(host)
	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.threaded = false
	label.fit_content = false
	label.scroll_active = scroll_active
	label.scroll_following = false
	label.autowrap_mode = TextServer.AUTOWRAP_OFF
	label.size = label_size
	label.add_theme_font_size_override(&"normal_font_size", 16)
	host.add_child(label)
	var helper := DialogueAdvanceIndicator.new()
	host.add_child(helper)
	assert_eq(helper.configure(
		load(INDICATOR_TEXTURE_PATH) as Texture2D, "none"), "")
	return {"host": host, "label": label, "helper": helper}


func _place_source(fixture: Dictionary, source: String) -> float:
	var label: RichTextLabel = fixture["label"]
	label.text = source
	label.visible_characters = -1
	await get_tree().process_frame
	await get_tree().process_frame
	return await _place_current_layout(fixture)


func _place_current_layout(fixture: Dictionary) -> float:
	var label: RichTextLabel = fixture["label"]
	var helper: DialogueAdvanceIndicator = fixture["helper"]
	helper.prepare_layout_probe(label)
	await get_tree().process_frame
	helper.sync_layout_probe_scroll()
	await get_tree().process_frame
	assert_true(helper.isolate_layout_probe_endpoint())
	await get_tree().process_frame
	var positioned := helper.position_after(label, Vector2.ZERO)
	assert_true(positioned,
		"renderer probe resolves the final visible endpoint")
	helper.show_ready()
	return helper.position.x


func _segment(text: String) -> Dictionary:
	return {"text": text, "voice": "", "expression": ""}


func _last_nonempty_line(label: RichTextLabel) -> int:
	for line in range(label.get_line_count() - 1, -1, -1):
		if label.get_line_width(line) > 0.0:
			return line
	return 0


func _texture_profile() -> Dictionary:
	return {
		"advance_indicator_texture": INDICATOR_TEXTURE_PATH,
		"advance_indicator_scene": "",
		"advance_indicator_offset": Vector2.ZERO,
		"advance_indicator_animation": "none",
	}


func _nvl_format_profile() -> Dictionary:
	return {
		"entry_prefix": "・",
		"entry_separator": "\n",
	}


func _wait_for_typing() -> bool:
	await get_tree().process_frame
	var completed: bool = await wait_until(
		func(): return not _presenter._is_typing \
			and (_presenter.get_node("%TextLabel") as RichTextLabel).visible_characters == -1,
		2.0,
		"dialogue reaches parsed-character ready boundary",
	)
	assert_true(completed)
	return completed


func _wait_for_indicator() -> Control:
	var appeared: bool = await wait_until(
		func():
			var node := _presenter.get_node_or_null("AdvanceIndicator") as Control
			return node != null and node.visible,
		1.0,
		"renderer-backed indicator appears",
	)
	assert_true(appeared)
	return (
		_presenter.get_node_or_null("AdvanceIndicator") as Control
		if appeared else null)


func _presenter_indicator_x(source: String) -> float:
	SignalBus.emit_show_dialogue(
		"", [_segment(source)], "adv", _texture_profile(), true)
	if not await _wait_for_typing():
		return -1.0
	var indicator := await _wait_for_indicator()
	if indicator == null:
		return -1.0
	assert_eq(
		(_presenter.get_node("%TextLabel") as RichTextLabel).text,
		source,
		"Godot BBCode must survive Stella's expression-marker pass",
	)
	return indicator.global_position.x


func _configure_presenter(presenter: Control) -> void:
	presenter.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	presenter.size = Vector2(320.0, 220.0)
	var region := presenter.get_node("TextRegion") as Control
	region.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	region.position = Vector2(20.0, 10.0)
	region.size = Vector2(280.0, 190.0)
	var label := region.get_node("TextLabel") as RichTextLabel
	label.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	label.position = Vector2(0.0, 30.0)
	label.size = Vector2(260.0, 140.0)
	label.fit_content = false
	label.scroll_active = false
	label.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	label.add_theme_font_size_override(&"normal_font_size", 16)
