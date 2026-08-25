extends GutTest
## Synthetic end-to-end lifecycle contract for issue #168.

const RuntimeTestSupport = preload("res://tests/helpers/runtime_test_support.gd")
const SOURCE_PATH := "res://synthetic/bgm_lifecycle.stla"
const FIXTURE_PATH := "res://tests/fixtures/audio/bgm/"

var _runtime: Node
var _audio: AudioPresenter
var _original_bgm_path: String
var _receipts: Array[Dictionary] = []
var _terminals: Array[Dictionary] = []


func before_each() -> void:
	_runtime = get_tree().root.get_node("StellaRuntime")
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	_audio = _runtime.get_node("AudioPresenter") as AudioPresenter
	_original_bgm_path = _runtime.bgm_path
	_runtime.bgm_path = FIXTURE_PATH
	_receipts.clear()
	_terminals.clear()
	SignalBus.bgm_transition_receipt_started.connect(_on_receipt_started)
	SignalBus.bgm_transition_terminal.connect(_on_terminal)


func after_each() -> void:
	if SignalBus.bgm_transition_receipt_started.is_connected(_on_receipt_started):
		SignalBus.bgm_transition_receipt_started.disconnect(_on_receipt_started)
	if SignalBus.bgm_transition_terminal.is_connected(_on_terminal):
		SignalBus.bgm_transition_terminal.disconnect(_on_terminal)
	_runtime.bgm_path = _original_bgm_path
	_runtime.skip_controller.is_active = false
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())


func _context() -> ScenarioContext:
	var data := ScenarioData.new()
	data.id = "bgm_lifecycle"
	data.source_path = SOURCE_PATH
	data.source_identity = ScenarioData.make_source_identity(SOURCE_PATH)
	var scene := SceneData.new()
	scene.id = "start"
	scene.commands = [CommandData.new()]
	data.scenes = [scene]
	var context := ScenarioContext.new(data)
	context.variable_store = VariableStore.new()
	return context


func _operation(
	action: String,
	asset: String = "",
	cue: String = "",
	volume: float = 1.0,
	fade: float = 0.0,
	line: int = 3,
) -> BgmPresentationOperation:
	return BgmPresentationOperation.new({
		"action": action,
		"asset": asset if action == "play" else "",
		"cue": cue if action == "play" else "",
		"fade_duration": fade,
		"resume_position": 0.0,
		"volume": volume if action == "play" else 1.0,
	}, {"source_path": SOURCE_PATH, "line": line})


func _submit(
	operations: Array,
	policy: PresentationBatchRequest.Policy = (
		PresentationBatchRequest.Policy.FIRE_AND_FORGET),
	context: ScenarioContext = null,
) -> PresentationBatchRequest:
	var typed: Array[PresentationOperation] = []
	for operation_value: Variant in operations:
		typed.append(operation_value as PresentationOperation)
	return _runtime.presentation_director.submit(
		typed,
		policy,
		context if context != null else _context(),
		{"source_path": SOURCE_PATH, "line": 1},
	)


func _player() -> AudioStreamPlayer:
	return (_audio._bgm_channel.get("current", {}) as Dictionary).get(
		"player") as AudioStreamPlayer


func _finish_receipt(receipt: Dictionary) -> void:
	SignalBus.bgm_transition_receipts_finish_requested.emit([{
		"presenter_instance_id": receipt["presenter_instance_id"],
		"token": receipt["token"],
		"operation_request_id": receipt["operation_request_id"],
		"generation": receipt["generation"],
	}])


func _signal_connection_counts() -> Dictionary:
	var result: Dictionary = {}
	for signal_name: StringName in [
		&"bgm_validate_requested",
		&"bgm_accept_requested",
		&"bgm_apply_requested",
		&"bgm_transition_receipt_started",
		&"bgm_transition_terminal",
		&"bgm_transition_receipts_finish_requested",
		&"bgm_projection_reset_requested",
		&"bgm_state_apply_requested",
		&"bgm_state_capture_requested",
	]:
		result[String(signal_name)] = (
			(SignalBus.get(signal_name) as Signal).get_connections().size())
	return result


func _on_receipt_started(
	presenter_instance_id: int,
	token: int,
	operation_request_id: int,
	generation: int,
) -> void:
	if presenter_instance_id != _audio.get_instance_id():
		return
	_receipts.append({
		"presenter_instance_id": presenter_instance_id,
		"token": token,
		"operation_request_id": operation_request_id,
		"generation": generation,
	})


func _on_terminal(
	presenter_instance_id: int,
	token: int,
	operation_request_id: int,
	generation: int,
	outcome: StringName,
) -> void:
	if presenter_instance_id != _audio.get_instance_id():
		return
	_terminals.append({
		"token": token, "operation_request_id": operation_request_id,
		"generation": generation, "outcome": outcome,
	})


func test_missing_or_invalid_resource_rejects_mixed_batch_atomically() -> void:
	for case: Dictionary in [
		{"asset": "missing", "line": 10},
		{"asset": "invalid_track", "line": 11},
		{"asset": "synthetic_track", "cue": "missing_cue", "line": 12},
	]:
		var stage_emissions := [0]
		var on_stage := func(_operations: Array, _force_cut: bool) -> void:
			stage_emissions[0] += 1
		SignalBus.stage_operations_requested.connect(on_stage)
		var operations: Array[PresentationOperation] = [
			StagePresentationOperation.new({
				"action": "show", "id": "atomic",
				"properties": {"asset": "character:sakura/smile"},
				"transition": "cut", "duration": 0.0,
			}, {"source_path": SOURCE_PATH, "line": 9}),
			_operation("play", String(case["asset"]), String(case.get("cue", "")), 1.0, 0.0,
				int(case["line"])),
		]
		var request := _submit(operations)
		assert_true(request.is_settled())
		assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
		assert_eq(stage_emissions[0], 0)
		assert_false(_runtime.presentation_state.stage_layers.has("atomic"))
		assert_eq(_runtime.presentation_state.current_bgm, {})
		assert_push_error("%s:%d" % [SOURCE_PATH, int(case["line"])])
		SignalBus.stage_operations_requested.disconnect(on_stage)


func test_public_dsl_uses_the_runtime_handler_and_unsupported_lifecycle_fails_at_line() -> void:
	var source := """@chapter synthetic
@scene start
@bgm play synthetic_track cue=intro volume=0.7"""
	var data := DslParser.parse(
		DslLexer.tokenize(source), "synthetic", SOURCE_PATH)
	assert_eq(data.diagnostics, [])
	var command: CommandData = data.scenes[0].commands[0]
	assert_eq(command.type, "presentation_batch")
	var context := ScenarioContext.new(data)
	context.variable_store = VariableStore.new()
	var handler: CommandHandler = _runtime.registry.get_handler(
		"presentation_batch")
	handler.call("execute", command, context)
	assert_false(context.is_finished)
	assert_eq(_runtime.presentation_state.current_bgm["asset"], "synthetic_track")
	assert_eq(_runtime.presentation_state.current_bgm["cue"], "intro")

	_runtime._reset_presentation()
	var unsupported_data := DslParser.parse(
		DslLexer.tokenize("@chapter synthetic\n@scene start\n@bgm pause fade=0.2"),
		"synthetic", SOURCE_PATH)
	assert_eq(unsupported_data.diagnostics, [])
	var unsupported_context := ScenarioContext.new(unsupported_data)
	unsupported_context.variable_store = VariableStore.new()
	handler.call(
		"execute", unsupported_data.scenes[0].commands[0], unsupported_context)
	assert_true(unsupported_context.is_finished)
	assert_eq(_runtime.presentation_state.current_bgm, {})
	assert_push_error(SOURCE_PATH + ":3")


func test_marker_metadata_raw_default_and_nonloop_cue_are_physical() -> void:
	var raw := _submit([_operation("play", "synthetic_raw")])
	assert_eq(raw.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(_runtime.presentation_state.current_bgm, {
		"asset": "synthetic_raw", "cue": "", "loop": true,
		"position": 0.0, "status": "playing", "volume": 1.0,
	})
	var raw_stream := _player().stream as AudioStreamWAV
	assert_eq(raw_stream.loop_mode, AudioStreamWAV.LOOP_FORWARD)
	assert_eq(raw_stream.loop_begin, 0)

	var cue := _submit([_operation(
		"play", "synthetic_track", "intro", 0.7)])
	assert_eq(cue.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(_runtime.presentation_state.current_bgm["cue"], "intro")
	assert_false(_runtime.presentation_state.current_bgm["loop"])
	assert_almost_eq(
		float(_runtime.presentation_state.current_bgm["position"]), 0.02, 0.001)
	assert_eq((_player().stream as AudioStreamWAV).loop_mode,
		AudioStreamWAV.LOOP_DISABLED)


func test_same_target_positive_preflight_and_volume_reuses_exact_cursor() -> void:
	_submit([_operation("play", "synthetic_track", "", 0.8)])
	var player := _player()
	player.seek(0.03)
	var before_position := player.get_playback_position()
	var receipt_count := _receipts.size()
	var same := _submit(
		[_operation("play", "synthetic_track", "", 0.8, 5.0)],
		PresentationBatchRequest.Policy.JOIN)
	assert_true(same.is_settled())
	assert_gt(same.get_batch_id(), 0, "same target still crossed Presenter preflight")
	assert_eq(_receipts.size(), receipt_count)
	assert_same(_player(), player)
	assert_almost_eq(player.get_playback_position(), before_position, 0.015)

	var volume_join := _submit(
		[_operation("play", "synthetic_track", "", 0.35, 10.0)],
		PresentationBatchRequest.Policy.JOIN)
	assert_false(volume_join.is_settled())
	assert_same(_player(), player)
	assert_almost_eq(player.get_playback_position(), before_position, 0.015)
	_finish_receipt(_receipts.back())
	assert_eq(volume_join.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(_runtime.presentation_state.current_bgm["volume"], 0.35)


func test_replacement_is_one_interval_crossfade_and_supersession_is_exact() -> void:
	_submit([_operation("play", "synthetic_raw")])
	var old_player := _player()
	var first := _submit(
		[_operation("play", "synthetic_track", "", 0.8, 10.0, 30)],
		PresentationBatchRequest.Policy.JOIN)
	assert_false(first.is_settled())
	assert_same(
		(_audio._bgm_channel["outgoing"] as Dictionary)["player"], old_player)
	assert_true(old_player.playing)
	assert_true(_player().playing)
	var in_flight_snapshot: Dictionary = (
		_runtime.presentation_state.capture_snapshot())
	assert_eq(in_flight_snapshot["bgm"]["asset"], "synthetic_track",
		"save projects only the canonical incoming target, never outgoing identity")

	var second := _submit(
		[_operation("play", "synthetic_raw", "", 0.6, 10.0, 31)],
		PresentationBatchRequest.Policy.JOIN)
	assert_true(first.is_settled())
	assert_eq(first.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_push_error(SOURCE_PATH + ":30")
	assert_false(second.is_settled())
	assert_eq(_runtime.presentation_state.current_bgm["asset"], "synthetic_raw")
	assert_eq(_terminals[-1]["outcome"], &"superseded")
	_finish_receipt(_receipts.back())
	assert_eq(second.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq((_audio._bgm_channel["outgoing"] as Dictionary), {})


func test_pause_resume_restart_and_save_restore_separate_stable_state_from_tween() -> void:
	_submit([_operation("play", "synthetic_track", "", 0.75)])
	var original_player := _player()
	original_player.seek(0.08)
	var pause := _submit(
		[_operation("pause", "", "", 1.0, 10.0)],
		PresentationBatchRequest.Policy.JOIN)
	assert_false(pause.is_settled())
	assert_eq(_runtime.presentation_state.current_bgm["status"], "paused")
	assert_false(original_player.stream_paused,
		"pause fade samples a stable paused target while audio finishes fading")
	var snapshot: Dictionary = _runtime.presentation_state.capture_snapshot()
	assert_eq(snapshot["bgm"]["status"], "paused")
	assert_gt(float(snapshot["bgm"]["position"]), 0.0)
	_finish_receipt(_receipts.back())
	assert_true(original_player.stream_paused)

	_runtime.presentation_state.restore_snapshot(snapshot)
	_runtime.presentation_state.apply_to_presenters()
	var restored_player := _player()
	assert_not_same(restored_player, original_player)
	assert_true(restored_player.stream_paused)
	assert_eq(
		_runtime.presentation_state.current_bgm["position"],
		snapshot["bgm"]["position"],
		"restore retains the sampled canonical cursor even when device playback position is coarse",
	)

	var resume := _submit(
		[_operation("resume", "", "", 1.0, 10.0)],
		PresentationBatchRequest.Policy.JOIN)
	assert_false(resume.is_settled())
	assert_same(_player(), restored_player)
	assert_false(restored_player.stream_paused)
	_finish_receipt(_receipts.back())
	assert_eq(resume.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)

	_submit([_operation("pause")])
	var paused_player := _player()
	_submit([_operation("play", "synthetic_track")])
	assert_not_same(_player(), paused_player,
		"play from paused restarts at the authored cue; resume preserves cursor")
	assert_almost_eq(
		float(_runtime.presentation_state.current_bgm["position"]), 0.01, 0.001)


func test_advance_and_skip_finish_only_the_exact_latest_join() -> void:
	_submit([_operation("play", "synthetic_track")])
	var advance_join := _submit(
		[_operation("pause", "", "", 1.0, 10.0)],
		PresentationBatchRequest.Policy.JOIN)
	assert_false(advance_join.is_settled())
	SignalBus.advance_requested.emit()
	assert_eq(advance_join.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_true(_player().stream_paused)

	var resume_join := _submit(
		[_operation("resume", "", "", 1.0, 10.0)],
		PresentationBatchRequest.Policy.JOIN)
	assert_false(resume_join.is_settled())
	_runtime.skip_controller.is_active = true
	await get_tree().process_frame
	assert_eq(resume_join.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_false(_player().stream_paused)


func test_auto_context_abort_and_global_abort_leave_no_unowned_tween() -> void:
	_submit([_operation("play", "synthetic_track")])
	var auto_join := _submit(
		[_operation("pause", "", "", 1.0, 10.0)],
		PresentationBatchRequest.Policy.JOIN)
	_runtime.auto_play.is_active = true
	await get_tree().process_frame
	assert_false(auto_join.is_settled(),
		"Auto mode alone never manufactures a presentation acknowledgement")
	SignalBus.advance_requested.emit()
	assert_eq(auto_join.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_true(_player().stream_paused)

	var context := _context()
	var context_join := _submit(
		[_operation("resume", "", "", 1.0, 10.0)],
		PresentationBatchRequest.Policy.JOIN, context)
	assert_false(context_join.is_settled())
	context.request_cancellation()
	assert_eq(
		context_join.get_outcome(), PresentationBatchRequest.Outcome.CANCELLED)
	assert_false(_player().stream_paused,
		"context abort cuts the exact receipt to its committed stable target")
	assert_eq(_audio._bgm_channel.get("receipt", {}), {})
	assert_eq(_audio._bgm_channel.get("outgoing", {}), {})
	assert_null(_audio._bgm_channel.get("tween"))

	var global_join := _submit(
		[_operation("stop", "", "", 1.0, 10.0)],
		PresentationBatchRequest.Policy.JOIN)
	assert_false(global_join.is_settled())
	SignalBus.engine_abort_requested.emit()
	assert_eq(global_join.get_outcome(), PresentationBatchRequest.Outcome.CANCELLED)
	assert_eq(_audio._bgm_channel, {},
		"global abort cannot leave either crossfade voice without an owner")
	assert_eq(_runtime.presentation_state.current_bgm, {})


func test_live_settings_multiplier_survives_crossfade_pause_and_resume() -> void:
	_submit([_operation("play", "synthetic_raw", "", 0.8)])
	var crossfade := _submit(
		[_operation("play", "synthetic_track", "", 0.6, 10.0)],
		PresentationBatchRequest.Policy.JOIN)
	var incoming: Dictionary = _audio._bgm_channel["current"]
	var outgoing: Dictionary = _audio._bgm_channel["outgoing"]
	_audio._set_bgm_voice_level(0.3, incoming)
	_audio._set_bgm_voice_level(0.4, outgoing)
	_runtime.set_setting("master_volume", 0.5)
	_runtime.set_setting("bgm_volume", 0.25)
	assert_almost_eq(
		(incoming["player"] as AudioStreamPlayer).volume_db,
		linear_to_db(0.5 * 0.25 * 0.3), 0.01)
	assert_almost_eq(
		(outgoing["player"] as AudioStreamPlayer).volume_db,
		linear_to_db(0.5 * 0.25 * 0.4), 0.01)
	_finish_receipt(_receipts.back())
	assert_eq(crossfade.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_almost_eq(
		_player().volume_db, linear_to_db(0.5 * 0.25 * 0.6), 0.01)

	var pause := _submit(
		[_operation("pause", "", "", 1.0, 10.0)],
		PresentationBatchRequest.Policy.JOIN)
	incoming = _audio._bgm_channel["current"]
	_audio._set_bgm_voice_level(0.2, incoming)
	_runtime.set_setting("master_volume", 0.4)
	_runtime.set_setting("bgm_volume", 0.5)
	assert_almost_eq(_player().volume_db, linear_to_db(0.4 * 0.5 * 0.2), 0.01)
	_finish_receipt(_receipts.back())
	assert_eq(pause.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_almost_eq(_player().volume_db, -80.0, 0.01)
	assert_true(_player().stream_paused)

	var resume := _submit(
		[_operation("resume", "", "", 1.0, 10.0)],
		PresentationBatchRequest.Policy.JOIN)
	incoming = _audio._bgm_channel["current"]
	_audio._set_bgm_voice_level(0.25, incoming)
	_runtime.set_setting("master_volume", 0.8)
	_runtime.set_setting("bgm_volume", 0.4)
	assert_almost_eq(_player().volume_db, linear_to_db(0.8 * 0.4 * 0.25), 0.01)
	_finish_receipt(_receipts.back())
	assert_eq(resume.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_almost_eq(_player().volume_db, linear_to_db(0.8 * 0.4 * 0.6), 0.01)


func test_projection_reset_cancels_join_and_stale_terminal_cannot_reclaim_state() -> void:
	_submit([_operation("play", "synthetic_track")])
	var join := _submit(
		[_operation("stop", "", "", 1.0, 10.0)],
		PresentationBatchRequest.Policy.JOIN)
	assert_false(join.is_settled())
	var stale_receipt: Dictionary = _receipts.back().duplicate(true)
	_runtime.presentation_state.current_bgm.clear()
	SignalBus.reset_bgm_presentation()
	assert_true(join.is_settled())
	assert_eq(join.get_outcome(), PresentationBatchRequest.Outcome.CANCELLED)
	assert_eq(_runtime.presentation_state.current_bgm, {})
	assert_eq(_audio._bgm_channel, {})
	_finish_receipt(stale_receipt)
	assert_eq(_runtime.presentation_state.current_bgm, {})
	assert_eq(_audio._bgm_channel, {})


func test_fire_and_forget_drains_exact_owner_and_runtime_reset_stops_both_voices() -> void:
	_submit([_operation("play", "synthetic_raw")])
	var fnf := _submit([
		_operation("play", "synthetic_track", "", 0.8, 10.0),
	])
	assert_eq(fnf.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	var fnf_id := fnf.get_batch_id()
	assert_true(_runtime.presentation_director._entries.has(fnf_id))
	var stale_receipt: Dictionary = _receipts.back().duplicate(true)
	_finish_receipt(stale_receipt)
	assert_false(_runtime.presentation_director._entries.has(fnf_id))

	var reset_join := _submit([
		_operation("play", "synthetic_raw", "", 0.6, 10.0),
	], PresentationBatchRequest.Policy.JOIN)
	var stale_current := _player()
	var stale_outgoing: AudioStreamPlayer = (
		_audio._bgm_channel.get("outgoing", {}) as Dictionary).get("player")
	assert_false(reset_join.is_settled())
	assert_true(_runtime._reset_presentation())
	assert_eq(reset_join.get_outcome(), PresentationBatchRequest.Outcome.CANCELLED)
	assert_eq(_audio._bgm_channel, {})
	assert_false(stale_current.playing)
	assert_false(stale_outgoing.playing)
	assert_eq(_runtime.presentation_director._entries, {})
	assert_eq(SignalBus._presentation_operation_queue, [])

	var fresh := _submit([
		_operation("play", "synthetic_track", "", 0.5, 10.0),
	], PresentationBatchRequest.Policy.JOIN)
	var fresh_player := _player()
	_audio.call("_complete_bgm_receipt", stale_receipt)
	SignalBus.bgm_transition_terminal.emit(
		stale_receipt["presenter_instance_id"], stale_receipt["token"],
		stale_receipt["operation_request_id"], stale_receipt["generation"],
		&"completed")
	assert_false(fresh.is_settled())
	assert_same(_player(), fresh_player)
	_finish_receipt(_receipts.back())
	assert_eq(fresh.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)


func test_rollback_replay_and_runtime_presenter_replacement_restore_cut_state() -> void:
	_submit([_operation("play", "synthetic_raw", "", 0.65)])
	var old_player := _player()
	old_player.seek(0.04)
	var stable_snapshot: Dictionary = (
		_runtime.presentation_state.capture_snapshot())
	var context := _context()
	var old_join := _submit([
		_operation("play", "synthetic_track", "", 0.4, 10.0),
	], PresentationBatchRequest.Policy.JOIN, context)
	assert_false(old_join.is_settled())
	assert_true(_runtime.presentation_director.cancel_blocking_waiters(
		context, true))
	assert_eq(old_join.get_outcome(), PresentationBatchRequest.Outcome.CANCELLED)
	assert_eq(_runtime.presentation_state.current_bgm["asset"], "synthetic_raw")
	assert_eq(_audio._bgm_channel.get("receipt", {}), {})
	assert_eq(_audio._bgm_channel.get("outgoing", {}), {})

	_runtime.presentation_state.restore_snapshot(stable_snapshot)
	_runtime.presentation_state.apply_to_presenters()
	var projected_player := _player()
	assert_not_same(projected_player, old_player)
	var old_audio := _audio
	old_audio.queue_free()
	await get_tree().process_frame
	var replacement := AudioPresenter.new()
	replacement.name = "AudioPresenter"
	_runtime.add_child(replacement)
	_audio = replacement
	var replacement_player := _player()
	assert_not_null(replacement_player)
	assert_not_same(replacement_player, projected_player)
	assert_eq(_audio._bgm_channel.get("receipt", {}), {})
	assert_eq(_audio._bgm_channel.get("outgoing", {}), {})
	assert_eq(_runtime.presentation_state.current_bgm["asset"], "synthetic_raw")


func test_same_process_reset_preserves_signal_topology_and_input_is_inert_after_bgm() -> void:
	var before_connections := _signal_connection_counts()
	_submit([_operation("play", "synthetic_raw")])
	var join := _submit([
		_operation("play", "synthetic_track", "", 0.6, 10.0),
	], PresentationBatchRequest.Policy.JOIN)
	assert_false(join.is_settled())
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	assert_eq(join.get_outcome(), PresentationBatchRequest.Outcome.CANCELLED)
	assert_eq(_signal_connection_counts(), before_connections,
		"facade/runtime resets cannot duplicate persistent BGM or input consumers")
	assert_eq(_runtime.presentation_director._entries, {})
	assert_eq(SignalBus._presentation_operation_queue, [])
	assert_eq(SignalBus._bgm_epoch_stack, [])
	assert_null(SignalBus._dispatching_bgm_request)
	assert_null(SignalBus._applying_bgm_request)
	assert_eq(_audio._bgm_validation_cache, {})
	assert_eq(_audio._bgm_channel, {})
	SignalBus.advance_requested.emit()
	assert_eq(_audio._bgm_channel, {},
		"ordinary input after cleanup cannot revive a retired BGM owner")


func test_nonloop_natural_finish_commits_stopped_state_once() -> void:
	_submit([_operation("play", "synthetic_track", "intro")])
	assert_false(_runtime.presentation_state.current_bgm.is_empty())
	await _player().finished
	assert_eq(_runtime.presentation_state.current_bgm, {})
	assert_eq(_audio._bgm_channel, {})
