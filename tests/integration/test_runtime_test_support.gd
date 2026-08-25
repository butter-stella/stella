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
var _owned_nodes: Array[Node] = []


func before_each() -> void:
	_runtime = get_tree().root.get_node("StellaRuntime")
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	_runtime.save_manager.save_dir = BOUNDARY_SAVE_DIR
	_runtime.save_manager.delete_save(1)
	_runtime.save_manager.delete_quick_save()
	_runtime.save_manager.delete_auto_save()
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	await _release_owned_nodes()
	_owned_nodes.clear()
	_scenario_ended_count.clear()
	_scenario_ended_listener = Callable()
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
	await _release_owned_nodes()


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


func test_reset_for_test_restores_a_clean_runtime_baseline() -> void:
	var old_settings_manager: SettingsManager = _runtime.settings_manager
	var old_presentation_state: PresentationState = _runtime.presentation_state
	var old_read_flags: ReadFlagManager = _runtime.read_flags
	var old_dialogue_handler := (
		_runtime.registry.get_handler("dialogue") as DialogueHandler
	)
	var old_wait_handler := _runtime.registry.get_handler("wait") as WaitHandler
	var old_unlock_manager: UnlockManager = _runtime.unlock_manager
	var old_flowchart_visited: FlowchartVisitedState = _runtime.flowchart_visited
	var audio_presenter: Node = _runtime.get_node("AudioPresenter")
	var bgm_player := _install_synthetic_bgm(audio_presenter)
	assert_not_null(bgm_player, "synthetic BGM setup must produce a player")
	if bgm_player == null:
		return
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
	for player: AudioStreamPlayer in [se_player, voice_player, system_se_player]:
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
	_runtime.presentation_state.current_bgm = {
		"asset": "dirty_bgm", "cue": "", "loop": true, "position": 0.0,
		"status": "playing", "stem_mix": {}, "volume": 1.0,
	}
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
	assert_false(is_instance_valid(bgm_player),
		"reset must retire the dynamic BGM voice before returning")
	assert_false(se_player.playing, "reset must stop looping or synthetic SE")
	assert_false(voice_player.playing, "reset must stop voice playback")
	assert_false(system_se_player.playing, "reset must stop system SE playback")
	assert_null(se_player.stream)
	assert_null(voice_player.stream)
	assert_null(system_se_player.stream)
	assert_same(_runtime.presentation_state, old_presentation_state,
		"preserve the presentation state's SignalBus connections")
	assert_eq(_runtime.presentation_state.capture_snapshot(), {
		"bg": "",
		"stage_layers": {},
		"bgm": {},
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
	var wait_handler := _runtime.registry.get_handler("wait") as WaitHandler
	assert_not_same(wait_handler, old_wait_handler,
		"reset must replace the handler bound to the old Skip controller")
	assert_same(wait_handler._skip_controller, _runtime.skip_controller,
		"the fresh WaitHandler observes the fresh session Skip owner")
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
	var bgm_player := _install_synthetic_bgm(audio_presenter)
	assert_not_null(bgm_player, "synthetic BGM setup must produce a player")
	if bgm_player == null:
		return
	var se_players: Array = audio_presenter._se_players
	var voice_player: AudioStreamPlayer = audio_presenter._voice_player
	var voice_bus_index := AudioServer.get_bus_index(audio_presenter._voice_dsp_bus_name)
	var system_se_player: AudioStreamPlayer = audio_presenter._system_se_player
	assert_gte(voice_bus_index, 0, "the Runtime voice Presenter must own its private DSP bus")
	if voice_bus_index < 0:
		return
	for player: AudioStreamPlayer in [voice_player, system_se_player]:
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
	assert_almost_eq(voice_player.volume_db, 0.0, 0.01,
		"the active voice source remains unity-gain")
	assert_almost_eq(
		AudioServer.get_bus_volume_db(voice_bus_index),
		linear_to_db(0.5 * 0.6 * 0.25),
		0.01,
		"the private post-effect bus owns the exact effective voice gain",
	)

	_runtime.settings_manager.set_character_voice_enabled("sakura", false)
	assert_almost_eq(voice_player.volume_db, 0.0, 0.01,
		"muting must not double-apply gain at the active source")
	assert_almost_eq(AudioServer.get_bus_volume_db(voice_bus_index), -80.0, 0.01,
		"muting the current character should affect source and buffered tail immediately")

	# An authored-level Tween remains valid across a live settings reset: every
	# frame multiplies its level by the current setting instead of restoring a
	# captured dB target from the old settings snapshot.
	var voice: Dictionary = audio_presenter._bgm_channel["current"]
	audio_presenter._set_bgm_voice_level(0.0, voice)
	var tween := audio_presenter.create_tween()
	audio_presenter._bgm_channel["tween"] = tween
	tween.tween_method(
		audio_presenter._set_bgm_voice_level.bind(voice), 0.0, 1.0, 0.05)
	_runtime.reset_settings()

	assert_almost_eq(bgm_player.volume_db, -80.0, 0.01,
		"settings reset must not terminate the authored BGM lifecycle Tween")
	for player: AudioStreamPlayer in se_players:
		assert_almost_eq(player.volume_db, 0.0, 0.01)
	assert_almost_eq(system_se_player.volume_db, 0.0, 0.01)
	assert_almost_eq(voice_player.volume_db, 0.0, 0.01,
		"the voice source remains unity-gain after settings reset")
	assert_almost_eq(AudioServer.get_bus_volume_db(voice_bus_index), 0.0, 0.01,
		"reset clears character overrides at the single post-effect authority")
	assert_eq(_runtime.settings_manager.settings.character_voice_volume, {})
	assert_eq(_runtime.settings_manager.settings.character_voice_enabled, {})

	await get_tree().create_timer(0.1).timeout
	assert_almost_eq(bgm_player.volume_db, linear_to_db(0.8), 0.01,
		"the authored Tween must keep using the live default settings multiplier")


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


func test_reset_for_test_cancels_skippable_timed_wait_generation() -> void:
	var advance_connections := SignalBus.advance_requested.get_connections().size()
	var abort_connections := SignalBus.engine_abort_requested.get_connections().size()
	var old_context := _start_blocking_command(
		_wait_command("timer", 60.0, true))
	assert_eq(SignalBus.advance_requested.get_connections().size(),
		advance_connections + 1)
	assert_eq(SignalBus.engine_abort_requested.get_connections().size(),
		abort_connections + 1)

	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())

	assert_true(old_context.is_cancellation_requested())
	assert_eq(SignalBus.advance_requested.get_connections().size(),
		advance_connections,
		"session reset retires the old normal-advance listener")
	assert_eq(SignalBus.engine_abort_requested.get_connections().size(),
		abort_connections,
		"session reset retires the old abort listener")
	assert_same(
		(_runtime.registry.get_handler("wait") as WaitHandler)._skip_controller,
		_runtime.skip_controller,
	)


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
	var advance_connections := SignalBus.advance_requested.get_connections().size()
	var abort_connections := SignalBus.engine_abort_requested.get_connections().size()
	var requests: Array[DialogueRequest] = []
	var on_request := func(request: DialogueRequest) -> void:
		requests.append(request)
	SignalBus.dialogue_requested.connect(on_request)
	var old_context := _start_blocking_command(_wait_command("timer", 0.2, true))
	assert_eq(SignalBus.advance_requested.get_connections().size(),
		advance_connections + 1)
	assert_eq(SignalBus.engine_abort_requested.get_connections().size(),
		abort_connections + 1)

	var loaded: bool = await _runtime.quick_load()
	assert_true(loaded)
	assert_true(await _wait_for_pending_activation(dialogue))
	var loaded_activation: DialogueActivation = dialogue._current_dialogue_activation

	_assert_blocking_load_boundary(old_context, dialogue)
	assert_eq(SignalBus.advance_requested.get_connections().size(),
		advance_connections,
		"quick load must disconnect the retired skippable wait input owner")
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


func test_save_operations_preserve_active_choice_and_playback_policy() -> void:
	var dialogue := await _instantiate_game_dialogue()
	var choice_panel: Control = dialogue.get_node("../ChoicePanel")
	_runtime.set_setting("auto_play_pause_on_choice", true)
	_runtime.set_setting("skip_stop_on_choice", false)
	_runtime.auto_play.is_active = true
	_runtime.skip_controller.is_active = true
	var choice_connections := SignalBus.choice_selected.get_connections().size()
	var abort_connections := (
		SignalBus.engine_abort_requested.get_connections().size())
	var context := _start_blocking_command(_choice_command())
	assert_true(choice_panel.visible)
	assert_true(_runtime.auto_play.is_active)
	assert_false(_runtime_auto_is_effective(),
		"the current choice owns an Auto suspension before saving")
	assert_true(_runtime.skip_controller.is_active)
	assert_eq(SignalBus.choice_selected.get_connections().size(),
		choice_connections + 1)
	assert_eq(SignalBus.engine_abort_requested.get_connections().size(),
		abort_connections + 1)

	_runtime.save(1)
	_runtime.quick_save()
	_runtime.auto_save()

	assert_true(_runtime.save_manager.has_save(1))
	assert_true(_runtime.has_quick_save())
	assert_true(_runtime.has_auto_save())
	assert_false(context.is_cancellation_requested(),
		"capturing a save is not a context boundary")
	assert_true(choice_panel.visible,
		"manual/quick/auto save cannot dismiss the active choice")
	assert_true(_runtime.auto_play.is_active)
	assert_false(_runtime_auto_is_effective(),
		"saving cannot release the exact choice suspension")
	assert_true(_runtime.skip_controller.is_active,
		"saving cannot stop retained Skip")
	assert_eq(SignalBus.choice_selected.get_connections().size(),
		choice_connections + 1)
	assert_eq(SignalBus.engine_abort_requested.get_connections().size(),
		abort_connections + 1)

	context.request_cancellation()
	await get_tree().process_frame
	assert_false(_runtime.auto_play.is_active)
	assert_false(_runtime.skip_controller.is_active)
	assert_eq(SignalBus.choice_selected.get_connections().size(),
		choice_connections)
	assert_eq(SignalBus.engine_abort_requested.get_connections().size(),
		abort_connections)
	assert_eq(context.cancellation_requested.get_connections().size(), 0)


func test_manual_load_from_active_choice_fail_closes_playback_modes() -> void:
	await _assert_choice_load_fail_closed(false)


func test_quick_load_from_active_choice_fail_closes_playback_modes() -> void:
	await _assert_choice_load_fail_closed(true)


func _assert_choice_load_fail_closed(quick: bool) -> void:
	var label := "quick load" if quick else "manual load"
	var dialogue := await _instantiate_game_dialogue()
	var choice_panel: Control = dialogue.get_node("../ChoicePanel")
	_prepare_load_snapshot(quick)
	_runtime.set_setting("auto_play_pause_on_choice", false)
	_runtime.set_setting("skip_stop_on_choice", false)
	_runtime.set_setting("auto_play_delay", 10.0)
	_runtime.set_setting("skip_interval", 10000)
	_runtime.set_setting("skip_only_read", false)
	_runtime.auto_play.is_active = true
	_runtime.skip_controller.is_active = true
	var choice_connections := SignalBus.choice_selected.get_connections().size()
	var abort_connections := (
		SignalBus.engine_abort_requested.get_connections().size())
	var old_context := _start_blocking_command(_choice_boundary_command())
	var old_store: VariableStore = old_context.variable_store
	assert_true(choice_panel.visible)
	assert_true(_runtime.auto_play.is_active)
	assert_true(_runtime.skip_controller.is_active)
	assert_eq(SignalBus.choice_selected.get_connections().size(),
		choice_connections + 1)
	assert_eq(SignalBus.engine_abort_requested.get_connections().size(),
		abort_connections + 1)
	assert_eq(old_context.cancellation_requested.get_connections().size(), 1)
	var hide_owners: Array[ScenarioContext] = []
	var on_hide := func() -> void:
		hide_owners.append(_runtime.engine.context)
		SignalBus.choice_selected.emit("old")
	SignalBus.choice_hide.connect(on_hide, CONNECT_ONE_SHOT)
	var stale_dialogues: Array[String] = []
	var on_dialogue := func(request: DialogueRequest) -> void:
		var text := _dialogue_request_text(request)
		if text == "must not start":
			stale_dialogues.append(text)
	SignalBus.dialogue_requested.connect(on_dialogue)

	var loaded: bool
	if quick:
		loaded = await _runtime.quick_load()
	else:
		loaded = await _runtime.continue_from_save(1)
	assert_true(loaded)
	assert_true(await _wait_for_pending_activation(dialogue))
	if SignalBus.choice_hide.is_connected(on_hide):
		SignalBus.choice_hide.disconnect(on_hide)
	SignalBus.dialogue_requested.disconnect(on_dialogue)
	var loaded_context: ScenarioContext = _runtime.engine.context

	assert_gte(hide_owners.size(), 1,
		"%s must publish a hard choice HIDE" % label)
	for owner in hide_owners:
		assert_not_same(owner, old_context,
			"%s transfers engine ownership before choice HIDE" % label)
	assert_true(old_context.is_cancellation_requested())
	assert_null(old_store.get_var("leaked"),
		"synchronous HIDE reentry cannot commit old option effects")
	assert_eq(stale_dialogues, [],
		"synchronous HIDE reentry cannot dispatch the old command tail")
	assert_eq(_scenario_ended_count[0], 0,
		"synchronous HIDE reentry is cancellation, not normal completion")
	assert_false(_runtime.auto_play.is_active,
		"%s cannot carry choice-retained Auto into the new context" % label)
	assert_false(_runtime.is_auto_playing())
	assert_false(_runtime.skip_controller.is_active,
		"%s cannot carry choice-retained Skip into the new context" % label)
	assert_false(_runtime.is_skipping())
	assert_eq(SignalBus.choice_selected.get_connections().size(),
		choice_connections)
	assert_eq(old_context.cancellation_requested.get_connections().size(), 0)
	assert_eq(SignalBus.engine_abort_requested.get_connections().size(),
		abort_connections + 1,
		"only the loaded dialogue owner remains abortable")
	SignalBus.choice_selected.emit("old")
	await get_tree().process_frame
	assert_false(_runtime.auto_play.is_active,
		"a late old-choice callback cannot revive Auto after %s" % label)
	assert_false(_runtime.skip_controller.is_active,
		"a late old-choice callback cannot revive Skip after %s" % label)

	loaded_context.request_cancellation()
	await get_tree().process_frame
	assert_eq(SignalBus.choice_selected.get_connections().size(),
		choice_connections)
	assert_eq(SignalBus.engine_abort_requested.get_connections().size(),
		abort_connections)
	assert_eq(loaded_context.cancellation_requested.get_connections().size(), 0)


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


func test_rollback_from_active_choice_fail_closes_playback_modes() -> void:
	var dialogue := await _instantiate_game_dialogue()
	var choice_panel: Control = dialogue.get_node("../ChoicePanel")
	_runtime.set_setting("auto_play_pause_on_choice", false)
	_runtime.set_setting("skip_stop_on_choice", false)
	_runtime.set_setting("auto_play_delay", 10.0)
	_runtime.set_setting("skip_interval", 10000)
	_runtime.set_setting("skip_only_read", false)
	_runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	_runtime.engine.load_scenario(_build_dialogue_choice_scenario())
	var old_context: ScenarioContext = _runtime.engine.context
	var old_store: VariableStore = old_context.variable_store
	var choice_connections := SignalBus.choice_selected.get_connections().size()
	var abort_connections := (
		SignalBus.engine_abort_requested.get_connections().size())
	var cancellation_connections := (
		old_context.cancellation_requested.get_connections().size())
	_runtime.engine.run()
	assert_true(await _wait_for_pending_activation(dialogue))
	assert_eq(_runtime.backlog_manager.get_entries().size(), 1)

	assert_true(RuntimeTestSupport.advance_dialogue_for_test(get_tree()),
		"the test explicitly commits the ready dialogue activation")
	await get_tree().process_frame
	assert_true(choice_panel.visible,
		"the authored choice becomes active without a wall-clock Skip race")
	# The hard-boundary contract is about retiring controller intent owned while
	# the choice is active. Enable both only after the modal owns execution so the
	# fixture does not depend on Skip's synchronous ready-line advance behavior.
	_runtime.auto_play.is_active = true
	_runtime.skip_controller.is_active = true
	assert_true(_runtime.auto_play.is_active)
	assert_true(_runtime.skip_controller.is_active)
	assert_eq(SignalBus.choice_selected.get_connections().size(),
		choice_connections + 1)
	assert_eq(SignalBus.engine_abort_requested.get_connections().size(),
		abort_connections + 1)
	var hide_owners: Array[ScenarioContext] = []
	var on_hide := func() -> void:
		hide_owners.append(_runtime.engine.context)
		SignalBus.choice_selected.emit("old")
	SignalBus.choice_hide.connect(on_hide, CONNECT_ONE_SHOT)
	var stale_dialogues: Array[String] = []
	var on_dialogue := func(request: DialogueRequest) -> void:
		var text := _dialogue_request_text(request)
		if text == "must not start from stale choice":
			stale_dialogues.append(text)
	SignalBus.dialogue_requested.connect(on_dialogue)

	assert_true(_runtime.jump_from_backlog(0))
	assert_true(await _wait_for_pending_activation(dialogue))
	if SignalBus.choice_hide.is_connected(on_hide):
		SignalBus.choice_hide.disconnect(on_hide)
	SignalBus.dialogue_requested.disconnect(on_dialogue)
	var restored_context: ScenarioContext = _runtime.engine.context

	assert_gte(hide_owners.size(), 1)
	for owner in hide_owners:
		assert_not_same(owner, old_context,
			"rollback transfers engine ownership before choice HIDE")
	assert_true(old_context.is_cancellation_requested())
	assert_null(old_store.get_var("leaked"))
	assert_eq(stale_dialogues, [])
	assert_eq(_scenario_ended_count[0], 0)
	assert_false(_runtime.auto_play.is_active,
		"rollback cannot release an old choice pause into restored content")
	assert_false(_runtime.is_auto_playing())
	assert_false(_runtime.skip_controller.is_active,
		"rollback cannot retain old choice Skip")
	assert_false(_runtime.is_skipping())
	assert_eq(SignalBus.choice_selected.get_connections().size(),
		choice_connections)
	assert_eq(old_context.cancellation_requested.get_connections().size(),
		cancellation_connections)
	assert_eq(SignalBus.engine_abort_requested.get_connections().size(),
		abort_connections + 1,
		"only the restored dialogue owner remains abortable")
	SignalBus.choice_selected.emit("old")
	await get_tree().process_frame
	assert_false(_runtime.auto_play.is_active)
	assert_false(_runtime.skip_controller.is_active)

	restored_context.request_cancellation()
	await get_tree().process_frame
	assert_eq(SignalBus.choice_selected.get_connections().size(),
		choice_connections)
	assert_eq(SignalBus.engine_abort_requested.get_connections().size(),
		abort_connections)
	assert_eq(restored_context.cancellation_requested.get_connections().size(), 0)


func test_return_to_title_from_active_choice_stops_modes_and_late_callbacks() -> void:
	var dialogue := await _instantiate_game_dialogue()
	var choice_panel: Control = dialogue.get_node("../ChoicePanel")
	var original_title_bgm: String = _runtime.config.title_bgm
	_runtime.config.title_bgm = ""
	_runtime.set_setting("auto_play_pause_on_choice", true)
	_runtime.set_setting("skip_stop_on_choice", false)
	_runtime.auto_play.is_active = true
	_runtime.skip_controller.is_active = true
	var choice_connections := SignalBus.choice_selected.get_connections().size()
	var abort_connections := (
		SignalBus.engine_abort_requested.get_connections().size())
	var old_context := _start_blocking_command(_choice_boundary_command())
	var old_store: VariableStore = old_context.variable_store
	assert_true(choice_panel.visible)
	assert_eq(SignalBus.choice_selected.get_connections().size(),
		choice_connections + 1)
	assert_eq(SignalBus.engine_abort_requested.get_connections().size(),
		abort_connections + 1)
	assert_eq(old_context.cancellation_requested.get_connections().size(), 1)
	var auto_effective_edges: Array[bool] = []
	var on_auto_effective := func(effective: bool) -> void:
		auto_effective_edges.append(effective)
	var auto_effective_signal := Signal(
		_runtime.auto_play, &"effective_changed")
	auto_effective_signal.connect(on_auto_effective)
	var hide_owners: Array[ScenarioContext] = []
	var on_hide := func() -> void:
		hide_owners.append(_runtime.engine.context)
		SignalBus.choice_selected.emit("old")
	SignalBus.choice_hide.connect(on_hide, CONNECT_ONE_SHOT)
	var stale_dialogues: Array[String] = []
	var on_dialogue := func(request: DialogueRequest) -> void:
		var text := _dialogue_request_text(request)
		if text == "must not start":
			stale_dialogues.append(text)
	SignalBus.dialogue_requested.connect(on_dialogue)

	_runtime.return_to_title()
	var title_completed: bool = await wait_until(
		func() -> bool: return not _runtime._return_to_title_pending,
		2.0,
		"return-to-title confirms its deferred scene transaction",
	)
	assert_true(title_completed)
	_runtime.config.title_bgm = original_title_bgm
	if auto_effective_signal.is_connected(on_auto_effective):
		auto_effective_signal.disconnect(on_auto_effective)
	if SignalBus.choice_hide.is_connected(on_hide):
		SignalBus.choice_hide.disconnect(on_hide)
	SignalBus.dialogue_requested.disconnect(on_dialogue)

	assert_gte(hide_owners.size(), 1)
	for owner in hide_owners:
		assert_null(owner,
			"return-to-title clears engine ownership before choice HIDE")
	assert_true(old_context.is_cancellation_requested())
	assert_null(old_store.get_var("leaked"))
	assert_eq(stale_dialogues, [])
	assert_eq(_scenario_ended_count[0], 0)
	assert_eq(auto_effective_edges, [],
		"a hard boundary stops intent before clearing the choice token")
	assert_null(_runtime.engine.context)
	assert_false(choice_panel.visible)
	assert_false(_runtime.auto_play.is_active)
	assert_false(_runtime.is_auto_playing())
	assert_false(_runtime.skip_controller.is_active)
	assert_false(_runtime.is_skipping())
	assert_eq(SignalBus.choice_selected.get_connections().size(),
		choice_connections)
	assert_eq(SignalBus.engine_abort_requested.get_connections().size(),
		abort_connections)
	assert_eq(old_context.cancellation_requested.get_connections().size(), 0)
	SignalBus.choice_selected.emit("old")
	await get_tree().process_frame
	assert_false(_runtime.auto_play.is_active,
		"late title-screen callbacks cannot revive Auto")
	assert_false(_runtime.skip_controller.is_active,
		"late title-screen callbacks cannot revive Skip")
	assert_eq(SignalBus.choice_selected.get_connections().size(),
		choice_connections)
	assert_eq(SignalBus.engine_abort_requested.get_connections().size(),
		abort_connections)


func test_screen_effects_retire_across_manual_and_quick_load_generations() -> void:
	var fixture: Dictionary = await _instantiate_screen_effect_fixture()
	var effects: Node = fixture["effects"]
	var visual_baseline := _capture_effect_visuals(fixture)
	_runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	_prepare_load_snapshot(false)
	_runtime.quick_save()

	var manual_retired := _start_effect_pair(effects)
	assert_true(await _runtime.continue_from_save(1))
	_assert_effects_neutral(fixture, visual_baseline)

	var quick_retired := _start_effect_pair(effects)
	effects._finish_shake(manual_retired["shake"])
	effects._finish_flash(manual_retired["flash"])
	assert_same(effects._shake_tween, quick_retired["shake"],
		"manual-load retirees cannot clear a post-load shake")
	assert_same(effects._flash_tween, quick_retired["flash"],
		"manual-load retirees cannot clear a post-load flash")

	assert_true(await _runtime.quick_load())
	_assert_effects_neutral(fixture, visual_baseline)
	effects._finish_shake(quick_retired["shake"])
	effects._finish_flash(quick_retired["flash"])
	_assert_effects_neutral(fixture, visual_baseline)


func test_screen_effects_retire_across_rollback_restart_and_title_boundaries() -> void:
	var effect_connections := SignalBus.effect_requested.get_connections().size()
	var abort_connections := SignalBus.engine_abort_requested.get_connections().size()
	var settings_connections := SignalBus.settings_changed.get_connections().size()
	var fixture: Dictionary = await _instantiate_screen_effect_fixture()
	var game: Node = fixture["game"]
	var effects: Node = fixture["effects"]
	var visual_baseline := _capture_effect_visuals(fixture)
	_runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	_runtime._last_scenario_path = LOAD_FIXTURE
	_runtime._prepare_scenario(LOAD_FIXTURE)
	var rollback_snapshot: Dictionary = _runtime._capture_rollback_snapshot()

	var rollback_retired := _start_effect_pair(effects)
	_runtime._restore_runtime_from_snapshot(rollback_snapshot)
	_assert_effects_neutral(fixture, visual_baseline)

	var restart_retired := _start_effect_pair(effects)
	effects._finish_shake(rollback_retired["shake"])
	effects._finish_flash(rollback_retired["flash"])
	assert_same(effects._shake_tween, restart_retired["shake"])
	assert_same(effects._flash_tween, restart_retired["flash"])
	_runtime.start_scenario(LOAD_FIXTURE)
	_assert_effects_neutral(fixture, visual_baseline)

	var title_retired := _start_effect_pair(effects)
	effects._finish_shake(restart_retired["shake"])
	effects._finish_flash(restart_retired["flash"])
	assert_same(effects._shake_tween, title_retired["shake"])
	assert_same(effects._flash_tween, title_retired["flash"])
	var original_title_bgm: String = _runtime.config.title_bgm
	_runtime.config.title_bgm = ""
	_runtime.return_to_title()
	var title_completed: bool = await wait_until(
		func() -> bool: return not _runtime._return_to_title_pending,
		2.0,
		"return-to-title confirms its deferred scene transaction",
	)
	assert_true(title_completed)
	_runtime.config.title_bgm = original_title_bgm
	_assert_effects_neutral(fixture, visual_baseline)
	effects._finish_shake(title_retired["shake"])
	effects._finish_flash(title_retired["flash"])
	_assert_effects_neutral(fixture, visual_baseline)

	game.queue_free()
	await get_tree().process_frame
	assert_eq(SignalBus.effect_requested.get_connections().size(), effect_connections,
		"scene exit releases the presenter effect listener")
	assert_eq(SignalBus.engine_abort_requested.get_connections().size(), abort_connections,
		"scene exit and title retirement restore the abort-listener baseline")
	assert_eq(SignalBus.settings_changed.get_connections().size(), settings_connections,
		"scene exit releases the presenter settings listener")


func test_reset_for_test_invalidates_a_real_dialogue_typewriter() -> void:
	var game: Node = load("res://addons/stella/scenes/game.tscn").instantiate()
	_add_owned_node(game)
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
	_add_owned_node(game)
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
	_add_owned_node(game)
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
	_add_owned_node(game)
	await get_tree().process_frame
	var dialogue: Control = game.get_node("UILayer/DialoguePanel")
	dialogue._char_interval = 0.0
	return dialogue


func _instantiate_screen_effect_fixture() -> Dictionary:
	var game: Node = load("res://addons/stella/scenes/game.tscn").instantiate()
	_add_owned_node(game)
	await get_tree().process_frame
	return {
		"game": game,
		"effects": game.get_node("ScreenEffects"),
		"background": game.get_node("BackgroundLayer/ShakeRoot"),
		"stage": game.get_node("StageLayer/ShakeRoot"),
	}


func _capture_effect_visuals(fixture: Dictionary) -> Dictionary:
	var background: Control = fixture["background"]
	var stage: Control = fixture["stage"]
	return {
		"background_position": background.position,
		"background_scale": background.scale,
		"background_pivot": background.pivot_offset,
		"stage_position": stage.position,
		"stage_scale": stage.scale,
		"stage_pivot": stage.pivot_offset,
	}


func _start_effect_pair(effects: Node) -> Dictionary:
	SignalBus.effect_requested.emit(
		"shake", {"intensity": 20.0, "duration": 100.0})
	SignalBus.effect_requested.emit(
		"flash", {"color": "red", "duration": 100.0})
	assert_not_null(effects._shake_tween)
	assert_not_null(effects._flash_tween)
	assert_not_null(effects._flash_overlay)
	return {
		"shake": effects._shake_tween,
		"flash": effects._flash_tween,
		"overlay": effects._flash_overlay,
	}


func _assert_effects_neutral(fixture: Dictionary, baseline: Dictionary) -> void:
	var effects: Node = fixture["effects"]
	var background: Control = fixture["background"]
	var stage: Control = fixture["stage"]
	assert_null(effects._shake_tween)
	assert_null(effects._flash_tween)
	assert_null(effects._flash_overlay)
	assert_true(effects._shake_targets.is_empty())
	assert_true(effects._shake_baselines.is_empty())
	assert_true(effects._shake_motion_baselines.is_empty())
	assert_true(effects._shake_coverage_baselines.is_empty())
	assert_true(effects._queued_effect_requests.is_empty())
	assert_eq(effects._effect_mutation_depth, 0)
	assert_false(effects.is_processing())
	assert_eq(background.position, baseline["background_position"])
	assert_eq(background.scale, baseline["background_scale"])
	assert_eq(background.pivot_offset, baseline["background_pivot"])
	assert_eq(stage.position, baseline["stage_position"])
	assert_eq(stage.scale, baseline["stage_scale"])
	assert_eq(stage.pivot_offset, baseline["stage_pivot"])


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


func _runtime_auto_is_effective() -> bool:
	return _runtime.auto_play.is_effective()


func _dialogue_request_text(request: DialogueRequest) -> String:
	var segments := request.get_segments()
	if segments.is_empty() or not segments[0] is Dictionary:
		return ""
	var first_segment: Dictionary = segments[0]
	return String(first_segment.get("text", ""))


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


func _install_synthetic_bgm(audio_presenter: Node) -> AudioStreamPlayer:
	var stream := AudioStreamGenerator.new()
	var voice: Dictionary = audio_presenter._create_bgm_voice(
		stream, "synthetic", "", true, 0.0, 0.0, -1.0, 1.0, {}, [], {})
	audio_presenter._bgm_channel = audio_presenter._new_bgm_channel()
	audio_presenter._bgm_channel["current"] = voice
	audio_presenter._bgm_channel["target_state"] = {
		"asset": "synthetic", "cue": "", "loop": true, "position": 0.0,
		"status": "playing", "stem_mix": {}, "volume": 1.0,
	}
	return voice["player"] as AudioStreamPlayer


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


func _build_dialogue_choice_scenario() -> ScenarioData:
	var data := ScenarioData.new()
	data.id = "runtime_choice_rollback_policy_test"
	var scene := SceneData.new()
	scene.id = "start"
	scene.commands = [
		_dialogue_command("snapshot before choice"),
		_choice_boundary_command(),
		_dialogue_command("must not start from stale choice"),
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


func _wait_command(
	mode: String,
	duration: float = 1.0,
	skippable: bool = false,
) -> CommandData:
	var command := CommandData.new()
	command.type = "wait"
	command.params = (
		{"mode": "click"}
		if mode == "click"
		else {"mode": "timer", "duration": duration, "skippable": skippable}
	)
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


func _choice_boundary_command() -> CommandData:
	var command := CommandData.new()
	command.type = "choice"
	command.params = {
		"prompt": "Retired choice boundary",
		"options": [{
			"id": "old",
			"label": "Old",
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
