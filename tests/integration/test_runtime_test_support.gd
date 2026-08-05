extends GutTest
## Regression coverage for issue #114: integration tests share the persistent
## StellaRuntime autoload, so every test must start from a clean runtime state.

const RuntimeTestSupport = preload("res://tests/helpers/runtime_test_support.gd")

var _runtime: Node
var _scenario_ended_count: Array[int]
var _scenario_ended_listener: Callable


func before_each() -> void:
	_runtime = get_tree().root.get_node("StellaRuntime")
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	_scenario_ended_count = [0]
	_scenario_ended_listener = func(_id: String) -> void:
		_scenario_ended_count[0] += 1
	_runtime.engine.scenario_ended.connect(_scenario_ended_listener)


func after_each() -> void:
	if _runtime.engine.scenario_ended.is_connected(_scenario_ended_listener):
		_runtime.engine.scenario_ended.disconnect(_scenario_ended_listener)

	# Keep a failing regression run from stranding ScenarioEngine on dialogue.
	# The tested helper performs the same cancellation in the normal path.
	var old_context: ScenarioContext = _runtime.engine.context
	_runtime.engine.context = null
	if old_context != null:
		old_context.is_finished = true
	SignalBus.engine_abort_requested.emit()
	await get_tree().process_frame


func test_reset_for_test_restores_a_clean_runtime_baseline() -> void:
	var old_settings_manager: SettingsManager = _runtime.settings_manager
	var old_presentation_state: PresentationState = _runtime.presentation_state
	var old_read_flags: ReadFlagManager = _runtime.read_flags
	var old_unlock_manager: UnlockManager = _runtime.unlock_manager
	var old_flowchart_visited: FlowchartVisitedState = _runtime.flowchart_visited
	var audio_presenter: Node = _runtime.get_node("AudioPresenter")
	var bgm_player: AudioStreamPlayer = audio_presenter._bgm_player
	var se_player: AudioStreamPlayer = audio_presenter._se_players[0]
	var voice_player: AudioStreamPlayer = audio_presenter._voice_player
	var system_se_player: AudioStreamPlayer = audio_presenter._system_se_player

	_runtime.engine.load_scenario(_build_blocking_scenario())
	var old_context: ScenarioContext = _runtime.engine.context
	_runtime.save_manager.register_provider(old_context)
	_runtime.save_manager.register_provider(old_context.variable_store)
	_runtime.engine.run()
	await get_tree().process_frame

	_runtime.auto_play.is_active = true
	_runtime.skip_controller.is_active = true
	_runtime.read_flags.mark_read("dirty", "start", 0)
	_runtime.unlock_manager.unlock("cg", "dirty_cg")
	_runtime.flowchart_visited.mark_chapter_visited("dirty_chapter")
	_runtime.settings_manager.set_value("skip_only_read", false)
	_runtime.settings_manager.set_character_voice_volume("dirty", 0.25)
	_runtime.settings_manager.set_value("master_volume", 0.1)
	assert_almost_eq(audio_presenter._se_players[0].volume_db, -20.0, 0.01,
		"persistent audio nodes should reflect the dirty setting before reset")
	for player: AudioStreamPlayer in [bgm_player, se_player, voice_player, system_se_player]:
		player.stream = AudioStreamGenerator.new()
		player.play()
	assert_true(bgm_player.playing)
	assert_true(se_player.playing)
	assert_true(voice_player.playing)
	assert_true(system_se_player.playing)
	_runtime.backlog_manager.add_entry("n", [{"text": "dirty"}], 7)
	_runtime.choice_history_manager.record(8, func() -> Dictionary: return {"dirty": true})
	_runtime.flowchart_state.enter_chapter("dirty_chapter", {"dirty": true})
	_runtime.presentation_state.current_bg = "dirty_bg"
	_runtime.presentation_state.visible_characters["dirty"] = {
		"expression": "angry",
		"position": "center",
	}
	_runtime.presentation_state.current_bgm = "dirty_bgm"
	_runtime.game_state.current_state = GameStateMachine.State.BACKLOG
	_runtime.game_state.previous_state = GameStateMachine.State.PLAYING
	_runtime.scenario_graph = ScenarioGraph.new()
	_runtime._last_scenario_path = "res://dirty.stla"

	var overlay_layer := CanvasLayer.new()
	var overlay := Control.new()
	overlay_layer.add_child(overlay)
	_runtime.add_child(overlay_layer)
	_runtime._current_overlay = overlay

	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())

	assert_true(old_context.is_finished, "the replaced scenario must be stopped")
	assert_null(_runtime.engine.context, "the next test must not inherit a scenario")
	assert_eq(_scenario_ended_count[0], 0,
		"aborting test state must not look like normal scenario completion")
	assert_false(_runtime.auto_play.is_active)
	assert_false(_runtime.skip_controller.is_active)

	assert_same(_runtime.settings_manager, old_settings_manager,
		"preserve the manager's long-lived settings_changed bridge")
	assert_true(_runtime.get_setting("skip_only_read"), "settings return to defaults")
	assert_eq(_runtime.settings_manager.settings.character_voice_volume, {})
	assert_almost_eq(audio_presenter._se_players[0].volume_db, 0.0, 0.01,
		"reset defaults must be reapplied to the persistent AudioPresenter")
	assert_false(bgm_player.playing,
		"reset must stop BGM before returning")
	assert_false(se_player.playing, "reset must stop looping or synthetic SE")
	assert_false(voice_player.playing, "reset must stop voice playback")
	assert_false(system_se_player.playing, "reset must stop system SE playback")
	assert_null(bgm_player.stream)
	assert_null(se_player.stream)
	assert_null(voice_player.stream)
	assert_null(system_se_player.stream)
	assert_same(_runtime.presentation_state, old_presentation_state,
		"preserve the presentation state's SignalBus connections")
	assert_eq(_runtime.presentation_state.capture_snapshot(), {
		"bg": "",
		"characters": {},
		"bgm": "",
	})

	assert_not_same(_runtime.read_flags, old_read_flags)
	assert_false(_runtime.read_flags.is_read("dirty", "start", 0))
	assert_not_same(_runtime.unlock_manager, old_unlock_manager)
	assert_false(_runtime.unlock_manager.is_unlocked("cg", "dirty_cg"))
	assert_not_same(_runtime.flowchart_visited, old_flowchart_visited)
	assert_false(_runtime.flowchart_visited.is_chapter_visited("dirty_chapter"))
	assert_eq(_runtime.backlog_manager.get_entries(), [])
	assert_eq(_runtime.choice_history_manager.size(), 0)
	assert_eq(_runtime.flowchart_state.current_path, [])
	assert_eq(_runtime.flowchart_state.initial_snapshot, {})

	assert_eq(_runtime.game_state.current_state, GameStateMachine.State.TITLE)
	assert_eq(_runtime.game_state.previous_state, GameStateMachine.State.TITLE)
	assert_null(_runtime.scenario_graph)
	assert_eq(_runtime._last_scenario_path, "")
	assert_null(_runtime._current_overlay)
	assert_false(is_instance_valid(overlay_layer), "queued overlay nodes must be drained")

	var providers_by_id := {}
	for provider in _runtime.save_manager._providers:
		providers_by_id[provider.get_provider_id()] = provider
	var provider_ids: Array = providers_by_id.keys()
	provider_ids.sort()
	assert_eq(provider_ids, [
		"flowchart_state",
		"flowchart_visited",
		"presentation_state",
		"read_flags",
		"unlocks",
	])
	assert_same(providers_by_id["read_flags"], _runtime.read_flags)
	assert_same(providers_by_id["unlocks"], _runtime.unlock_manager)
	assert_same(providers_by_id["presentation_state"], _runtime.presentation_state)
	assert_same(providers_by_id["flowchart_state"], _runtime.flowchart_state)
	assert_same(providers_by_id["flowchart_visited"], _runtime.flowchart_visited)


func test_reset_for_test_does_not_leave_parallel_children_waiting() -> void:
	var advance_connection_count := SignalBus.advance_requested.get_connections().size()
	var abort_connection_count := SignalBus.engine_abort_requested.get_connections().size()
	var shown_texts: Array[String] = []
	var dialogue_listener := func(_character: String, segments: Array, _mode: String) -> void:
		shown_texts.append(String(segments[0].get("text", "")))
	SignalBus.show_dialogue.connect(dialogue_listener)

	_runtime.engine.load_scenario(_build_blocking_parallel_scenario())
	var old_context: ScenarioContext = _runtime.engine.context
	_runtime.engine.run()
	await get_tree().process_frame
	assert_eq(
		SignalBus.advance_requested.get_connections().size(),
		advance_connection_count + 1,
		"the first parallel dialogue should be awaiting advance",
	)

	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	SignalBus.show_dialogue.disconnect(dialogue_listener)

	assert_true(old_context.is_finished)
	assert_eq(shown_texts, ["first"],
		"abort must not dispatch a later parallel child after its signal was spent")
	assert_eq(SignalBus.advance_requested.get_connections().size(), advance_connection_count,
		"parallel must not start another child after the abort")
	assert_eq(SignalBus.engine_abort_requested.get_connections().size(), abort_connection_count,
		"the one-shot abort loser must be disconnected")
	assert_eq(_scenario_ended_count[0], 0)


func test_reset_for_test_invalidates_a_real_dialogue_typewriter() -> void:
	var game: Node = load("res://addons/stella/scenes/game.tscn").instantiate()
	add_child_autoqfree(game)
	await get_tree().process_frame
	var dialogue: Control = game.get_node("UILayer/DialoguePanel")
	dialogue._char_interval = 0.01

	_runtime.engine.load_scenario(_build_blocking_scenario())
	SignalBus.show_dialogue.emit("n", [{
		"text": "x",
		"voice": "",
		"expression": "",
	}], "adv")
	var active_generation: int = dialogue._dialogue_gen
	assert_eq(dialogue._current_scenario_id, "runtime_reset_test")
	assert_eq(dialogue._current_command_index, 0)

	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	var fresh_read_flags: ReadFlagManager = _runtime.read_flags

	assert_gt(dialogue._dialogue_gen, active_generation)
	assert_false(dialogue._is_typing,
		"hide_dialogue must not let the pre-typewriter frame resume stale work")
	assert_eq(dialogue._current_command_index, -1)
	await get_tree().create_timer(0.03).timeout
	assert_false(fresh_read_flags.is_read("runtime_reset_test", "start", 0),
		"the old typewriter must not mark its line in the replacement manager")


func test_reset_for_test_cancels_a_delayed_skip_advance() -> void:
	var game: Node = load("res://addons/stella/scenes/game.tscn").instantiate()
	add_child_autoqfree(game)
	await get_tree().process_frame

	_runtime.engine.load_scenario(_build_blocking_scenario())
	_runtime.settings_manager.set_value("skip_only_read", false)
	_runtime.settings_manager.set_value("skip_interval", 50)
	_runtime.skip_controller.is_active = true
	var advance_count: Array[int] = [0]
	var advance_listener := func() -> void: advance_count[0] += 1
	SignalBus.advance_requested.connect(advance_listener)

	SignalBus.show_dialogue.emit("n", [{
		"text": "skip then reset",
		"voice": "",
		"expression": "",
	}], "adv")
	await get_tree().process_frame
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	var count_after_reset: int = advance_count[0]

	await get_tree().create_timer(0.06).timeout
	SignalBus.advance_requested.disconnect(advance_listener)
	assert_eq(advance_count[0], count_after_reset,
		"the old skip timer must not advance the next test")


func _build_blocking_scenario() -> ScenarioData:
	var data := ScenarioData.new()
	data.id = "runtime_reset_test"
	var scene := SceneData.new()
	scene.id = "start"
	var dialogue := CommandData.new()
	dialogue.type = "dialogue"
	dialogue.params = {
		"character": "n",
		"text": "wait for abort",
	}
	scene.commands.append(dialogue)
	data.scenes.append(scene)
	return data


func _build_blocking_parallel_scenario() -> ScenarioData:
	var data := ScenarioData.new()
	data.id = "runtime_reset_parallel_test"
	var scene := SceneData.new()
	scene.id = "start"
	var parallel := CommandData.new()
	parallel.type = "parallel"
	parallel.params = {
		"commands": [
			_dialogue_command("first"),
			_dialogue_command("must not start"),
		],
	}
	scene.commands.append(parallel)
	data.scenes.append(scene)
	return data


func _dialogue_command(text: String) -> CommandData:
	var dialogue := CommandData.new()
	dialogue.type = "dialogue"
	dialogue.params = {
		"character": "n",
		"text": text,
	}
	return dialogue
