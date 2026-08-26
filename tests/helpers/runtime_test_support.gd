extends RefCounted
## Test-only isolation helper for the persistent StellaRuntime autoload.

static var _active_dialogue_request: DialogueRequest


static func _capture_dialogue_request(request: DialogueRequest) -> void:
	_active_dialogue_request = request


static func reset_for_test(runtime: Node, tree: SceneTree) -> void:
	if not SignalBus.dialogue_requested.is_connected(_capture_dialogue_request):
		SignalBus.dialogue_requested.connect(_capture_dialogue_request)
	_active_dialogue_request = null
	# Detach and invalidate the run before waking a blocking handler. Reversing
	# these steps can let an old continuation publish lifecycle events into the
	# replacement test session.
	runtime.engine.cancel_current_run()
	if runtime._active_recollection_playback != null:
		runtime._active_recollection_playback.cancel()
	runtime._active_recollection_playback = null
	runtime._active_recollection_context = null
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

	# The canonical BGM reset is synchronous. One-shot SE/system-SE have no public
	# stop lifecycle, so test isolation clears those private pools directly.
	_reset_audio_for_test(audio_presenter)

	# Overlay cleanup and aborted handler/typewriter continuations resume on the
	# lifecycle boundary. Drain it before installing fresh session objects so
	# none can mutate their replacements.
	await tree.process_frame

	# Recreate mutable session objects whose limits or monotonic merge semantics
	# make clear()/restore_snapshot({}) insufficient for complete isolation.
	runtime.auto_play = AutoPlayController.new()
	runtime.skip_controller = SkipController.new()
	if (
		runtime.presentation_director != null
		and not runtime.skip_controller.active_changed.is_connected(
			runtime.presentation_director.on_skip_active_changed)
	):
		runtime.skip_controller.active_changed.connect(
			runtime.presentation_director.on_skip_active_changed)
	runtime.backlog_manager = BacklogManager.new()
	runtime.choice_history_manager = ChoiceHistoryManager.new()
	runtime.read_flags = ReadFlagManager.new()
	runtime.unlock_manager = UnlockManager.new()
	runtime.flowchart_state = FlowchartState.new()
	runtime.flowchart_visited = FlowchartVisitedState.new()
	# DialogueHandler owns the Core-side write boundary for read history. Replace
	# the handler so no in-flight execution can be rebound to the fresh manager.
	runtime._register_dialogue_handler()
	runtime._register_wait_handler()

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
	# Direct-engine integration fixtures bypass StellaRuntime.start_game(), but
	# their rollback checkpoints still exercise the current strict provider
	# schema. Install one deterministic playthrough baseline without consuming
	# Runtime entropy, and keep the authority registered on the rebuilt manager.
	var choice_authority: PresentationClipAudioChoiceAuthority = (
		runtime.presentation_clip_audio_choice_authority)
	if not choice_authority.clear_to_unstarted():
		push_error(
			"RuntimeTestSupport: presentation-clip audio-choice transaction survived reset")
		return
	if not choice_authority.restore_snapshot({
		"version": PresentationClipAudioChoiceAuthority.SNAPSHOT_VERSION,
		"initialized": true,
		"initial_seed": 1,
		"state": 1,
		"last_choices": {},
	}):
		push_error(
			"RuntimeTestSupport: failed to install deterministic audio-choice baseline")
		return
	runtime.save_manager.register_provider(choice_authority)
	runtime.save_manager.register_provider(runtime.flowchart_state)
	runtime.save_manager.register_provider(runtime.flowchart_visited)


## Drive the exact DialogueRequest rendered by the active built-in panel.
## Tests must not use the global advance notification as a command ack.
static func advance_dialogue_for_test(tree: SceneTree) -> bool:
	if (
		_active_dialogue_request != null
		and _active_dialogue_request.get_activation() != null
		and _active_dialogue_request.get_activation().is_pending()
	):
		return _active_dialogue_request.advance()
	for node in tree.root.find_children("DialoguePanel", "", true, false):
		if not node.has_method("request_current_dialogue_advance"):
			continue
		var activation = node.get("_current_dialogue_activation")
		if activation is DialogueActivation and activation.is_pending():
			return bool(node.request_current_dialogue_advance())
	return false


static func _reset_audio_for_test(audio_presenter: Node) -> void:
	if audio_presenter == null:
		return
	for player: AudioStreamPlayer in audio_presenter._se_players:
		player.stop()
		player.stream = null
	audio_presenter._voice_player.stop()
	audio_presenter._voice_player.stream = null
	audio_presenter._current_voice_character = ""
	audio_presenter._system_se_player.stop()
	audio_presenter._system_se_player.stream = null
