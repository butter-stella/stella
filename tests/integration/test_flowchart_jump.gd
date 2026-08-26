extends GutTest
## Integration tests for flowchart chapter transitions and jump_from_flowchart
## (issue #97 PR-C).


const RuntimeTestSupport = preload("res://tests/helpers/runtime_test_support.gd")

var _runtime: Node


func before_each() -> void:
	_runtime = get_tree().root.get_node("StellaRuntime")
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())


func _build_two_chapter_scenario() -> ScenarioData:
	# @chapter prologue / @scene start / dialogue / @jump s_ch1
	# @chapter ch1 / @scene s_ch1 / set score=42 / dialogue
	var data = ScenarioData.new()
	data.id = "fc_test"

	var ch0 = ChapterData.new()
	ch0.id = "prologue"
	ch0.display_name = "序章"
	ch0.scene_ids = ["start"]
	data.chapters.append(ch0)

	var ch1 = ChapterData.new()
	ch1.id = "ch1"
	ch1.display_name = "第一章"
	ch1.scene_ids = ["s_ch1"]
	data.chapters.append(ch1)

	var s0 = SceneData.new()
	s0.id = "start"
	s0.chapter_id = "prologue"
	var d0 = CommandData.new()
	d0.type = "dialogue"
	d0.params = {"character": "n", "text": "prologue line"}
	s0.commands.append(d0)
	var j0 = CommandData.new()
	j0.type = "jump"
	j0.params = {"target": "s_ch1"}
	s0.commands.append(j0)
	data.scenes.append(s0)

	var s1 = SceneData.new()
	s1.id = "s_ch1"
	s1.chapter_id = "ch1"
	var setter = CommandData.new()
	setter.type = "set"
	setter.params = {"var": "score", "value": 42}
	s1.commands.append(setter)
	var d1 = CommandData.new()
	d1.type = "dialogue"
	d1.params = {"character": "n", "text": "ch1 line"}
	s1.commands.append(d1)
	data.scenes.append(s1)

	return data


func _setup_scenario(data: ScenarioData) -> void:
	_runtime.engine.load_scenario(data)
	_runtime.save_manager.register_provider(_runtime.engine.context)
	_runtime.save_manager.register_provider(_runtime.engine.context.variable_store)
	_runtime.save_manager.register_provider(_runtime.flowchart_state)
	_runtime.scenario_graph = ScenarioGraphBuilder.build(data)
	_runtime.flowchart_state.clear()
	_runtime.flowchart_state.initial_snapshot = _runtime._capture_rollback_snapshot()


func _advance(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame
		RuntimeTestSupport.advance_dialogue_for_test(get_tree())
	await get_tree().process_frame


func _stop_engine() -> void:
	_runtime.engine.stop()
	SignalBus.advance_requested.emit()
	await get_tree().process_frame


# ─── Chapter transition detection ───

func test_chapter_transition_detected_on_scene_change():
	var data = _build_two_chapter_scenario()
	_setup_scenario(data)
	_runtime.engine.run()

	# After run, engine enters "start" → first scene_changed fires → prologue entered.
	# Then dialogue waits for advance. Current chapter = prologue.
	assert_eq(_runtime.flowchart_state.get_current_chapter_id(), "prologue")

	# Advance past dialogue → @jump s_ch1 → scene_changed("s_ch1") → ch1 entered.
	await _advance(1)
	assert_eq(_runtime.flowchart_state.get_current_chapter_id(), "ch1")
	assert_eq(_runtime.flowchart_state.current_path, ["prologue", "ch1"])

	await _stop_engine()


func test_chapter_transition_marks_visited():
	var data = _build_two_chapter_scenario()
	_setup_scenario(data)
	_runtime.engine.run()

	assert_true(_runtime.flowchart_visited.is_chapter_visited("prologue"),
		"first chapter should be visited on scenario start")

	await _advance(1)  # jump to ch1
	assert_true(_runtime.flowchart_visited.is_chapter_visited("ch1"),
		"second chapter should be visited after jump")

	await _stop_engine()


func test_chapter_transition_marks_edges_visited():
	var data = _build_two_chapter_scenario()
	_setup_scenario(data)
	_runtime.engine.run()

	await _advance(1)  # jump prologue → ch1

	# There should be at least one edge from prologue to ch1 marked as visited.
	var graph = _runtime.scenario_graph
	var found_visited_edge := false
	for edge in graph.get_outgoing_edges("prologue"):
		if edge.target_chapter_id == "ch1":
			if _runtime.flowchart_visited.is_edge_visited(edge.get_edge_id()):
				found_visited_edge = true
	assert_true(found_visited_edge,
		"edge from prologue → ch1 should be marked visited after jump")

	await _stop_engine()


# ─── jump_from_flowchart ───

func test_jump_from_flowchart_returns_to_chapter_entry():
	var data = _build_two_chapter_scenario()
	_setup_scenario(data)
	_runtime.engine.run()
	await _advance(1)  # → ch1

	assert_eq(_runtime.flowchart_state.get_current_chapter_id(), "ch1")

	# Jump back to prologue via flowchart
	var ok = _runtime.jump_from_flowchart("prologue")
	assert_true(ok)
	await get_tree().process_frame
	await get_tree().process_frame

	# Engine should be positioned at prologue's entry scene
	assert_eq(_runtime.engine.context.current_scene().id, "start",
		"flowchart jump should position engine at chapter entry scene")

	await _stop_engine()


func test_jump_from_flowchart_restores_variables():
	var data = _build_two_chapter_scenario()
	_setup_scenario(data)
	_runtime.engine.run()
	await _advance(1)  # → ch1 (score=42 set by set command)

	assert_eq(_runtime.engine.context.variable_store.get_var("score"), 42)

	# Jump back to prologue — variables should roll back to the snapshot
	# captured at prologue entry (before score was set).
	_runtime.jump_from_flowchart("prologue")
	await get_tree().process_frame
	await get_tree().process_frame

	var score = _runtime.engine.context.variable_store.get_var("score")
	assert_true(score == null or score == 0,
		"score should be rolled back to pre-set value after flowchart jump, got: %s" % str(score))

	await _stop_engine()


func test_jump_from_flowchart_preserves_global_scope():
	# Issue #98: Scope.GLOBAL survives flowchart jump (same as backlog jump).
	var data = _build_two_chapter_scenario()
	_setup_scenario(data)
	_runtime.engine.run()
	await _advance(1)  # → ch1

	# Simulate a global-scope write (no DSL command does this yet, but the
	# contract must be established — see PR #99).
	_runtime.engine.context.variable_store.set_var(
		"cg_unlocked", true, VariableStore.Scope.GLOBAL)

	_runtime.jump_from_flowchart("prologue")
	await get_tree().process_frame
	await get_tree().process_frame

	assert_eq(
		_runtime.engine.context.variable_store.get_var("cg_unlocked"), true,
		"global var should survive flowchart jump (issue #98)")

	await _stop_engine()


func test_jump_from_flowchart_updates_current_path():
	var data = _build_two_chapter_scenario()
	_setup_scenario(data)
	_runtime.engine.run()
	await _advance(1)  # → ch1
	assert_eq(_runtime.flowchart_state.current_path, ["prologue", "ch1"])

	_runtime.jump_from_flowchart("prologue")
	await get_tree().process_frame
	await get_tree().process_frame

	# In-path jump → truncate to prologue
	assert_eq(_runtime.flowchart_state.current_path, ["prologue"],
		"in-path flowchart jump should truncate current_path")

	await _stop_engine()


func test_jump_from_flowchart_to_nonexistent_chapter_returns_false():
	var data = _build_two_chapter_scenario()
	_setup_scenario(data)
	_runtime.engine.run()

	var ok = _runtime.jump_from_flowchart("does_not_exist")
	assert_false(ok, "jump to nonexistent chapter should return false")

	await _stop_engine()


func test_invalid_audio_choice_snapshot_cannot_rewrite_flowchart_path() -> void:
	var data = _build_two_chapter_scenario()
	_setup_scenario(data)
	_runtime.flowchart_state.current_path = ["prologue", "ch1"]
	var invalid: Dictionary = _runtime._capture_rollback_snapshot()
	invalid.erase(PresentationClipAudioChoiceAuthority.PROVIDER_ID)
	_runtime.flowchart_state.chapter_snapshots["prologue"] = invalid
	var before_context: ScenarioContext = _runtime.engine.context
	var before_authority: Dictionary = (
		_runtime.presentation_clip_audio_choice_authority.capture_snapshot())
	assert_false(_runtime.jump_from_flowchart("prologue"))
	assert_eq(_runtime.flowchart_state.current_path, ["prologue", "ch1"],
		"mandatory provider validation precedes path truncation")
	assert_same(_runtime.engine.context, before_context)
	assert_eq(
		_runtime.presentation_clip_audio_choice_authority.capture_snapshot(),
		before_authority)


# ─── _prepare_scenario clears flowchart state ───

func test_prepare_scenario_clears_flowchart_state():
	var data = _build_two_chapter_scenario()
	_setup_scenario(data)
	_runtime.engine.run()
	await _advance(1)  # → ch1
	assert_gt(_runtime.flowchart_state.current_path.size(), 0)

	await _stop_engine()

	# Write a minimal scenario file and route through _prepare_scenario.
	var path = "user://test_flowchart_clear.stla"
	var f = FileAccess.open(path, FileAccess.WRITE)
	f.store_string("@chapter ch\n@scene start\nnarrator「hi」\n")
	f.close()
	_runtime.presentation_state.current_bg = "stale_title"
	_runtime.presentation_state.current_bgm = {
		"asset": "stale_bgm", "cue": "", "loop": true, "position": 0.0,
		"status": "playing", "stem_mix": {}, "volume": 1.0,
	}
	_runtime.presentation_state.stage_layers = {
		"stale": StageLayerState.default_state(),
	}

	_runtime._prepare_scenario(path)
	assert_eq(_runtime.flowchart_state.current_path.size(), 0,
		"_prepare_scenario must clear flowchart state")
	assert_true(_runtime.flowchart_state.initial_snapshot.size() > 0,
		"_prepare_scenario must capture INITIAL_SNAPSHOT")
	assert_eq(
		_runtime.flowchart_state.initial_snapshot["presentation_state"],
		{
			"bg": "",
			"stage_layers": {},
			"bgm": {},
			"movie": {},
			"loop_se_channels": {},
			"dialogue_visibility": {
				"surface": true,
				"quick_menu": true,
			},
			"dialogue_content": {
				"version": 2,
				"active": false,
				"cleared": false,
				"mode": "adv",
				"profile_name": "",
				"declarative_presentation": false,
				"character": "",
				"segments": [],
				"avatar_expression": "",
				"nvl_entries": [],
			},
			"dialogue_avatar": DialogueAvatarState.default_state(),
		},
		"initial rollback state must not inherit title or previous-run visuals",
	)

	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
