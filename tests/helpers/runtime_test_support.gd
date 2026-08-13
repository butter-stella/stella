extends RefCounted
## Test-only isolation helper for the persistent StellaRuntime autoload.


static func reset_for_test(runtime: Node, tree: SceneTree) -> void:
	# Detach and invalidate the run before waking a blocking handler. Reversing
	# these steps can let an old continuation publish lifecycle events into the
	# replacement test session.
	runtime.engine.cancel_current_run()
	SignalBus.engine_abort_requested.emit()

	runtime.settings_manager.reset_to_default()
	DisplayHelper.apply(runtime.settings_manager.settings)

	runtime._reset_presentation()
	var audio_presenter: Node = runtime.get_node_or_null("AudioPresenter")
	SignalBus.fade_requested.emit("in", 0.0)
	# hide_dialogue invalidates the presenter's voice-queue generation; wake any
	# queue that was already awaiting the old voice's completion so it can exit.
	# advance_requested also stops the persistent AudioPresenter's voice player;
	# settings are reset first so voice_continue_on_advance cannot block that.
	SignalBus.advance_requested.emit()
	SignalBus.voice_finished.emit()
	runtime._close_current_overlay()

	# The public presentation reset has no global SE/system-SE stop and models a
	# zero-duration BGM stop as an asynchronous tween. Tests need a synchronous
	# boundary, so clear the persistent audio node directly after exercising the
	# normal signals above.
	_reset_audio_for_test(audio_presenter)

	# Overlay cleanup and aborted handler/typewriter continuations resume on the
	# lifecycle boundary. Drain it before installing fresh session objects so
	# none can mutate their replacements.
	await tree.process_frame

	# Recreate mutable session objects whose limits or monotonic merge semantics
	# make clear()/restore_snapshot({}) insufficient for complete isolation.
	runtime.auto_play = AutoPlayController.new()
	runtime.skip_controller = SkipController.new()
	runtime.backlog_manager = BacklogManager.new()
	runtime.choice_history_manager = ChoiceHistoryManager.new()
	runtime.read_flags = ReadFlagManager.new()
	runtime.unlock_manager = UnlockManager.new()
	runtime.flowchart_state = FlowchartState.new()
	runtime.flowchart_visited = FlowchartVisitedState.new()

	# These instances own long-lived SignalBus/runtime connections established in
	# StellaRuntime._ready(), so preserve them and reset only their data models.
	runtime.presentation_state.clear()
	runtime.game_state.current_state = GameStateMachine.State.TITLE
	runtime.game_state.previous_state = GameStateMachine.State.TITLE

	runtime.scenario_graph = null
	runtime._last_scenario_path = ""
	runtime.character_config_loader.clear_cache()
	runtime.character_config_loader.set_base_path(runtime.characters_path)

	# SaveManager has no unregister operation. Rebuilding it is the only way to
	# remove stale scenario_context, variable_store, and custom providers while
	# rebinding every base provider to the replacement instances above.
	runtime.save_manager = SaveManager.new()
	runtime.save_manager.register_provider(runtime.read_flags)
	runtime.save_manager.register_provider(runtime.unlock_manager)
	runtime.save_manager.register_provider(runtime.presentation_state)
	runtime.save_manager.register_provider(runtime.flowchart_state)
	runtime.save_manager.register_provider(runtime.flowchart_visited)


static func _reset_audio_for_test(audio_presenter: Node) -> void:
	if audio_presenter == null:
		return
	audio_presenter._cancel_bgm_tween()
	audio_presenter._bgm_player.stop()
	audio_presenter._bgm_player.stream = null
	for player: AudioStreamPlayer in audio_presenter._se_players:
		player.stop()
		player.stream = null
	audio_presenter._voice_player.stop()
	audio_presenter._voice_player.stream = null
	audio_presenter._current_voice_character = ""
	audio_presenter._system_se_player.stop()
	audio_presenter._system_se_player.stream = null
