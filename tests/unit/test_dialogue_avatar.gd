extends GutTest
## Tests for dialogue box avatar feature.

var _game_scene: Node


func before_each():
	_game_scene = load("res://addons/stella/scenes/game.tscn").instantiate()
	add_child_autoqfree(_game_scene)
	await get_tree().process_frame


func _get_presenter():
	return _game_scene.get_node("UILayer/DialoguePanel")


func _get_avatar_container() -> Control:
	return _game_scene.get_node("UILayer/DialoguePanel/HBox/AvatarContainer")

func _get_avatar() -> TextureRect:
	return _game_scene.get_node("UILayer/DialoguePanel/HBox/AvatarContainer/AvatarTexture")


# --- CharacterConfig avatar_rect support ---

func test_config_avatar_rect_default_is_zero():
	var config = CharacterConfig.new()
	assert_eq(config.avatar_rect, Rect2())


func test_config_avatar_rect_loaded_from_dict():
	var config = CharacterConfig.new()
	config.load_from_dict({
		"avatar_rect": {"x": 80, "y": 10, "w": 200, "h": 200}
	})
	assert_eq(config.avatar_rect, Rect2(80, 10, 200, 200))


func test_config_has_avatar_rect_true():
	var config = CharacterConfig.new()
	config.load_from_dict({
		"avatar_rect": {"x": 0, "y": 0, "w": 100, "h": 100}
	})
	assert_true(config.has_avatar_rect())


func test_config_has_avatar_rect_false_when_default():
	var config = CharacterConfig.new()
	assert_false(config.has_avatar_rect())


func test_config_has_avatar_rect_false_when_zero_size():
	var config = CharacterConfig.new()
	config.load_from_dict({
		"avatar_rect": {"x": 50, "y": 50, "w": 0, "h": 0}
	})
	assert_false(config.has_avatar_rect())


func test_config_avatar_rect_partial_dict_uses_defaults():
	var config = CharacterConfig.new()
	config.load_from_dict({
		"avatar_rect": {"x": 100, "h": 150}
	})
	assert_eq(config.avatar_rect, Rect2(100, 0, 0, 150))


func test_config_avatar_rect_coexists_with_avatar_asset_mapping():
	var config = CharacterConfig.new()
	config.load_from_dict({
		"avatar_assets": {"default": "portrait_default"},
		"avatar_rect": {"x": 0, "y": 0, "w": 200, "h": 200}
	})
	assert_eq(config.resolve_avatar_asset("unknown"), "portrait_default")
	assert_true(config.has_avatar_rect())


# --- Presenter avatar visibility ---

func test_avatar_hidden_initially():
	var container = _get_avatar_container()
	assert_false(container.visible, "avatar should be hidden initially")


func test_avatar_hidden_in_nvl_mode():
	SignalBus.show_dialogue.emit("sakura", [{"text": "Hello", "voice": ""}], "nvl")
	await get_tree().process_frame
	var container = _get_avatar_container()
	assert_false(container.visible, "avatar should be hidden in NVL mode")


func test_avatar_hidden_in_overlay_mode():
	SignalBus.show_dialogue.emit("sakura", [{"text": "Hello", "voice": ""}], "overlay")
	await get_tree().process_frame
	var container = _get_avatar_container()
	assert_false(container.visible, "avatar should be hidden in overlay mode")


func test_avatar_hidden_for_narrator():
	SignalBus.show_dialogue.emit("", [{"text": "Narration text", "voice": ""}], "adv")
	await get_tree().process_frame
	var container = _get_avatar_container()
	assert_false(container.visible, "avatar should be hidden for narrator (empty character)")


func test_avatar_hidden_when_no_avatar_rect():
	# Character without avatar_rect config — avatar should stay hidden
	SignalBus.show_dialogue.emit("nonexistent_char", [{"text": "Hello", "voice": ""}], "adv")
	await get_tree().process_frame
	var container = _get_avatar_container()
	var avatar = _get_avatar()
	assert_false(container.visible, "avatar should be hidden when no avatar_rect configured")
	assert_null(avatar.texture)


func test_inline_expression_updates_only_dialogue_avatar_state():
	var presenter = _get_presenter()
	var stage_batches: Array = []
	var callback := func(operations: Array, _force_cut: bool) -> void:
		stage_batches.append(operations)
	SignalBus.stage_operations_requested.connect(callback)

	SignalBus.show_dialogue.emit("sakura", [{
		"text": "[expr:angry]Hello",
		"voice": "",
		"stage_ops": [],
	}], "adv")
	SignalBus.stage_operations_requested.disconnect(callback)

	assert_eq(presenter._avatar_expressions.get("sakura"), "angry")
	assert_true(stage_batches.is_empty(),
		"inline avatar markers must not mutate named stage layers")


func test_trailing_inline_expression_applies_after_natural_typewriter() -> void:
	var presenter = _get_presenter()
	presenter._char_interval = 0.001
	SignalBus.show_dialogue.emit(
		"sakura",
		[{"text": "Hello[expr:sad]", "voice": ""}],
		"adv",
	)
	await get_tree().process_frame
	assert_true(await wait_until(
		func(): return not presenter._is_typing,
		0.5,
		"natural typewriter completion",
	))
	assert_eq(presenter._avatar_expressions.get("sakura"), "sad")


func test_inline_effects_and_avatar_markers_share_visible_text_positions() -> void:
	var presenter = _get_presenter()
	var parsed: Dictionary = ExpressionTimeline.parse_inline_annotations(
		"a{wait:500}[expr:sad]b[expr:surprised]{speed:30}c"
	)
	assert_eq(parsed["clean_text"], "abc")
	assert_eq(parsed["effects"], [
		{"type": "wait", "value": 500.0, "pos": 1, "source_offset": 1},
		{"type": "speed", "value": 30.0, "pos": 2, "source_offset": 2},
	])
	assert_eq(parsed["markers"], [
		{"expression": "sad", "at_char": 1, "source_offset": 1},
		{"expression": "surprised", "at_char": 2, "source_offset": 2},
	])


func test_wait_effect_pauses_before_the_following_character() -> void:
	var presenter = _get_presenter()
	presenter._char_interval = 0.001
	SignalBus.show_dialogue.emit(
		"sakura",
		[{"text": "a{wait:80}b", "voice": ""}],
		"adv",
	)
	assert_true(await wait_until(
		func(): return presenter.text_label.visible_characters >= 1,
		0.5,
		"first visible character",
	))
	await get_tree().create_timer(0.02).timeout
	assert_eq(presenter.text_label.visible_characters, 1)
	presenter.complete_current_dialogue()


func test_speed_effect_persists_until_another_speed_effect() -> void:
	var presenter = _get_presenter()
	presenter._char_interval = 0.001
	SignalBus.show_dialogue.emit(
		"sakura",
		[{"text": "a{speed:80}bcd", "voice": ""}],
		"adv",
	)
	assert_true(await wait_until(
		func(): return presenter.text_label.visible_characters >= 3,
		0.5,
		"third visible character",
	))
	await get_tree().create_timer(0.02).timeout
	assert_eq(presenter.text_label.visible_characters, 3)
	presenter.complete_current_dialogue()


func test_nvl_accumulation_counts_literal_bracket_text_exactly() -> void:
	var presenter = _get_presenter()
	presenter._char_interval = 0.001
	SignalBus.show_dialogue.emit(
		"",
		[{"text": "[b]A[/b]", "voice": ""}],
		"nvl",
	)
	await get_tree().process_frame
	assert_true(await wait_until(
		func(): return not presenter._is_typing,
		0.5,
		"first NVL entry completion",
	))
	SignalBus.show_dialogue.emit(
		"",
		[{"text": "B", "voice": ""}],
		"nvl",
	)
	# The default label enables BBCode, so only A plus the NVL newline are part
	# of the accumulated parsed-character history when the second entry starts.
	assert_eq(presenter.text_label.visible_characters, 2)
	presenter.complete_current_dialogue()


func test_plain_nvl_growth_uses_incremental_label_and_offset_paths() -> void:
	var presenter = _get_presenter()
	presenter._char_interval = 0.0
	var started := Time.get_ticks_msec()
	var first_half_elapsed := 0
	for index in range(80):
		SignalBus.show_dialogue.emit(
			"",
			[{"text": "entry-%03d %s" % [index, "plain text ".repeat(4)],
				"voice": ""}],
			"nvl",
		)
		await get_tree().process_frame
		assert_true(await wait_until(
			func(): return not presenter._is_typing,
			0.5,
			"plain NVL entry %d finishes" % index,
		))
		if index == 39:
			first_half_elapsed = Time.get_ticks_msec() - started
	var elapsed_msec := Time.get_ticks_msec() - started
	var second_half_elapsed := elapsed_msec - first_half_elapsed

	assert_eq(presenter._nvl_incremental_append_count, 79)
	assert_eq(presenter._nvl_full_text_rebuild_count, 1,
		"only the first entry assigns the full RichTextLabel document")
	assert_eq(presenter._parsed_character_full_parse_count, 0,
		"plain NVL boundaries never create temporary full-page parsers")
	var parsed_document: String = presenter.text_label.get_parsed_text()
	assert_true(parsed_document.contains("entry-000"))
	assert_true(parsed_document.contains("entry-079"),
		"incremental append keeps the complete growing document rendered")
	assert_eq(
		presenter.text_label.get_total_character_count(),
		presenter._nvl_render_source.length(),
		"plain authored offsets remain in the label's parsed-character domain",
	)
	assert_lt(elapsed_msec, 3000,
		"80 Presenter-level NVL appends stay within a bounded CPU budget")
	assert_lt(second_half_elapsed, first_half_elapsed * 3 + 100,
		"doubling a growing page must not restore a quadratic full-reparse curve")


func test_repeated_characters_do_not_recreate_unchanged_avatar_texture() -> void:
	var presenter = _get_presenter()
	presenter._char_interval = 0.001
	SignalBus.show_dialogue.emit(
		"sakura",
		[{"text": "[expr:sad]unchanged avatar", "voice": ""}],
		"adv",
	)
	var initial_texture: Texture2D = presenter._avatar_texture.texture
	assert_not_null(initial_texture)
	assert_true(await wait_until(
		func(): return not presenter._is_typing,
		0.5,
		"avatar line completion",
	))
	assert_same(presenter._avatar_texture.texture, initial_texture)


func test_skip_projects_new_speaker_avatar_without_inline_marker() -> void:
	var presenter = _get_presenter()
	SignalBus.show_dialogue.emit(
		"senpai",
		[{"text": "old", "voice": ""}],
		"adv",
	)
	assert_eq(presenter._current_character, "senpai")

	presenter._ctrl_held = true
	SignalBus.show_dialogue.emit(
		"sakura",
		[{"text": "new", "voice": ""}],
		"adv",
	)
	await get_tree().process_frame
	assert_true(await wait_until(
		func(): return not presenter._is_typing,
		0.5,
		"skipped avatar projection",
	))
	presenter._ctrl_held = false
	assert_eq(presenter._current_character, "sakura")
	assert_eq(presenter._current_avatar_expression, "default")
	var avatar := presenter._avatar_texture.texture as AtlasTexture
	assert_not_null(avatar)
	assert_true(avatar.atlas.resource_path.ends_with("sakura/default.png"))


func test_each_dialogue_avatar_starts_from_default_without_hidden_history() -> void:
	var presenter = _get_presenter()
	SignalBus.show_dialogue.emit(
		"sakura",
		[{"text": "[expr:sad]first", "voice": ""}],
		"adv",
	)
	assert_eq(presenter._current_avatar_expression, "sad")
	SignalBus.show_dialogue.emit(
		"sakura",
		[{"text": "second", "voice": ""}],
		"adv",
	)
	assert_eq(presenter._avatar_expressions.get("sakura"), "default")
	assert_eq(presenter._current_avatar_expression, "default")


func test_avatar_cleared_on_hide_dialogue():
	var presenter = _get_presenter()
	var container = _get_avatar_container()
	var avatar = _get_avatar()
	presenter._current_character = "sakura"
	presenter._avatar_expressions["sakura"] = "smile"
	SignalBus.hide_dialogue.emit()
	assert_eq(presenter._current_character, "")
	assert_true(presenter._avatar_expressions.is_empty())
	assert_false(container.visible)
	assert_null(avatar.texture)
