extends GutTest
## Real VideoStreamPlayer and typed Director lifecycle for issue #179.

const RuntimeTestSupport = preload("res://tests/helpers/runtime_test_support.gd")
const SOURCE_PATH := "res://tests/fixtures/scenarios/movie_lifecycle.stla"
const PUBLIC_SOURCE_PATH := "res://tests/fixtures/scenarios/movie/lifecycle.stla"
const PUBLIC_FNF_PATH := "res://tests/fixtures/scenarios/movie/fire_and_forget.stla"
const MOVIE_ROOT := "res://tests/fixtures/movies/"
const CLIP_ROOT := "res://tests/fixtures/presentation_clips/"
const SYSTEM_AUDIO_ROOT := "res://tests/fixtures/audio/bgm/"
const STAGE_ROOT := "res://tests/fixtures/stage/"
const SAVE_DIR := "user://tests/movie_lifecycle/"
const SAVE_SLOT := 179

var _runtime: Node
var _presenter: MoviePresenter
var _context: ScenarioContext
var _original_engine: ScenarioEngine
var _original_movies_path := ""
var _original_clips_path := ""
var _original_se_path := ""
var _original_stage_path := ""
var _original_save_dir := ""
var _original_title_scene_path := ""
var _original_navigation_override := Callable()
var _original_master_volume := 1.0
var _original_movie_volume := 1.0
var _original_right_click := true
var _original_skip_on_skip := false
var _receipts: Array[Dictionary] = []
var _terminals: Array[Dictionary] = []
var _game_scene: Node
var _stage_presenter: StagePresenter
var _choice_session := -1


func before_each() -> void:
	_runtime = get_tree().root.get_node("StellaRuntime")
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	_original_engine = _runtime.engine
	_original_movies_path = _runtime.movies_path
	_original_clips_path = _runtime.presentation_clips_path
	_original_se_path = _runtime.se_path
	_original_stage_path = _runtime.stage_assets_path
	_original_save_dir = _runtime.save_manager.save_dir
	_original_title_scene_path = _runtime.title_scene_path
	_original_navigation_override = _runtime._navigation_scene_change_override
	_original_master_volume = float(_runtime.get_setting("master_volume"))
	_original_movie_volume = float(_runtime.get_setting("movie_volume"))
	_original_right_click = bool(_runtime.get_setting("movie_right_click_skip"))
	_original_skip_on_skip = bool(_runtime.get_setting("movie_skip_on_skip"))
	_runtime.movies_path = MOVIE_ROOT
	_runtime.presentation_clips_path = CLIP_ROOT
	_runtime.se_path = SYSTEM_AUDIO_ROOT
	_runtime.stage_assets_path = STAGE_ROOT
	_runtime.save_manager.save_dir = SAVE_DIR
	_runtime.delete_save(SAVE_SLOT)
	_runtime.delete_quick_save()
	_runtime.delete_auto_save()
	_runtime.game_state.current_state = GameStateMachine.State.PLAYING
	_presenter = _runtime.get_node("MoviePresenter") as MoviePresenter
	var scenario := ScenarioData.new()
	scenario.id = "movie_lifecycle"
	scenario.source_path = SOURCE_PATH
	var scene := SceneData.new()
	scene.id = "start"
	scenario.scenes = [scene]
	_context = ScenarioContext.new(scenario)
	_context.variable_store = VariableStore.new()
	var engine := ScenarioEngine.new()
	engine.registry = _runtime.registry
	engine.context = _context
	_runtime.engine = engine
	_receipts.clear()
	_terminals.clear()
	SignalBus.movie_transition_receipt_started.connect(_on_receipt)
	SignalBus.movie_transition_terminal.connect(_on_terminal)


func after_each() -> void:
	if SignalBus.movie_transition_receipt_started.is_connected(_on_receipt):
		SignalBus.movie_transition_receipt_started.disconnect(_on_receipt)
	if SignalBus.movie_transition_terminal.is_connected(_on_terminal):
		SignalBus.movie_transition_terminal.disconnect(_on_terminal)
	_runtime.presentation_director.cancel_all()
	if _choice_session >= 0:
		_runtime._cancel_choice_policy_session(_choice_session)
	_choice_session = -1
	SignalBus.reset_movie_presentation()
	SignalBus.reset_presentation_clip()
	if _game_scene != null and is_instance_valid(_game_scene):
		_game_scene.queue_free()
		await _game_scene.tree_exited
		await get_tree().process_frame
	_game_scene = null
	if _stage_presenter != null and is_instance_valid(_stage_presenter):
		_stage_presenter.queue_free()
		await _stage_presenter.tree_exited
		await get_tree().process_frame
	_stage_presenter = null
	_runtime.movies_path = _original_movies_path
	_runtime.presentation_clips_path = _original_clips_path
	_runtime.se_path = _original_se_path
	_runtime.stage_assets_path = _original_stage_path
	_runtime.delete_save(SAVE_SLOT)
	_runtime.delete_quick_save()
	_runtime.delete_auto_save()
	_runtime.save_manager.save_dir = _original_save_dir
	_runtime.title_scene_path = _original_title_scene_path
	_runtime._navigation_scene_change_override = _original_navigation_override
	_runtime.set_setting("master_volume", _original_master_volume)
	_runtime.set_setting("movie_volume", _original_movie_volume)
	_runtime.set_setting("movie_right_click_skip", _original_right_click)
	_runtime.set_setting("movie_skip_on_skip", _original_skip_on_skip)
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	# Reset while the scenario started by this test still owns Runtime. Replacing
	# the Engine first would strand its suspended @wait coroutine and retain the
	# entire parsed ScenarioData graph until process exit.
	_runtime.engine = _original_engine


func _operation(
	action: String = "play",
	loop: bool = false,
	skippable: bool = true,
	asset: String = "synthetic_movie",
	line: int = 3,
) -> MoviePresentationOperation:
	return MoviePresentationOperation.new({
		"action": action,
		"asset": asset if action == "play" else "",
		"loop": loop if action == "play" else false,
		"skippable": skippable if action == "play" else true,
	}, {"source_path": SOURCE_PATH, "line": line})


func _submit(
	operation: MoviePresentationOperation,
	policy: PresentationBatchRequest.Policy,
) -> PresentationBatchRequest:
	var operations: Array[PresentationOperation] = [operation]
	return _runtime.presentation_director.submit(
		operations, policy, _context, operation.get_source())


func _submit_operations(
	operations: Array[PresentationOperation],
	policy: PresentationBatchRequest.Policy,
	line: int,
) -> PresentationBatchRequest:
	return _runtime.presentation_director.submit(
		operations,
		policy,
		_context,
		{"source_path": SOURCE_PATH, "line": line},
	)


func _clip_operation(
	asset: String = "synthetic_clip",
	line: int = 40,
) -> PresentationClipPresentationOperation:
	return PresentationClipPresentationOperation.new(
		{"asset": asset}, {"source_path": SOURCE_PATH, "line": line})


func _mount_game_scene() -> void:
	if _game_scene != null:
		return
	_game_scene = load("res://addons/stella/scenes/game.tscn").instantiate()
	add_child(_game_scene)
	await get_tree().process_frame


func _mount_stage_presenter() -> void:
	if _stage_presenter != null:
		return
	_stage_presenter = StagePresenter.new()
	_stage_presenter.name = "MovieRollbackStagePresenter"
	add_child(_stage_presenter)
	await get_tree().process_frame


func _wait_until(predicate: Callable, max_frames: int = 180) -> bool:
	for _frame in range(max_frames):
		if bool(predicate.call()):
			return true
		await get_tree().process_frame
	return bool(predicate.call())


func _on_receipt(
	presenter_id: int,
	token: int,
	request_id: int,
	generation: int,
) -> void:
	_receipts.append({
		"presenter": presenter_id,
		"token": token,
		"request": request_id,
		"generation": generation,
	})


func _on_terminal(
	presenter_id: int,
	token: int,
	request_id: int,
	generation: int,
	outcome: StringName,
) -> void:
	_terminals.append({
		"presenter": presenter_id,
		"token": token,
		"request": request_id,
		"generation": generation,
		"outcome": outcome,
	})


func test_native_movie_plays_on_one_typed_fnf_owner_and_live_volume_is_exact() -> void:
	var request := _submit(
		_operation(), PresentationBatchRequest.Policy.FIRE_AND_FORGET)
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(_receipts.size(), 1)
	assert_eq(_terminals.size(), 0)
	assert_true(_presenter._player.is_playing())
	assert_true(_presenter._player.stream is VideoStreamTheora)
	assert_eq(_presenter.layer, PresentationLayerOrder.FULLSCREEN_MEDIA)
	assert_eq(_presenter._player.bus, &"Master")
	assert_true(_presenter._player.visible)
	assert_true(_presenter._backdrop.visible)
	assert_eq(SignalBus.capture_movie_state()["asset"], "synthetic_movie")

	_runtime.set_setting("master_volume", 0.5)
	_runtime.set_setting("movie_volume", 0.4)
	assert_almost_eq(_presenter._player.volume, 0.2, 0.000001)
	_runtime.set_setting("movie_volume", 0.0)
	assert_eq(_presenter._player.volume, 0.0)


func test_input_policy_consumes_without_leak_and_exactly_finishes_when_enabled() -> void:
	_submit(_operation(), PresentationBatchRequest.Policy.FIRE_AND_FORGET)
	_runtime.set_setting("movie_right_click_skip", false)
	assert_true(_runtime.presentation_director.consume_active_movie_input(
		&"right_click"))
	assert_true(_presenter._player.is_playing())
	assert_eq(_terminals.size(), 0)
	_runtime.set_setting("movie_right_click_skip", true)
	var reentrant_capture: Array = ["not-called"]
	var capture_during_completion := func() -> void:
		reentrant_capture[0] = _runtime.save_manager._capture_save_data()
	SignalBus.movie_completion_committed.connect(
		capture_during_completion, CONNECT_ONE_SHOT)
	assert_true(_runtime.presentation_director.consume_active_movie_input(
		&"right_click"))
	assert_push_warning(
		"SaveManager: save rejected during an unresolved native movie terminal boundary")
	assert_null(reentrant_capture[0])
	assert_false(_presenter._player.is_playing())
	assert_true(_runtime.presentation_state.current_movie.is_empty())
	assert_true((
		_runtime.save_manager._capture_save_data() as Dictionary
	)["presentation_state"]["movie"].is_empty())
	assert_eq(_terminals.size(), 1)
	assert_eq(_terminals[0]["outcome"], &"completed")
	assert_false(_runtime.presentation_director.consume_active_movie_input(
		&"advance"), "the finishing edge cannot claim a newly exposed owner")

	_submit(
		_operation("play", false, false),
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
	)
	assert_true(_runtime.presentation_director.consume_active_movie_input(&"advance"))
	assert_true(_presenter._player.is_playing(),
		"skippable=false consumes every story completion edge")


func test_owned_dialogue_advance_echo_never_masquerades_as_movie_input() -> void:
	_submit(_operation(), PresentationBatchRequest.Policy.FIRE_AND_FORGET)
	var activation := DialogueActivation.new()
	assert_true(activation.advance())
	assert_true(SignalBus.emit_dialogue_advance_committed(activation))
	assert_true(_presenter._player.is_playing())
	assert_eq(_terminals.size(), 0)
	assert_eq(SignalBus.capture_movie_state()["asset"], "synthetic_movie")


func test_distinct_movie_replacement_retires_old_resource_and_receipt_once() -> void:
	_submit(_operation(), PresentationBatchRequest.Policy.FIRE_AND_FORGET)
	var old_stream := _presenter._player.stream
	var old_request_id := int(_receipts[0]["request"])
	var replacement := _submit(
		_operation("play", false, true, "synthetic_movie_b", 12),
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
	)
	assert_eq(replacement.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_ne(_presenter._player.stream, old_stream)
	assert_eq(SignalBus.capture_movie_state()["asset"], "synthetic_movie_b")
	assert_eq(_terminals.filter(func(item: Dictionary) -> bool:
		return int(item["request"]) == old_request_id
	).size(), 1)
	assert_eq(_terminals[0]["outcome"], &"superseded")
	assert_eq(_receipts.size(), 2)


func test_completion_commit_reentry_cannot_retire_distinct_replacement() -> void:
	_submit(_operation(), PresentationBatchRequest.Policy.FIRE_AND_FORGET)
	var old_request_id := int(_receipts[0]["request"])
	var replacement_requests: Array[PresentationBatchRequest] = []
	var replace_on_commit := func() -> void:
		replacement_requests.append(_submit(
			_operation("play", false, true, "synthetic_movie_b", 13),
			PresentationBatchRequest.Policy.FIRE_AND_FORGET,
		))
	SignalBus.movie_completion_committed.connect(replace_on_commit, CONNECT_ONE_SHOT)
	assert_true(_runtime.presentation_director.consume_active_movie_input(&"advance"))
	assert_eq(replacement_requests.size(), 1)
	assert_eq(replacement_requests[0].get_outcome(),
		PresentationBatchRequest.Outcome.COMPLETED)
	assert_true(_presenter._player.is_playing())
	assert_eq(SignalBus.capture_movie_state()["asset"], "synthetic_movie_b")
	assert_true(_runtime.presentation_director.has_active_movie_owner(_context))
	assert_eq(_terminals.filter(func(item: Dictionary) -> bool:
		return int(item["request"]) == old_request_id
	).size(), 1)
	assert_eq(_receipts.size(), 2)


func test_nested_completion_boundaries_clear_reentrant_replacement_exactly() -> void:
	_submit(_operation(), PresentationBatchRequest.Policy.FIRE_AND_FORGET)
	var replace_and_finish := func() -> void:
		_submit(
			_operation("play", false, true, "synthetic_movie_b", 14),
			PresentationBatchRequest.Policy.FIRE_AND_FORGET,
		)
		assert_true(
			_runtime.presentation_director.consume_active_movie_input(&"advance"))
	SignalBus.movie_completion_committed.connect(replace_and_finish, CONNECT_ONE_SHOT)
	assert_true(_runtime.presentation_director.consume_active_movie_input(&"advance"))
	assert_true(SignalBus.capture_movie_state().is_empty())
	assert_true(_runtime.presentation_state.current_movie.is_empty())
	assert_false(_runtime.presentation_director.has_active_movie_owner(_context))
	assert_eq(_receipts.size(), 2)
	assert_eq(_terminals.size(), 2)
	assert_true(SignalBus.movie_save_boundary_is_stable())


func test_explicit_stop_retires_looping_fnf_owner_and_owns_exact_receipt() -> void:
	_submit(
		_operation("play", true),
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
	)
	assert_true(_presenter._player.loop)
	var stop := _submit(
		_operation("stop"), PresentationBatchRequest.Policy.JOIN)
	assert_true(stop.is_settled())
	assert_eq(stop.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_false(_presenter._player.is_playing())
	assert_true(SignalBus.capture_movie_state().is_empty())
	assert_eq(_receipts.size(), 2, "play and stop each own one exact receipt")
	assert_eq(_terminals.size(), 2)
	assert_eq(_terminals[0]["outcome"], &"superseded")
	assert_eq(_terminals[1]["outcome"], &"completed")


func test_restore_ticket_is_generation_owned_and_native_seek_is_exact() -> void:
	_submit(_operation(), PresentationBatchRequest.Policy.FIRE_AND_FORGET)
	_presenter._player.stream_position = 0.75
	var state := SignalBus.capture_movie_state()
	assert_almost_eq(float(state["position"]), 0.75, 0.000001)
	var stale_ticket := _presenter.prepare_restore_state(state)
	assert_true(stale_ticket > 0)
	var current_ticket := _presenter.prepare_restore_state(state)
	assert_true(current_ticket > stale_ticket)
	assert_false(_presenter.arm_restore_state(stale_ticket, state),
		"a failed/superseded navigation cannot arm by matching JSON bytes")
	assert_true(_presenter.arm_restore_state(current_ticket, state))
	SignalBus.reset_and_apply_movie_state(state)
	assert_true(_presenter._player.is_playing())
	assert_almost_eq(_presenter._player.stream_position, 0.75, 0.000001)
	assert_eq(SignalBus.capture_movie_state()["skippable"], true)
	assert_false(_presenter.arm_restore_state(current_ticket, state),
		"the restore ticket is consumed exactly once")
	assert_true(_presenter._restore_cache.is_empty())
	assert_eq(_presenter._restore_ticket, 0)
	assert_eq(_presenter._armed_restore_ticket, 0)


func test_fnf_save_restore_rearms_exact_native_cursor_and_typed_owner() -> void:
	_submit(_operation(), PresentationBatchRequest.Policy.FIRE_AND_FORGET)
	_presenter._player.stream_position = 0.65
	var saved_presentation: Dictionary = (
		_runtime.presentation_state.capture_snapshot())
	var save_data := {"presentation_state": saved_presentation}
	var ticket: int = _runtime._prepare_movie_restore_from_save(save_data)
	assert_true(ticket > 0)
	_runtime.presentation_director.cancel_all()
	_runtime.presentation_state.restore_snapshot(saved_presentation)
	assert_true(_runtime._arm_prepared_movie_restore(
		ticket, _runtime.presentation_state.current_movie))
	assert_true(_runtime.presentation_state.apply_to_presenters())
	assert_true(_runtime._adopt_restored_movie(_context))
	var restored: Dictionary = SignalBus.capture_movie_state()
	assert_eq(restored["asset"], "synthetic_movie")
	assert_almost_eq(float(restored["position"]), 0.65, 0.02)
	assert_true(_runtime.presentation_director.has_active_movie_owner(_context))
	assert_true(_presenter._restore_cache.is_empty())
	assert_eq(_presenter._restore_ticket, 0)


func test_join_save_restore_adopts_then_same_command_attaches_without_restart() -> void:
	var original_join := _submit(_operation(), PresentationBatchRequest.Policy.JOIN)
	_presenter._player.stream_position = 0.7
	var saved_presentation: Dictionary = (
		_runtime.presentation_state.capture_snapshot())
	var ticket: int = _runtime._prepare_movie_restore_from_save({
		"presentation_state": saved_presentation,
	})
	assert_true(ticket > 0)
	_runtime.presentation_director.cancel_all()
	assert_eq(original_join.get_outcome(), PresentationBatchRequest.Outcome.CANCELLED)
	_runtime.presentation_state.restore_snapshot(saved_presentation)
	assert_true(_runtime._arm_prepared_movie_restore(
		ticket, _runtime.presentation_state.current_movie))
	assert_true(_runtime.presentation_state.apply_to_presenters())
	assert_true(_runtime._adopt_restored_movie(_context))
	var player_id: int = _presenter._player.get_instance_id()
	var before_attach: float = _presenter._player.stream_position
	var resumed_join := _submit(_operation(), PresentationBatchRequest.Policy.JOIN)
	assert_false(resumed_join.is_settled())
	assert_eq(_presenter._player.get_instance_id(), player_id)
	assert_gte(_presenter._player.stream_position, before_attach)
	assert_almost_eq(_presenter._player.stream_position, 0.7, 0.03)
	_presenter._on_player_finished()
	assert_eq(resumed_join.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)


func test_public_load_facades_restore_native_cursor_and_exact_owner() -> void:
	await _runtime.start_scenario(PUBLIC_SOURCE_PATH)
	assert_true(await _wait_until(func() -> bool:
		return _presenter._player.is_playing()))
	_presenter._player.stream_position = 0.62
	_runtime.quick_save()
	var quick_context: ScenarioContext = _runtime.engine.context
	_presenter._player.stream_position = 1.25
	assert_true(await _runtime.quick_load())
	assert_true(await _wait_until(func() -> bool:
		return (
			_runtime.engine.context != quick_context
			and _presenter._player.is_playing()
		)))
	assert_almost_eq(_presenter._player.stream_position, 0.62, 0.04)
	assert_true(_runtime.presentation_director.has_active_movie_owner(
		_runtime.engine.context))

	_presenter._player.stream_position = 0.83
	_runtime.save(SAVE_SLOT)
	var manual_context: ScenarioContext = _runtime.engine.context
	_presenter._player.stream_position = 1.31
	assert_true(await _runtime.continue_from_save(SAVE_SLOT))
	assert_ne(_runtime.engine.context, manual_context)
	assert_almost_eq(_presenter._player.stream_position, 0.83, 0.04)
	assert_true(_runtime.presentation_director.has_active_movie_owner(
		_runtime.engine.context))

	_runtime.delete_quick_save()
	_presenter._player.stream_position = 1.05
	_runtime.auto_save()
	var continue_context: ScenarioContext = _runtime.engine.context
	_presenter._player.stream_position = 0.2
	assert_true(await _runtime.continue_game())
	assert_ne(_runtime.engine.context, continue_context)
	assert_almost_eq(_presenter._player.stream_position, 1.05, 0.04)
	assert_true(_presenter._restore_cache.is_empty())
	assert_eq(_presenter._restore_ticket, 0)


func test_title_continue_restores_movie_before_the_replacement_context_runs() -> void:
	await _runtime.start_scenario(PUBLIC_SOURCE_PATH)
	assert_true(await _wait_until(func() -> bool:
		return _presenter._player.is_playing()))
	_presenter._player.stream_position = 0.68
	_runtime.save(SAVE_SLOT)
	_runtime.presentation_director.cancel_all()
	SignalBus.reset_movie_presentation()
	_runtime.engine.cancel_current_run()
	_runtime.game_state.current_state = GameStateMachine.State.TITLE
	_runtime.game_state.previous_state = GameStateMachine.State.TITLE
	_runtime._navigation_scene_change_override = (
		func(_scene: PackedScene) -> int: return OK)
	var loaded: Array = [null]
	var load_from_title := func() -> void:
		loaded[0] = await _runtime.continue_from_save(SAVE_SLOT)
	load_from_title.call()
	assert_true(await _wait_until(func() -> bool:
		return int(_runtime._navigation_scene_slot_active_serial) > 0))
	var slot := int(_runtime._navigation_scene_slot_active_serial)
	_runtime._settle_navigation_scene_slot(slot, true)
	assert_true(await _wait_until(func() -> bool:
		return loaded[0] is bool))
	assert_eq(loaded[0], true)
	assert_eq(_runtime.game_state.current_state, GameStateMachine.State.PLAYING)
	assert_not_null(_runtime.engine.context)
	assert_true(_presenter._player.is_playing())
	assert_almost_eq(_presenter._player.stream_position, 0.68, 0.04)
	assert_true(_runtime.presentation_director.has_active_movie_owner(
		_runtime.engine.context))
	assert_true(_presenter._restore_cache.is_empty())
	assert_eq(_presenter._restore_ticket, 0)


func test_rejected_title_fallback_restores_cursor_and_exact_movie_owner() -> void:
	_submit(_operation(), PresentationBatchRequest.Policy.FIRE_AND_FORGET)
	_presenter._player.stream_position = 0.57
	var before := SignalBus.capture_movie_state()
	var old_request := int(_receipts[0]["request"])
	_runtime.game_state.current_state = GameStateMachine.State.PLAYING
	# Full-suite predecessors may leave the configured path at the built-in
	# default.  Pin a distinct, enterable configured scene so this regression
	# deterministically exercises both rejected attempts.
	_runtime.title_scene_path = "res://addons/stella/scenes/game.tscn"
	_runtime._navigation_scene_change_override = (
		func(_scene: PackedScene) -> int: return ERR_CANT_CREATE)
	_runtime.return_to_title()
	assert_true(await _wait_until(func() -> bool:
		return (
			not _runtime._return_to_title_pending
			and String(_runtime._navigation_kind).is_empty()
		)))
	assert_push_error("failed to request the configured title scene")
	assert_push_error("failed to enter the configured title scene")
	assert_push_error("failed to request the built-in title scene")
	assert_push_error("failed to enter the built-in title scene")
	var restored := SignalBus.capture_movie_state()
	assert_eq(restored["asset"], before["asset"])
	assert_almost_eq(float(restored["position"]), float(before["position"]), 0.03)
	assert_true(_presenter._player.is_playing())
	assert_same(_runtime.engine.context, _context)
	assert_true(_runtime.presentation_director.has_active_movie_owner(_context))
	assert_eq(_terminals.filter(func(item: Dictionary) -> bool:
		return int(item["request"]) == old_request).size(), 1)
	assert_true(_presenter._recovery_cache.is_empty())


func test_successful_title_navigation_discards_recovery_stream_lease() -> void:
	_submit(_operation(), PresentationBatchRequest.Policy.FIRE_AND_FORGET)
	var retired_stream := _presenter._player.stream
	_runtime.game_state.current_state = GameStateMachine.State.PLAYING
	_runtime._navigation_scene_change_override = (
		func(_scene: PackedScene) -> int: return OK)
	_runtime.return_to_title()
	assert_true(await _wait_until(func() -> bool:
		return int(_runtime._navigation_scene_slot_active_serial) > 0))
	var slot := int(_runtime._navigation_scene_slot_active_serial)
	_runtime._settle_navigation_scene_slot(slot, true)
	assert_true(await _wait_until(func() -> bool:
		return (
			not _runtime._return_to_title_pending
			and String(_runtime._navigation_kind).is_empty()
		)))
	assert_eq(_runtime.game_state.current_state, GameStateMachine.State.TITLE)
	assert_false(_presenter._player.is_playing())
	assert_null(_presenter._player.stream)
	assert_true(_presenter._recovery_cache.is_empty())
	assert_false(_presenter._recovery_cache.values().has(retired_stream))


func test_public_fnf_load_keeps_advanced_cursor_without_replaying_movie_command() -> void:
	await _runtime.start_scenario(PUBLIC_FNF_PATH)
	assert_true(await _wait_until(func() -> bool:
		return _presenter._player.is_playing()))
	await get_tree().process_frame
	var saved_command: int = _runtime.engine.context.current_command_index
	assert_gt(saved_command, 0, "FNF must advance past the movie command")
	_presenter._player.stream_position = 0.71
	_runtime.quick_save()
	var old_context: ScenarioContext = _runtime.engine.context
	_presenter._player.stream_position = 1.4
	assert_true(await _runtime.quick_load())
	assert_ne(_runtime.engine.context, old_context)
	assert_eq(_runtime.engine.context.current_command_index, saved_command)
	assert_almost_eq(_presenter._player.stream_position, 0.71, 0.04)
	assert_true(_runtime.presentation_director.has_active_movie_owner(
		_runtime.engine.context))


func test_runtime_rollback_restores_movie_cursor_before_context_replacement() -> void:
	await _runtime.start_scenario(PUBLIC_FNF_PATH)
	assert_true(await _wait_until(func() -> bool:
		return _presenter._player.is_playing()))
	_presenter._player.stream_position = 0.58
	var snapshot: Dictionary = _runtime._capture_rollback_snapshot()
	var old_context: ScenarioContext = _runtime.engine.context
	_presenter._player.stream_position = 1.3
	assert_true(await _runtime._restore_runtime_from_snapshot(snapshot))
	assert_ne(_runtime.engine.context, old_context)
	assert_almost_eq(_presenter._player.stream_position, 0.58, 0.04)
	assert_true(_runtime.presentation_director.has_active_movie_owner(
		_runtime.engine.context))

	var invalid := snapshot.duplicate(true)
	var invalid_presentation := (
		invalid["presentation_state"] as Dictionary).duplicate(true)
	var invalid_movie := (
		invalid_presentation["movie"] as Dictionary).duplicate(true)
	invalid_movie["length"] = float(invalid_movie["length"]) + 1.0
	invalid_presentation["movie"] = invalid_movie
	invalid["presentation_state"] = invalid_presentation
	var retained_context: ScenarioContext = _runtime.engine.context
	var retained_state := SignalBus.capture_movie_state()
	assert_false(await _runtime._restore_runtime_from_snapshot(invalid))
	assert_push_error(
		"StellaRuntime: movie resource changed or cannot satisfy saved playback state")
	assert_same(_runtime.engine.context, retained_context)
	assert_eq(SignalBus.capture_movie_state(), retained_state)


func test_near_end_restore_is_exact_and_terminal_makes_save_empty() -> void:
	_submit(_operation(), PresentationBatchRequest.Policy.FIRE_AND_FORGET)
	var length := float(SignalBus.capture_movie_state()["length"])
	var near_end := length - 0.05
	_presenter._player.stream_position = near_end
	var state := SignalBus.capture_movie_state()
	var ticket := _presenter.prepare_restore_state(state)
	assert_true(ticket > 0)
	assert_true(_presenter.arm_restore_state(ticket, state))
	assert_true(SignalBus.reset_and_apply_movie_state(state))
	assert_almost_eq(_presenter._player.stream_position, near_end, 0.01)
	_presenter._player.stop()
	assert_true(SignalBus.capture_movie_state().is_empty())
	_presenter._on_player_finished()
	assert_true(SignalBus.movie_save_boundary_is_stable())
	assert_true((
		_runtime.save_manager._capture_save_data() as Dictionary
	)["presentation_state"]["movie"].is_empty())


func test_public_save_facades_reject_completion_boundary_before_flowchart_mutation() -> void:
	await _runtime.start_scenario(PUBLIC_SOURCE_PATH)
	assert_true(await _wait_until(func() -> bool:
		return _presenter._player.is_playing()))
	var snapshots: Array[String] = []
	var save_during_completion := func() -> void:
		snapshots.append(JSON.stringify(_runtime.flowchart_state.capture_snapshot()))
		_runtime.quick_save()
		_runtime.auto_save()
		_runtime.save(SAVE_SLOT)
		snapshots.append(JSON.stringify(_runtime.flowchart_state.capture_snapshot()))
	SignalBus.movie_completion_committed.connect(
		save_during_completion, CONNECT_ONE_SHOT)
	assert_true(_runtime.presentation_director.consume_active_movie_input(&"advance"))
	for _expected in range(3):
		assert_push_warning(
			"SaveManager: save rejected during an unresolved native movie terminal boundary")
	assert_eq(snapshots.size(), 2)
	assert_eq(snapshots[1], snapshots[0])
	assert_false(_runtime.has_quick_save())
	assert_false(_runtime.has_auto_save())
	assert_false(_runtime.has_save(SAVE_SLOT))


func test_native_natural_finish_settles_join_exactly_once() -> void:
	var request := _submit(_operation(), PresentationBatchRequest.Policy.JOIN)
	assert_false(request.is_settled())
	await request.settled
	await get_tree().process_frame
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(_receipts.size(), 1)
	assert_eq(_terminals.size(), 1)
	assert_eq(_terminals[0]["outcome"], &"completed")
	assert_true(SignalBus.capture_movie_state().is_empty())


func test_natural_finish_reentrant_save_fails_closed_until_join_terminal() -> void:
	var request := _submit(_operation(), PresentationBatchRequest.Policy.JOIN)
	var reentrant_capture: Array = ["not-called"]
	var capture_during_commit := func() -> void:
		reentrant_capture[0] = _runtime.save_manager._capture_save_data()
	SignalBus.movie_completion_committed.connect(
		capture_during_commit, CONNECT_ONE_SHOT)
	_presenter._on_player_finished()
	assert_push_warning(
		"SaveManager: save rejected during an unresolved native movie terminal boundary")
	assert_null(reentrant_capture[0],
		"the pre-advance command cursor can never be serialized with movie={}")
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_not_null(_runtime.save_manager._capture_save_data(),
		"the stable post-terminal owner is immediately saveable")


func test_native_stopped_before_finished_signal_is_an_unsaveable_boundary() -> void:
	_submit(_operation(), PresentationBatchRequest.Policy.FIRE_AND_FORGET)
	var canonical_before: Dictionary = (
		_runtime.presentation_state.current_movie.duplicate(true))
	_presenter._player.stop()
	assert_true(SignalBus.capture_movie_state().is_empty())
	assert_true(SignalBus.has_active_movie_projection(),
		"semantic movie ownership survives until its exact terminal")
	var captured: Variant = _runtime.save_manager._capture_save_data()
	assert_push_warning(
		"SaveManager: save rejected during an unresolved native movie terminal boundary")
	assert_null(captured,
		"an active receipt with no native cursor must not serialize as stopped")
	await _mount_stage_presenter()
	var receipts_before := _receipts.size()
	var replacement := _submit_operations([
		StagePresentationOperation.new({
			"action": "show",
			"duration": 0.0,
			"id": "must_not_apply",
			"properties": {"asset": "stage:redraw_source"},
			"transition": "cut",
			"transition_params": {},
		}, {"source_path": SOURCE_PATH, "line": 24}),
		_operation("play", false, true, "synthetic_movie_b", 25),
	], PresentationBatchRequest.Policy.FIRE_AND_FORGET, 24)
	assert_push_error(
		SOURCE_PATH + ":25] movie request rejected: active native movie is between")
	assert_eq(replacement.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_true(_stage_presenter._layers.is_empty(),
		"whole-batch validation rejects before the earlier stage child mutates")
	assert_eq(_receipts.size(), receipts_before)
	assert_eq(_terminals.size(), 0)
	assert_eq(_runtime.presentation_state.current_movie, canonical_before)
	await _mount_game_scene()
	var clip := _submit_operations(
		[_clip_operation("synthetic_clip", 21)],
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
		21,
	)
	assert_push_error(
		SOURCE_PATH + ":21] presentation clip request rejected: a movie owns")
	assert_eq(clip.get_outcome(), PresentationBatchRequest.Outcome.FAILED)


func test_mixed_failure_restores_sealed_previous_movie_and_reowns_receipt() -> void:
	await _mount_stage_presenter()
	_submit(_operation(), PresentationBatchRequest.Policy.FIRE_AND_FORGET)
	_presenter._player.stream_position = 0.75
	var previous := SignalBus.capture_movie_state()
	var old_request_id := int(_receipts[0]["request"])
	var replacement_result := [false]
	var invalidate_stage := func(
		_operation_value: MoviePresentationOperation,
		_state: Dictionary,
	) -> void:
		replacement_result[0] = true
		_stage_presenter.queue_free()
	SignalBus.movie_operation_committed.connect(invalidate_stage, CONNECT_ONE_SHOT)
	var operations: Array[PresentationOperation] = [
		_operation("play", false, false, "synthetic_movie", 30),
		StagePresentationOperation.new({
			"action": "show",
			"duration": 0.0,
			"id": "rollback_probe",
			"properties": {"asset": "stage:redraw_source"},
			"transition": "cut",
			"transition_params": {},
		}, {"source_path": SOURCE_PATH, "line": 31}),
	]
	var request := _submit_operations(
		operations, PresentationBatchRequest.Policy.FIRE_AND_FORGET, 30)
	assert_push_error(SOURCE_PATH + ":31")
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_true(replacement_result[0],
		"the participant failed only after the movie committed")
	var restored := SignalBus.capture_movie_state()
	assert_eq(restored["asset"], previous["asset"])
	assert_eq(restored["loop"], previous["loop"])
	assert_eq(restored["skippable"], previous["skippable"])
	assert_almost_eq(float(restored["position"]), float(previous["position"]), 0.01)
	assert_true(_runtime.presentation_director.has_active_movie_owner(_context),
		"the restored projection must regain typed modal ownership")
	assert_eq(_terminals.filter(func(item: Dictionary) -> bool:
		return int(item["request"]) == old_request_id).size(), 1)
	assert_eq(_terminals.filter(func(item: Dictionary) -> bool:
		return item["outcome"] == &"superseded").size(), 1)
	assert_eq(_receipts.size(), 3,
		"old play, failed stop, and restored owner each publish one receipt")
	assert_true(_presenter._rollback_cache.is_empty())
	assert_true(_presenter._armed_rollback_plans.is_empty())


func test_mixed_failure_rolls_back_an_explicit_sealed_empty_movie_state() -> void:
	await _mount_stage_presenter()
	var replacement_result := [false]
	var invalidate_stage := func(
		_operation_value: MoviePresentationOperation,
		_state: Dictionary,
	) -> void:
		replacement_result[0] = true
		_stage_presenter.queue_free()
	SignalBus.movie_operation_committed.connect(invalidate_stage, CONNECT_ONE_SHOT)
	var request := _submit_operations([
		_operation("play", false, true, "synthetic_movie", 34),
		StagePresentationOperation.new({
			"action": "show",
			"duration": 0.0,
			"id": "empty_rollback_probe",
			"properties": {"asset": "stage:redraw_source"},
			"transition": "cut",
			"transition_params": {},
		}, {"source_path": SOURCE_PATH, "line": 35}),
	], PresentationBatchRequest.Policy.FIRE_AND_FORGET, 34)
	assert_push_error(SOURCE_PATH + ":35")
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_true(replacement_result[0])
	assert_true(SignalBus.capture_movie_state().is_empty())
	assert_false(_presenter._player.is_playing())
	assert_eq(_receipts.size(), 1)
	assert_eq(_terminals.size(), 1)
	assert_true(_presenter._rollback_cache.is_empty())
	assert_true(_presenter._armed_rollback_plans.is_empty())


func test_successful_fnf_commit_releases_rollback_plan_before_stream_terminal() -> void:
	var request := _submit(
		_operation("play", true), PresentationBatchRequest.Policy.FIRE_AND_FORGET)
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_true(_presenter._player.is_playing())
	assert_true(_presenter._player.loop)
	assert_true(_presenter._rollback_cache.is_empty(),
		"a looping FNF owner cannot pin a superseded stream rollback plan")
	assert_true(_presenter._armed_rollback_plans.is_empty())


func test_loop_native_cursor_is_normalized_before_capture_and_restore() -> void:
	_submit(
		_operation("play", true), PresentationBatchRequest.Policy.FIRE_AND_FORGET)
	var length := float(SignalBus.capture_movie_state()["length"])
	_presenter._player.stream_position = length - 0.03
	assert_true(await _wait_until(func() -> bool:
		return (
			_presenter._player.is_playing()
			and _presenter._player.stream_position < length * 0.5
		)))
	var captured := SignalBus.capture_movie_state()
	assert_gte(float(captured["position"]), 0.0)
	assert_lt(float(captured["position"]), length)
	var ticket := _presenter.prepare_restore_state(captured)
	assert_true(ticket > 0)
	assert_true(_presenter.arm_restore_state(ticket, captured))
	assert_true(SignalBus.reset_and_apply_movie_state(captured))
	assert_true(_presenter._player.loop)
	assert_almost_eq(
		_presenter._player.stream_position, float(captured["position"]), 0.02)


func test_runtime_owned_presenter_and_cursor_survive_game_scene_replacement() -> void:
	var request := _submit(
		_operation(), PresentationBatchRequest.Policy.FIRE_AND_FORGET)
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	_presenter._player.stream_position = 0.55
	var before := SignalBus.capture_movie_state()
	var old_presenter_id := _presenter.get_instance_id()
	var old_player_id := _presenter._player.get_instance_id()
	var old_receipt: Dictionary = _presenter._active.receipt.duplicate(true)
	await _mount_game_scene()
	_game_scene.queue_free()
	await _game_scene.tree_exited
	await get_tree().process_frame
	_game_scene = load("res://addons/stella/scenes/game.tscn").instantiate()
	add_child(_game_scene)
	await get_tree().process_frame
	var restored := SignalBus.capture_movie_state()
	assert_eq(restored["asset"], before["asset"])
	assert_eq(restored["loop"], before["loop"])
	assert_eq(restored["skippable"], before["skippable"])
	assert_gte(float(restored["position"]), float(before["position"]))
	assert_true(_runtime.presentation_director.has_active_movie_owner(_context))
	assert_true(_presenter._player.is_playing())
	assert_eq(_presenter.get_instance_id(), old_presenter_id)
	assert_eq(_presenter._player.get_instance_id(), old_player_id)
	assert_eq(_presenter._active.receipt, old_receipt)
	assert_eq(_receipts.size(), 1)
	assert_eq(_terminals.size(), 0)


func test_active_clip_and_movie_reject_each_other_before_mutation() -> void:
	await _mount_game_scene()
	var clip := _submit_operations(
		[_clip_operation()], PresentationBatchRequest.Policy.FIRE_AND_FORGET, 40)
	assert_eq(clip.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	var clip_presenter := (
		_runtime.get_node("PresentationClipPresenter") as PresentationClipPresenter)
	assert_false(clip_presenter._active.is_empty())
	var movie := _submit(
		_operation("play", false, true, "missing_must_not_resolve", 41),
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
	)
	assert_push_error(
		SOURCE_PATH + ":41] movie request rejected: a presentation clip owns")
	assert_eq(movie.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_false(clip_presenter._active.is_empty())
	assert_true(SignalBus.capture_movie_state().is_empty())
	SignalBus.presentation_clip_finish_requested.emit(
		int(clip_presenter._active.get("request_id", 0)))

	_submit(_operation("play", false, true, "synthetic_movie", 42),
		PresentationBatchRequest.Policy.FIRE_AND_FORGET)
	var before_movie := SignalBus.capture_movie_state()
	var rejected_clip := _submit_operations(
		[_clip_operation("definitely_missing_but_must_not_resolve", 43)],
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
		43,
	)
	assert_push_error(
		SOURCE_PATH + ":43] presentation clip request rejected: "
		+ "a movie owns")
	assert_eq(rejected_clip.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_eq(SignalBus.capture_movie_state()["asset"], before_movie["asset"])
	assert_true(clip_presenter._active.is_empty())


func test_ctrl_claims_movie_before_underlying_choice_without_edge_tail() -> void:
	await _mount_game_scene()
	var input_handler := _game_scene.get_node("InputHandler")
	var dialogue := _game_scene.get_node("UILayer/DialoguePanel")
	_choice_session = _runtime._begin_choice_policy_session()
	assert_true(_choice_session >= 0)
	assert_true(_runtime.is_choice_active())
	_runtime.set_setting("movie_skip_on_skip", false)
	_submit(_operation(), PresentationBatchRequest.Policy.FIRE_AND_FORGET)
	var before_serial := SignalBus.current_advance_dispatch_serial()
	var ctrl_press := InputEventKey.new()
	ctrl_press.keycode = KEY_CTRL
	ctrl_press.pressed = true
	input_handler._unhandled_input(ctrl_press)
	assert_true(dialogue._ctrl_held,
		"the central momentary Ctrl intent remains authoritative")
	assert_true(_presenter._player.is_playing(),
		"the default policy consumes Ctrl without finishing the movie")
	assert_true(_runtime.is_choice_active())
	assert_eq(SignalBus.current_advance_dispatch_serial(), before_serial)

	var ctrl_release := InputEventKey.new()
	ctrl_release.keycode = KEY_CTRL
	ctrl_release.pressed = false
	input_handler._unhandled_input(ctrl_release)
	assert_false(dialogue._ctrl_held)
	_runtime.set_setting("movie_skip_on_skip", true)
	input_handler._unhandled_input(ctrl_press)
	assert_false(_presenter._player.is_playing())
	assert_true(_runtime.is_choice_active(),
		"the same edge cannot activate or retire the underlying choice")
	assert_eq(SignalBus.current_advance_dispatch_serial(), before_serial)
	assert_eq(_terminals.size(), 1)
	input_handler._unhandled_input(ctrl_release)
	assert_false(dialogue._ctrl_held)
	assert_true(_runtime._cancel_choice_policy_session(_choice_session))
	_choice_session = -1


func test_restore_apply_failure_is_acknowledged_and_never_restarts_at_zero() -> void:
	_submit(_operation(), PresentationBatchRequest.Policy.FIRE_AND_FORGET)
	_presenter._player.stream_position = 0.6
	var state := SignalBus.capture_movie_state()
	var ticket := _presenter.prepare_restore_state(state)
	assert_true(ticket > 0)
	assert_true(_presenter.arm_restore_state(ticket, state))
	var key := _presenter._state_key(state)
	(_presenter._restore_cache[key] as Dictionary)["stream"] = null
	var receipt_count := _receipts.size()
	var restored := SignalBus.reset_and_apply_movie_state(state)
	assert_push_error("MoviePresenter: native movie seek failed during restore")
	assert_false(restored)
	assert_true(SignalBus.capture_movie_state().is_empty())
	assert_false(_runtime.presentation_director.has_active_movie_owner(_context))
	assert_eq(_receipts.size(), receipt_count,
		"a failed physical install cannot be adopted as playback from frame zero")


func test_same_target_terminal_reentry_cannot_install_a_stale_receipt() -> void:
	_submit(_operation(), PresentationBatchRequest.Policy.FIRE_AND_FORGET)
	var old_request_id := int(_receipts[0]["request"])
	var reset_on_old_terminal := func(
		_presenter_id: int,
		_token: int,
		request_id: int,
		_generation_value: int,
		_outcome: StringName,
	) -> void:
		if request_id == old_request_id:
			SignalBus.reset_movie_presentation()
	SignalBus.movie_transition_terminal.connect(
		reset_on_old_terminal, CONNECT_ONE_SHOT)
	var attached := _submit(
		_operation("play", false, true, "synthetic_movie", 60),
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
	)
	assert_eq(attached.get_outcome(), PresentationBatchRequest.Outcome.CANCELLED)
	assert_true(SignalBus.capture_movie_state().is_empty())
	assert_eq(_receipts.size(), 1,
		"the invalidated attach tail publishes no stale receipt")
	assert_eq(_terminals.size(), 1)
	assert_true(_runtime.presentation_director._entries.is_empty())


func test_same_target_terminal_nested_submit_owns_the_final_exact_receipt() -> void:
	_submit(_operation(), PresentationBatchRequest.Policy.FIRE_AND_FORGET)
	var old_request := int(_receipts[0]["request"])
	var nested: Array[PresentationBatchRequest] = []
	var submit_same_target := func(
		_presenter_id: int,
		_token: int,
		request_id: int,
		_generation_value: int,
		_outcome: StringName,
	) -> void:
		if request_id == old_request:
			nested.append(_submit(
				_operation("play", false, true, "synthetic_movie", 61),
				PresentationBatchRequest.Policy.FIRE_AND_FORGET,
			))
	SignalBus.movie_transition_terminal.connect(submit_same_target, CONNECT_ONE_SHOT)
	var outer := _submit(
		_operation("play", false, true, "synthetic_movie", 62),
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
	)
	assert_eq(outer.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(nested.size(), 1)
	assert_eq(nested[0].get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_true(_presenter._player.is_playing())
	assert_eq(SignalBus.capture_movie_state()["asset"], "synthetic_movie")
	assert_eq(_receipts.size(), 3)
	assert_eq(_terminals.size(), 2)
	assert_eq(
		int((_presenter._active.receipt as Dictionary)["request_id"]),
		int(_receipts[2]["request"]),
		"the nested same-target owner, never the outer attach tail, keeps receipt",
	)


func test_stop_terminal_nested_distinct_submit_cannot_be_orphaned() -> void:
	_submit(_operation(), PresentationBatchRequest.Policy.FIRE_AND_FORGET)
	var old_request := int(_receipts[0]["request"])
	var nested: Array[PresentationBatchRequest] = []
	var submit_distinct := func(
		_presenter_id: int,
		_token: int,
		request_id: int,
		_generation_value: int,
		_outcome: StringName,
	) -> void:
		if request_id == old_request:
			nested.append(_submit(
				_operation("play", false, true, "synthetic_movie_b", 64),
				PresentationBatchRequest.Policy.FIRE_AND_FORGET,
			))
	SignalBus.movie_transition_terminal.connect(submit_distinct, CONNECT_ONE_SHOT)
	var stop := _submit(
		_operation("stop", false, true, "", 63),
		PresentationBatchRequest.Policy.JOIN,
	)
	assert_eq(stop.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(nested.size(), 1)
	assert_eq(nested[0].get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_true(_presenter._player.is_playing())
	assert_eq(SignalBus.capture_movie_state()["asset"], "synthetic_movie_b")
	assert_true(_runtime.presentation_director.has_active_movie_owner(_context))
	assert_eq(_receipts.size(), 3)
	assert_eq(_terminals.size(), 2)
	assert_eq(int((_presenter._active.receipt as Dictionary)["request_id"]),
		int(_receipts[2]["request"]))


func test_clip_and_movie_same_batch_fail_before_receipts_in_both_orders() -> void:
	for record: Dictionary in [
		{"operations": [_clip_operation("synthetic_clip", 70), _operation(
			"play", false, true, "synthetic_movie", 71)], "line": 70},
		{"operations": [_operation(
			"play", false, true, "synthetic_movie", 72),
			_clip_operation("synthetic_clip", 73)], "line": 73},
	]:
		var operations: Array[PresentationOperation] = []
		for operation: PresentationOperation in record["operations"]:
			operations.append(operation)
		var request := _submit_operations(
			operations,
			PresentationBatchRequest.Policy.FIRE_AND_FORGET,
			int(record["line"]),
		)
		assert_push_error(SOURCE_PATH + ":%d" % int(record["line"]))
		assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
		assert_true(SignalBus.capture_movie_state().is_empty())
		assert_eq(_receipts.size(), 0)
		assert_eq(_terminals.size(), 0)
