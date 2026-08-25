extends GutTest
## Synthetic end-to-end lifecycle contract for issue #168.

const RuntimeTestSupport = preload("res://tests/helpers/runtime_test_support.gd")
const FailingBootstrap = preload(
	"res://tests/fixtures/startup/failing_bootstrap.gd")
const SOURCE_PATH := "res://synthetic/bgm_lifecycle.stla"
const FIXTURE_PATH := "res://tests/fixtures/audio/bgm/"

var _runtime: Node
var _audio: AudioPresenter
var _original_bgm_path: String
var _original_se_path: String
var _original_voice_path: String
var _receipts: Array[Dictionary] = []
var _terminals: Array[Dictionary] = []


func before_each() -> void:
	_runtime = get_tree().root.get_node("StellaRuntime")
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	_audio = _runtime.get_node("AudioPresenter") as AudioPresenter
	_audio._shutdown_quiesced = false
	SignalBus._runtime_audio_shutdown_started = false
	SignalBus._runtime_audio_shutdown_epochs_retired = false
	_original_bgm_path = _runtime.bgm_path
	_original_se_path = _runtime.se_path
	_original_voice_path = _runtime.voice_path
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
	_runtime.se_path = _original_se_path
	_runtime.voice_path = _original_voice_path
	_runtime.skip_controller.is_active = false
	_audio._shutdown_quiesced = false
	SignalBus._runtime_audio_shutdown_started = false
	SignalBus._runtime_audio_shutdown_epochs_retired = false
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
	stem_mix: Dictionary = {},
) -> BgmPresentationOperation:
	return BgmPresentationOperation.new({
		"action": action,
		"asset": asset if action == "play" else "",
		"cue": cue if action == "play" else "",
		"fade_duration": fade,
		"resume_position": 0.0,
		"stem_mix": stem_mix if action in ["play", "mix"] else {},
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


func _expected_bgm_db(level: float) -> float:
	return linear_to_db(
		float(_runtime.get_setting("master_volume"))
		* float(_runtime.get_setting("bgm_volume"))
		* level)


func _synchronized_stream() -> AudioStreamSynchronized:
	return _player().stream as AudioStreamSynchronized


func _stem_db(stem_name: String) -> float:
	var voice: Dictionary = _audio._bgm_channel.get("current", {})
	var stem_names: Array = voice.get("stem_names", [])
	var stem_index := stem_names.find(stem_name)
	if stem_index < 0:
		return NAN
	var synchronized := _synchronized_stream()
	return synchronized.get_sync_stream_volume(stem_index) if synchronized != null else NAN


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
		&"se_play",
		&"voice_playback_requested",
		&"system_se_play",
		&"loop_se_validate_requested",
		&"loop_se_apply_requested",
		&"loop_se_projection_reset_requested",
		&"bgm_validate_requested",
		&"bgm_accept_requested",
		&"bgm_apply_requested",
		&"bgm_transition_receipt_started",
		&"bgm_transition_terminal",
		&"bgm_transition_receipts_finish_requested",
		&"bgm_projection_reset_requested",
		&"bgm_state_apply_requested",
		&"bgm_state_capture_requested",
		&"runtime_audio_shutdown_requested",
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
		{"asset": "invalid_stem_metadata", "line": 13},
		{"asset": "invalid_stem_format", "line": 14},
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
		"position": 0.0, "status": "playing", "stem_mix": {},
		"volume": 1.0,
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


func test_synchronized_stems_play_on_one_player_with_one_canonical_state() -> void:
	var request := _submit([_operation(
		"play", "synthetic_stems", "intro", 0.8, 0.0, 20,
		{"harmony": 0.25, "rhythm": 1.0},
	)])
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	var player := _player()
	var synchronized := _synchronized_stream()
	assert_not_null(player)
	assert_not_null(synchronized)
	if synchronized == null:
		return
	assert_eq(synchronized.stream_count, 2)
	assert_eq(_runtime.presentation_state.current_bgm, {
		"asset": "synthetic_stems", "cue": "intro", "loop": true,
		"position": 0.02, "status": "playing",
		"stem_mix": {"harmony": 0.25, "rhythm": 1.0},
		"volume": 0.8,
	})
	assert_almost_eq(_stem_db("rhythm"), 0.0, 0.01)
	assert_almost_eq(_stem_db("harmony"), linear_to_db(0.25), 0.01)
	var synchronized_players := 0
	for child: Node in _audio.get_children():
		if child is AudioStreamPlayer and (child as AudioStreamPlayer).stream is AudioStreamSynchronized:
			synchronized_players += 1
	assert_eq(synchronized_players, 1,
		"all stems share the one physical bgm:main player")


func test_stem_resource_preflight_enforces_audible_mix_and_32_stream_limit() -> void:
	var source := ResourceLoader.load(
		FIXTURE_PATH + "synthetic_raw.tres") as AudioStream
	var maximum := BgmTrackDefinition.new()
	maximum.loop = true
	maximum.start_position = 0.0
	maximum.loop_position = 0.0
	for index in range(AudioStreamSynchronized.MAX_STREAMS):
		var stem := BgmStemDefinition.new()
		stem.stem_name = "stem_%02d" % index
		stem.stream = source
		stem.default_gain = 1.0 if index == 0 else 0.0
		maximum.stems.append(stem)
	var prepared: Dictionary = _audio._prepare_bgm_definition(maximum, "")
	assert_false(prepared.is_empty())
	assert_eq((prepared["stream"] as AudioStreamSynchronized).stream_count, 32)

	var overflow := maximum.duplicate(true) as BgmTrackDefinition
	var extra := BgmStemDefinition.new()
	extra.stem_name = "stem_32"
	extra.stream = source
	overflow.stems.append(extra)
	assert_eq(_audio._prepare_bgm_definition(overflow, ""), {})
	var duplicate := maximum.duplicate(true) as BgmTrackDefinition
	duplicate.stems[1].stem_name = duplicate.stems[0].stem_name
	assert_eq(_audio._prepare_bgm_definition(duplicate, ""), {},
		"duplicate authored stem names fail before stream construction")

	var silent := BgmTrackDefinition.new()
	silent.loop = true
	for stem_name: String in ["rhythm", "harmony"]:
		var stem := BgmStemDefinition.new()
		stem.stem_name = stem_name
		stem.stream = source
		stem.default_gain = 0.0
		silent.stems.append(stem)
	assert_eq(_audio._prepare_bgm_definition(silent, ""), {},
		"an all-zero default resource cannot become a silent live channel")
	assert_eq(_runtime.presentation_state.current_bgm, {},
		"private resource preflight never mutates canonical state")
	assert_eq(_audio._bgm_channel, {})


func test_mix_fade_preserves_player_stream_and_cursor() -> void:
	_submit([_operation("play", "synthetic_stems")])
	var player := _player()
	var synchronized := _synchronized_stream()
	player.seek(0.04)
	var before_position := player.get_playback_position()
	var mix_join := _submit([
		_operation("mix", "", "", 1.0, 2.0, 21,
			{"harmony": 1.0, "rhythm": 0.0}),
	], PresentationBatchRequest.Policy.JOIN)
	assert_false(mix_join.is_settled())
	assert_same(_player(), player)
	assert_same(_synchronized_stream(), synchronized)
	assert_almost_eq(player.get_playback_position(), before_position, 0.015)
	var tween: Tween = _audio._bgm_channel.get("tween")
	assert_true(tween.custom_step(1.0))
	assert_almost_eq(_stem_db("harmony"), linear_to_db(0.5), 0.01)
	assert_almost_eq(_stem_db("rhythm"), linear_to_db(0.5), 0.01)
	assert_same(_player(), player)
	assert_same(_synchronized_stream(), synchronized)
	assert_true(tween.custom_step(1.0))
	tween.custom_step(0.000001)
	assert_eq(mix_join.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_almost_eq(_stem_db("harmony"), 0.0, 0.01)
	assert_eq(_stem_db("rhythm"), -INF,
		"the authored fade endpoint uses Godot exact silence, not a finite dB floor")
	assert_eq(_runtime.presentation_state.current_bgm["stem_mix"], {
		"harmony": 1.0, "rhythm": 0.0,
	})
	var synchronized_playback := synchronized.instantiate_playback()
	synchronized_playback.start(0.0)
	var mixed_frames := synchronized_playback.mix_audio(1.0, 32)
	var harmony_index := (
		(_audio._bgm_channel["current"] as Dictionary)["stem_names"] as Array
	).find("harmony")
	var harmony_playback := synchronized.get_sync_stream(
		harmony_index).instantiate_playback()
	harmony_playback.start(0.0)
	var harmony_only_frames := harmony_playback.mix_audio(1.0, 32)
	assert_eq(mixed_frames, harmony_only_frames,
		"the faded-to-zero nonzero rhythm source contributes exactly no samples")


func test_sub_approximate_mix_and_same_play_update_physical_and_saved_gain() -> void:
	_submit([_operation("play", "synthetic_stems", "", 1.0, 0.0, 30,
		{"harmony": 0.5, "rhythm": 1.0})])
	var player := _player()
	var synchronized := _synchronized_stream()
	var first_delta := 0.5000001
	assert_true(is_equal_approx(0.5, first_delta))
	_submit([_operation("mix", "", "", 1.0, 0.0, 31,
		{"harmony": first_delta, "rhythm": 1.0})])
	assert_same(_player(), player)
	assert_same(_synchronized_stream(), synchronized)
	assert_eq(_runtime.presentation_state.current_bgm["stem_mix"]["harmony"],
		first_delta)
	assert_eq((_audio._bgm_channel["current"] as Dictionary)
		["stem_mix"]["harmony"], first_delta)
	assert_almost_eq(_stem_db("harmony"), linear_to_db(first_delta), 0.000001)

	var second_delta := 0.5000002
	assert_true(is_equal_approx(first_delta, second_delta))
	_submit([_operation("play", "synthetic_stems", "", 1.0, 0.0, 32,
		{"harmony": second_delta, "rhythm": 1.0})])
	assert_same(_player(), player)
	assert_same(_synchronized_stream(), synchronized)
	assert_eq(_runtime.presentation_state.current_bgm["stem_mix"]["harmony"],
		second_delta)
	assert_eq((_audio._bgm_channel["current"] as Dictionary)
		["stem_mix"]["harmony"], second_delta)
	assert_almost_eq(_stem_db("harmony"), linear_to_db(second_delta), 0.000001)


func test_aligned_mix_hands_fnf_to_join_without_a_second_tween() -> void:
	_submit([_operation("play", "synthetic_stems")])
	var target := {"harmony": 1.0, "rhythm": 0.25}
	var receipt_count := _receipts.size()
	var terminal_count := _terminals.size()
	var fnf := _submit([
		_operation("mix", "", "", 1.0, 8.0, 22, target),
	])
	assert_eq(fnf.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(_receipts.size(), receipt_count + 1)
	var stale_receipt: Dictionary = (
		_audio._bgm_channel["receipt"] as Dictionary).duplicate(true)
	var stale_tween: Tween = _audio._bgm_channel["tween"]

	var aligned := _submit([
		_operation("mix", "", "", 1.0, 3.0, 23, target),
	], PresentationBatchRequest.Policy.JOIN)
	assert_eq(aligned.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(_receipts.size(), receipt_count + 1)
	assert_eq(_terminals.size(), terminal_count + 1)
	assert_eq(_terminals.back()["token"], stale_receipt["token"])
	assert_eq(_terminals.back()["outcome"], &"completed")
	assert_false(stale_tween.is_valid())
	assert_eq(_audio._bgm_channel.get("receipt", {}), {})
	assert_null(_audio._bgm_channel.get("tween"))
	assert_almost_eq(_stem_db("harmony"), 0.0, 0.01)
	assert_almost_eq(_stem_db("rhythm"), linear_to_db(0.25), 0.01)

	var stable_channel: Dictionary = _audio._bgm_channel.duplicate(true)
	_audio.call("_complete_bgm_receipt", stale_receipt)
	assert_eq(_audio._bgm_channel, stable_channel)
	assert_eq(_terminals.size(), terminal_count + 1)


func test_mix_supersession_and_abort_reject_stale_callbacks_exactly() -> void:
	_submit([_operation("play", "synthetic_stems")])
	var first := _submit([
		_operation("mix", "", "", 1.0, 10.0, 24,
			{"harmony": 1.0, "rhythm": 0.0}),
	], PresentationBatchRequest.Policy.JOIN)
	var stale_receipt: Dictionary = _receipts.back().duplicate(true)
	var stale_tween: Tween = _audio._bgm_channel["tween"]
	assert_true(stale_tween.custom_step(2.0))
	var second_context := _context()
	var second := _submit([
		_operation("mix", "", "", 1.0, 10.0, 25,
			{"harmony": 0.4, "rhythm": 0.8}),
	], PresentationBatchRequest.Policy.JOIN, second_context)
	assert_eq(first.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_push_error(SOURCE_PATH + ":24")
	assert_eq(_terminals.back()["outcome"], &"superseded")
	assert_false(stale_tween.is_valid())
	var current_receipt: Dictionary = (
		_audio._bgm_channel["receipt"] as Dictionary).duplicate(true)
	var current_tween: Tween = _audio._bgm_channel["tween"]
	_audio.call("_complete_bgm_receipt", stale_receipt)
	assert_eq(_audio._bgm_channel["receipt"], current_receipt)
	assert_same(_audio._bgm_channel["tween"], current_tween)

	second_context.request_cancellation()
	assert_eq(second.get_outcome(), PresentationBatchRequest.Outcome.CANCELLED)
	assert_eq(_audio._bgm_channel.get("receipt", {}), {})
	assert_null(_audio._bgm_channel.get("tween"))
	assert_eq(_runtime.presentation_state.current_bgm["stem_mix"], {
		"harmony": 0.4, "rhythm": 0.8,
	})
	assert_almost_eq(_stem_db("harmony"), linear_to_db(0.4), 0.01)
	assert_almost_eq(_stem_db("rhythm"), linear_to_db(0.8), 0.01)
	_audio.call("_complete_bgm_receipt", current_receipt)
	assert_eq(_audio._bgm_channel.get("receipt", {}), {})


func test_stem_mix_survives_pause_skip_save_restore_and_settings() -> void:
	_submit([_operation(
		"play", "synthetic_stems", "", 0.7, 0.0, 26,
		{"harmony": 0.4, "rhythm": 0.8},
	)])
	var player := _player()
	player.seek(0.04)
	var pause := _submit([
		_operation("pause", "", "", 1.0, 10.0, 27),
	], PresentationBatchRequest.Policy.JOIN)
	_runtime.skip_controller.is_active = true
	await get_tree().process_frame
	_runtime.skip_controller.is_active = false
	assert_eq(pause.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_true(player.stream_paused)
	assert_eq(_runtime.presentation_state.current_bgm["stem_mix"], {
		"harmony": 0.4, "rhythm": 0.8,
	})

	var snapshot: Dictionary = _runtime.presentation_state.capture_snapshot()
	_runtime.presentation_state.restore_snapshot(snapshot)
	_runtime.presentation_state.apply_to_presenters()
	var restored_player := _player()
	assert_not_same(restored_player, player)
	assert_true(restored_player.stream_paused)
	assert_eq(_runtime.presentation_state.current_bgm["stem_mix"],
		snapshot["bgm"]["stem_mix"])
	assert_almost_eq(_stem_db("harmony"), linear_to_db(0.4), 0.01)
	assert_almost_eq(_stem_db("rhythm"), linear_to_db(0.8), 0.01)

	_submit([_operation("resume")])
	_runtime.set_setting("master_volume", 0.5)
	_runtime.set_setting("bgm_volume", 0.25)
	assert_almost_eq(_player().volume_db, linear_to_db(0.5 * 0.25 * 0.7), 0.01)
	assert_almost_eq(_stem_db("harmony"), linear_to_db(0.4), 0.01,
		"settings scale the player, not the synchronized stem balance")
	assert_almost_eq(_stem_db("rhythm"), linear_to_db(0.8), 0.01)


func test_invalid_hot_reloaded_stem_and_replacement_stale_token_do_not_pollute() -> void:
	_submit([_operation("play", "synthetic_stems")])
	var player := _player()
	var synchronized := _synchronized_stream()
	var definition := ResourceLoader.load(
		FIXTURE_PATH + "synthetic_stems.tres") as BgmTrackDefinition
	var original_name := definition.stems[0].stem_name
	definition.stems[0].stem_name = "bad:id"
	var before_state: Dictionary = (
		_runtime.presentation_state.current_bgm.duplicate(true))
	var rejected := _submit([
		_operation("mix", "", "", 1.0, 0.0, 28,
			{"harmony": 1.0, "rhythm": 0.25}),
	])
	assert_eq(rejected.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_push_error(SOURCE_PATH + ":28")
	assert_eq(_runtime.presentation_state.current_bgm, before_state)
	assert_same(_player(), player)
	assert_same(_synchronized_stream(), synchronized)
	definition.stems[0].stem_name = original_name

	var active := _submit([
		_operation("mix", "", "", 1.0, 10.0, 29,
			{"harmony": 1.0, "rhythm": 0.25}),
	], PresentationBatchRequest.Policy.JOIN)
	assert_false(active.is_settled())
	var stale_receipt: Dictionary = _receipts.back().duplicate(true)
	var committed_mix: Dictionary = (
		_runtime.presentation_state.current_bgm["stem_mix"] as Dictionary).duplicate(true)
	var old_audio := _audio
	old_audio.queue_free()
	await get_tree().process_frame
	assert_eq(active.get_outcome(), PresentationBatchRequest.Outcome.CANCELLED)
	var replacement := AudioPresenter.new()
	replacement.name = "AudioPresenter"
	_runtime.add_child(replacement)
	_audio = replacement
	var replacement_player := _player()
	assert_not_null(replacement_player)
	assert_not_same(replacement_player, player)
	assert_true(replacement_player.stream is AudioStreamSynchronized)
	assert_eq(_runtime.presentation_state.current_bgm["stem_mix"], committed_mix)
	assert_eq((_audio._bgm_channel["current"] as Dictionary)["stem_mix"],
		committed_mix)
	assert_eq(_audio._bgm_channel.get("receipt", {}), {})

	SignalBus.bgm_transition_terminal.emit(
		stale_receipt["presenter_instance_id"], stale_receipt["token"],
		stale_receipt["operation_request_id"], stale_receipt["generation"],
		&"completed")
	assert_same(_player(), replacement_player)
	assert_eq(_runtime.presentation_state.current_bgm["stem_mix"], committed_mix)
	assert_eq(_audio._bgm_channel.get("receipt", {}), {})


func test_valid_hot_reload_schema_changes_fail_mixed_preflight_before_stage() -> void:
	_submit([_operation("play", "synthetic_stems")])
	var player := _player()
	var synchronized := _synchronized_stream()
	var definition := ResourceLoader.load(
		FIXTURE_PATH + "synthetic_stems.tres") as BgmTrackDefinition
	var original_stems: Array[BgmStemDefinition] = definition.stems.duplicate()
	var original_names := original_stems.map(func(stem: BgmStemDefinition) -> String:
		return stem.stem_name
	)
	var original_signature: Dictionary = (
		(_audio._bgm_channel["current"] as Dictionary)["resource_signature"]
		as Dictionary).duplicate(true)
	var stage_emissions := [0]
	var on_stage := func(_operations: Array, _force_cut: bool) -> void:
		stage_emissions[0] += 1
	SignalBus.stage_operations_requested.connect(on_stage)

	for mutation: String in ["add", "rename", "reorder"]:
		definition.stems.clear()
		for stem: BgmStemDefinition in original_stems:
			definition.stems.append(stem)
		if mutation == "add":
			var extra := BgmStemDefinition.new()
			extra.stem_name = "melody"
			extra.stream = original_stems[0].stream
			extra.default_gain = 0.25
			definition.stems.append(extra)
		elif mutation == "rename":
			definition.stems[0].stem_name = "melody"
		else:
			definition.stems.reverse()
		var state_before: Dictionary = (
			_runtime.presentation_state.current_bgm.duplicate(true))
		var rejected := _submit([
			StagePresentationOperation.new({
				"action": "show", "id": "schema_guard",
				"properties": {"asset": "stage:synthetic"},
				"transition": "cut", "duration": 0.0,
			}, {"source_path": SOURCE_PATH, "line": 59}),
			_operation("mix", "", "", 1.0, 0.0, 60,
				{"harmony": 1.0, "rhythm": 0.25}),
		], PresentationBatchRequest.Policy.JOIN)
		assert_eq(rejected.get_outcome(), PresentationBatchRequest.Outcome.FAILED,
			mutation)
		assert_push_error(SOURCE_PATH + ":60")
		assert_eq(stage_emissions[0], 0,
			mutation + " must fail during all-participant preflight")
		assert_eq(_runtime.presentation_state.current_bgm, state_before, mutation)
		assert_same(_player(), player, mutation)
		assert_same(_synchronized_stream(), synchronized, mutation)
		assert_eq((_audio._bgm_channel["current"] as Dictionary)
			["resource_signature"], original_signature, mutation)
		if mutation == "rename":
			definition.stems[0].stem_name = String(original_names[0])

	definition.stems.clear()
	for stem: BgmStemDefinition in original_stems:
		definition.stems.append(stem)
	SignalBus.stage_operations_requested.disconnect(on_stage)


func test_restore_rejects_changed_full_schema_and_reorder_rebuilds_by_name() -> void:
	_submit([_operation("play", "synthetic_stems", "", 0.8, 0.0, 61,
		{"harmony": 0.4, "rhythm": 0.8})])
	var snapshot: Dictionary = _runtime.presentation_state.capture_snapshot()
	var definition := ResourceLoader.load(
		FIXTURE_PATH + "synthetic_stems.tres") as BgmTrackDefinition
	var original_stems: Array[BgmStemDefinition] = definition.stems.duplicate()
	var original_first_name := original_stems[0].stem_name

	var extra := BgmStemDefinition.new()
	extra.stem_name = "melody"
	extra.stream = original_stems[0].stream
	extra.default_gain = 0.25
	definition.stems.append(extra)
	_runtime.presentation_state.restore_snapshot(snapshot)
	_runtime.presentation_state.apply_to_presenters()
	assert_push_error("AudioPresenter: cannot project saved BGM state")
	assert_eq(_audio._bgm_channel, {},
		"an added valid stem cannot silently expand a saved full mix")
	assert_eq(_runtime.presentation_state.current_bgm, snapshot["bgm"])
	definition.stems.pop_back()
	_runtime.presentation_state.apply_to_presenters()
	assert_not_null(_player())

	definition.stems[0].stem_name = "melody"
	_runtime.presentation_state.restore_snapshot(snapshot)
	_runtime.presentation_state.apply_to_presenters()
	assert_push_error("AudioPresenter: cannot project saved BGM state")
	assert_eq(_audio._bgm_channel, {},
		"a valid renamed stem cannot silently drop a saved full-mix key")
	definition.stems[0].stem_name = original_first_name
	_runtime.presentation_state.apply_to_presenters()
	assert_not_null(_player())

	definition.stems.reverse()
	_runtime.presentation_state.restore_snapshot(snapshot)
	_runtime.presentation_state.apply_to_presenters()
	assert_not_null(_player())
	assert_true(_player().stream is AudioStreamSynchronized)
	assert_eq(_runtime.presentation_state.current_bgm, snapshot["bgm"])
	assert_eq((_audio._bgm_channel["current"] as Dictionary)["stem_names"],
		["harmony", "rhythm"],
		"restore owns a fresh synchronized stream and maps the full mix by name")
	assert_almost_eq(_stem_db("harmony"), linear_to_db(0.4), 0.01)
	assert_almost_eq(_stem_db("rhythm"), linear_to_db(0.8), 0.01)
	definition.stems.reverse()

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


func test_aligned_pause_resume_stop_handoff_finishes_fnf_once_before_join() -> void:
	_submit([_operation("play", "synthetic_track", "", 0.75)])
	for action: String in ["pause", "resume", "stop"]:
		var receipt_count := _receipts.size()
		var terminal_count := _terminals.size()
		var fnf := _submit([_operation(action, "", "", 1.0, 10.0)])
		assert_eq(fnf.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
		assert_eq(_receipts.size(), receipt_count + 1, action)
		var stale_receipt: Dictionary = (
			_audio._bgm_channel.get("receipt", {}) as Dictionary).duplicate(true)
		var stale_tween: Tween = _audio._bgm_channel.get("tween")
		assert_not_null(stale_tween, action)

		var aligned_join := _submit(
			[_operation(action, "", "", 1.0, 7.0)],
			PresentationBatchRequest.Policy.JOIN)
		assert_eq(
			aligned_join.get_outcome(),
			PresentationBatchRequest.Outcome.COMPLETED,
			action + " JOIN must wait for and inherit the exact stable endpoint",
		)
		assert_eq(_receipts.size(), receipt_count + 1,
			action + " aligned handoff must not allocate a replacement Tween")
		assert_eq(_terminals.size(), terminal_count + 1, action)
		assert_eq(_terminals.back()["outcome"], &"completed", action)
		assert_false(stale_tween.is_valid(), action)
		assert_eq(_audio._bgm_channel.get("receipt", {}), {}, action)
		if action == "pause":
			assert_true(_player().stream_paused)
		elif action == "resume":
			assert_false(_player().stream_paused)
		else:
			assert_eq(_audio._bgm_channel, {})

		var stable_channel: Dictionary = _audio._bgm_channel.duplicate(true)
		var terminals_after_handoff := _terminals.size()
		_audio.call("_complete_bgm_receipt", stale_receipt)
		assert_eq(_audio._bgm_channel, stable_channel,
			action + " stale old-token callback must be inert")
		assert_eq(_terminals.size(), terminals_after_handoff, action)


func test_resume_fnf_same_target_play_cut_stabilizes_one_exact_owner() -> void:
	_submit([_operation("play", "synthetic_track", "", 0.75)])
	_submit([_operation("pause")])
	var terminal_count := _terminals.size()
	var resume_fnf := _submit([_operation("resume", "", "", 1.0, 8.0)])
	var resume_batch_id := resume_fnf.get_batch_id()
	var stale_receipt: Dictionary = (
		_audio._bgm_channel["receipt"] as Dictionary).duplicate(true)
	var stale_tween: Tween = _audio._bgm_channel["tween"]
	assert_true(stale_tween.custom_step(2.0))
	assert_true(_runtime.presentation_director._entries.has(resume_batch_id))

	var play_fnf := _submit([
		_operation("play", "synthetic_track", "", 0.4),
	])
	assert_eq(resume_fnf.get_outcome(),
		PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(play_fnf.get_outcome(),
		PresentationBatchRequest.Outcome.COMPLETED)
	assert_false(stale_tween.is_valid(),
		"aligned play kills the exact old resume Tween at its endpoint")
	assert_eq(_terminals.size(), terminal_count + 1)
	assert_eq(_terminals.back()["token"], stale_receipt["token"])
	assert_eq(_terminals.back()["outcome"], &"completed")
	assert_eq(_runtime.presentation_director._entries, {},
		"the resume and cut play Director entries both drain")
	assert_eq(_audio._bgm_channel.get("receipt", {}), {})
	assert_null(_audio._bgm_channel.get("tween"))
	assert_eq(_runtime.presentation_state.current_bgm["status"], "playing")
	assert_eq(_runtime.presentation_state.current_bgm["volume"], 0.4)
	assert_almost_eq(
		float((_audio._bgm_channel["current"] as Dictionary)["level"]),
		0.4, 0.001)
	assert_almost_eq(_player().volume_db, _expected_bgm_db(0.4), 0.01)

	var stable_channel: Dictionary = _audio._bgm_channel.duplicate(true)
	_audio.call("_complete_bgm_receipt", stale_receipt)
	assert_eq(_audio._bgm_channel, stable_channel,
		"the old resume callback is inert after the cut play")
	assert_eq(_terminals.size(), terminal_count + 1,
		"the old resume terminal is emitted exactly once")


func test_resume_fnf_same_target_play_fade_transfers_to_one_new_tween() -> void:
	_submit([_operation("play", "synthetic_track", "", 0.75)])
	_submit([_operation("pause")])
	var terminal_count := _terminals.size()
	var resume_fnf := _submit([_operation("resume", "", "", 1.0, 8.0)])
	var resume_batch_id := resume_fnf.get_batch_id()
	var stale_receipt: Dictionary = (
		_audio._bgm_channel["receipt"] as Dictionary).duplicate(true)
	var stale_tween: Tween = _audio._bgm_channel["tween"]
	assert_true(stale_tween.custom_step(2.0))

	var play_fnf := _submit([
		_operation("play", "synthetic_track", "", 0.4, 8.0),
	])
	var play_batch_id := play_fnf.get_batch_id()
	var play_receipt: Dictionary = (
		_audio._bgm_channel["receipt"] as Dictionary).duplicate(true)
	var play_tween: Tween = _audio._bgm_channel["tween"]
	assert_false(stale_tween.is_valid())
	assert_not_same(play_tween, stale_tween)
	assert_same(_audio._bgm_channel["tween"], play_tween,
		"the aligned play owns the only live Tween")
	assert_eq(_terminals.size(), terminal_count + 1)
	assert_eq(_terminals.back()["token"], stale_receipt["token"])
	assert_eq(_terminals.back()["outcome"], &"completed")
	assert_false(_runtime.presentation_director._entries.has(resume_batch_id))
	assert_true(_runtime.presentation_director._entries.has(play_batch_id))
	assert_eq(_runtime.presentation_director._entries.size(), 1)
	assert_eq(_runtime.presentation_state.current_bgm["volume"], 0.4)
	assert_almost_eq(
		float((_audio._bgm_channel["current"] as Dictionary)["level"]),
		0.75, 0.001, "the resume reaches its stable endpoint before play fades")
	assert_almost_eq(_player().volume_db, _expected_bgm_db(0.75), 0.01)

	_audio.call("_complete_bgm_receipt", stale_receipt)
	assert_same(_audio._bgm_channel["tween"], play_tween,
		"a stale resume callback cannot reclaim the new Tween")
	assert_eq(_audio._bgm_channel["receipt"], play_receipt)
	assert_eq(_terminals.size(), terminal_count + 1)

	assert_true(play_tween.custom_step(4.0))
	assert_almost_eq(
		float((_audio._bgm_channel["current"] as Dictionary)["level"]),
		0.575, 0.001)
	assert_almost_eq(_player().volume_db, _expected_bgm_db(0.575), 0.01,
		"the new authored play owns the physical midpoint")
	assert_true(play_tween.custom_step(4.0))
	play_tween.custom_step(0.000001)
	assert_eq(_terminals.size(), terminal_count + 2)
	assert_eq(_terminals.back()["token"], play_receipt["token"])
	assert_eq(_terminals.back()["outcome"], &"completed")
	assert_eq(_runtime.presentation_director._entries, {},
		"the resume and faded play Director entries both drain")
	assert_eq(_audio._bgm_channel.get("receipt", {}), {})
	assert_null(_audio._bgm_channel.get("tween"))
	assert_eq(_runtime.presentation_state.current_bgm["status"], "playing")
	assert_eq(_runtime.presentation_state.current_bgm["volume"], 0.4)
	assert_almost_eq(
		float((_audio._bgm_channel["current"] as Dictionary)["level"]),
		0.4, 0.001)
	assert_almost_eq(_player().volume_db, _expected_bgm_db(0.4), 0.01)


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


func test_real_tweens_have_deterministic_midpoints_and_one_authored_endpoint() -> void:
	var terminal_count := _terminals.size()
	var fade_in := _submit(
		[_operation("play", "synthetic_track", "", 0.8, 2.0)],
		PresentationBatchRequest.Policy.JOIN)
	assert_false(fade_in.is_settled())
	var fade_in_receipt: Dictionary = (
		_audio._bgm_channel["receipt"] as Dictionary).duplicate(true)
	var fade_in_tween: Tween = _audio._bgm_channel["tween"]
	assert_true(fade_in_tween.custom_step(1.0))
	assert_almost_eq(
		float((_audio._bgm_channel["current"] as Dictionary)["level"]),
		0.4, 0.001, "fade-in midpoint is half of its authored interval")
	assert_almost_eq(_player().volume_db, _expected_bgm_db(0.4), 0.01,
		"fade-in midpoint reaches the physical player")
	assert_eq(_terminals.size(), terminal_count)
	assert_true(fade_in_tween.custom_step(1.0))
	assert_almost_eq(
		float((_audio._bgm_channel["current"] as Dictionary)["level"]),
		0.8, 0.001)
	assert_almost_eq(_player().volume_db, _expected_bgm_db(0.8), 0.01)
	fade_in_tween.custom_step(0.000001)
	assert_eq(fade_in.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(_terminals.size(), terminal_count + 1)
	_audio.call("_complete_bgm_receipt", fade_in_receipt)
	assert_eq(_terminals.size(), terminal_count + 1,
		"fade-in authored endpoint is terminal exactly once")

	terminal_count = _terminals.size()
	var old_player := _player()
	var crossfade := _submit(
		[_operation("play", "synthetic_raw", "", 0.6, 2.0)],
		PresentationBatchRequest.Policy.JOIN)
	assert_false(crossfade.is_settled())
	var crossfade_receipt: Dictionary = (
		_audio._bgm_channel["receipt"] as Dictionary).duplicate(true)
	var crossfade_tween: Tween = _audio._bgm_channel["tween"]
	assert_true(crossfade_tween.custom_step(1.0))
	assert_almost_eq(
		float((_audio._bgm_channel["current"] as Dictionary)["level"]),
		0.3, 0.001, "incoming reaches its crossfade midpoint")
	assert_almost_eq(
		float((_audio._bgm_channel["outgoing"] as Dictionary)["level"]),
		0.4, 0.001, "outgoing reaches the same interval midpoint")
	assert_almost_eq(_player().volume_db, _expected_bgm_db(0.3), 0.01,
		"incoming crossfade midpoint reaches the physical player")
	assert_almost_eq(old_player.volume_db, _expected_bgm_db(0.4), 0.01,
		"outgoing crossfade midpoint reaches the physical player")
	assert_eq(_terminals.size(), terminal_count)
	assert_true(crossfade_tween.custom_step(1.0))
	assert_almost_eq(
		float((_audio._bgm_channel["current"] as Dictionary)["level"]),
		0.6, 0.001)
	assert_almost_eq(_player().volume_db, _expected_bgm_db(0.6), 0.01)
	assert_almost_eq(old_player.volume_db, -80.0, 0.01)
	crossfade_tween.custom_step(0.000001)
	assert_eq(crossfade.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(_audio._bgm_channel["outgoing"], {})
	assert_false(old_player.playing)
	assert_eq(_terminals.size(), terminal_count + 1)
	_audio.call("_complete_bgm_receipt", crossfade_receipt)
	assert_eq(_terminals.size(), terminal_count + 1,
		"crossfade authored endpoint is terminal exactly once")

	terminal_count = _terminals.size()
	var fade_out := _submit(
		[_operation("stop", "", "", 1.0, 2.0)],
		PresentationBatchRequest.Policy.JOIN)
	assert_false(fade_out.is_settled())
	var fade_out_receipt: Dictionary = (
		_audio._bgm_channel["receipt"] as Dictionary).duplicate(true)
	var fade_out_tween: Tween = _audio._bgm_channel["tween"]
	var fade_out_player := _player()
	assert_true(fade_out_tween.custom_step(1.0))
	assert_almost_eq(
		float((_audio._bgm_channel["current"] as Dictionary)["level"]),
		0.3, 0.001, "fade-out midpoint retains half the authored gain")
	assert_almost_eq(fade_out_player.volume_db, _expected_bgm_db(0.3), 0.01,
		"fade-out midpoint reaches the physical player")
	assert_eq(_terminals.size(), terminal_count)
	assert_true(fade_out_tween.custom_step(1.0))
	assert_almost_eq(fade_out_player.volume_db, -80.0, 0.01)
	fade_out_tween.custom_step(0.000001)
	assert_eq(fade_out.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(_audio._bgm_channel, {})
	assert_eq(_terminals.size(), terminal_count + 1)
	_audio.call("_complete_bgm_receipt", fade_out_receipt)
	assert_eq(_terminals.size(), terminal_count + 1,
		"fade-out authored endpoint is terminal exactly once")


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


func test_first_quiesce_invalidates_queued_preseal_mixed_audio_without_late_apply() -> void:
	var stage_emissions := [0]
	var on_stage := func(_operations: Array, _force_cut: bool) -> void:
		stage_emissions[0] += 1
	SignalBus.stage_operations_requested.connect(on_stage)
	var entered := [false]
	var first_ack := [true]
	var queued_requests: Array[PresentationBatchRequest] = []
	var bgm_epoch_before := SignalBus.current_bgm_epoch()
	var loop_epoch_before := SignalBus.current_loop_se_epoch()
	var on_validate := func(_request: BgmOperationRequest) -> void:
		if entered[0]:
			return
		entered[0] = true
		queued_requests.append(_submit([
			StagePresentationOperation.new({
				"action": "show", "id": "queued_after_quit",
				"properties": {"asset": "stage:synthetic"},
				"transition": "cut", "duration": 0.0,
			}, {"source_path": SOURCE_PATH, "line": 92}),
			_operation("play", "synthetic_raw", "", 0.6, 0.0, 93),
		], PresentationBatchRequest.Policy.JOIN))
		first_ack[0] = SignalBus.quiesce_runtime_audio_for_shutdown()
	SignalBus.bgm_validate_requested.connect(on_validate)
	var outer := _submit([
		StagePresentationOperation.new({
			"action": "show", "id": "preseal_before_quit",
			"properties": {"asset": "stage:synthetic"},
			"transition": "cut", "duration": 0.0,
		}, {"source_path": SOURCE_PATH, "line": 90}),
		_operation("play", "synthetic_track", "", 0.7, 0.0, 91),
	], PresentationBatchRequest.Policy.JOIN)
	SignalBus.bgm_validate_requested.disconnect(on_validate)

	assert_true(entered[0])
	assert_push_error(SOURCE_PATH + ":91")
	assert_false(first_ack[0],
		"nested first quiesce cannot acknowledge an active preflight stack")
	assert_true(outer.is_settled())
	assert_eq(queued_requests.size(), 1)
	assert_true(queued_requests[0].is_settled())
	assert_eq(stage_emissions[0], 0,
		"neither current nor queued mixed Stage child may apply after quit latch")
	assert_eq(SignalBus.current_bgm_epoch(), bgm_epoch_before + 1)
	assert_eq(SignalBus.current_loop_se_epoch(), loop_epoch_before + 1,
		"first quiesce invalidates both audio epochs even with empty local maps")
	assert_eq(_runtime.presentation_director._entries, {})
	assert_eq(SignalBus._presentation_operation_queue, [])
	assert_null(SignalBus._dispatching_bgm_request)
	assert_null(SignalBus._applying_bgm_request)
	assert_null(SignalBus._dispatching_loop_se_request)
	assert_null(SignalBus._applying_loop_se_request)
	assert_eq(SignalBus._bgm_epoch_stack, [])
	assert_eq(SignalBus._loop_se_epoch_stack, [])
	assert_eq(_audio._bgm_validation_cache, {})
	assert_eq(_audio._loop_se_validation_cache, {})
	assert_eq(_audio._bgm_channel, {})
	assert_eq(_audio._loop_se_channels, {})
	assert_true(SignalBus._runtime_audio_shutdown_bus_is_idle())
	assert_true(SignalBus.quiesce_runtime_audio_for_shutdown(),
		"repeat quiesce acknowledges only after the outer dispatch unwinds")
	assert_eq(SignalBus.current_bgm_epoch(), bgm_epoch_before + 1)
	assert_eq(SignalBus.current_loop_se_epoch(), loop_epoch_before + 1,
		"already-quiesced acknowledgement must not advance epochs again")
	await get_tree().process_frame
	assert_eq(stage_emissions[0], 0)
	assert_eq(_audio._bgm_channel, {})
	SignalBus.stage_operations_requested.disconnect(on_stage)


func test_duplicate_audio_presenter_never_becomes_a_second_consumer() -> void:
	var connection_counts := _signal_connection_counts()
	assert_eq(int(connection_counts["se_play"]), 1)
	assert_eq(int(connection_counts["voice_playback_requested"]), 1)
	assert_eq(int(connection_counts["system_se_play"]), 1)
	var duplicate := AudioPresenter.new()
	duplicate.name = "RejectedAudioPresenter"
	_runtime.add_child(duplicate)
	assert_null(duplicate._bgm_capability)
	assert_null(duplicate._loop_se_capability)
	assert_eq(duplicate.get_child_count(), 0)
	assert_false(duplicate.is_processing())
	assert_eq(_signal_connection_counts(), connection_counts)

	_runtime.se_path = "res://examples/demo/audio/se/"
	SignalBus.se_play.emit("se_select")
	var playing_owner_channels := 0
	for player_value: Variant in _audio._se_players:
		var player := player_value as AudioStreamPlayer
		if player.playing and player.stream != null:
			playing_owner_channels += 1
	assert_eq(playing_owner_channels, 1,
		"one raw request reaches exactly the admitted AudioPresenter")
	assert_eq(duplicate.get_child_count(), 0)
	duplicate.queue_free()
	await get_tree().process_frame


func test_audio_presenter_atomic_admission_never_leaves_a_partial_owner() -> void:
	_audio.queue_free()
	await get_tree().process_frame
	var foreign_loop_owner := Node.new()
	foreign_loop_owner.name = "SyntheticForeignLoopOwner"
	_runtime.add_child(foreign_loop_owner)
	var foreign_loop_capability := RefCounted.new()
	SignalBus._loop_se_presenter = weakref(foreign_loop_owner)
	SignalBus._loop_se_capability = foreign_loop_capability
	SignalBus._bgm_presenter = null
	SignalBus._bgm_capability = null
	var candidate := AudioPresenter.new()
	candidate.name = "RejectedSplitOwnerCandidate"
	_runtime.add_child(candidate)
	assert_null(candidate._loop_se_capability)
	assert_null(candidate._bgm_capability)
	assert_eq(candidate.get_child_count(), 0)
	assert_same(SignalBus._loop_se_presenter.get_ref(), foreign_loop_owner)
	assert_same(SignalBus._loop_se_capability, foreign_loop_capability)
	assert_null(SignalBus._bgm_presenter,
		"dual-slot preflight mutates neither owner when either slot is occupied")
	assert_null(SignalBus._bgm_capability)

	# Restore the intentionally corrupted registry only inside this test boundary.
	candidate.queue_free()
	foreign_loop_owner.queue_free()
	SignalBus._loop_se_presenter = null
	SignalBus._loop_se_capability = null
	await get_tree().process_frame
	var restored := AudioPresenter.new()
	restored.name = "AudioPresenter"
	_runtime.add_child(restored)
	_audio = restored
	assert_not_null(restored._loop_se_capability)
	assert_not_null(restored._bgm_capability)


func test_runtime_audio_shutdown_quiesces_every_exact_owner_idempotently() -> void:
	var stream := load(FIXTURE_PATH + "synthetic_raw.tres") as AudioStreamWAV
	var connection_counts := _signal_connection_counts()
	var duplicate := AudioPresenter.new()
	duplicate.name = "ShutdownNonOwnerDuplicate"
	_runtime.add_child(duplicate)
	assert_null(duplicate._bgm_capability)
	assert_null(duplicate._loop_se_capability)
	assert_eq(duplicate.get_child_count(), 0)
	assert_false(duplicate.is_processing())
	assert_eq(_signal_connection_counts(), connection_counts,
		"capability rejection happens before every raw or typed connection")
	var fnf := _submit([
		_operation("play", "synthetic_track", "", 0.7, 10.0),
	])
	assert_eq(fnf.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_false(_runtime.presentation_director._entries.is_empty())
	var bgm_player := _player()

	var loop_voice: Dictionary = _audio._create_loop_se_voice(
		stream, "synthetic_loop", 0.0, 0.5)
	var loop_player := loop_voice["player"] as AudioStreamPlayer
	var loop_channel: Dictionary = _audio._new_loop_se_channel()
	loop_channel["current"] = loop_voice
	loop_channel["target_active"] = true
	loop_channel["target_asset"] = "synthetic_loop"
	loop_channel["target_volume"] = 0.5
	_audio._loop_se_channels["ambient"] = loop_channel

	_audio._voice_player.stream = stream
	_audio._voice_playback_token = 801
	_audio._voice_playback_revision = _audio._voice_lifecycle_revision
	_audio._voice_player.play()
	var se_player := _audio._se_players[0] as AudioStreamPlayer
	se_player.stream = stream
	se_player.play()
	_audio._system_se_player.stream = stream
	_audio._system_se_player.play()

	assert_true(SignalBus.quiesce_runtime_audio_for_shutdown())
	assert_true(_audio._shutdown_quiesced)
	assert_false(duplicate._shutdown_quiesced,
		"an invalid participant has no shutdown connection or compatibility path")
	assert_eq(duplicate.get_child_count(), 0)
	assert_eq(_audio._bgm_channel, {})
	assert_eq(_audio._loop_se_channels, {})
	assert_eq(_runtime.presentation_director._entries, {})
	assert_eq(SignalBus._presentation_operation_queue, [])
	assert_false(bgm_player.playing)
	assert_null(bgm_player.stream)
	assert_false(loop_player.playing)
	assert_null(loop_player.stream)
	assert_false(_audio._voice_player.playing)
	assert_null(_audio._voice_player.stream)
	assert_false(se_player.playing)
	assert_null(se_player.stream)
	assert_false(_audio._system_se_player.playing)
	assert_null(_audio._system_se_player.stream)
	var retired_bgm_epoch := SignalBus.current_bgm_epoch()
	var retired_loop_epoch := SignalBus.current_loop_se_epoch()
	assert_true(SignalBus.quiesce_runtime_audio_for_shutdown(),
		"a concurrent/repeated quit request reuses the empty projection")
	assert_eq(SignalBus.current_bgm_epoch(), retired_bgm_epoch)
	assert_eq(SignalBus.current_loop_se_epoch(), retired_loop_epoch)
	assert_eq(SignalBus._dispatching_runtime_audio_shutdown_serial, 0)
	assert_false(SignalBus._runtime_audio_shutdown_acknowledged)
	await get_tree().process_frame
	assert_false(is_instance_valid(bgm_player))
	assert_false(is_instance_valid(loop_player))

	# Replacement remains possible during StellaRuntime's bounded real-mix wait.
	# A new unique owner must inherit the global terminal latch before _ready can
	# admit title/state projection or any raw audio notification.
	_audio.queue_free()
	await get_tree().process_frame
	var terminal_connection_counts := _signal_connection_counts()
	var replacement := AudioPresenter.new()
	replacement.name = "AudioPresenter"
	_runtime.add_child(replacement)
	_audio = replacement
	assert_true(replacement._shutdown_quiesced)
	assert_true(SignalBus.runtime_audio_shutdown_has_started())
	assert_null(replacement._bgm_capability,
		"terminal replacement never registers or announces typed ownership")
	assert_null(replacement._loop_se_capability)
	assert_eq(replacement.get_child_count(), 0)
	assert_false(replacement.is_processing())
	assert_eq(_signal_connection_counts(), terminal_connection_counts,
		"after the old owner exits, a terminal replacement connects no consumers")
	_runtime.se_path = "res://examples/demo/audio/se/"
	_runtime.voice_path = "res://examples/demo/audio/voice/"
	assert_eq(SignalBus.apply_title_bgm_cut("synthetic_raw"), 0)
	assert_eq(SignalBus.reset_and_apply_bgm_state({
		"asset": "synthetic_raw", "cue": "", "loop": true,
		"position": 0.0, "status": "playing", "stem_mix": {},
		"volume": 0.7,
	}), 0)
	assert_eq(SignalBus.reset_and_apply_loop_se_state({
		"ambient": {
			"asset": "se_select", "loop": true,
			"position": 0.0, "volume": 0.5,
		},
	}), 0)
	var voice_response := SignalBus.request_voice_playback(
		"sakura_001", "sakura", Callable(), false)
	assert_true(voice_response.was_handled())
	assert_false(voice_response.was_accepted())
	SignalBus.se_play.emit("se_select")
	SignalBus.system_se_play.emit("se_select")
	assert_eq(replacement.get_child_count(), 0,
		"terminal state never allocates fixed or dynamic audio players")
	assert_eq(replacement._bgm_channel, {})
	assert_eq(replacement._loop_se_channels, {})
	assert_eq(duplicate._bgm_channel, {})
	assert_eq(duplicate._loop_se_channels, {})
	assert_eq(duplicate.get_child_count(), 0)
	assert_eq(SignalBus.current_bgm_epoch(), retired_bgm_epoch)
	assert_eq(SignalBus.current_loop_se_epoch(), retired_loop_epoch)
	assert_true(SignalBus.quiesce_runtime_audio_for_shutdown())
	assert_eq(SignalBus.current_bgm_epoch(), retired_bgm_epoch,
		"replacement owner cannot repeat the globally retired epochs")
	assert_eq(SignalBus.current_loop_se_epoch(), retired_loop_epoch)
	duplicate.queue_free()
	replacement.queue_free()
	await get_tree().process_frame
	# Product shutdown is terminal. Restore a fresh owner only inside this test's
	# isolation boundary so later same-process files exercise ordinary admission.
	SignalBus._runtime_audio_shutdown_started = false
	SignalBus._runtime_audio_shutdown_epochs_retired = false
	var restored := AudioPresenter.new()
	restored.name = "AudioPresenter"
	_runtime.add_child(restored)
	_audio = restored
	assert_not_null(restored._bgm_capability)
	assert_not_null(restored._loop_se_capability)


func test_runtime_audio_shutdown_cancels_active_join_only_through_one_epoch() -> void:
	var started := _submit([
		_operation("play", "synthetic_track", "", 0.8),
	])
	assert_eq(started.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	var joined := _submit(
		[_operation("pause", "", "", 1.0, 10.0)],
		PresentationBatchRequest.Policy.JOIN,
	)
	assert_false(joined.is_settled())
	assert_false(_runtime.presentation_director._entries.is_empty())
	var state_apply_count := [0]
	var on_state_apply := func(_state: Dictionary, _generation: int) -> void:
		state_apply_count[0] += 1
	SignalBus.bgm_state_apply_requested.connect(on_state_apply)
	var bgm_epoch_before := SignalBus.current_bgm_epoch()
	var loop_epoch_before := SignalBus.current_loop_se_epoch()

	assert_true(SignalBus.quiesce_runtime_audio_for_shutdown())
	assert_true(joined.is_settled())
	assert_eq(joined.get_outcome(), PresentationBatchRequest.Outcome.CANCELLED)
	assert_eq(SignalBus.current_bgm_epoch(), bgm_epoch_before + 1,
		"active JOIN retirement advances the BGM epoch exactly once")
	assert_eq(SignalBus.current_loop_se_epoch(), loop_epoch_before + 1,
		"first quiesce advances the loop-SE epoch exactly once")
	assert_eq(state_apply_count[0], 0,
		"JOIN cancellation cannot roll back or replay a stable BGM during shutdown")
	assert_eq(_audio._bgm_channel, {})
	assert_eq(_audio._loop_se_channels, {})
	assert_eq(_runtime.presentation_director._entries, {})
	SignalBus.bgm_state_apply_requested.disconnect(on_state_apply)


func test_graceful_quit_latch_and_mix_boundary_fail_close_are_bounded() -> void:
	var old_requested: bool = _runtime._quit_requested
	var old_code: int = _runtime._quit_exit_code
	assert_true(_runtime._begin_quit_request(7))
	assert_false(_runtime._begin_quit_request(9),
		"OS close and an explicit quit can only schedule one completion")
	assert_eq(_runtime._quit_exit_code, 7)
	_runtime._quit_requested = old_requested
	_runtime._quit_exit_code = old_code

	assert_false(await _runtime._await_audio_mix_boundary(
		1, func() -> float: return 0.0, ""),
		"an unavailable driver fails closed without waiting forever")
	assert_false(await _runtime._await_audio_mix_boundary(
		1, func() -> float: return NAN, "SyntheticDriver"),
		"non-finite AudioServer timing fails closed")
	assert_false(await _runtime._await_audio_mix_boundary(
		2, func() -> float: return 0.5, "SyntheticDriver"),
		"a driver that never reaches another mix is bounded by process frames")
	assert_true(await _runtime._await_audio_mix_boundary(),
		"the real Godot audio driver exposes a mix rollover and cleanup frame")

	assert_false(get_tree().auto_accept_quit,
		"OS close must route through StellaRuntime instead of auto-quit")
	var runtime_source := FileAccess.get_file_as_string(
		"res://addons/stella/autoload/stella_runtime.gd")
	assert_true(runtime_source.contains(
		"auto_save()\n\t\trequest_quit()"),
		"OS close preserves autosave then reuses the public graceful boundary")
	for path: String in [
		"res://addons/stella/presentation/ui/title_screen.gd",
		"res://addons/stella/presentation/ui/stella_action.gd",
		"res://examples/demo/scripts/demo_title.gd",
	]:
		var source := FileAccess.get_file_as_string(path)
		assert_true(source.contains("StellaRuntime.request_quit()"), path)
		assert_false(source.contains("get_tree().quit("), path)


func test_bootstrap_double_scene_failure_requests_one_public_graceful_quit() -> void:
	var bootstrap := FailingBootstrap.new()
	add_child_autofree(bootstrap)
	var original_requested: bool = _runtime._quit_requested
	var original_code: int = _runtime._quit_exit_code
	var original_completion_started: bool = _runtime._quit_completion_started
	_runtime._quit_requested = false
	_runtime._quit_exit_code = 0
	# Keep the real public request observable without allowing its deferred
	# completion to terminate the GUT process.
	_runtime._quit_completion_started = true

	bootstrap._enter_title_scene(PackedScene.new())
	assert_push_error("StellaBootstrap: failed to enter the resolved title scene")
	var change_attempt_count: int = bootstrap.change_attempts.size()
	var quit_was_requested: bool = _runtime._quit_requested
	var requested_exit_code: int = _runtime._quit_exit_code

	# Flush the deferred completion while its guard is still raised, then restore
	# the shared autoload before making assertions about the captured result.
	await get_tree().process_frame
	_runtime._quit_requested = original_requested
	_runtime._quit_exit_code = original_code
	_runtime._quit_completion_started = original_completion_started

	assert_eq(change_attempt_count, 2,
		"the resolved title and default fallback both fail before shutdown")
	assert_true(quit_was_requested,
		"terminal bootstrap failure crosses StellaRuntime.request_quit")
	assert_eq(requested_exit_code, 1)
	var bootstrap_source := FileAccess.get_file_as_string(
		"res://addons/stella/scenes/bootstrap.gd")
	assert_eq(bootstrap_source.count("StellaRuntime.request_quit(1)"), 1,
		"both failures schedule the public graceful boundary exactly once")
	assert_false(bootstrap_source.contains("get_tree().quit("))


func test_repeated_nonloop_natural_finish_retires_the_exact_player_once() -> void:
	var baseline_children := _audio.get_child_count()
	for iteration in range(3):
		_submit([_operation("play", "synthetic_track", "intro")])
		assert_false(_runtime.presentation_state.current_bgm.is_empty())
		assert_eq(_audio.get_child_count(), baseline_children + 1, str(iteration))
		var finished_player := _player()
		await finished_player.finished
		await get_tree().process_frame
		assert_eq(_runtime.presentation_state.current_bgm, {}, str(iteration))
		assert_eq(_audio._bgm_channel, {}, str(iteration))
		assert_false(is_instance_valid(finished_player),
			"the exact naturally finished player must be freed")
		assert_eq(_audio.get_child_count(), baseline_children,
			"repeated natural endings cannot accumulate dead children or streams")
