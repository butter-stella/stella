extends GutTest
## Regression coverage for issue #114: integration tests share the persistent
## StellaRuntime autoload, so every test must start from a clean runtime state.

const RuntimeTestSupport = preload("res://tests/helpers/runtime_test_support.gd")
const LOAD_FIXTURE := \
	"res://tests/fixtures/scenarios/dialogue/presentation_profile.stla"
const BOUNDARY_SAVE_DIR := "user://tests/pr175_runtime_boundary/"

var _runtime: Node
var _scenario_ended_count: Array[int]
var _scenario_ended_listener: Callable


func before_each() -> void:
	_runtime = get_tree().root.get_node("StellaRuntime")
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	_runtime.save_manager.save_dir = BOUNDARY_SAVE_DIR
	_runtime.save_manager.delete_save(1)
	_runtime.save_manager.delete_quick_save()
	_runtime.save_manager.delete_auto_save()
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
	_runtime.save_manager.delete_save(1)
	_runtime.save_manager.delete_quick_save()
	_runtime.save_manager.delete_auto_save()


func test_reset_for_test_restores_a_clean_runtime_baseline() -> void:
	var old_settings_manager: SettingsManager = _runtime.settings_manager
	var old_presentation_state: PresentationState = _runtime.presentation_state
	var old_read_flags: ReadFlagManager = _runtime.read_flags
	var old_dialogue_handler := (
		_runtime.registry.get_handler("dialogue") as DialogueHandler
	)
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
	_runtime.presentation_state.stage_layers["dirty"] = (
		StageLayerState.normalize_full({"asset": "stage:dirty"})
	)
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
		"stage_layers": {},
		"bgm": "",
		"dialogue_visibility": {
			"surface": true,
			"quick_menu": true,
		},
		"dialogue_content": {
			"version": 1,
			"active": false,
			"mode": "adv",
			"profile_name": "",
			"declarative_presentation": false,
			"character": "",
			"segments": [],
			"avatar_expression": "",
			"nvl_entries": [],
		},
	})

	assert_not_same(_runtime.read_flags, old_read_flags)
	assert_false(_runtime.read_flags.is_read("dirty", "start", 0))
	assert_false(old_read_flags.is_read("runtime_reset_test", "start", 0),
		"the aborted handler must not complete into its original read history")
	assert_false(_runtime.read_flags.is_read("runtime_reset_test", "start", 0),
		"the aborted handler must not complete into replacement read history")
	var dialogue_handler := (
		_runtime.registry.get_handler("dialogue") as DialogueHandler
	)
	assert_not_same(dialogue_handler, old_dialogue_handler,
		"reset must replace the handler instead of rebinding an in-flight instance")
	assert_same(dialogue_handler._read_flags, _runtime.read_flags,
		"reset must rebind the handler to the replacement read history")
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


func test_runtime_reset_immediately_reapplies_audio_defaults() -> void:
	var audio_presenter: Node = _runtime.get_node("AudioPresenter")
	var bgm_player: AudioStreamPlayer = audio_presenter._bgm_player
	var se_players: Array = audio_presenter._se_players
	var voice_player: AudioStreamPlayer = audio_presenter._voice_player
	var system_se_player: AudioStreamPlayer = audio_presenter._system_se_player
	for player: AudioStreamPlayer in [bgm_player, voice_player, system_se_player]:
		player.stream = AudioStreamGenerator.new()
		player.play()
	for player: AudioStreamPlayer in se_players:
		player.stream = AudioStreamGenerator.new()
		player.play()

	_runtime.settings_manager.set_value("master_volume", 0.5)
	_runtime.settings_manager.set_value("bgm_volume", 0.4)
	_runtime.settings_manager.set_value("se_volume", 0.3)
	_runtime.settings_manager.set_value("system_se_volume", 0.2)
	_runtime.settings_manager.set_value("voice_volume", 0.6)
	audio_presenter._current_voice_character = "sakura"
	_runtime.settings_manager.set_character_voice_volume("sakura", 0.25)

	assert_almost_eq(bgm_player.volume_db, linear_to_db(0.5 * 0.4), 0.01)
	for player: AudioStreamPlayer in se_players:
		assert_almost_eq(player.volume_db, linear_to_db(0.5 * 0.3), 0.01)
	assert_almost_eq(system_se_player.volume_db, linear_to_db(0.5 * 0.2), 0.01)
	assert_almost_eq(voice_player.volume_db, linear_to_db(0.5 * 0.6 * 0.25), 0.01)

	_runtime.settings_manager.set_character_voice_enabled("sakura", false)
	assert_almost_eq(voice_player.volume_db, -80.0, 0.01,
		"muting the current character should affect an active voice immediately")

	# Exercise the stale-target race directly: resetting while a fade-in still
	# targets the dirty volume must cancel that target before it can be applied.
	bgm_player.volume_db = -80.0
	audio_presenter._start_bgm_fade_in(0.05)
	_runtime.reset_settings()

	assert_almost_eq(bgm_player.volume_db, linear_to_db(0.8), 0.01)
	for player: AudioStreamPlayer in se_players:
		assert_almost_eq(player.volume_db, 0.0, 0.01)
	assert_almost_eq(system_se_player.volume_db, 0.0, 0.01)
	assert_almost_eq(voice_player.volume_db, 0.0, 0.01,
		"reset clears the current character mute and volume overrides")
	assert_eq(_runtime.settings_manager.settings.character_voice_volume, {})
	assert_eq(_runtime.settings_manager.settings.character_voice_enabled, {})

	await get_tree().create_timer(0.1).timeout
	assert_almost_eq(bgm_player.volume_db, linear_to_db(0.8), 0.01,
		"a killed fade-in must not restore its pre-reset target")


func test_reset_for_test_does_not_advance_past_aborted_dialogue() -> void:
	var advance_connection_count := SignalBus.advance_requested.get_connections().size()
	var abort_connection_count := SignalBus.engine_abort_requested.get_connections().size()
	var shown_texts: Array[String] = []
	var dialogue_listener := func(_character: String, segments: Array, _mode: String) -> void:
		shown_texts.append(String(segments[0].get("text", "")))
	SignalBus.show_dialogue.connect(dialogue_listener)

	_runtime.engine.load_scenario(_build_two_dialogue_scenario())
	var old_context: ScenarioContext = _runtime.engine.context
	_runtime.engine.run()
	await get_tree().process_frame
	assert_eq(
		SignalBus.advance_requested.get_connections().size(),
		advance_connection_count,
		"request-scoped dialogue must not install a global advance waiter",
	)
	assert_eq(
		SignalBus.engine_abort_requested.get_connections().size(),
		abort_connection_count + 1,
		"the current dialogue owns one request-scoped abort listener",
	)

	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	SignalBus.show_dialogue.disconnect(dialogue_listener)

	assert_true(old_context.is_finished)
	assert_eq(shown_texts, ["first"],
		"abort must not dispatch the next authored dialogue")
	assert_eq(SignalBus.advance_requested.get_connections().size(), advance_connection_count,
		"abort must not start another dialogue after the reset")
	assert_eq(SignalBus.engine_abort_requested.get_connections().size(), abort_connection_count,
		"the one-shot abort loser must be disconnected")
	assert_eq(_scenario_ended_count[0], 0)


func test_in_game_manual_load_transfers_owner_before_presenter_hide() -> void:
	var dialogue := await _instantiate_game_dialogue()
	_prepare_load_snapshot(false)
	var old_context := _start_blocking_dialogue()
	assert_true(await _wait_for_pending_activation(dialogue))
	var old_activation: DialogueActivation = dialogue._current_dialogue_activation

	var loaded: bool = await _runtime.continue_from_save(1)
	assert_true(loaded)
	assert_true(await _wait_for_replacement_activation(dialogue, old_activation))

	_assert_load_boundary_owner(old_context, old_activation, dialogue)


func test_in_game_quick_load_transfers_owner_before_presenter_hide() -> void:
	var dialogue := await _instantiate_game_dialogue()
	_prepare_load_snapshot(true)
	var old_context := _start_blocking_dialogue()
	assert_true(await _wait_for_pending_activation(dialogue))
	var old_activation: DialogueActivation = dialogue._current_dialogue_activation

	var loaded: bool = await _runtime.quick_load()
	assert_true(loaded)
	assert_true(await _wait_for_replacement_activation(dialogue, old_activation))

	_assert_load_boundary_owner(old_context, old_activation, dialogue)


func test_in_game_manual_load_cancels_retired_click_wait_generation() -> void:
	var dialogue := await _instantiate_game_dialogue()
	_prepare_load_snapshot(false)
	var advance_connections := SignalBus.advance_requested.get_connections().size()
	var abort_connections := SignalBus.engine_abort_requested.get_connections().size()
	var old_context := _start_blocking_command(_wait_command("click"))
	assert_eq(SignalBus.advance_requested.get_connections().size(),
		advance_connections + 1)
	assert_eq(SignalBus.engine_abort_requested.get_connections().size(),
		abort_connections + 1)

	var loaded: bool = await _runtime.continue_from_save(1)
	assert_true(loaded)
	assert_true(await _wait_for_pending_activation(dialogue))

	_assert_blocking_load_boundary(old_context, dialogue)
	assert_eq(SignalBus.advance_requested.get_connections().size(),
		advance_connections,
		"manual load must disconnect the old click waiter")
	assert_eq(SignalBus.engine_abort_requested.get_connections().size(),
		abort_connections + 1,
		"only the loaded dialogue activation may remain abortable")
	var loaded_activation: DialogueActivation = dialogue._current_dialogue_activation
	SignalBus.advance_requested.emit()
	await get_tree().process_frame
	assert_same(dialogue._current_dialogue_activation, loaded_activation,
		"late input for the retired click wait cannot advance loaded content")


func test_in_game_quick_load_cancels_retired_timer_wait_generation() -> void:
	var dialogue := await _instantiate_game_dialogue()
	_prepare_load_snapshot(true)
	var abort_connections := SignalBus.engine_abort_requested.get_connections().size()
	var requests: Array[DialogueRequest] = []
	var on_request := func(request: DialogueRequest) -> void:
		requests.append(request)
	SignalBus.dialogue_requested.connect(on_request)
	var old_context := _start_blocking_command(_wait_command("timer", 0.2))
	assert_eq(SignalBus.engine_abort_requested.get_connections().size(),
		abort_connections + 1)

	var loaded: bool = await _runtime.quick_load()
	assert_true(loaded)
	assert_true(await _wait_for_pending_activation(dialogue))
	var loaded_activation: DialogueActivation = dialogue._current_dialogue_activation

	_assert_blocking_load_boundary(old_context, dialogue)
	assert_eq(SignalBus.engine_abort_requested.get_connections().size(),
		abort_connections + 1,
		"quick load must replace the timer waiter with only the loaded dialogue")
	await get_tree().create_timer(0.25).timeout
	assert_eq(requests.size(), 1,
		"the retired timer completion cannot dispatch old scenario content")
	assert_same(dialogue._current_dialogue_activation, loaded_activation)
	SignalBus.dialogue_requested.disconnect(on_request)


func test_in_game_continue_cancels_retired_choice_generation() -> void:
	var dialogue := await _instantiate_game_dialogue()
	var choice_panel: Control = dialogue.get_node("../ChoicePanel")
	_prepare_load_snapshot(true)
	var choice_connections := SignalBus.choice_selected.get_connections().size()
	var abort_connections := SignalBus.engine_abort_requested.get_connections().size()
	var command := _choice_command()
	var old_context := _start_blocking_command(command)
	var old_store: VariableStore = old_context.variable_store
	assert_eq(SignalBus.choice_selected.get_connections().size(),
		choice_connections + 1)
	assert_eq(SignalBus.engine_abort_requested.get_connections().size(),
		abort_connections + 1)
	assert_true(choice_panel.visible,
		"the production choice presenter owns the old completion")

	var loaded: bool = await _runtime.continue_game()
	assert_true(loaded)
	assert_true(await _wait_for_pending_activation(dialogue))
	var loaded_activation: DialogueActivation = dialogue._current_dialogue_activation

	_assert_blocking_load_boundary(old_context, dialogue)
	assert_eq(SignalBus.choice_selected.get_connections().size(),
		choice_connections,
		"continue must disconnect the old choice completion")
	assert_eq(SignalBus.engine_abort_requested.get_connections().size(),
		abort_connections + 1,
		"only the continued dialogue activation may remain abortable")
	assert_false(choice_panel.visible,
		"context cancellation must retire the old choice presentation")
	SignalBus.choice_selected.emit("old")
	await get_tree().process_frame
	assert_eq(old_context.pending_jump, "")
	assert_null(old_store.get_var("leaked"),
		"a late choice completion cannot mutate the retired run")
	assert_same(dialogue._current_dialogue_activation, loaded_activation,
		"a retired choice cannot complete the continued dialogue")


func test_in_game_rollback_transfers_owner_before_presenter_hide() -> void:
	var dialogue := await _instantiate_game_dialogue()
	_runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	_runtime.engine.load_scenario(_build_two_dialogue_scenario())
	var old_context: ScenarioContext = _runtime.engine.context
	_runtime.engine.run()
	assert_true(await _wait_for_pending_activation(dialogue))
	assert_eq(_runtime.backlog_manager.get_entries().size(), 1)
	var first_activation: DialogueActivation = dialogue._current_dialogue_activation
	assert_true(first_activation.advance())
	assert_true(await _wait_for_replacement_activation(dialogue, first_activation))
	var second_activation: DialogueActivation = dialogue._current_dialogue_activation

	assert_true(_runtime.jump_from_backlog(0))
	assert_true(await _wait_for_replacement_activation(dialogue, second_activation))

	assert_true(old_context.is_finished)
	assert_eq(second_activation.get_outcome(), DialogueActivation.Outcome.ABORTED)
	assert_not_same(_runtime.engine.context, old_context)
	assert_eq(_runtime.engine.context.current_command_index, 0)
	assert_eq(_scenario_ended_count[0], 0,
		"rollback cancellation must not look like natural scenario completion")
	assert_eq(_runtime.game_state.current_state, GameStateMachine.State.PLAYING)
	assert_true(dialogue._current_dialogue_activation.is_pending(),
		"the restored context remains the final dialogue owner")


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
	}], "adv")
	var active_generation: int = dialogue._dialogue_gen
	assert_eq(dialogue._current_scenario_id, "runtime_reset_test")
	assert_eq(dialogue._current_command_index, 0)

	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())

	assert_gt(dialogue._dialogue_gen, active_generation)
	assert_false(dialogue._is_typing,
		"hide_dialogue must not let the pre-typewriter frame resume stale work")
	assert_eq(dialogue._current_command_index, -1)
	await get_tree().create_timer(0.03).timeout
	assert_false(dialogue._is_typing,
		"the retired typewriter must not resume after its old delay")
	assert_false(dialogue._dialogue_ready)
	assert_eq(dialogue._current_command_index, -1)


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
	}], "adv")
	await get_tree().process_frame
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	var count_after_reset: int = advance_count[0]

	await get_tree().create_timer(0.06).timeout
	SignalBus.advance_requested.disconnect(advance_listener)
	assert_eq(advance_count[0], count_after_reset,
		"the old skip timer must not advance the next test")


func test_real_input_routes_dialogue_then_click_wait_then_dialogue() -> void:
	var game: Node = load("res://addons/stella/scenes/game.tscn").instantiate()
	add_child_autoqfree(game)
	await get_tree().process_frame
	var input_handler: Node = game.get_node("InputHandler")
	var dialogue: Control = game.get_node("UILayer/DialoguePanel")
	dialogue._char_interval = 0.0
	var requests: Array[DialogueRequest] = []
	var on_request := func(request: DialogueRequest) -> void:
		requests.append(request)
	SignalBus.dialogue_requested.connect(on_request)

	_runtime.engine.load_scenario(_build_dialogue_wait_dialogue_scenario())
	_runtime.engine.run()
	assert_true(await wait_until(
		func(): return requests.size() == 1 and not dialogue._is_typing,
		1.0,
		"first dialogue becomes ready",
	))
	input_handler._request_dialogue_advance(dialogue)
	assert_true(await wait_until(
		func(): return _runtime.engine.context.current_command_index == 1,
		1.0,
		"engine enters click wait",
	))
	input_handler._request_dialogue_advance(dialogue)
	assert_true(await wait_until(
		func(): return requests.size() == 2,
		1.0,
		"click wait releases into second dialogue",
	))

	assert_eq(requests[0].get_segments()[0].get("text"), "first")
	assert_eq(requests[1].get_segments()[0].get("text"), "second")
	requests[1].abort()
	SignalBus.dialogue_requested.disconnect(on_request)


func _instantiate_game_dialogue() -> Control:
	var game: Node = load("res://addons/stella/scenes/game.tscn").instantiate()
	add_child_autoqfree(game)
	await get_tree().process_frame
	var dialogue: Control = game.get_node("UILayer/DialoguePanel")
	dialogue._char_interval = 0.0
	return dialogue


func _prepare_load_snapshot(quick: bool) -> void:
	_runtime._last_scenario_path = LOAD_FIXTURE
	_runtime._prepare_scenario(LOAD_FIXTURE)
	if quick:
		_runtime.quick_save()
	else:
		_runtime.save(1)


func _start_blocking_dialogue() -> ScenarioContext:
	_runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	_runtime.engine.load_scenario(_build_blocking_scenario())
	var context: ScenarioContext = _runtime.engine.context
	_runtime.engine.run()
	return context


func _start_blocking_command(command: CommandData) -> ScenarioContext:
	_runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	_runtime.engine.load_scenario(_build_command_then_dialogue_scenario(command))
	var context: ScenarioContext = _runtime.engine.context
	_runtime.engine.run()
	return context


func _wait_for_pending_activation(dialogue: Control) -> bool:
	return await wait_until(
		func() -> bool:
			return (
				dialogue._current_dialogue_activation != null
				and dialogue._current_dialogue_activation.is_pending()
			),
		1.0,
		"production DialoguePresenter owns the blocking request",
	)


func _wait_for_replacement_activation(
	dialogue: Control,
	old_activation: DialogueActivation,
) -> bool:
	return await wait_until(
		func() -> bool:
			return (
				dialogue._current_dialogue_activation != null
				and dialogue._current_dialogue_activation != old_activation
				and dialogue._current_dialogue_activation.is_pending()
			),
		1.0,
		"replacement context becomes the final Presenter owner",
	)


func _assert_load_boundary_owner(
	old_context: ScenarioContext,
	old_activation: DialogueActivation,
	dialogue: Control,
) -> void:
	assert_true(old_context.is_finished)
	assert_eq(old_activation.get_outcome(), DialogueActivation.Outcome.ABORTED)
	assert_not_same(_runtime.engine.context, old_context)
	assert_eq(_runtime.engine.context.scenario_data.id, "presentation_profile")
	assert_eq(_scenario_ended_count[0], 0,
		"load cancellation must not look like natural scenario completion")
	assert_eq(_runtime.game_state.current_state, GameStateMachine.State.PLAYING)
	assert_true(dialogue._current_dialogue_activation.is_pending(),
		"the loaded context remains the final dialogue owner")


func _assert_blocking_load_boundary(
	old_context: ScenarioContext,
	dialogue: Control,
) -> void:
	assert_true(old_context.is_finished)
	assert_true(old_context.is_cancellation_requested(),
		"context replacement must cancel the retired execution generation")
	assert_not_same(_runtime.engine.context, old_context)
	assert_eq(_runtime.engine.context.scenario_data.id, "presentation_profile")
	assert_eq(_scenario_ended_count[0], 0,
		"blocking cancellation must not look like natural scenario completion")
	assert_eq(_runtime.game_state.current_state, GameStateMachine.State.PLAYING)
	assert_true(dialogue._current_dialogue_activation.is_pending(),
		"loaded content remains the final blocking owner")


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


func _build_two_dialogue_scenario() -> ScenarioData:
	var data := ScenarioData.new()
	data.id = "runtime_reset_two_dialogue_test"
	var scene := SceneData.new()
	scene.id = "start"
	scene.commands = [
		_dialogue_command("first"),
		_dialogue_command("must not start"),
	]
	data.scenes.append(scene)
	return data


func _build_command_then_dialogue_scenario(command: CommandData) -> ScenarioData:
	var data := ScenarioData.new()
	data.id = "runtime_blocking_generation_test"
	var scene := SceneData.new()
	scene.id = "start"
	scene.commands = [command, _dialogue_command("must not start")]
	data.scenes.append(scene)
	return data


func _wait_command(mode: String, duration: float = 1.0) -> CommandData:
	var command := CommandData.new()
	command.type = "wait"
	command.params = {"mode": mode, "duration": duration}
	return command


func _choice_command() -> CommandData:
	var command := CommandData.new()
	command.type = "choice"
	command.params = {
		"prompt": "Retired choice",
		"options": [{
			"id": "old",
			"label": "Old",
			"jump": "must_not_apply",
			"set": {"leaked": "= 1"},
		}],
	}
	return command


func _build_dialogue_wait_dialogue_scenario() -> ScenarioData:
	var data := ScenarioData.new()
	data.id = "runtime_input_routing_test"
	var scene := SceneData.new()
	scene.id = "start"
	var wait := CommandData.new()
	wait.type = "wait"
	wait.params = {"mode": "click"}
	scene.commands = [
		_dialogue_command("first"),
		wait,
		_dialogue_command("second"),
	]
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
