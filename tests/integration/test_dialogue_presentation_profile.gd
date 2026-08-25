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
var _owned_nodes: Array[Node] = []


func before_each() -> void:
	_presenter = null
	_engine = null
	_runtime_nvl_event_count = 0
	_runtime_nvl_page_keys.clear()
	_owned_nodes.clear()
	StellaRuntime.auto_play.is_active = false
	StellaRuntime.skip_controller.is_active = false


func after_each() -> void:
	if _engine != null and _engine.context != null and not _engine.context.is_finished:
		_engine.context.is_finished = true
		SignalBus.engine_abort_requested.emit()
		await get_tree().process_frame
	if SignalBus.show_dialogue.is_connected(_capture_runtime_nvl_event):
		SignalBus.show_dialogue.disconnect(_capture_runtime_nvl_event)
	SignalBus.hide_dialogue.emit()
	await _release_owned_nodes()
	_presenter = null
	_engine = null
	_runtime_nvl_page_keys.clear()


func _add_owned_node(node: Node) -> void:
	_owned_nodes.append(node)
	add_child_autoqfree(node)


func _release_owned_nodes() -> void:
	for node: Node in _owned_nodes:
		if not is_instance_valid(node):
			continue
		if node.is_inside_tree():
			var exited: Signal = node.tree_exited
			if not node.is_queued_for_deletion():
				node.queue_free()
			await exited
		elif is_instance_valid(node):
			node.free()
	_owned_nodes.clear()
	await get_tree().process_frame


func test_nvl_profile_accumulates_three_prefixed_entries_and_restores_authored_adv() -> void:
	_presenter = FIXTURE.instantiate()
	_add_owned_node(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 0.0

	_start_scenario_fixture()
	if not await _wait_for_dialogue(0, "・First"):
		return
	_presenter.request_current_dialogue_advance()
	if not await _wait_for_dialogue(1, "・First・Second"):
		return
	_presenter.request_current_dialogue_advance()
	if not await _wait_for_dialogue(2, "・First・Second・Third"):
		return

	var text_label: RichTextLabel = _presenter.get_node("TextRegion/TextLabel")
	var text_region: Control = _presenter.get_node("TextRegion")
	var background: Control = _presenter.get_node("DialogueBg")
	var adv_chrome: Control = _presenter.get_node("AdvChrome")
	var quick_menu: Control = _presenter.get_node("Toolbar")
	assert_eq(_presenter._nvl_render_source, "・First・Second・Third")
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

	_presenter.request_current_dialogue_advance()
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

	_presenter.request_current_dialogue_advance()
	var finished: bool = await wait_until(
		func(): return _engine.context.is_finished,
		1.0,
		"dialogue presentation fixture reaches @end",
	)
	assert_true(finished)


func test_nvl_snapshot_restore_rebuilds_the_authored_page() -> void:
	_presenter = FIXTURE.instantiate()
	_add_owned_node(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 0.0

	_start_scenario_fixture()
	if not await _wait_for_dialogue(0, "・First"):
		return
	_presenter.request_current_dialogue_advance()
	if not await _wait_for_dialogue(1, "・First・Second"):
		return
	var snapshot := _engine.context.capture_snapshot()
	var scenario := _engine.context.scenario_data
	assert_eq(snapshot.get("nvl_page_entries", []).size(), 2)

	# Save/load hard-resets presentation nodes, then re-executes the saved command
	# in a fresh ScenarioContext. The restored page must come from authored entries
	# in the snapshot, not from the retired RichTextLabel string.
	_engine.context.is_finished = true
	SignalBus.engine_abort_requested.emit()
	await get_tree().process_frame
	SignalBus.hide_dialogue.emit()
	assert_eq(_presenter._nvl_text, "")

	var restored_engine := ScenarioEngine.new()
	restored_engine.registry = StellaRuntime.registry
	restored_engine.load_scenario(scenario)
	restored_engine.context.restore_snapshot(snapshot)
	_engine = restored_engine
	_engine.run()

	if not await _wait_for_dialogue(1, "・First・Second"):
		return
	assert_eq(_engine.context.nvl_page_entries.size(), 2,
		"re-executing the restored current command must not duplicate its entry")


func test_nvl_save_restore_preserves_each_entrys_original_profile_format() -> void:
	await _start_runtime_fixture_at("cross_profile_restore")
	if not await _wait_for_runtime_nvl(1, "AOne"):
		return
	_presenter.request_current_dialogue_advance()
	if not await _wait_for_runtime_nvl(2, "AOne~BTwo"):
		return
	var snapshot := _round_trip_context_through_save_file(_engine.context)
	_assert_cross_profile_snapshot_is_authored_only(snapshot)

	await _restore_runtime_snapshot(snapshot)
	if not await _wait_for_runtime_nvl(3, "AOne~BTwo"):
		return
	assert_eq(_engine.context.nvl_page_entries.size(), 2,
		"save restore must not duplicate the re-executed current entry")


func test_nvl_backlog_rollback_preserves_each_entrys_original_profile_format() -> void:
	await _start_runtime_fixture_at("cross_profile_restore")
	if not await _wait_for_runtime_nvl(1, "AOne"):
		return
	_presenter.request_current_dialogue_advance()
	if not await _wait_for_runtime_nvl(2, "AOne~BTwo"):
		return
	var backlog := BacklogManager.new()
	backlog.add_entry(
		"", [{"text": "Two", "voice": ""}], 2,
		func(): return _engine.context.capture_snapshot(), [], "rollback:two")
	var rollback_snapshot: Dictionary = backlog.jump_to(0).get("snapshot", {})
	_assert_cross_profile_snapshot_is_authored_only(rollback_snapshot)

	await _restore_runtime_snapshot(rollback_snapshot)
	if not await _wait_for_runtime_nvl(3, "AOne~BTwo"):
		return
	assert_eq(_presenter._nvl_render_source, "AOne~BTwo",
		"Backlog rollback under the second Profile cannot rewrite the first entry")


func test_runtime_jump_reentry_starts_a_fresh_nvl_page_after_off() -> void:
	await _start_runtime_fixture_at("jump_loop_entry")
	if not await _wait_for_runtime_nvl(1, "・Jump page"):
		return
	var first_page_key := _runtime_nvl_page_keys[0]
	var first_generation: int = _presenter._dialogue_gen
	assert_eq(first_page_key, "%d:1" % _engine.context.get_instance_id())
	assert_eq(_presenter._active_nvl_page_key, first_page_key)

	_presenter.request_current_dialogue_advance()
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
	assert_eq(_presenter._nvl_render_source, "・Jump page",
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

	_presenter.request_current_dialogue_advance()
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
	assert_eq(_presenter._nvl_render_source, "・Called page",
		"each @call activation must get a fresh page even for the same command")

	await _advance_runtime_to_finish("repeated-call fixture")


func test_true_branch_nvl_page_continues_after_the_conditional() -> void:
	await _start_runtime_fixture_at("branch_true_entry")
	if not await _wait_for_runtime_nvl(1, "・True branch"):
		return

	_presenter.request_current_dialogue_advance()
	if not await _wait_for_runtime_nvl(2, "・True branch・After branch"):
		return
	assert_eq(_presenter._nvl_render_source,
		"・True branch・After branch",
		"the continuation must inherit the runtime page selected by the true branch")

	await _advance_runtime_to_finish("true-branch fixture")


func test_false_branch_nvl_page_continues_after_the_conditional() -> void:
	await _start_runtime_fixture_at("branch_false_entry")
	if not await _wait_for_runtime_nvl(1, "・False branch"):
		return

	_presenter.request_current_dialogue_advance()
	if not await _wait_for_runtime_nvl(2, "・False branch・After branch"):
		return
	assert_eq(_presenter._nvl_render_source,
		"・False branch・After branch",
		"the continuation must inherit the runtime page selected by the false branch")

	await _advance_runtime_to_finish("false-branch fixture")


func test_repeated_nvl_directive_without_off_keeps_the_runtime_page() -> void:
	await _start_runtime_fixture_at("repeated_nvl_entry")
	if not await _wait_for_runtime_nvl(1, "・Repeated one"):
		return

	_presenter.request_current_dialogue_advance()
	if not await _wait_for_runtime_nvl(2, "・Repeated one・Repeated two"):
		return
	assert_eq(_presenter._nvl_render_source,
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
	_add_owned_node(_presenter)
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
		_presenter._nvl_render_source,
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
	_add_owned_node(_presenter)
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

	assert_eq(_presenter._nvl_render_source, "›One ›Two")


func test_nvl_prefix_is_the_first_typed_character_and_avatar_marker_is_local() -> void:
	_presenter = FIXTURE.instantiate()
	_add_owned_node(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 1.0

	SignalBus.emit_show_dialogue(
		"narrator",
		[{"text": "[expr:thoughtful]Text", "voice": ""}],
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
	assert_eq(_presenter._avatar_expressions.get("narrator"), "thoughtful",
		"a zero-offset marker should initialize dialogue avatar state only")

	SignalBus.hide_dialogue.emit()


func test_nvl_typewriter_keeps_history_visible_and_types_only_the_new_entry() -> void:
	_presenter = FIXTURE.instantiate()
	_add_owned_node(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 0.0
	var profile := {"entry_prefix": "・", "entry_separator": "\n"}
	if not await _emit_profiled_dialogue("", "Old", "nvl", profile):
		return

	_presenter._char_interval = 1.0
	SignalBus.emit_show_dialogue(
		"",
		[{"text": "New", "voice": ""}],
		"nvl",
		profile,
		true,
	)
	var text_label: RichTextLabel = _presenter.get_node("TextRegion/TextLabel")
	var history_length := "・Old\n".length()
	assert_eq(_presenter._nvl_render_source, "・Old\n・New")
	assert_eq(text_label.visible_characters, history_length,
		"the accumulated entry and separator are visible before new typing starts")

	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(text_label.visible_characters, history_length + 1,
		"the first new typewriter step reveals only the next entry prefix")
	SignalBus.hide_dialogue.emit()


func test_leaving_nvl_for_overlay_or_adv_resets_the_accumulator() -> void:
	_presenter = FIXTURE.instantiate()
	_add_owned_node(_presenter)
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
	_add_owned_node(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 0.0
	var profile := {"entry_prefix": "・", "entry_separator": ""}

	if not await _emit_profiled_dialogue("", "Old", "nvl", profile, "scenario-a:11"):
		return
	if not await _emit_profiled_dialogue("", "New", "nvl", profile, "scenario-a:12"):
		return
	assert_eq(_presenter._nvl_render_source, "・New",
		"a different runtime NVL page key starts a fresh page")

	if not await _emit_profiled_dialogue("", "Continued", "nvl", profile, "scenario-a:12"):
		return
	assert_eq(_presenter._nvl_render_source, "・New・Continued",
		"entries with the same page key keep accumulating")


func test_nvl_decoration_does_not_mutate_segments_or_backlog_text() -> void:
	_presenter = FIXTURE.instantiate()
	_add_owned_node(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 1.0
	var segments := [{
		"text": "Original source text",
		"voice": "",
	}]

	SignalBus.emit_show_dialogue(
		"Narrator",
		segments,
		"nvl",
		{"entry_prefix": "・", "entry_separator": ""},
		true,
	)
	assert_eq(
		_presenter._nvl_render_source,
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
	_add_owned_node(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 1.0
	var context := ScenarioContext.new(scenario)
	context.apply_dialogue_mode_events(command.dialogue_mode_events_before)
	SignalBus.emit_show_dialogue(
		command.get_string("character"),
		segments,
		context.current_dialogue_mode,
		context.resolve_current_dialogue_profile(),
		context.current_dialogue_uses_declarative_presentation,
	)
	assert_eq(_presenter._nvl_render_source, "・FirstSecond")
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
	_add_owned_node(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 0.0

	await _show_dialogue("One", "nvl")
	await _show_dialogue("Two", "nvl")
	assert_eq(_presenter._nvl_render_source, "※One※Two")


func test_named_profile_without_entry_format_keeps_legacy_newline() -> void:
	_presenter = FIXTURE.instantiate()
	_add_owned_node(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 0.0
	var layout_only_profile := {"horizontal_alignment": HORIZONTAL_ALIGNMENT_CENTER}

	if not await _emit_profiled_dialogue("", "One", "nvl", layout_only_profile):
		return
	if not await _emit_profiled_dialogue("", "Two", "nvl", layout_only_profile):
		return
	assert_eq(_presenter._nvl_render_source, "One\nTwo",
		"entry formatting remains legacy-compatible when a profile only changes layout")


func test_missing_nvl_profile_uses_legacy_layout_then_restores_toolbar_in_adv() -> void:
	_presenter = FIXTURE.instantiate()
	_presenter.presentation_profile = DialoguePresentationProfile.new()
	_add_owned_node(_presenter)
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
	_add_owned_node(_presenter)
	await get_tree().process_frame
	assert_push_warning(
		"DialoguePresenter profile 'nvl': entry_prefix is plain text and cannot contain BBCode brackets")
	assert_push_warning(
		"DialoguePresenter profile 'nvl': panel_anchors must be ordered left <= right and top <= bottom")

	_presenter._char_interval = 0.0
	await _show_dialogue("Fallback", "nvl")
	assert_eq(_rect_anchors(_presenter), Vector4(0.0, 0.0, 1.0, 1.0))
	assert_almost_eq(_presenter.modulate.a, 0.9, 0.0001)
	assert_eq(_presenter._nvl_render_source, "Fallback",
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


func test_profile_selection_is_compiled_into_runtime_sidecars_and_off_restores_adv() -> void:
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
	assert_eq(scenario.get_dialogue_profile("centered").get(
		"horizontal_alignment"), HORIZONTAL_ALIGNMENT_CENTER)
	assert_true(overlay_command.get_bool("presentation_from_context"))
	assert_true(adv_command.get_bool("presentation_from_context"))
	assert_eq(overlay_command.dialogue_mode_events_before, [{
		"action": "select_mode",
		"mode": "overlay",
		"profile_name": "centered",
	}])
	assert_eq(adv_command.dialogue_mode_events_before, [{
		"action": "restore_adv",
		"mode": "adv",
	}])

	var context := ScenarioContext.new(scenario)
	context.apply_dialogue_mode_events(overlay_command.dialogue_mode_events_before)
	assert_eq(context.current_dialogue_mode, "overlay")
	assert_eq(context.current_dialogue_profile_name, "centered")
	context.apply_dialogue_mode_events(adv_command.dialogue_mode_events_before)
	assert_eq(context.current_dialogue_mode, "adv")
	assert_eq(context.current_dialogue_profile_name, "")
	assert_true(context.current_dialogue_uses_declarative_presentation,
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
	var profile := scenario.get_dialogue_profile("novel")
	assert_eq(profile["visibility_groups"], {
		"quick_menu": true,
		"adv_chrome": false,
	})
	assert_eq(profile["line_spacing"], 7)
	assert_false(profile.has("show"), "show is only an STLA authoring alias")
	assert_false(profile.has("hide"), "hide is only an STLA authoring alias")


func test_stla_properties_are_independent_and_preserve_unwritten_authored_values() -> void:
	_presenter = FIXTURE.instantiate()
	_add_owned_node(_presenter)
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
	_add_owned_node(_presenter)
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
	_add_owned_node(_presenter)
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
	assert_eq(_presenter._nvl_render_source, "・After soft hide",
		"the hidden SHOW must render rather than leave the previous page on screen")


func test_empty_segments_do_not_mutate_soft_hide_or_nvl_page_state() -> void:
	_presenter = FIXTURE.instantiate()
	_add_owned_node(_presenter)
	await get_tree().process_frame
	_presenter._char_interval = 0.0
	var profile := {"entry_prefix": "・", "entry_separator": ""}

	if not await _emit_profiled_dialogue(
		"", "Before empty SHOW", "nvl", profile, "empty-show:1"):
		return
	_presenter._ui_hidden = true
	_presenter.visible = false
	var previous_generation: int = _presenter._dialogue_gen
	var previous_text: String = _presenter._nvl_render_source

	SignalBus.emit_show_dialogue(
		"", [], "nvl", profile, true, "empty-show:2")
	assert_true(_presenter._ui_hidden,
		"an empty SHOW must not restore a soft-hidden presenter")
	assert_false(_presenter.visible)
	assert_eq(_presenter._dialogue_gen, previous_generation)
	assert_eq(_presenter._active_nvl_page_key, "empty-show:1")
	assert_eq(_presenter._nvl_render_source, previous_text,
		"an empty SHOW must not clear or replace the active NVL page")


func test_soft_hidden_keyboard_restore_does_not_advance_or_start_ctrl_skip() -> void:
	var game := GAME_SCENE.instantiate()
	_add_owned_node(game)
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
	_add_owned_node(_presenter)
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
		add_child(game)
		await get_tree().process_frame
		var presenter: Control = game.get_node("UILayer/DialoguePanel")
		var text_target: Control = presenter.get_node(presenter.text_rect_target_path)
		var toolbar: Control = presenter.get_node("%Toolbar")
		assert_eq(presenter.text_rect_target_path, NodePath("HBox"), scene_path)
		assert_false(text_target.get_parent() is Container,
			"the profile target must own its rect in %s" % scene_path)
		assert_true(toolbar.is_in_group("quick_menu"), scene_path)
		var avatar: CanvasItem = presenter.get_node("HBox/AvatarContainer")
		assert_true(avatar.is_in_group("dialogue_surface"),
			"surface ownership includes the avatar in %s" % scene_path)
		var voice_progress := presenter.get_node_or_null(
			"HBox/TextArea/MarginContainer/VBox/NameRow/VoiceProgressBar")
		if scene_path == "res://examples/demo/scenes/game.tscn":
			assert_not_null(voice_progress)
			if voice_progress != null:
				assert_true((voice_progress as CanvasItem).is_in_group("dialogue_surface"),
					"demo voice progress belongs to the Dialogue surface")
		var avatar_baseline := avatar.visible
		var toolbar_baseline := toolbar.visible
		var voice_baseline := (
			(voice_progress as CanvasItem).visible if voice_progress != null else false)
		presenter.set("_canonical_dialogue_visibility", {
			"surface": false, "quick_menu": true,
		})
		presenter.call("_apply_canonical_dialogue_visibility")
		assert_false(avatar.visible,
			"canonical surface hide reaches the real avatar in %s" % scene_path)
		if voice_progress != null:
			assert_false((voice_progress as CanvasItem).visible,
				"canonical surface hide reaches demo voice progress")
		assert_eq(toolbar.visible, toolbar_baseline,
			"surface hide is independent from the real quick menu")
		presenter.set("_canonical_dialogue_visibility", {
			"surface": true, "quick_menu": true,
		})
		presenter.call("_apply_canonical_dialogue_visibility")
		assert_eq(avatar.visible, avatar_baseline,
			"surface show restores the real avatar Profile baseline")
		if voice_progress != null:
			assert_eq((voice_progress as CanvasItem).visible, voice_baseline,
				"surface show restores demo voice progress Profile baseline")
		assert_eq(toolbar.visible, toolbar_baseline)
		assert_false(text_target.is_ancestor_of(toolbar),
			"quick menu must stay at the viewport bottom when the text rect moves")
		game.free()


func test_profile_visibility_baseline_and_canonical_surface_mask_are_orthogonal() -> void:
	_presenter = FIXTURE.instantiate()
	_add_owned_node(_presenter)
	await get_tree().process_frame
	var surface: CanvasItem = _presenter.get_node("DialogueBg")
	surface.add_to_group("dialogue_surface")
	var profile_surface_groups: Array[String] = ["dialogue_surface"]
	var profile_quick_groups: Array[String] = ["quick_menu"]
	_presenter.call("_resolve_dialogue_visibility_binding", {
		"current": {
			"profile_name": "baseline_probe",
			"provenance": {},
			"surface_groups": profile_surface_groups,
			"quick_menu_groups": profile_quick_groups,
		},
		"default": {
			"surface_groups": profile_surface_groups,
			"quick_menu_groups": profile_quick_groups,
		},
		"nvl_entries": [],
	})
	var profile := DialogueModeProfile.from_dictionary({
		"visibility_groups": {"dialogue_surface": false},
		"surface_groups": profile_surface_groups,
		"quick_menu_groups": profile_quick_groups,
	})
	_presenter.call("_apply_mode_profile", "adv", profile)
	_presenter.set("_canonical_dialogue_visibility", {
		"surface": true, "quick_menu": true,
	})
	_presenter.call("_apply_canonical_dialogue_visibility")
	assert_false(surface.visible,
		"canonical show cannot override the current Profile desired-hidden baseline")
	_presenter.set("_canonical_dialogue_visibility", {
		"surface": false, "quick_menu": true,
	})
	_presenter.call("_apply_canonical_dialogue_visibility")
	assert_false(surface.visible)
	_presenter.set("_canonical_dialogue_visibility", {
		"surface": true, "quick_menu": true,
	})
	_presenter.call("_apply_canonical_dialogue_visibility")
	assert_false(surface.visible,
		"hide then show preserves the Profile visibility baseline")


func test_profile_switch_rebinds_canonical_surface_to_the_new_owned_group() -> void:
	_presenter = FIXTURE.instantiate()
	_add_owned_node(_presenter)
	await get_tree().process_frame
	var adv_chrome: CanvasItem = _presenter.get_node("AdvChrome")
	var text_region: CanvasItem = _presenter.get_node("TextRegion")
	adv_chrome.add_to_group("adv_surface")
	text_region.add_to_group("nvl_surface")
	_presenter.set("_canonical_dialogue_visibility", {
		"surface": false, "quick_menu": true,
	})
	var adv_surface_groups: Array[String] = ["adv_surface"]
	var quick_groups: Array[String] = ["quick_menu"]
	var adv_profile := DialogueModeProfile.from_dictionary({
		"surface_groups": adv_surface_groups,
		"quick_menu_groups": quick_groups,
	})
	_presenter.call("_apply_mode_profile", "adv", adv_profile)
	var adv_binding: Dictionary = _presenter.get("_dialogue_visibility_binding")
	assert_eq(adv_binding.get("current", {}).get("surface_groups"), ["adv_surface"])
	assert_false(adv_chrome.visible)
	var nvl_surface_groups: Array[String] = ["nvl_surface"]
	var nvl_profile := DialogueModeProfile.from_dictionary({
		"surface_groups": nvl_surface_groups,
		"quick_menu_groups": quick_groups,
	})
	_presenter.call("_apply_mode_profile", "nvl", nvl_profile)
	var nvl_binding: Dictionary = _presenter.get("_dialogue_visibility_binding")
	assert_eq(nvl_binding.get("current", {}).get("surface_groups"), ["nvl_surface"],
		"profile switch resolves the new authored ownership groups")
	assert_true(adv_chrome.visible, "old Profile group is restored after rebind")
	assert_false(text_region.visible, "canonical hidden follows the new Profile group")


func test_actual_mode_transaction_captures_new_profile_before_hidden_gate() -> void:
	_presenter = FIXTURE.instantiate()
	_add_owned_node(_presenter)
	await get_tree().process_frame
	var adv_chrome: CanvasItem = _presenter.get_node("AdvChrome")
	var text_region: CanvasItem = _presenter.get_node("TextRegion")
	adv_chrome.add_to_group("profile_a_surface")
	text_region.add_to_group("profile_b_surface")
	_presenter.set("_canonical_dialogue_visibility", {
		"surface": false, "quick_menu": true,
	})
	var profile_a_surface_groups: Array[String] = ["profile_a_surface"]
	var profile_b_surface_groups: Array[String] = ["profile_b_surface"]
	var profile_quick_menu_groups: Array[String] = ["quick_menu"]
	var profile_a := DialogueModeProfile.from_dictionary({
		"surface_groups": profile_a_surface_groups,
		"quick_menu_groups": profile_quick_menu_groups,
	})
	var profile_b := DialogueModeProfile.from_dictionary({
		"surface_groups": profile_b_surface_groups,
		"quick_menu_groups": profile_quick_menu_groups,
	})
	_presenter.call("_apply_dialogue_mode_presentation", "adv", profile_a, true)
	assert_false(adv_chrome.visible)
	_presenter.call("_apply_dialogue_mode_presentation", "nvl", profile_b, true)
	assert_true(adv_chrome.visible, "profile A authored state is restored")
	assert_false(text_region.visible, "new profile B is immediately canonical-gated")
	_presenter.set("_canonical_dialogue_visibility", {
		"surface": true, "quick_menu": true,
	})
	_presenter.call("_apply_canonical_dialogue_visibility")
	assert_true(text_region.visible,
		"old canonical=false never contaminates profile B desired baseline")


func test_profile_to_no_profile_rebuilds_default_binding_and_restores_custom_group() -> void:
	_presenter = FIXTURE.instantiate()
	_add_owned_node(_presenter)
	await get_tree().process_frame
	var custom: CanvasItem = _presenter.get_node("AdvChrome")
	var default_surface: CanvasItem = _presenter.get_node("DialogueBg")
	custom.add_to_group("custom_surface")
	default_surface.add_to_group("dialogue_surface")
	var custom_surface_groups: Array[String] = ["custom_surface"]
	var default_quick_menu_groups: Array[String] = ["quick_menu"]
	var profile := DialogueModeProfile.from_dictionary({
		"surface_groups": custom_surface_groups,
		"quick_menu_groups": default_quick_menu_groups,
		"visibility_groups": {"custom_surface": false},
	})
	_presenter.call("_apply_dialogue_mode_presentation", "adv", profile, true)
	assert_false(custom.visible)
	_presenter.call("_apply_dialogue_mode_presentation", "adv", null, false)
	var binding: Dictionary = _presenter.get("_dialogue_visibility_binding")
	assert_eq(binding.get("current", {}).get("profile_name"), "")
	assert_eq(binding.get("current", {}).get("provenance"), {})
	assert_eq(binding.get("current", {}).get("surface_groups"), ["dialogue_surface"])
	assert_eq(binding.get("current", {}).get("quick_menu_groups"), ["quick_menu"])
	assert_true(custom.visible, "leaving the profile restores its custom group")
	_presenter.set("_canonical_dialogue_visibility", {
		"surface": false, "quick_menu": true,
	})
	_presenter.call("_apply_canonical_dialogue_visibility")
	assert_false(default_surface.visible, "default surface owns the canonical gate")
	assert_true(custom.visible, "old custom group is no longer canonical-owned")


func test_demo_voice_progress_runtime_baseline_survives_real_cut_hide_show() -> void:
	var game: Node = load("res://examples/demo/scenes/game.tscn").instantiate()
	_add_owned_node(game)
	await get_tree().process_frame
	var presenter: Control = game.get_node("UILayer/DialoguePanel")
	var voice_progress: CanvasItem = presenter.get_node(
		"HBox/TextArea/MarginContainer/VBox/NameRow/VoiceProgressBar")
	var toolbar: CanvasItem = presenter.get_node("%Toolbar")
	voice_progress.visible = true
	var toolbar_before := toolbar.visible
	presenter.call("_on_dialogue_visibility_operations_requested", [{
		"target": "surface", "action": "hide",
		"transition": "cut", "duration": 0.0,
	}], true)
	assert_false(voice_progress.visible)
	assert_eq(toolbar.visible, toolbar_before)
	presenter.call("_on_dialogue_visibility_operations_requested", [{
		"target": "surface", "action": "show",
		"transition": "cut", "duration": 0.0,
	}], true)
	assert_true(voice_progress.visible,
		"cut show restores the latest runtime-visible surface baseline")
	assert_eq(toolbar.visible, toolbar_before, "surface cuts leave quick menu unchanged")


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
	var context := ScenarioContext.new(scenario)
	var states: Array = []
	for command in commands:
		context.apply_dialogue_mode_events(command.dialogue_mode_events_before)
		states.append({
			"mode": context.current_dialogue_mode,
			"profile_name": context.current_dialogue_profile_name,
			"declarative": context.current_dialogue_uses_declarative_presentation,
		})
	assert_eq(states, [
		{"mode": "adv", "profile_name": "message", "declarative": true},
		{"mode": "nvl", "profile_name": "novel", "declarative": true},
		{"mode": "adv", "profile_name": "message", "declarative": true},
	])


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
		[{"text": entry_text, "voice": ""}],
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
	assert_true(first_dialogue.get_bool("presentation_from_context"))
	assert_eq(first_dialogue.dialogue_mode_events_before, [{
		"action": "select_mode",
		"mode": "nvl",
		"profile_name": "novel",
	}])
	assert_false(scenario.get_dialogue_profile("novel").is_empty(),
		"ScenarioData must own the profile selected by runtime sidecars")
	_engine = ScenarioEngine.new()
	_engine.registry = StellaRuntime.registry
	_engine.load_scenario(scenario)
	_engine.run()


func _start_runtime_fixture_at(entry_scene_id: String) -> void:
	_presenter = FIXTURE.instantiate()
	_add_owned_node(_presenter)
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


func _assert_cross_profile_snapshot_is_authored_only(snapshot: Dictionary) -> void:
	var entries: Array = snapshot.get("nvl_page_entries", [])
	assert_eq(entries.size(), 2)
	if entries.size() != 2:
		return
	assert_eq(entries[0].get("profile_name"), "restore_first")
	assert_eq(entries[1].get("profile_name"), "restore_second")
	for entry in entries:
		assert_false(entry.has("presentation_profile"),
			"snapshot entries persist Profile names, not resolved dictionaries")
		assert_false(entry.has("presentation_provenance"),
			"snapshot entries do not serialize diagnostic/runtime metadata")


func _round_trip_context_through_save_file(context: ScenarioContext) -> Dictionary:
	var save_manager := SaveManager.new()
	save_manager.save_dir = "user://test_cross_profile_nvl_save/"
	const SLOT := 154
	save_manager.delete_save(SLOT)
	save_manager.register_provider(context)
	save_manager.save(SLOT)
	assert_true(save_manager.has_save(SLOT),
		"the regression must exercise SaveManager's JSON file boundary")

	var restored := ScenarioContext.new(context.scenario_data)
	save_manager.register_provider(restored)
	assert_true(save_manager.load_save(SLOT))
	save_manager.delete_save(SLOT)
	return restored.capture_snapshot()


func _restore_runtime_snapshot(snapshot: Dictionary) -> void:
	var scenario: ScenarioData = _engine.context.scenario_data
	_engine.context.is_finished = true
	SignalBus.engine_abort_requested.emit()
	await get_tree().process_frame
	SignalBus.hide_dialogue.emit()
	assert_eq(_presenter._nvl_render_source, "",
		"hard reset retires only the Presenter's derived NVL document")

	var restored_engine := ScenarioEngine.new()
	restored_engine.registry = StellaRuntime.registry
	restored_engine.load_scenario(scenario)
	restored_engine.context.restore_snapshot(snapshot)
	_engine = restored_engine
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
				and _presenter._nvl_render_source == expected_text
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

	_presenter.request_current_dialogue_advance()
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

	_presenter.request_current_dialogue_advance()
	var continuation_text := branch_visible_text + "・Nested continuation"
	if not await _wait_for_runtime_nvl(3, continuation_text):
		return
	assert_eq(_runtime_nvl_page_keys[2], branch_page_key,
		"the join continuation must inherit the selected nested branch page")
	assert_eq(_presenter._active_nvl_page_key, branch_page_key)

	await _advance_runtime_to_finish("%s nested fixture" % entry_scene_id)


func _advance_runtime_to_finish(fixture_name: String) -> void:
	_presenter.request_current_dialogue_advance()
	var finished: bool = await wait_until(
		func(): return _engine.context.is_finished,
		1.0,
		"%s reaches its terminal jump" % fixture_name,
	)
	assert_true(finished, "%s reaches its terminal jump" % fixture_name)


func _wait_for_dialogue(command_index: int, expected_text: String) -> bool:
	var reached: bool = await wait_until(
		func():
			var presenter_text: String = (
				_presenter._nvl_render_source
				if _presenter._current_mode == "nvl"
				else String(_presenter.get_node("TextRegion/TextLabel").text)
			)
			return (
				_engine.context.current_command_index == command_index
				and presenter_text == expected_text
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
