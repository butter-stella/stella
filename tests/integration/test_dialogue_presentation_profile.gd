extends GutTest
## Synthetic coverage for declarative ADV/NVL/overlay presentation profiles.

const FIXTURE := preload("res://tests/integration/fixtures/dialogue_presentation_profile.tscn")
const GAME_SCENE := preload("res://addons/stella/scenes/game.tscn")
const SCENARIO_PATH := "res://tests/fixtures/scenarios/dialogue/presentation_profile.stla"

const AUTHORED_PANEL_ANCHORS := Vector4(0.07, 0.58, 0.93, 0.94)
const AUTHORED_PANEL_OFFSETS := Vector4(4.0, 5.0, -6.0, -7.0)
const AUTHORED_TEXT_ANCHORS := Vector4(0.12, 0.18, 0.88, 0.79)
const AUTHORED_TEXT_OFFSETS := Vector4(7.0, 8.0, -9.0, -10.0)
const AUTHORED_BACKGROUND_ANCHORS := Vector4(0.02, 0.08, 0.98, 0.92)
const AUTHORED_BACKGROUND_OFFSETS := Vector4(1.0, 2.0, -3.0, -4.0)
const AUTHORED_PANEL_MODULATE := Color(0.9, 0.8, 0.7, 0.95)
const AUTHORED_BACKGROUND_MODULATE := Color(0.4, 0.5, 0.6, 0.75)

var _presenter: Control
var _engine: ScenarioEngine
var _runtime_nvl_event_count: int = 0
var _runtime_nvl_page_keys: Array[String] = []


func before_each() -> void:
	_presenter = null
	_engine = null
	_runtime_nvl_event_count = 0
	_runtime_nvl_page_keys.clear()
	StellaRuntime.auto_play.is_active = false
	StellaRuntime.skip_controller.is_active = false


func after_each() -> void:
	if _engine != null and _engine.context != null and not _engine.context.is_finished:
		_engine.context.is_finished = true
		SignalBus.engine_abort_requested.emit()
		await get_tree().process_frame
	if SignalBus.show_dialogue.is_connected(_capture_runtime_nvl_event):
		SignalBus.show_dialogue.disconnect(_capture_runtime_nvl_event)


func test_nvl_profile_accumulates_three_prefixed_entries_and_restores_authored_adv() -> void:
	_presenter = FIXTURE.instantiate()
	add_child_autoqfree(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 0.0

	_start_scenario_fixture()
	if not await _wait_for_dialogue(0, "・First"):
		return
	SignalBus.advance_requested.emit()
	if not await _wait_for_dialogue(1, "・First・Second"):
		return
	SignalBus.advance_requested.emit()
	if not await _wait_for_dialogue(2, "・First・Second・Third"):
		return

	var text_label: RichTextLabel = _presenter.get_node("TextRegion/TextLabel")
	var text_region: Control = _presenter.get_node("TextRegion")
	var background: Control = _presenter.get_node("DialogueBg")
	var adv_chrome: Control = _presenter.get_node("AdvChrome")
	var quick_menu: Control = _presenter.get_node("Toolbar")
	assert_eq(text_label.text, "・First・Second・Third")
	assert_eq(_rect_anchors(_presenter), Vector4(0.0, 0.0, 1.0, 1.0))
	assert_eq(_rect_offsets(_presenter), Vector4.ZERO)
	assert_eq(_rect_anchors(text_region), Vector4(0.18, 0.12, 0.82, 0.62))
	assert_eq(_rect_offsets(text_region), Vector4(18.0, 24.0, -30.0, -42.0))
	assert_eq(text_label.horizontal_alignment, HORIZONTAL_ALIGNMENT_CENTER)
	assert_eq(text_label.vertical_alignment, VERTICAL_ALIGNMENT_CENTER)
	assert_eq(text_label.get_theme_constant("line_separation"), 9)
	assert_false(text_label.fit_content)
	assert_true(text_label.scroll_active)
	assert_true(text_label.scroll_following)
	assert_eq(text_label.autowrap_mode, TextServer.AUTOWRAP_WORD_SMART)
	assert_true(text_label.clip_contents)
	assert_true(background.visible)
	assert_eq(background.modulate, Color(1.0, 1.0, 1.0, 0.0))
	assert_false(adv_chrome.visible)
	assert_true(quick_menu.visible)

	SignalBus.advance_requested.emit()
	if not await _wait_for_dialogue(3, "Back in ADV"):
		return

	assert_eq(text_label.text, "Back in ADV")
	assert_eq(_presenter._nvl_text, "")
	assert_eq(_rect_anchors(_presenter), AUTHORED_PANEL_ANCHORS)
	assert_eq(_rect_offsets(_presenter), AUTHORED_PANEL_OFFSETS)
	assert_eq(_presenter.modulate, AUTHORED_PANEL_MODULATE)
	assert_eq(_rect_anchors(text_region), AUTHORED_TEXT_ANCHORS)
	assert_eq(_rect_offsets(text_region), AUTHORED_TEXT_OFFSETS)
	assert_eq(_rect_anchors(background), AUTHORED_BACKGROUND_ANCHORS)
	assert_eq(_rect_offsets(background), AUTHORED_BACKGROUND_OFFSETS)
	assert_eq(background.modulate, AUTHORED_BACKGROUND_MODULATE)
	assert_true(background.visible)
	assert_true(adv_chrome.visible)
	assert_true(quick_menu.visible)
	assert_eq(text_label.horizontal_alignment, HORIZONTAL_ALIGNMENT_LEFT)
	assert_eq(text_label.vertical_alignment, VERTICAL_ALIGNMENT_TOP)
	assert_eq(text_label.get_theme_constant("line_separation"), 3)
	assert_false(text_label.fit_content)
	assert_false(text_label.scroll_active)
	assert_false(text_label.scroll_following)
	assert_eq(text_label.autowrap_mode, TextServer.AUTOWRAP_WORD)
	assert_false(text_label.clip_contents)

	SignalBus.advance_requested.emit()
	var finished: bool = await wait_until(
		func(): return _engine.context.is_finished,
		1.0,
		"dialogue presentation fixture reaches @end",
	)
	assert_true(finished)


func test_runtime_jump_reentry_starts_a_fresh_nvl_page_after_off() -> void:
	await _start_runtime_fixture_at("jump_loop_entry")
	if not await _wait_for_runtime_nvl(1, "・Jump page"):
		return
	var first_page_key := _runtime_nvl_page_keys[0]
	var first_generation: int = _presenter._dialogue_gen
	assert_eq(first_page_key, "%d:1" % _engine.context.get_instance_id())
	assert_eq(_presenter._active_nvl_page_key, first_page_key)

	SignalBus.advance_requested.emit()
	if not await _wait_for_runtime_nvl(2, "・Jump page"):
		return
	var second_page_key := _runtime_nvl_page_keys[1]
	assert_ne(second_page_key, first_page_key,
		"jump re-entry must emit a distinct runtime page key")
	assert_eq(second_page_key, "%d:2" % _engine.context.get_instance_id())
	assert_gt(_presenter._dialogue_gen, first_generation,
		"the second SHOW must be accepted by the presenter")
	assert_eq(_presenter._active_nvl_page_key, second_page_key,
		"the presenter must activate the second runtime page")
	assert_eq(_presenter.get_node("TextRegion/TextLabel").text, "・Jump page",
		"jumping back after @nvl off must activate a new runtime page")

	await _advance_runtime_to_finish("jump-loop fixture")


func test_repeated_call_activates_a_fresh_nvl_page_after_callee_off() -> void:
	await _start_runtime_fixture_at("repeated_call_entry")
	if not await _wait_for_runtime_nvl(1, "・Called page"):
		return
	var first_page_key := _runtime_nvl_page_keys[0]
	var first_generation: int = _presenter._dialogue_gen
	assert_eq(first_page_key, "%d:1" % _engine.context.get_instance_id())
	assert_eq(_presenter._active_nvl_page_key, first_page_key)

	SignalBus.advance_requested.emit()
	if not await _wait_for_runtime_nvl(2, "・Called page"):
		return
	var second_page_key := _runtime_nvl_page_keys[1]
	assert_ne(second_page_key, first_page_key,
		"each call activation must emit a distinct runtime page key")
	assert_eq(second_page_key, "%d:2" % _engine.context.get_instance_id())
	assert_gt(_presenter._dialogue_gen, first_generation,
		"the second SHOW must be accepted by the presenter")
	assert_eq(_presenter._active_nvl_page_key, second_page_key,
		"the presenter must activate the called scene's second runtime page")
	assert_eq(_presenter.get_node("TextRegion/TextLabel").text, "・Called page",
		"each @call activation must get a fresh page even for the same command")

	await _advance_runtime_to_finish("repeated-call fixture")


func test_true_branch_nvl_page_continues_after_the_conditional() -> void:
	await _start_runtime_fixture_at("branch_true_entry")
	if not await _wait_for_runtime_nvl(1, "・True branch"):
		return

	SignalBus.advance_requested.emit()
	if not await _wait_for_runtime_nvl(2, "・True branch・After branch"):
		return
	assert_eq(_presenter.get_node("TextRegion/TextLabel").text,
		"・True branch・After branch",
		"the continuation must inherit the runtime page selected by the true branch")

	await _advance_runtime_to_finish("true-branch fixture")


func test_false_branch_nvl_page_continues_after_the_conditional() -> void:
	await _start_runtime_fixture_at("branch_false_entry")
	if not await _wait_for_runtime_nvl(1, "・False branch"):
		return

	SignalBus.advance_requested.emit()
	if not await _wait_for_runtime_nvl(2, "・False branch・After branch"):
		return
	assert_eq(_presenter.get_node("TextRegion/TextLabel").text,
		"・False branch・After branch",
		"the continuation must inherit the runtime page selected by the false branch")

	await _advance_runtime_to_finish("false-branch fixture")


func test_repeated_nvl_directive_without_off_keeps_the_runtime_page() -> void:
	await _start_runtime_fixture_at("repeated_nvl_entry")
	if not await _wait_for_runtime_nvl(1, "・Repeated one"):
		return

	SignalBus.advance_requested.emit()
	if not await _wait_for_runtime_nvl(2, "・Repeated one・Repeated two"):
		return
	assert_eq(_presenter.get_node("TextRegion/TextLabel").text,
		"・Repeated one・Repeated two",
		"repeating @nvl while already active must not create a new runtime page")

	await _advance_runtime_to_finish("repeated-@nvl fixture")


func test_nested_true_true_path_restarts_page_and_continuation_accumulates() -> void:
	await _assert_nested_runtime_path(
		"nested_true_true_entry", "TT branch", true)


func test_nested_true_false_path_keeps_the_outer_page() -> void:
	await _assert_nested_runtime_path(
		"nested_true_false_entry", "TF branch", false)


func test_nested_condition_inside_else_true_path_restarts_page() -> void:
	await _assert_nested_runtime_path(
		"nested_false_true_entry", "FT branch", true)


func test_nested_condition_inside_else_false_path_keeps_the_outer_page() -> void:
	await _assert_nested_runtime_path(
		"nested_false_false_entry", "FF branch", false)


func test_no_profile_preserves_the_original_legacy_mode_layouts() -> void:
	_presenter = FIXTURE.instantiate()
	add_child_autoqfree(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 0.0

	await _show_dialogue("Legacy NVL", "nvl")
	var background: Control = _presenter.get_node("DialogueBg")
	assert_eq(_rect_anchors(_presenter), Vector4(0.0, 0.0, 1.0, 1.0))
	assert_eq(_rect_offsets(_presenter), Vector4.ZERO)
	assert_almost_eq(_presenter.modulate.a, 0.9, 0.0001)
	assert_eq(background.anchor_top, 0.0)
	assert_eq(background.offset_top, 0.0)
	assert_false(_presenter.get_node("Toolbar").visible)

	await _show_dialogue("Second legacy entry", "nvl")
	assert_eq(
		_presenter.get_node("TextRegion/TextLabel").text,
		"Legacy NVL\nSecond legacy entry",
		"unprofiled NVL keeps the historical newline separator",
	)

	await _show_dialogue("Legacy ADV", "adv")
	assert_eq(_rect_anchors(_presenter), Vector4(0.0, 0.58, 1.0, 1.0))
	assert_eq(_rect_offsets(_presenter), Vector4(0.0, 5.0, 0.0, 0.0))
	assert_almost_eq(_presenter.modulate.a, 1.0, 0.0001)
	assert_eq(background.anchor_top, 1.0)
	assert_eq(background.offset_top, -220.0)
	assert_true(_presenter.get_node("Toolbar").visible)


func test_nvl_profile_accepts_a_space_separator() -> void:
	_presenter = FIXTURE.instantiate()
	add_child_autoqfree(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 0.0
	var profile := {
		"entry_prefix": "›",
		"entry_separator": " ",
	}

	if not await _emit_profiled_dialogue("", "One", "nvl", profile):
		return
	if not await _emit_profiled_dialogue("", "Two", "nvl", profile):
		return

	assert_eq(_presenter.get_node("TextRegion/TextLabel").text, "›One ›Two")


func test_nvl_prefix_is_the_first_typed_character_and_offsets_inline_markers() -> void:
	_presenter = FIXTURE.instantiate()
	add_child_autoqfree(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 1.0
	var expressions: Array[String] = []
	var expression_listener := func(_character: String, expression: String) -> void:
		expressions.append(expression)
	SignalBus.char_expression_changed.connect(expression_listener)

	SignalBus.emit_show_dialogue(
		"narrator",
		[{"text": "[thoughtful]Text", "voice": "", "expression": ""}],
		"nvl",
		{"entry_prefix": "・", "entry_separator": ""},
		true,
	)
	var text_label: RichTextLabel = _presenter.get_node("TextRegion/TextLabel")
	assert_eq(text_label.text, "・narrator：Text")
	assert_eq(text_label.visible_characters, 0)

	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(text_label.visible_characters, 1,
		"the first typewriter step reveals only the entry prefix")
	assert_eq(expressions, [],
		"a marker at authored offset zero must not fire while the prefix is typed")

	SignalBus.hide_dialogue.emit()
	SignalBus.char_expression_changed.disconnect(expression_listener)


func test_nvl_typewriter_keeps_history_visible_and_types_only_the_new_entry() -> void:
	_presenter = FIXTURE.instantiate()
	add_child_autoqfree(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 0.0
	var profile := {"entry_prefix": "・", "entry_separator": "\n"}
	if not await _emit_profiled_dialogue("", "Old", "nvl", profile):
		return

	_presenter._char_interval = 1.0
	SignalBus.emit_show_dialogue(
		"",
		[{"text": "New", "voice": "", "expression": ""}],
		"nvl",
		profile,
		true,
	)
	var text_label: RichTextLabel = _presenter.get_node("TextRegion/TextLabel")
	var history_length := "・Old\n".length()
	assert_eq(text_label.text, "・Old\n・New")
	assert_eq(text_label.visible_characters, history_length,
		"the accumulated entry and separator are visible before new typing starts")

	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(text_label.visible_characters, history_length + 1,
		"the first new typewriter step reveals only the next entry prefix")
	SignalBus.hide_dialogue.emit()


func test_leaving_nvl_for_overlay_or_adv_resets_the_accumulator() -> void:
	_presenter = FIXTURE.instantiate()
	add_child_autoqfree(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 0.0

	await _show_dialogue("Before overlay", "nvl")
	await _show_dialogue("Overlay", "overlay")
	await _show_dialogue("After overlay", "nvl")
	assert_eq(_presenter.get_node("TextRegion/TextLabel").text, "After overlay")

	await _show_dialogue("ADV", "adv")
	await _show_dialogue("After ADV", "nvl")
	assert_eq(_presenter.get_node("TextRegion/TextLabel").text, "After ADV")


func test_new_nvl_page_resets_without_an_intervening_non_nvl_dialogue() -> void:
	_presenter = FIXTURE.instantiate()
	add_child_autoqfree(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 0.0
	var profile := {"entry_prefix": "・", "entry_separator": ""}

	if not await _emit_profiled_dialogue("", "Old", "nvl", profile, "scenario-a:11"):
		return
	if not await _emit_profiled_dialogue("", "New", "nvl", profile, "scenario-a:12"):
		return
	assert_eq(_presenter.get_node("TextRegion/TextLabel").text, "・New",
		"a different runtime NVL page key starts a fresh page")

	if not await _emit_profiled_dialogue("", "Continued", "nvl", profile, "scenario-a:12"):
		return
	assert_eq(_presenter.get_node("TextRegion/TextLabel").text, "・New・Continued",
		"entries with the same page key keep accumulating")


func test_nvl_decoration_does_not_mutate_segments_or_backlog_text() -> void:
	_presenter = FIXTURE.instantiate()
	add_child_autoqfree(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 1.0
	var segments := [{
		"text": "Original source text",
		"voice": "",
		"expression": "",
	}]

	SignalBus.emit_show_dialogue(
		"Narrator",
		segments,
		"nvl",
		{"entry_prefix": "・", "entry_separator": ""},
		true,
	)
	assert_eq(
		_presenter.get_node("TextRegion/TextLabel").text,
		"・Narrator：Original source text",
	)
	assert_eq(segments[0]["text"], "Original source text")

	var backlog := BacklogManager.new()
	backlog.add_entry("Narrator", segments)
	assert_eq(backlog.get_entry(0)["text"], "Original source text",
		"presentation-only decoration must stay out of backlog data")
	SignalBus.hide_dialogue.emit()


func test_combine_is_decorated_once_as_one_nvl_entry() -> void:
	var source := """@dialogue_profile novel entry_prefix="・" entry_separator=""
@chapter test "Test"
@scene start
@nvl profile=novel
@combine
「First」
「Second」
@end"""
	var scenario := DslParser.parse(DslLexer.tokenize(source), "profiled_combine")
	assert_eq(scenario.diagnostics, [])
	if not scenario.diagnostics.is_empty():
		return
	var command: CommandData = scenario.scenes[0].commands[0]
	var segments: Array = command.params["segments"]
	assert_eq(segments.size(), 2)

	_presenter = FIXTURE.instantiate()
	add_child_autoqfree(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 1.0
	SignalBus.emit_show_dialogue(
		command.get_string("character"),
		segments,
		command.get_string("mode"),
		command.params["presentation_profile"],
		true,
	)
	assert_eq(_presenter.get_node("TextRegion/TextLabel").text, "・FirstSecond")
	SignalBus.hide_dialogue.emit()


func test_resource_fallback_can_override_nvl_entry_format_independently() -> void:
	_presenter = FIXTURE.instantiate()
	var nvl_profile := DialogueModeProfile.new()
	nvl_profile.override_entry_prefix = true
	nvl_profile.entry_prefix = "※"
	nvl_profile.override_entry_separator = true
	nvl_profile.entry_separator = ""
	var profile := DialoguePresentationProfile.new()
	profile.nvl = nvl_profile
	_presenter.presentation_profile = profile
	add_child_autoqfree(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 0.0

	await _show_dialogue("One", "nvl")
	await _show_dialogue("Two", "nvl")
	assert_eq(_presenter.get_node("TextRegion/TextLabel").text, "※One※Two")


func test_named_profile_without_entry_format_keeps_legacy_newline() -> void:
	_presenter = FIXTURE.instantiate()
	add_child_autoqfree(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 0.0
	var layout_only_profile := {"horizontal_alignment": HORIZONTAL_ALIGNMENT_CENTER}

	if not await _emit_profiled_dialogue("", "One", "nvl", layout_only_profile):
		return
	if not await _emit_profiled_dialogue("", "Two", "nvl", layout_only_profile):
		return
	assert_eq(_presenter.get_node("TextRegion/TextLabel").text, "One\nTwo",
		"entry formatting remains legacy-compatible when a profile only changes layout")


func test_missing_nvl_profile_uses_legacy_layout_then_restores_toolbar_in_adv() -> void:
	_presenter = FIXTURE.instantiate()
	_presenter.presentation_profile = DialoguePresentationProfile.new()
	add_child_autoqfree(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 0.0

	await _show_dialogue("Legacy", "nvl")
	assert_eq(_rect_anchors(_presenter), Vector4(0.0, 0.0, 1.0, 1.0))
	assert_eq(_rect_offsets(_presenter), Vector4.ZERO)
	assert_almost_eq(_presenter.modulate.a, 0.9, 0.0001)
	assert_false(_presenter.get_node("Toolbar").visible)

	await _show_dialogue("ADV", "adv")
	assert_eq(_rect_anchors(_presenter), AUTHORED_PANEL_ANCHORS)
	assert_eq(_rect_offsets(_presenter), AUTHORED_PANEL_OFFSETS)
	assert_eq(_presenter.modulate, AUTHORED_PANEL_MODULATE)
	assert_true(_presenter.get_node("Toolbar").visible)


func test_invalid_profile_reports_diagnostic_and_falls_back_safely() -> void:
	var invalid_mode := DialogueModeProfile.new()
	invalid_mode.override_panel_rect = true
	invalid_mode.panel_anchors = Vector4(0.9, 0.0, 0.1, 1.0)
	invalid_mode.override_entry_prefix = true
	invalid_mode.entry_prefix = "[b]・[/b]"
	var profile := DialoguePresentationProfile.new()
	profile.nvl = invalid_mode

	_presenter = FIXTURE.instantiate()
	_presenter.presentation_profile = profile
	add_child_autoqfree(_presenter)
	await get_tree().process_frame
	assert_push_warning(
		"DialoguePresenter profile 'nvl': entry_prefix is plain text and cannot contain BBCode brackets")
	assert_push_warning(
		"DialoguePresenter profile 'nvl': panel_anchors must be ordered left <= right and top <= bottom")

	_presenter._char_interval = 0.0
	await _show_dialogue("Fallback", "nvl")
	assert_eq(_rect_anchors(_presenter), Vector4(0.0, 0.0, 1.0, 1.0))
	assert_almost_eq(_presenter.modulate.a, 0.9, 0.0001)
	assert_eq(_presenter.get_node("TextRegion/TextLabel").text, "Fallback",
		"invalid entry formatting must not bypass whole-profile fallback")


func test_stla_profile_validation_reports_source_lines_and_unknown_references() -> void:
	var source := """@dialogue_profile broken panel_anchors=0.9,0,0.1,1
@chapter test "Test"
@scene start
@nvl profile=missing
「line」"""
	var scenario := DslParser.parse(DslLexer.tokenize(source), "invalid_profile")
	assert_eq(scenario.diagnostics.size(), 2)
	assert_eq(scenario.diagnostics[0]["line"], 1)
	assert_string_contains(
		scenario.diagnostics[0]["message"],
		"panel_anchors must be ordered",
	)
	assert_eq(scenario.diagnostics[1]["line"], 4)
	assert_string_contains(
		scenario.diagnostics[1]["message"],
		"unknown dialogue profile 'missing'",
	)


func test_profile_selection_is_compiled_into_commands_and_off_keeps_restore_contract() -> void:
	var source := """@chapter test "Test"
@scene start
@overlay profile=centered
「overlay」
@overlay off
「adv」
@dialogue_profile centered horizontal_alignment=center"""
	var scenario := DslParser.parse(DslLexer.tokenize(source), "profile_selection")
	assert_eq(scenario.diagnostics, [])
	var overlay_command: CommandData = scenario.scenes[0].commands[0]
	var adv_command: CommandData = scenario.scenes[0].commands[1]
	assert_eq(overlay_command.get_string("mode"), "overlay")
	assert_eq(overlay_command.get_string("presentation_profile_name"), "centered")
	assert_true(overlay_command.get_bool("declarative_presentation"))
	assert_eq(adv_command.get_string("mode"), "adv")
	assert_false(adv_command.has_param("presentation_profile_name"))
	assert_true(adv_command.get_bool("declarative_presentation"),
		"@overlay off must restore the authored ADV baseline")


func test_profile_declarations_merge_aliases_and_strip_whitespace_comments() -> void:
	var source := """@dialogue_profile novel show=quick_menu\thide=adv_chrome\t// author note
@dialogue_profile novel line_spacing=7 // another note
@chapter test "Test"
@scene start
@nvl profile=novel // select the compiled profile
「line」"""
	var scenario := DslParser.parse(DslLexer.tokenize(source), "profile_comments")
	assert_eq(scenario.diagnostics, [])
	var command: CommandData = scenario.scenes[0].commands[0]
	var profile: Dictionary = command.params["presentation_profile"]
	assert_eq(profile["visibility_groups"], {
		"quick_menu": true,
		"adv_chrome": false,
	})
	assert_eq(profile["line_spacing"], 7)
	assert_false(profile.has("show"), "show is only an STLA authoring alias")
	assert_false(profile.has("hide"), "hide is only an STLA authoring alias")


func test_stla_properties_are_independent_and_preserve_unwritten_authored_values() -> void:
	_presenter = FIXTURE.instantiate()
	add_child_autoqfree(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 0.0

	SignalBus.emit_show_dialogue(
		"",
		[{"text": ""}],
		"nvl",
		{"horizontal_alignment": HORIZONTAL_ALIGNMENT_CENTER},
		true,
	)

	var text_label: RichTextLabel = _presenter.get_node("TextRegion/TextLabel")
	var text_region: Control = _presenter.get_node("TextRegion")
	assert_eq(_rect_anchors(_presenter), AUTHORED_PANEL_ANCHORS)
	assert_eq(_rect_offsets(_presenter), AUTHORED_PANEL_OFFSETS)
	assert_eq(_rect_anchors(text_region), AUTHORED_TEXT_ANCHORS)
	assert_eq(_rect_offsets(text_region), AUTHORED_TEXT_OFFSETS)
	assert_eq(text_label.horizontal_alignment, HORIZONTAL_ALIGNMENT_CENTER)
	assert_eq(text_label.vertical_alignment, VERTICAL_ALIGNMENT_TOP,
		"unwritten vertical alignment keeps its authored top value")
	assert_eq(text_label.get_theme_constant("line_separation"), 3)
	assert_false(text_label.fit_content)
	assert_false(text_label.scroll_active)
	assert_false(text_label.scroll_following)
	assert_eq(text_label.autowrap_mode, TextServer.AUTOWRAP_WORD)
	assert_false(text_label.clip_contents)
	await get_tree().process_frame


func test_profile_state_is_restored_before_unprofiled_legacy_mode() -> void:
	_presenter = FIXTURE.instantiate()
	add_child_autoqfree(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 0.0

	var text_label: RichTextLabel = _presenter.get_node("TextRegion/TextLabel")
	var background: Control = _presenter.get_node("DialogueBg")
	var adv_chrome: Control = _presenter.get_node("AdvChrome")
	SignalBus.emit_show_dialogue(
		"",
		[{"text": ""}],
		"nvl",
		{
			"horizontal_alignment": HORIZONTAL_ALIGNMENT_CENTER,
			"background_visible": false,
			"visibility_groups": {"adv_chrome": false},
		},
		true,
	)
	assert_eq(text_label.horizontal_alignment, HORIZONTAL_ALIGNMENT_CENTER)
	assert_false(background.visible)
	assert_false(adv_chrome.visible)

	SignalBus.emit_show_dialogue("", [{"text": ""}], "overlay")
	assert_eq(_rect_anchors(_presenter), Vector4(0.15, 0.3, 0.85, 0.7))
	assert_eq(text_label.horizontal_alignment, HORIZONTAL_ALIGNMENT_LEFT)
	assert_true(background.visible)
	assert_eq(background.modulate, AUTHORED_BACKGROUND_MODULATE)
	assert_true(adv_chrome.visible)
	await get_tree().process_frame


func test_soft_hidden_show_restores_and_renders_the_new_runtime_page() -> void:
	_presenter = FIXTURE.instantiate()
	add_child_autoqfree(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 0.0
	var profile := {"entry_prefix": "・", "entry_separator": ""}

	if not await _emit_profiled_dialogue(
		"", "Before soft hide", "nvl", profile, "soft-hide:1"):
		return
	_presenter._ui_hidden = true
	_presenter.visible = false
	var previous_generation: int = _presenter._dialogue_gen

	if not await _emit_profiled_dialogue(
		"", "After soft hide", "nvl", profile, "soft-hide:2"):
		return
	assert_false(_presenter._ui_hidden,
		"a valid SHOW must restore a soft-hidden presenter")
	assert_true(_presenter.visible)
	assert_gt(_presenter._dialogue_gen, previous_generation,
		"a SHOW received while soft-hidden must start a new presentation generation")
	assert_eq(_presenter._active_nvl_page_key, "soft-hide:2")
	assert_eq(_presenter.get_node("TextRegion/TextLabel").text, "・After soft hide",
		"the hidden SHOW must render rather than leave the previous page on screen")


func test_empty_segments_do_not_mutate_soft_hide_or_nvl_page_state() -> void:
	_presenter = FIXTURE.instantiate()
	add_child_autoqfree(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 0.0
	var profile := {"entry_prefix": "・", "entry_separator": ""}

	if not await _emit_profiled_dialogue(
		"", "Before empty SHOW", "nvl", profile, "empty-show:1"):
		return
	_presenter._ui_hidden = true
	_presenter.visible = false
	var previous_generation: int = _presenter._dialogue_gen
	var previous_text: String = _presenter.get_node("TextRegion/TextLabel").text

	SignalBus.emit_show_dialogue(
		"", [], "nvl", profile, true, "empty-show:2")
	assert_true(_presenter._ui_hidden,
		"an empty SHOW must not restore a soft-hidden presenter")
	assert_false(_presenter.visible)
	assert_eq(_presenter._dialogue_gen, previous_generation)
	assert_eq(_presenter._active_nvl_page_key, "empty-show:1")
	assert_eq(_presenter.get_node("TextRegion/TextLabel").text, previous_text,
		"an empty SHOW must not clear or replace the active NVL page")


func test_soft_hidden_keyboard_restore_does_not_advance_or_start_ctrl_skip() -> void:
	var game := GAME_SCENE.instantiate()
	add_child_autoqfree(game)
	await get_tree().process_frame
	var presenter: Control = game.get_node("%DialoguePanel")
	var input_handler: Node = game.get_node("InputHandler")
	var advances: Array[bool] = []
	var on_advance := func(): advances.append(true)
	SignalBus.advance_requested.connect(on_advance)
	StellaRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)

	for keycode in [KEY_SPACE, KEY_ENTER, KEY_CTRL]:
		presenter._ui_hidden = true
		presenter.visible = false
		presenter._ctrl_held = false
		var event := InputEventKey.new()
		event.keycode = keycode
		event.pressed = true
		input_handler._unhandled_input(event)

		assert_false(presenter._ui_hidden,
			"%s restores the soft-hidden dialogue" % OS.get_keycode_string(keycode))
		assert_true(presenter.visible)
		assert_false(presenter._ctrl_held,
			"the restoring key must not start Ctrl skipping")
		assert_eq(advances.size(), 0,
			"the key used to restore a soft-hidden dialogue must be consumed")

	SignalBus.advance_requested.disconnect(on_advance)


func test_hiding_dialogue_restores_profile_state_and_clears_active_profile() -> void:
	_presenter = FIXTURE.instantiate()
	add_child_autoqfree(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 0.0

	var text_label: RichTextLabel = _presenter.get_node("TextRegion/TextLabel")
	var background: Control = _presenter.get_node("DialogueBg")
	var adv_chrome: Control = _presenter.get_node("AdvChrome")
	SignalBus.emit_show_dialogue(
		"",
		[{"text": "Before hide"}],
		"nvl",
		{
			"horizontal_alignment": HORIZONTAL_ALIGNMENT_CENTER,
			"background_visible": false,
			"visibility_groups": {"adv_chrome": false},
		},
		true,
	)
	_presenter._ui_hidden = true

	SignalBus.hide_dialogue.emit()
	assert_false(_presenter.visible)
	assert_false(_presenter._ui_hidden,
		"hard hide must clear a soft-hidden state before the next scenario dialogue")
	assert_eq(_rect_anchors(_presenter), AUTHORED_PANEL_ANCHORS)
	assert_eq(_rect_offsets(_presenter), AUTHORED_PANEL_OFFSETS)
	assert_eq(text_label.horizontal_alignment, HORIZONTAL_ALIGNMENT_LEFT)
	assert_true(background.visible)
	assert_eq(background.modulate, AUTHORED_BACKGROUND_MODULATE)
	assert_true(adv_chrome.visible)
	assert_null(_presenter._active_stla_mode_profile)
	assert_false(_presenter._active_uses_stla_presentation)
	assert_eq(_presenter._nvl_text, "")
	await get_tree().process_frame

	await _show_dialogue("After hide", "nvl")
	assert_eq(text_label.text, "After hide",
		"hard hide starts the next NVL block with a fresh accumulator")


func test_builtin_scenes_expose_stla_profile_targets_without_scene_editing() -> void:
	for scene_path in [
		"res://addons/stella/scenes/game.tscn",
		"res://examples/demo/scenes/game.tscn",
	]:
		var game: Node = load(scene_path).instantiate()
		var presenter: Control = game.get_node("UILayer/DialoguePanel")
		var text_target: Control = presenter.get_node(presenter.text_rect_target_path)
		var toolbar: Control = presenter.get_node("%Toolbar")
		assert_eq(presenter.text_rect_target_path, NodePath("HBox"), scene_path)
		assert_false(text_target.get_parent() is Container,
			"the profile target must own its rect in %s" % scene_path)
		assert_true(toolbar.is_in_group("quick_menu"), scene_path)
		assert_false(text_target.is_ancestor_of(toolbar),
			"quick menu must stay at the viewport bottom when the text rect moves")
		game.free()


func test_stla_can_configure_adv_and_restore_it_after_nvl() -> void:
	var source := """@dialogue_profile message panel_anchors=0,0.6,1,1
@dialogue_profile novel background_modulate=#ffffff00
@chapter test "Test"
@scene start
@adv profile=message
「adv before」
@nvl profile=novel
「nvl」
@nvl off
「adv after」"""
	var scenario := DslParser.parse(DslLexer.tokenize(source), "adv_profile")
	assert_eq(scenario.diagnostics, [])
	var commands: Array = scenario.scenes[0].commands
	assert_eq(commands[0].get_string("presentation_profile_name"), "message")
	assert_eq(commands[1].get_string("presentation_profile_name"), "novel")
	assert_eq(commands[2].get_string("presentation_profile_name"), "message")
	assert_eq(commands[2].get_string("mode"), "adv")
	assert_true(commands[2].get_bool("declarative_presentation"))


func _show_dialogue(text: String, mode: String) -> void:
	await _presenter._on_show_dialogue("", [{"text": text}], mode)


func _emit_profiled_dialogue(
	character: String,
	entry_text: String,
	mode: String,
	profile: Dictionary,
	nvl_page_key: String = "",
) -> bool:
	SignalBus.emit_show_dialogue(
		character,
		[{"text": entry_text, "voice": "", "expression": ""}],
		mode,
		profile,
		true,
		nvl_page_key,
	)
	# _on_show_dialogue marks typing active after its initial process-frame
	# synchronization, so do not mistake the pre-typewriter false state for done.
	await get_tree().process_frame
	var completed: bool = await wait_until(
		func():
			return (
				not _presenter._is_typing
				and _presenter.get_node("TextRegion/TextLabel").visible_characters == -1
			),
		1.5,
		"profiled dialogue finishes typing",
	)
	assert_true(completed, "profiled dialogue finishes typing")
	return completed


func _start_scenario_fixture() -> void:
	var file := FileAccess.open(SCENARIO_PATH, FileAccess.READ)
	assert_not_null(file, "fixture must exist: %s" % SCENARIO_PATH)
	if file == null:
		return
	var source := file.get_as_text()
	file.close()
	var scenario := DslParser.parse(DslLexer.tokenize(source), "dialogue_presentation_profile")
	assert_eq(scenario.diagnostics, [], "fixture must parse without diagnostics")
	var first_dialogue: CommandData = scenario.scenes[0].commands[0]
	assert_eq(first_dialogue.get_string("presentation_profile_name"), "novel")
	assert_true(first_dialogue.get_bool("declarative_presentation"))
	assert_false(first_dialogue.params.get("presentation_profile", {}).is_empty(),
		"the compiled command must own its resolved profile data")
	_engine = ScenarioEngine.new()
	_engine.registry = StellaRuntime.registry
	_engine.load_scenario(scenario)
	_engine.run()


func _start_runtime_fixture_at(entry_scene_id: String) -> void:
	_presenter = FIXTURE.instantiate()
	add_child_autoqfree(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 0.0

	var file := FileAccess.open(SCENARIO_PATH, FileAccess.READ)
	assert_not_null(file, "fixture must exist: %s" % SCENARIO_PATH)
	if file == null:
		return
	var source := file.get_as_text()
	file.close()
	var scenario := DslParser.parse(DslLexer.tokenize(source),
		"dialogue_presentation_runtime_pages")
	assert_eq(scenario.diagnostics, [], "runtime page fixture must parse cleanly")
	if not scenario.diagnostics.is_empty():
		return

	_engine = ScenarioEngine.new()
	_engine.registry = StellaRuntime.registry
	_engine.load_scenario(scenario)
	var selected := _engine.context.set_scene(entry_scene_id)
	assert_true(selected, "runtime page fixture scene exists: %s" % entry_scene_id)
	if not selected:
		return
	SignalBus.show_dialogue.connect(_capture_runtime_nvl_event)
	_engine.run()


func _capture_runtime_nvl_event(_character: String, _segments: Array, mode: String) -> void:
	if mode == "nvl":
		_runtime_nvl_event_count += 1
		_runtime_nvl_page_keys.append(SignalBus.current_dialogue_nvl_page_key())


func _wait_for_runtime_nvl(event_count: int, expected_text: String) -> bool:
	# Let DialoguePresenter pass its initial pre-typewriter process-frame await;
	# otherwise a zero interval can look complete before typing has even started.
	await get_tree().process_frame
	var reached: bool = await wait_until(
		func():
			return (
				_runtime_nvl_event_count >= event_count
				and _presenter.get_node("TextRegion/TextLabel").text == expected_text
				and not _presenter._is_typing
				and _presenter.get_node(
					"TextRegion/TextLabel").visible_characters == -1
			),
		1.5,
		"runtime NVL event %d displays '%s'" % [event_count, expected_text],
	)
	assert_true(reached,
		"runtime NVL event %d displays '%s'" % [event_count, expected_text])
	return reached


func _assert_nested_runtime_path(
	entry_scene_id: String,
	branch_text: String,
	restarts_page: bool,
) -> void:
	await _start_runtime_fixture_at(entry_scene_id)
	if not await _wait_for_runtime_nvl(1, "・Nested seed"):
		return
	var context_id := _engine.context.get_instance_id()
	var first_page_key := "%d:1" % context_id
	assert_eq(_runtime_nvl_page_keys[0], first_page_key)

	SignalBus.advance_requested.emit()
	var branch_visible_text := (
		"・%s" % branch_text
		if restarts_page
		else "・Nested seed・%s" % branch_text
	)
	if not await _wait_for_runtime_nvl(2, branch_visible_text):
		return
	var expected_epoch := 2 if restarts_page else 1
	var branch_page_key := "%d:%d" % [context_id, expected_epoch]
	assert_eq(_runtime_nvl_page_keys[1], branch_page_key,
		"only the selected nested branch may change the runtime page")
	if restarts_page:
		assert_ne(branch_page_key, first_page_key,
			"the selected off -> NVL branch must activate a fresh page")
	else:
		assert_eq(branch_page_key, first_page_key,
			"an unselected reset branch must not change the active page")
	assert_eq(_presenter._active_nvl_page_key, branch_page_key)
	assert_eq(_engine.context.nvl_page_epoch, expected_epoch)

	SignalBus.advance_requested.emit()
	var continuation_text := branch_visible_text + "・Nested continuation"
	if not await _wait_for_runtime_nvl(3, continuation_text):
		return
	assert_eq(_runtime_nvl_page_keys[2], branch_page_key,
		"the join continuation must inherit the selected nested branch page")
	assert_eq(_presenter._active_nvl_page_key, branch_page_key)

	await _advance_runtime_to_finish("%s nested fixture" % entry_scene_id)


func _advance_runtime_to_finish(fixture_name: String) -> void:
	SignalBus.advance_requested.emit()
	var finished: bool = await wait_until(
		func(): return _engine.context.is_finished,
		1.0,
		"%s reaches its terminal jump" % fixture_name,
	)
	assert_true(finished, "%s reaches its terminal jump" % fixture_name)


func _wait_for_dialogue(command_index: int, expected_text: String) -> bool:
	var reached: bool = await wait_until(
		func():
			return (
				_engine.context.current_command_index == command_index
				and _presenter.get_node("TextRegion/TextLabel").text == expected_text
				and not _presenter._is_typing
			),
		1.0,
		"fixture presents command %d" % command_index,
	)
	assert_true(reached, "fixture presents command %d" % command_index)
	return reached


func _rect_anchors(control: Control) -> Vector4:
	return Vector4(
		control.anchor_left, control.anchor_top,
		control.anchor_right, control.anchor_bottom)


func _rect_offsets(control: Control) -> Vector4:
	return Vector4(
		control.offset_left, control.offset_top,
		control.offset_right, control.offset_bottom)
