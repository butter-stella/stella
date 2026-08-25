extends GutTest
## Synthetic end-to-end lifecycle contract for persistent named loop-SE channels.

const RuntimeTestSupport = preload("res://tests/helpers/runtime_test_support.gd")
const SOURCE_PATH := "res://synthetic/loop_se_lifecycle.stla"
const STAGE_ASSET_ROOT := "res://tests/fixtures/stage/"

var _runtime: Node
var _audio: AudioPresenter
var _stage_presenter: StagePresenter
var _original_stage_assets_path := ""
var _receipts: Array[Dictionary] = []
var _terminals: Array[Dictionary] = []
var _loop_state_apply_count := 0


func before_each() -> void:
	_runtime = get_tree().root.get_node("StellaRuntime")
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	_original_stage_assets_path = _runtime.stage_assets_path
	_runtime.stage_assets_path = STAGE_ASSET_ROOT
	_stage_presenter = StagePresenter.new()
	_stage_presenter.name = "LoopSeLifecycleStagePresenter"
	add_child_autoqfree(_stage_presenter)
	await get_tree().process_frame
	_audio = _runtime.get_node("AudioPresenter") as AudioPresenter
	_receipts.clear()
	_terminals.clear()
	_loop_state_apply_count = 0
	SignalBus.loop_se_transition_receipt_started.connect(_on_receipt_started)
	SignalBus.loop_se_transition_terminal.connect(_on_terminal)
	SignalBus.loop_se_state_apply_requested.connect(_on_loop_state_apply)


func after_each() -> void:
	if SignalBus.loop_se_transition_receipt_started.is_connected(_on_receipt_started):
		SignalBus.loop_se_transition_receipt_started.disconnect(_on_receipt_started)
	if SignalBus.loop_se_transition_terminal.is_connected(_on_terminal):
		SignalBus.loop_se_transition_terminal.disconnect(_on_terminal)
	if SignalBus.loop_se_state_apply_requested.is_connected(_on_loop_state_apply):
		SignalBus.loop_se_state_apply_requested.disconnect(_on_loop_state_apply)
	_runtime.skip_controller.is_active = false
	_runtime.auto_play.is_active = false
	_runtime.stage_assets_path = _original_stage_assets_path
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())


func _context() -> ScenarioContext:
	var data := ScenarioData.new()
	data.id = "loop_se_lifecycle"
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
	channel_id: String,
	action: String,
	asset: String = "",
	volume: float = 1.0,
	fade: float = 0.0,
	line: int = 3,
	position: float = 0.0,
) -> LoopSePresentationOperation:
	return LoopSePresentationOperation.new({
		"action": action,
		"asset": asset if action == "play" else "",
		"channel": channel_id,
		"fade_duration": fade,
		"resume_position": position if action == "play" else 0.0,
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
	if context == null:
		context = _context()
	return _runtime.presentation_director.submit(
		typed, policy, context, {"source_path": SOURCE_PATH, "line": 1})


func _channel(channel_id: String) -> Dictionary:
	return _audio._loop_se_channels.get(channel_id, {})


func _player(channel_id: String) -> AudioStreamPlayer:
	var voice: Dictionary = _channel(channel_id).get("current", {})
	return voice.get("player") as AudioStreamPlayer


func _finish_receipt(receipt: Dictionary) -> void:
	SignalBus.loop_se_transition_receipts_finish_requested.emit([{
		"presenter_instance_id": receipt["presenter_instance_id"],
		"channel_id": receipt["channel_id"],
		"token": receipt["token"],
		"operation_request_id": receipt["operation_request_id"],
		"generation": receipt["generation"],
	}])


func _on_receipt_started(
	presenter_instance_id: int,
	channel_id: String,
	token: int,
	operation_request_id: int,
	generation: int,
) -> void:
	if presenter_instance_id != _audio.get_instance_id():
		return
	_receipts.append({
		"presenter_instance_id": presenter_instance_id,
		"channel_id": channel_id,
		"token": token,
		"operation_request_id": operation_request_id,
		"generation": generation,
	})


func _on_terminal(
	presenter_instance_id: int,
	channel_id: String,
	token: int,
	operation_request_id: int,
	generation: int,
	outcome: StringName,
) -> void:
	if presenter_instance_id != _audio.get_instance_id():
		return
	_terminals.append({
		"channel_id": channel_id,
		"generation": generation,
		"operation_request_id": operation_request_id,
		"outcome": outcome,
		"token": token,
	})


func _on_loop_state_apply(_channels: Dictionary, _generation: int) -> void:
	_loop_state_apply_count += 1


func test_missing_second_resource_rejects_mixed_batch_before_any_mutation() -> void:
	var stage_emissions := [0]
	var on_stage := func(_operations: Array, _force_cut: bool) -> void:
		stage_emissions[0] += 1
	SignalBus.stage_operations_requested.connect(on_stage)
	var operations: Array[PresentationOperation] = [
		StagePresentationOperation.new({
			"action": "show", "id": "atomic",
			"properties": {"asset": "stage:redraw_source"},
			"transition_params": {},
			"transition": "cut", "duration": 0.0,
		}, {"source_path": SOURCE_PATH, "line": 9}),
		_operation("ambience", "play", "definitely_missing", 1.0, 0.0, 10),
	]
	var request: PresentationBatchRequest = _runtime.presentation_director.submit(
		operations,
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
		_context(),
		{"source_path": SOURCE_PATH, "line": 8},
	)
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_eq(stage_emissions[0], 0, "resource preflight precedes every mixed child")
	assert_false(_runtime.presentation_state.stage_layers.has("atomic"))
	assert_false(_runtime.presentation_state.loop_se_channels.has("ambience"))
	assert_push_error(SOURCE_PATH + ":10")
	SignalBus.stage_operations_requested.disconnect(on_stage)


func test_volume_change_reuses_player_and_preserves_position() -> void:
	var initial := _submit([_operation("ambience", "play", "se_select", 0.8)])
	assert_eq(initial.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	var player := _player("ambience")
	assert_not_null(player)
	if player == null:
		return
	player.seek(0.02)
	var before_position := player.get_playback_position()
	var request := _submit(
		[_operation("ambience", "play", "se_select", 0.35, 10.0)],
		PresentationBatchRequest.Policy.JOIN,
	)
	assert_false(request.is_settled())
	assert_same(_player("ambience"), player, "same asset never allocates a new player")
	assert_almost_eq(
		_player("ambience").get_playback_position(), before_position, 0.01,
		"volume transition never seeks or restarts playback",
	)
	assert_eq(_receipts.size(), 1)
	_finish_receipt(_receipts[0])
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_same(_player("ambience"), player)
	assert_eq(_runtime.presentation_state.loop_se_channels["ambience"]["volume"], 0.35)
	assert_almost_eq(
		float(_runtime.presentation_state.loop_se_channels["ambience"]["position"]),
		before_position,
		0.01,
		"canonical volume commit preserves the physical incoming cursor",
	)


func test_live_aligned_absent_stop_and_same_target_still_preflight_without_receipts() -> void:
	var absent := _submit(
		[_operation("absent", "stop", "", 1.0, 5.0)],
		PresentationBatchRequest.Policy.JOIN,
	)
	assert_true(absent.is_settled())
	assert_eq(absent.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_gt(absent.get_batch_id(), 0,
		"state equality cannot bypass the Runtime-owned AudioPresenter")
	assert_eq(_receipts, [])

	_submit([_operation("stable", "play", "se_select", 0.7)])
	var player := _player("stable")
	assert_not_null(player)
	if player == null:
		return
	player.seek(0.02)
	var receipt_count := _receipts.size()
	var same := _submit(
		[_operation("stable", "play", "se_select", 0.7, 5.0)],
		PresentationBatchRequest.Policy.JOIN,
	)
	assert_true(same.is_settled())
	assert_eq(same.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_gt(same.get_batch_id(), 0)
	assert_eq(_receipts.size(), receipt_count)
	assert_same(_player("stable"), player)
	assert_almost_eq(player.get_playback_position(), 0.02, 0.01)


func test_same_target_missing_resource_fails_preflight_without_mutation() -> void:
	_submit([_operation("removed", "play", "se_select", 0.7)])
	var player := _player("removed")
	var original_se_path: String = _runtime.se_path
	_runtime.se_path = "res://synthetic/missing_loop_se/"
	var request := _submit([
		_operation("removed", "play", "se_select", 0.7, 0.0, 61),
	], PresentationBatchRequest.Policy.JOIN)
	_runtime.se_path = original_se_path
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_same(_player("removed"), player)
	assert_true(player.playing)
	assert_eq(_runtime.presentation_state.loop_se_channels["removed"]["volume"], 0.7)
	assert_push_error(SOURCE_PATH + ":61")


func test_same_target_join_during_fade_completes_old_owner_then_stabilizes() -> void:
	_submit([_operation("same_fade", "play", "se_select", 0.8)])
	var player := _player("same_fade")
	var old_join := _submit([
		_operation("same_fade", "play", "se_select", 0.3, 10.0, 62),
	], PresentationBatchRequest.Policy.JOIN)
	assert_false(old_join.is_settled())
	var receipt_count := _receipts.size()
	var current_join := _submit([
		_operation("same_fade", "play", "se_select", 0.3, 10.0, 63),
	], PresentationBatchRequest.Policy.JOIN)
	assert_eq(old_join.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(current_join.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_gt(current_join.get_batch_id(), 0)
	assert_eq(_receipts.size(), receipt_count,
		"the current stable endpoint needs no replacement receipt")
	assert_same(_player("same_fade"), player)
	assert_eq(_channel("same_fade").get("receipt", {}), {})
	assert_eq(_channel("same_fade").get("outgoing", {}), {})
	assert_null(_channel("same_fade").get("tween"))
	assert_almost_eq(float((_channel("same_fade")["current"] as Dictionary)["level"]), 0.3, 0.001)


func test_repeated_stop_during_fade_completes_old_owner_at_stopped_endpoint() -> void:
	_submit([_operation("repeat_stop", "play", "se_select")])
	var old_join := _submit([
		_operation("repeat_stop", "stop", "", 1.0, 10.0, 64),
	], PresentationBatchRequest.Policy.JOIN)
	assert_false(old_join.is_settled())
	var receipt_count := _receipts.size()
	var current_join := _submit([
		_operation("repeat_stop", "stop", "", 1.0, 10.0, 65),
	], PresentationBatchRequest.Policy.JOIN)
	assert_eq(old_join.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(current_join.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_gt(current_join.get_batch_id(), 0)
	assert_eq(_receipts.size(), receipt_count)
	assert_false(_audio._loop_se_channels.has("repeat_stop"))
	assert_false(_runtime.presentation_state.loop_se_channels.has("repeat_stop"))


func test_presenter_unavailable_rejects_even_canonical_same_target() -> void:
	_submit([_operation("unavailable", "play", "se_select", 0.6)])
	_audio.queue_free()
	await get_tree().process_frame
	var request := _submit([
		_operation("unavailable", "play", "se_select", 0.6, 0.0, 66),
	], PresentationBatchRequest.Policy.JOIN)
	var replacement := AudioPresenter.new()
	replacement.name = "AudioPresenter"
	_runtime.add_child(replacement)
	_audio = replacement
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_push_error(SOURCE_PATH + ":66")
	assert_true(_runtime.presentation_state.loop_se_channels.has("unavailable"))
	assert_not_null(_player("unavailable"),
		"replacement reprojects the preserved canonical target once")


func test_channel_volume_composes_with_live_master_and_se_settings() -> void:
	_submit([_operation("settings", "play", "se_select", 0.5)])
	var player := _player("settings")
	assert_not_null(player)
	if player == null:
		return
	_runtime.set_setting("master_volume", 0.5)
	_runtime.set_setting("se_volume", 0.4)
	assert_almost_eq(player.volume_db, linear_to_db(0.5 * 0.4 * 0.5), 0.01)
	_runtime.set_setting("se_volume", 0.0)
	assert_eq(player.volume_db, -80.0)


func test_duplicated_wav_wraps_past_stream_end_without_changing_one_shot_resource() -> void:
	var source := ResourceLoader.load(
		"res://examples/demo/audio/se/se_select.wav") as AudioStreamWAV
	assert_not_null(source)
	if source == null:
		return
	var original_loop_mode := source.loop_mode
	_submit([_operation("short", "play", "se_select")])
	var player := _player("short")
	assert_not_null(player)
	if player == null:
		return
	assert_true(player.stream is AudioStreamWAV)
	assert_not_same(player.stream, source, "loop metadata belongs to a duplicate")
	assert_ne((player.stream as AudioStreamWAV).loop_mode, AudioStreamWAV.LOOP_DISABLED)
	assert_eq(source.loop_mode, original_loop_mode,
		"persistent playback cannot mutate the shared one-shot resource")
	var length := player.stream.get_length()
	await get_tree().create_timer(length * 2.5).timeout
	assert_true(player.playing, "a short authored loop remains active past stream end")
	assert_true(player.get_playback_position() < length,
		"format looping wraps playback position inside the stream")


func test_stop_is_exact_channel_addressing_even_for_the_same_asset() -> void:
	_submit([
		_operation("rain", "play", "se_select"),
		_operation("rain_detail", "play", "se_select"),
	])
	var untouched := _player("rain_detail")
	assert_not_null(untouched)
	if untouched == null:
		return
	untouched.seek(0.02)
	var before_position := untouched.get_playback_position()
	_submit([_operation("rain", "stop")])
	assert_false(_audio._loop_se_channels.has("rain"))
	assert_same(_player("rain_detail"), untouched)
	assert_true(untouched.playing)
	assert_almost_eq(untouched.get_playback_position(), before_position, 0.01)
	assert_true(_runtime.presentation_state.loop_se_channels.has("rain_detail"))


func test_natural_fade_completion_emits_one_exact_terminal() -> void:
	_submit([_operation("natural", "play", "se_select")])
	var request := _submit(
		[_operation("natural", "play", "se_cancel", 0.7, 0.03)],
		PresentationBatchRequest.Policy.JOIN,
	)
	assert_false(request.is_settled())
	var receipt := _receipts[-1].duplicate(true)
	await SignalBus.loop_se_transition_terminal
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	await get_tree().create_timer(0.06).timeout
	var exact_terminals := _terminals.filter(func(event: Dictionary) -> bool:
		return (
			int(event["operation_request_id"])
				== int(receipt["operation_request_id"])
			and int(event["token"]) == int(receipt["token"])
			and int(event["generation"]) == int(receipt["generation"])
		)
	)
	assert_eq(exact_terminals.size(), 1,
		"natural tween completion publishes exactly one terminal receipt")


func test_superseding_crossfade_keeps_only_incoming_and_one_outgoing() -> void:
	_submit([_operation("weather", "play", "se_select")])
	var first := _submit(
		[_operation("weather", "play", "se_cancel", 1.0, 10.0)],
		PresentationBatchRequest.Policy.JOIN,
	)
	var first_channel := _channel("weather")
	var oldest: AudioStreamPlayer = (
		first_channel.get("outgoing", {}) as Dictionary).get("player")
	var incoming: AudioStreamPlayer = (
		first_channel.get("current", {}) as Dictionary).get("player")
	assert_not_null(oldest)
	assert_not_null(incoming)
	var replacement := _submit([
		_operation("weather", "play", "se_select", 0.6, 10.0),
	])
	assert_true(first.is_settled())
	assert_eq(first.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_true(replacement.is_settled(), "FNF settles at the sealed dispatch tail")
	var channel := _channel("weather")
	assert_same(
		(channel.get("outgoing", {}) as Dictionary).get("player"), incoming,
		"the prior canonical incoming becomes the sole outgoing voice",
	)
	assert_not_same(
		(channel.get("current", {}) as Dictionary).get("player"), incoming)
	assert_false(oldest.playing, "the older outgoing voice is cut before allocation")
	assert_eq(_terminals.filter(func(event: Dictionary) -> bool:
		return event["outcome"] == &"superseded"
	).size(), 1)
	assert_push_error(SOURCE_PATH + ":3")


func test_fire_and_forget_entry_drains_on_exact_terminal_and_stale_cannot_settle_new() -> void:
	_submit([_operation("crowd", "play", "se_select")])
	var first := _submit([_operation("crowd", "play", "se_cancel", 1.0, 10.0)])
	assert_true(first.is_settled())
	var first_id := first.get_batch_id()
	assert_true(_runtime.presentation_director._entries.has(first_id))
	var first_receipt := _receipts[-1].duplicate(true)
	_finish_receipt(first_receipt)
	assert_false(_runtime.presentation_director._entries.has(first_id),
		"FNF receipt ownership is released at its exact terminal")

	var second := _submit(
		[_operation("crowd", "play", "se_select", 0.7, 10.0)],
		PresentationBatchRequest.Policy.JOIN,
	)
	assert_false(second.is_settled())
	SignalBus.loop_se_transition_terminal.emit(
		first_receipt["presenter_instance_id"],
		first_receipt["channel_id"],
		first_receipt["token"],
		first_receipt["operation_request_id"],
		first_receipt["generation"],
		&"completed",
	)
	assert_false(second.is_settled(), "a stale serial cannot settle a newer batch")
	_finish_receipt(_receipts[-1])
	assert_eq(second.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)


func test_second_channel_terminal_failure_reports_its_own_authored_line() -> void:
	_submit([
		_operation("left", "play", "se_select"),
		_operation("right", "play", "se_cancel"),
	])
	var joined := _submit([
		_operation("left", "play", "se_select", 0.4, 10.0, 41),
		_operation("right", "play", "se_cancel", 0.4, 10.0, 42),
	], PresentationBatchRequest.Policy.JOIN)
	assert_false(joined.is_settled())
	_submit([_operation("right", "play", "se_cancel", 0.7, 0.0, 50)])
	assert_true(joined.is_settled())
	assert_eq(joined.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_push_error(SOURCE_PATH + ":42")


func test_click_skip_auto_and_abort_share_exact_join_lifecycle() -> void:
	_submit([_operation("control", "play", "se_select")])
	var clicked := _submit(
		[_operation("control", "play", "se_cancel", 1.0, 10.0)],
		PresentationBatchRequest.Policy.JOIN,
	)
	SignalBus.advance_requested.emit()
	assert_eq(clicked.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)

	var auto_request := _submit(
		[_operation("control", "play", "se_select", 0.8, 10.0)],
		PresentationBatchRequest.Policy.JOIN,
	)
	_runtime.auto_play.is_active = true
	await get_tree().process_frame
	assert_false(auto_request.is_settled(), "Auto does not manufacture presentation acks")
	_runtime.skip_controller.is_active = true
	await get_tree().process_frame
	assert_eq(auto_request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	var cut := _submit([
		_operation("control", "play", "se_cancel", 0.6, 10.0),
	], PresentationBatchRequest.Policy.JOIN)
	assert_true(cut.is_settled(), "new authored work is cut while Skip is active")

	_runtime.skip_controller.is_active = false
	var aborted := _submit(
		[_operation("control", "play", "se_select", 0.5, 10.0)],
		PresentationBatchRequest.Policy.JOIN,
	)
	SignalBus.engine_abort_requested.emit()
	assert_eq(aborted.get_outcome(), PresentationBatchRequest.Outcome.CANCELLED)
	assert_true(_runtime.presentation_state.loop_se_channels.has("control"),
		"abort retires the waiter but does not invent a session reset")


func test_snapshot_restore_reprojects_loop_position_without_transition_state() -> void:
	_submit([_operation("saved", "play", "se_select", 0.55)])
	var original_player := _player("saved")
	original_player.seek(0.02)
	var snapshot: Dictionary = _runtime.presentation_state.capture_snapshot()
	assert_not_null(JSON.parse_string(JSON.stringify(snapshot)))
	assert_eq(snapshot["loop_se_channels"]["saved"].keys().size(), 4)
	var old_join := _submit([
		_operation("saved", "play", "se_cancel", 1.0, 10.0),
	], PresentationBatchRequest.Policy.JOIN)
	assert_false(old_join.is_settled())
	var stale_receipt := _receipts[-1].duplicate(true)
	_runtime.presentation_state.restore_snapshot(snapshot)
	_runtime.presentation_state.apply_to_presenters()
	assert_eq(old_join.get_outcome(), PresentationBatchRequest.Outcome.CANCELLED)
	var restored_player := _player("saved")
	assert_not_same(restored_player, original_player)
	assert_eq(_channel("saved").get("outgoing", {}), {})
	assert_eq(_channel("saved").get("receipt", {}), {})
	assert_eq(_runtime.presentation_state.loop_se_channels["saved"]["asset"], "se_select")
	assert_almost_eq(
		restored_player.get_playback_position(),
		float(snapshot["loop_se_channels"]["saved"]["position"]),
		0.02,
	)

	var fresh_join := _submit([
		_operation("saved", "play", "se_select", 0.4, 10.0),
	], PresentationBatchRequest.Policy.JOIN)
	assert_false(fresh_join.is_settled())
	var fresh_receipt := _receipts[-1].duplicate(true)
	_audio.call("_complete_loop_se_receipt", "saved", stale_receipt)
	SignalBus.loop_se_transition_terminal.emit(
		stale_receipt["presenter_instance_id"],
		stale_receipt["channel_id"],
		stale_receipt["token"],
		stale_receipt["operation_request_id"],
		stale_receipt["generation"],
		&"completed",
	)
	assert_false(fresh_join.is_settled(),
		"late pre-load callback cannot settle the fresh exact owner")
	assert_same(_player("saved"), restored_player)
	assert_eq(_runtime.presentation_state.loop_se_channels["saved"]["asset"], "se_select")
	_finish_receipt(fresh_receipt)
	assert_eq(fresh_join.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)


func test_restore_for_replay_is_target_scoped_after_fresh_channel_takeover() -> void:
	_submit([
		_operation("rollback_a", "play", "se_select"),
		_operation("rollback_b", "play", "se_select"),
	])
	var shared_context := _context()
	var old_join := _submit([
		_operation("rollback_a", "play", "se_cancel", 0.7, 10.0),
		_operation("rollback_b", "play", "se_cancel", 0.6, 10.0),
	], PresentationBatchRequest.Policy.JOIN, shared_context)
	assert_false(old_join.is_settled())
	var old_a_receipt: Dictionary = _receipts.filter(
		func(receipt: Dictionary) -> bool:
			return receipt["channel_id"] == "rollback_a"
	)[-1].duplicate(true)

	var fresh_b := _submit([
		_operation("rollback_b", "play", "se_cancel", 0.6, 10.0),
	], PresentationBatchRequest.Policy.FIRE_AND_FORGET, shared_context)
	assert_eq(fresh_b.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_false(old_join.is_settled(),
		"exact-completing B leaves the old JOIN waiting only on A")
	var fresh_b_player := _player("rollback_b")
	assert_true(_runtime.presentation_director.cancel_blocking_waiters(
		shared_context, true))
	assert_eq(old_join.get_outcome(), PresentationBatchRequest.Outcome.CANCELLED)
	assert_eq(_runtime.presentation_state.loop_se_channels["rollback_a"]["asset"], "se_select")
	assert_eq(_runtime.presentation_state.loop_se_channels["rollback_b"]["asset"], "se_cancel")
	assert_same(_player("rollback_b"), fresh_b_player,
		"fresh B ownership is outside the old request's rollback target set")
	var restored_a_player := _player("rollback_a")
	_audio.call("_complete_loop_se_receipt", "rollback_a", old_a_receipt)
	SignalBus.loop_se_transition_terminal.emit(
		old_a_receipt["presenter_instance_id"],
		old_a_receipt["channel_id"],
		old_a_receipt["token"],
		old_a_receipt["operation_request_id"],
		old_a_receipt["generation"],
		&"completed",
	)
	assert_same(_player("rollback_a"), restored_a_player)
	assert_same(_player("rollback_b"), fresh_b_player)
	assert_eq(_runtime.presentation_state.loop_se_channels["rollback_a"]["asset"], "se_select")
	assert_eq(_runtime.presentation_state.loop_se_channels["rollback_b"]["asset"], "se_cancel")


func test_runtime_session_reset_clears_physical_state_and_rejects_old_callbacks() -> void:
	_submit([_operation("session", "play", "se_select")])
	var old_join := _submit([
		_operation("session", "play", "se_cancel", 0.7, 10.0),
	], PresentationBatchRequest.Policy.JOIN)
	assert_false(old_join.is_settled())
	var stale_receipt := _receipts[-1].duplicate(true)
	var stale_channel := _channel("session")
	var stale_current: AudioStreamPlayer = (
		stale_channel.get("current", {}) as Dictionary).get("player")
	var stale_outgoing: AudioStreamPlayer = (
		stale_channel.get("outgoing", {}) as Dictionary).get("player")
	assert_true(_runtime._reset_presentation(),
		"exercise the real Runtime restart/load presentation boundary")
	assert_eq(old_join.get_outcome(), PresentationBatchRequest.Outcome.CANCELLED)
	assert_eq(_runtime.presentation_state.loop_se_channels, {})
	assert_eq(_audio._loop_se_channels, {})
	assert_false(stale_current.playing)
	assert_false(stale_outgoing.playing)

	var fresh_join := _submit([
		_operation("session", "play", "se_select", 0.5, 10.0),
	], PresentationBatchRequest.Policy.JOIN)
	assert_false(fresh_join.is_settled())
	var fresh_receipt := _receipts[-1].duplicate(true)
	var fresh_player := _player("session")
	_audio.call("_complete_loop_se_receipt", "session", stale_receipt)
	SignalBus.loop_se_transition_terminal.emit(
		stale_receipt["presenter_instance_id"],
		stale_receipt["channel_id"],
		stale_receipt["token"],
		stale_receipt["operation_request_id"],
		stale_receipt["generation"],
		&"completed",
	)
	assert_false(fresh_join.is_settled())
	assert_same(_player("session"), fresh_player)
	assert_eq(_runtime.presentation_state.loop_se_channels["session"]["asset"], "se_select")
	_finish_receipt(fresh_receipt)
	assert_eq(fresh_join.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)


func test_runtime_owned_presenter_replacement_reprojects_once_without_duplicate() -> void:
	_submit([_operation("persistent", "play", "se_select", 0.65)])
	var old_audio := _audio
	var old_player := _player("persistent")
	old_player.seek(0.02)
	var before_apply_count := _loop_state_apply_count
	old_audio.queue_free()
	await get_tree().process_frame
	var replacement := AudioPresenter.new()
	replacement.name = "AudioPresenter"
	_runtime.add_child(replacement)
	_audio = replacement
	assert_eq(_loop_state_apply_count, before_apply_count + 1,
		"replacement registration publishes one canonical cut projection")
	var channel: Dictionary = replacement._loop_se_channels.get("persistent", {})
	assert_false(channel.is_empty())
	assert_eq(channel.get("outgoing", {}), {})
	assert_eq(channel.get("receipt", {}), {})
	assert_eq(replacement._loop_se_channels.size(), 1)
	assert_true(_runtime.presentation_state.loop_se_channels.has("persistent"))
