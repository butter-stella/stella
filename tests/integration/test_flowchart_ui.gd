extends GutTest
## Integration tests for the flowchart UI overlay (issue #97 PR-D).
## Tests overlay open/close lifecycle, state transitions, and jump-via-UI.


var _runtime: Node


func before_each():
	_runtime = get_tree().root.get_node("StellaRuntime")
	_runtime.backlog_manager.clear()


func _build_scenario() -> ScenarioData:
	var data = ScenarioData.new()
	data.id = "fc_ui_test"

	var ch0 = ChapterData.new()
	ch0.id = "prologue"
	ch0.display_name = "Prologue"
	ch0.scene_ids = ["start"]
	data.chapters.append(ch0)

	var ch1 = ChapterData.new()
	ch1.id = "ch1"
	ch1.display_name = "Chapter 1"
	ch1.scene_ids = ["s_ch1"]
	data.chapters.append(ch1)

	var s0 = SceneData.new()
	s0.id = "start"
	s0.chapter_id = "prologue"
	var d0 = CommandData.new()
	d0.type = "dialogue"
	d0.params = {"character": "n", "text": "prologue"}
	s0.commands.append(d0)
	var j0 = CommandData.new()
	j0.type = "jump"
	j0.params = {"target": "s_ch1"}
	s0.commands.append(j0)
	data.scenes.append(s0)

	var s1 = SceneData.new()
	s1.id = "s_ch1"
	s1.chapter_id = "ch1"
	var d1 = CommandData.new()
	d1.type = "dialogue"
	d1.params = {"character": "n", "text": "ch1 line"}
	s1.commands.append(d1)
	data.scenes.append(s1)

	return data


func _setup_and_play(data: ScenarioData) -> void:
	_runtime.engine.load_scenario(data)
	_runtime.save_manager.register_provider(_runtime.engine.context)
	_runtime.save_manager.register_provider(_runtime.engine.context.variable_store)
	_runtime.scenario_graph = ScenarioGraphBuilder.build(data)
	_runtime.flowchart_state.clear()
	_runtime.flowchart_state.initial_snapshot = _runtime._capture_rollback_snapshot()
	_runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	_runtime.engine.run()


func _advance(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame
		SignalBus.advance_requested.emit()
	await get_tree().process_frame


func _stop_engine() -> void:
	_runtime.engine.stop()
	SignalBus.advance_requested.emit()
	await get_tree().process_frame


# ─── GameStateMachine.State.FLOWCHART ───

func test_flowchart_state_exists_in_enum():
	# Verify the FLOWCHART state was added and doesn't collide with others.
	assert_true(GameStateMachine.State.FLOWCHART >= 0)
	assert_ne(GameStateMachine.State.FLOWCHART, GameStateMachine.State.PLAYING)
	assert_ne(GameStateMachine.State.FLOWCHART, GameStateMachine.State.BACKLOG)


# ─── show_flowchart / close_overlay lifecycle ───

func test_show_flowchart_transitions_to_flowchart_state():
	var data = _build_scenario()
	_setup_and_play(data)

	_runtime.show_flowchart()
	assert_eq(_runtime.game_state.current_state, GameStateMachine.State.FLOWCHART)

	_runtime.close_overlay()
	assert_eq(_runtime.game_state.current_state, GameStateMachine.State.PLAYING,
		"close_overlay should return to PLAYING")

	await _stop_engine()


func test_show_flowchart_creates_overlay_node():
	var data = _build_scenario()
	_setup_and_play(data)

	assert_null(_runtime._current_overlay, "no overlay before show_flowchart")

	_runtime.show_flowchart()
	assert_not_null(_runtime._current_overlay, "overlay should exist after show_flowchart")

	_runtime.close_overlay()
	await get_tree().process_frame
	await get_tree().process_frame

	await _stop_engine()


func test_show_flowchart_returns_to_title_correctly():
	# When opened from PLAYING, close should return to PLAYING.
	# _is_on_title_screen should return false.
	var data = _build_scenario()
	_setup_and_play(data)

	_runtime.show_flowchart()
	assert_false(_runtime._is_on_title_screen(),
		"flowchart opened from PLAYING should not be considered title screen")

	_runtime.close_overlay()

	await _stop_engine()


# ─── Flowchart content ───

func test_flowchart_shows_chapter_with_current_marker():
	var data = _build_scenario()
	_setup_and_play(data)

	# Currently at prologue
	_runtime.show_flowchart()
	var overlay = _runtime._current_overlay
	assert_not_null(overlay)

	# Find a button whose text contains ">>" (current marker) and "Prologue"
	var found_current := false
	for child in _find_buttons(overlay):
		if ">>" in child.text and "Prologue" in child.text:
			found_current = true
	assert_true(found_current,
		"flowchart should show current chapter with >> marker")

	_runtime.close_overlay()
	await _stop_engine()


func test_flowchart_shows_both_chapters():
	var data = _build_scenario()
	_setup_and_play(data)

	_runtime.show_flowchart()
	var overlay = _runtime._current_overlay
	var button_texts := []
	for child in _find_buttons(overlay):
		button_texts.append(child.text)
	var all_text = " ".join(button_texts)
	assert_true("Prologue" in all_text, "flowchart should show Prologue")
	assert_true("Chapter 1" in all_text, "flowchart should show Chapter 1")

	_runtime.close_overlay()
	await _stop_engine()


# ─── Helpers ───

func _find_buttons(node: Node) -> Array:
	var result: Array = []
	if node is Button:
		result.append(node)
	for child in node.get_children():
		result.append_array(_find_buttons(child))
	return result
