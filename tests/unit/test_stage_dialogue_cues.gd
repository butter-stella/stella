extends GutTest
## Named-stage cues at @combine segment boundaries.

var _game_scene: Node
var _dialogue: Control
var _original_voice_path: String
var _original_skip_active: bool
var _original_auto_active: bool
var _original_voice_enabled: Dictionary
var _original_presentation_snapshot: Dictionary
var _original_engine: ScenarioEngine
var _original_stage_assets_path := ""
var _original_backgrounds_path := ""


func before_each() -> void:
	_original_presentation_snapshot = (
		StellaRuntime.presentation_state.capture_snapshot()
	)
	StellaRuntime.presentation_state.clear()
	_original_voice_path = StellaRuntime.voice_path
	_original_skip_active = StellaRuntime.skip_controller.is_active
	_original_auto_active = StellaRuntime.auto_play.is_active
	var voice_enabled = StellaRuntime.get_setting("character_voice_enabled")
	_original_voice_enabled = (
		voice_enabled.duplicate(true) if voice_enabled is Dictionary else {}
	)
	StellaRuntime.voice_path = "res://examples/demo/audio/voice/"
	StellaRuntime.skip_controller.is_active = false
	StellaRuntime.auto_play.is_active = false
	StellaRuntime.set_setting("character_voice_enabled", {})
	_original_engine = StellaRuntime.engine
	_original_stage_assets_path = StellaRuntime.stage_assets_path
	_original_backgrounds_path = StellaRuntime.backgrounds_path
	StellaRuntime.stage_assets_path = "res://examples/demo/art/stage/"
	StellaRuntime.backgrounds_path = "res://examples/demo/art/backgrounds/"
	var scenario := ScenarioData.new()
	scenario.id = "stage_dialogue_cues"
	scenario.source_path = "res://tests/fixtures/scenarios/stage_dialogue_cues.stla"
	var scene := SceneData.new()
	scene.id = "start"
	scenario.scenes.append(scene)
	var test_engine := ScenarioEngine.new()
	test_engine.context = ScenarioContext.new(scenario)
	StellaRuntime.engine = test_engine
	_game_scene = load("res://addons/stella/scenes/game.tscn").instantiate()
	add_child_autoqfree(_game_scene)
	await get_tree().process_frame
	_dialogue = _game_scene.get_node("UILayer/DialoguePanel")
	_dialogue._current_mode = "adv"
	_dialogue._playback_is_dialogue = false


func after_each() -> void:
	SignalBus.advance_requested.emit()
	StellaRuntime.voice_path = _original_voice_path
	StellaRuntime.skip_controller.is_active = _original_skip_active
	StellaRuntime.auto_play.is_active = _original_auto_active
	StellaRuntime.set_setting("character_voice_enabled", _original_voice_enabled)
	StellaRuntime.presentation_state.restore_snapshot(
		_original_presentation_snapshot
	)
	StellaRuntime.engine = _original_engine
	StellaRuntime.stage_assets_path = _original_stage_assets_path
	StellaRuntime.backgrounds_path = _original_backgrounds_path


func _stage_op(
	action: String,
	layer_id: String,
	properties: Dictionary = {},
	transition: String = "cut",
	duration: float = 0.0,
	transition_params: Dictionary = {},
) -> Dictionary:
	return {"kind": "stage", "payload": _stage_payload(
		action, layer_id, properties, transition, duration, transition_params)}


func _stage_payload(
	action: String,
	layer_id: String,
	properties: Dictionary = {},
	transition: String = "cut",
	duration: float = 0.0,
	transition_params: Dictionary = {},
) -> Dictionary:
	var spec := StageTransitionSpec.canonicalize(
		transition, transition_params)
	var canonical_transition := transition
	var canonical_params := transition_params.duplicate(true)
	if bool(spec.get("valid", false)):
		canonical_transition = String(spec.get("kind", transition))
		canonical_params = (spec.get("params", {}) as Dictionary).duplicate(true)
	return {
		"action": action,
		"id": layer_id,
		"properties": properties,
		"transition_params": canonical_params,
		"transition": canonical_transition,
		"duration": duration,
	}


func _avatar_op(
	action: String,
	properties: Dictionary = {},
	transition: String = "cut",
	duration: float = 0.0,
) -> Dictionary:
	return {"kind": "dialogue_avatar", "payload": {
		"action": action,
		"properties": properties,
		"transition": transition,
		"duration": duration,
	}}


func _records_for_presenter(records: Array, presenter: StagePresenter) -> Array:
	return records.filter(func(record: Dictionary) -> bool:
		return int(record.get("presenter_instance_id", -1)) == presenter.get_instance_id()
	)


func _open_synthetic_dialogue_voice_session() -> void:
	_dialogue._playback_owner_dialogue_gen = _dialogue._dialogue_gen
	_dialogue._playback_aborted = false
	_dialogue._playback_queue_active = true
	_dialogue._playback_dialogue_finished_emitted = false
	_dialogue._playback_is_dialogue = true
	_dialogue._playback_total_duration = 1.0


func test_projection_cues_use_typed_director_and_preserve_segment_order() -> void:
	var presenter := _game_scene.get_node("StageLayer") as StagePresenter
	var raw_batches: Array[Dictionary] = []
	var receipts: Array[Dictionary] = []
	var on_stage := func(operations: Array, force_cut: bool) -> void:
		raw_batches.append({
			"operations": operations.duplicate(true),
			"force_cut": force_cut,
		})
	var on_receipt := func(
		presenter_id: int,
		layer_id: String,
		token: int,
		operation_request_id: int,
		generation: int,
	) -> void:
		if presenter_id == presenter.get_instance_id():
			receipts.append({
				"presenter_instance_id": presenter_id,
				"layer_id": layer_id,
				"token": token,
				"operation_request_id": operation_request_id,
				"generation": generation,
			})
	SignalBus.stage_operations_requested.connect(on_stage)
	SignalBus.stage_transition_receipt_started.connect(on_receipt)
	var first_id: int = _dialogue._apply_segment_presentation({
		"presentation_ops": [_stage_op(
			"show",
			"typed_combine",
			{"asset": "background:bg_cafe"},
			"rule",
			10.0,
			{"mask": "stage:masks/diagonal"},
		)],
		"presentation_operation_lines": [31],
	}, false)
	var second_id: int = _dialogue._apply_segment_presentation({
		"presentation_ops": [_stage_op(
			"update",
			"typed_combine",
			{"opacity": 0.5},
			"mosaic",
			10.0,
		)],
		"presentation_operation_lines": [37],
	}, false)
	assert_gt(first_id, 0)
	assert_gt(second_id, first_id)
	assert_eq(raw_batches.size(), 2)
	assert_eq(raw_batches[0]["operations"][0]["transition"], "rule")
	assert_eq(raw_batches[1]["operations"][0]["transition"], "mosaic")
	assert_false(bool(raw_batches[0]["force_cut"]))
	assert_false(bool(raw_batches[1]["force_cut"]))
	assert_eq(presenter.get_layer_state("typed_combine")["opacity"], 0.5)
	assert_eq(receipts.size(), 2)
	assert_true(_dialogue._stage_operation_request_owners.is_empty())
	assert_true(_dialogue._stage_operation_request_results.is_empty())
	SignalBus.stage_transition_receipts_finish_requested.emit(
		receipts.duplicate(true))
	SignalBus.stage_transition_receipt_started.disconnect(on_receipt)
	SignalBus.stage_operations_requested.disconnect(on_stage)


func test_avatar_cues_use_typed_director_at_exact_segment_boundaries() -> void:
	var commits: Array[Dictionary] = []
	var receipts: Array[Dictionary] = []
	var on_commit := func(operation: DialogueAvatarPresentationOperation) -> void:
		commits.append(operation.get_payload())
	var on_receipt := func(
		presenter_id: int,
		token: int,
		request_id: int,
		generation: int,
	) -> void:
		if presenter_id == _dialogue.get_instance_id():
			receipts.append({
				"presenter_instance_id": presenter_id,
				"token": token,
				"operation_request_id": request_id,
				"generation": generation,
			})
	SignalBus.dialogue_avatar_operation_committed.connect(on_commit)
	SignalBus.dialogue_avatar_transition_receipt_started.connect(on_receipt)
	var first_id: int = _dialogue._apply_segment_presentation({
		"presentation_ops": [_avatar_op("set", {
			"asset": "background:bg_cafe", "visible": false,
		})],
		"presentation_operation_lines": [31],
	}, false)
	var second_id: int = _dialogue._apply_segment_presentation({
		"presentation_ops": [_avatar_op("show", {}, "fade", 10.0)],
		"presentation_operation_lines": [37],
	}, false)
	assert_gt(first_id, 0)
	assert_gt(second_id, first_id)
	assert_eq(commits.map(func(value: Dictionary): return value["action"]), [
		"set", "show",
	])
	assert_true(StellaRuntime.presentation_state.dialogue_avatar["visible"])
	assert_eq(
		StellaRuntime.presentation_state.dialogue_avatar["asset"],
		"background:bg_cafe",
	)
	assert_eq(receipts.size(), 1)
	assert_true(_dialogue._stage_operation_request_owners.is_empty())
	SignalBus.dialogue_avatar_transition_receipts_finish_requested.emit(receipts)
	SignalBus.dialogue_avatar_transition_receipt_started.disconnect(on_receipt)
	SignalBus.dialogue_avatar_operation_committed.disconnect(on_commit)


func test_avatar_final_fold_preserves_order_but_force_cuts_all_pending_cues() -> void:
	var commits: Array[String] = []
	var receipts := [0]
	var on_commit := func(operation: DialogueAvatarPresentationOperation) -> void:
		commits.append(String(operation.get_payload()["action"]))
	var on_receipt := func(
		_presenter_id: int,
		_token: int,
		_request_id: int,
		_generation: int,
	) -> void: receipts[0] += 1
	SignalBus.dialogue_avatar_operation_committed.connect(on_commit)
	SignalBus.dialogue_avatar_transition_receipt_started.connect(on_receipt)
	_dialogue._next_stage_segment_index = 0
	_dialogue._apply_final_segment_presentation([{
		"presentation_ops": [_avatar_op("set", {
			"asset": "background:bg_cafe", "visible": false,
		}, "fade", 3.0)],
		"presentation_operation_lines": [41],
	}, {
		"presentation_ops": [_avatar_op("show", {}, "fade", 3.0)],
		"presentation_operation_lines": [45],
	}], true, false)
	assert_eq(commits, ["set", "show"])
	assert_eq(receipts[0], 0)
	assert_true(StellaRuntime.presentation_state.dialogue_avatar["visible"])
	assert_eq(
		StellaRuntime.presentation_state.dialogue_avatar["asset"],
		"background:bg_cafe",
	)
	assert_true(_dialogue._stage_operation_request_owners.is_empty())
	SignalBus.dialogue_avatar_transition_receipt_started.disconnect(on_receipt)
	SignalBus.dialogue_avatar_operation_committed.disconnect(on_commit)


func test_avatar_segment_missing_asset_fails_at_authored_line_without_owner_leak() -> void:
	var before: Dictionary = (
		StellaRuntime.presentation_state.dialogue_avatar.duplicate(true))
	var request_id: int = _dialogue._apply_segment_presentation({
		"presentation_ops": [_avatar_op("show", {
			"asset": "stage:definitely_missing",
		})],
		"presentation_operation_lines": [73],
	}, false)
	assert_push_error("res://tests/fixtures/scenarios/stage_dialogue_cues.stla:73")
	assert_gt(request_id, 0)
	assert_eq(StellaRuntime.presentation_state.dialogue_avatar, before)
	assert_true(_dialogue._stage_operation_request_owners.is_empty())
	assert_true(_dialogue._stage_operation_request_results.is_empty())


func test_projection_cue_failure_is_source_located_and_owner_clean() -> void:
	var presenter := _game_scene.get_node("StageLayer") as StagePresenter
	var before := presenter._states.duplicate(true)
	var raw_batches := [0]
	var on_stage := func(_operations: Array, _force_cut: bool) -> void:
		raw_batches[0] += 1
	SignalBus.stage_operations_requested.connect(on_stage)
	var request_id: int = _dialogue._apply_segment_presentation({
		"presentation_ops": [_stage_op(
			"show",
			"missing_combine",
			{"asset": "background:bg_cafe"},
			"rule",
			1.0,
			{"mask": "stage:masks/definitely_missing"},
		)],
		"presentation_operation_lines": [45],
	}, false)
	assert_push_error(
		"res://tests/fixtures/scenarios/stage_dialogue_cues.stla:45")
	assert_push_error("[runtime] Stage request rejected: presenter ")
	assert_gt(request_id, 0)
	assert_eq(raw_batches[0], 0)
	assert_eq(presenter._states, before)
	assert_true(presenter._layer_tweens.is_empty())
	assert_true(presenter._layer_transition_projections.is_empty())
	assert_true(_dialogue._stage_operation_request_owners.is_empty())
	assert_true(_dialogue._stage_operation_request_results.is_empty())
	SignalBus.stage_operations_requested.disconnect(on_stage)


func test_force_cut_combine_still_validates_projection_and_sidecar() -> void:
	var presenter := _game_scene.get_node("StageLayer") as StagePresenter
	var raw_batches: Array[Dictionary] = []
	var receipts := [0]
	var on_stage := func(operations: Array, force_cut: bool) -> void:
		raw_batches.append({
			"operations": operations.duplicate(true),
			"force_cut": force_cut,
		})
	var on_receipt := func(_p: int, _l: String, _t: int, _r: int, _g: int) -> void:
		receipts[0] += 1
	SignalBus.stage_operations_requested.connect(on_stage)
	SignalBus.stage_transition_receipt_started.connect(on_receipt)
	_dialogue._apply_segment_presentation({
		"presentation_ops": [_stage_op(
			"show",
			"cut_combine",
			{"asset": "background:bg_cafe"},
			"mosaic",
			10.0,
		)],
		"presentation_operation_lines": [58],
	}, true)
	assert_eq(raw_batches.size(), 1)
	assert_true(bool(raw_batches[0]["force_cut"]))
	assert_eq(raw_batches[0]["operations"][0]["transition"], "mosaic")
	assert_eq(receipts[0], 0)
	assert_true(presenter._layer_tweens.is_empty())
	assert_true(presenter._layer_transition_projections.is_empty())
	var malformed_id: int = _dialogue._apply_segment_presentation({
		"presentation_ops": [_stage_op(
			"update", "cut_combine", {"opacity": 0.25}, "mosaic", 0.0)],
		"presentation_operation_lines": [],
	}, true)
	assert_push_error("source-line sidecar is malformed")
	assert_gt(malformed_id, 0)
	assert_eq(raw_batches.size(), 1)
	assert_true(_dialogue._stage_operation_request_owners.is_empty())
	assert_true(_dialogue._stage_operation_request_results.is_empty())
	assert_true((StellaRuntime.presentation_director as PresentationDirector)
		._pending_request_reservations.is_empty())
	SignalBus.stage_transition_receipt_started.disconnect(on_receipt)
	SignalBus.stage_operations_requested.disconnect(on_stage)


func test_owned_stage_reentrant_show_retires_old_lifecycle_and_transition() -> void:
	var presenter := _game_scene.get_node("StageLayer") as StagePresenter
	SignalBus.show_dialogue.emit("", [{
		"text": "old", "voice": "", "presentation_ops": [],
	}], "adv")
	_open_synthetic_dialogue_voice_session()
	SignalBus.emit_stage_operations([
		_stage_payload("show", "owned", {"asset": "background:bg_cafe"}),
	], true)

	var presenter_callback := Callable(presenter, "_on_stage_operations_requested")
	SignalBus.stage_operations_requested.disconnect(presenter_callback)
	var replacement_requested := [false]
	var early_show: Callable = func(operations: Array, force_cut: bool):
		if force_cut or operations.is_empty() or replacement_requested[0]:
			return
		if String(operations[0].get("id", "")) != "owned":
			return
		replacement_requested[0] = true
		SignalBus.show_dialogue.emit("", [{
			"text": "winner", "voice": "", "presentation_ops": [],
		}], "adv")
	var logical_finish_count := [0]
	var on_logical_finish: Callable = func():
		logical_finish_count[0] += 1
	var transition_finish_batches: Array = []
	var on_transition_finish: Callable = func(records: Array):
		transition_finish_batches.append(records.duplicate(true))
	SignalBus.stage_operations_requested.connect(early_show)
	SignalBus.stage_operations_requested.connect(presenter_callback)
	SignalBus.dialogue_voice_finished.connect(on_logical_finish)
	SignalBus.stage_transitions_finish_requested.connect(on_transition_finish)

	_dialogue._apply_segment_presentation({
		"presentation_ops": [_stage_op(
			"update", "owned", {"opacity": 0.25}, "fade", 10.0
		)],
		"presentation_operation_lines": [273],
	}, false, 0, 1, _dialogue._playback_queue_gen)

	assert_true(replacement_requested[0])
	assert_eq(logical_finish_count[0], 1,
		"the replaced dialogue must publish logical FINISH exactly once")
	assert_eq(_dialogue.text_label.text, "winner")
	assert_eq(transition_finish_batches.size(), 1,
		"the replacement must finish the exact acknowledged old transition")
	if transition_finish_batches.size() == 1:
		var records := _records_for_presenter(
			transition_finish_batches[0], presenter)
		assert_eq(records.size(), 1)
		if records.size() == 1:
			assert_eq(records[0]["layer_id"], "owned")
	assert_false(presenter._layer_tweens.has("owned"))
	assert_eq(_dialogue._presentation_dispatch_depth, 0)
	assert_true(_dialogue._presentation_dispatch_generations.is_empty())
	assert_true(_dialogue._stage_operation_request_owners.is_empty())
	assert_true(_dialogue._queued_dialogue_requests.is_empty())
	SignalBus.stage_operations_requested.disconnect(early_show)
	SignalBus.dialogue_voice_finished.disconnect(on_logical_finish)
	SignalBus.stage_transitions_finish_requested.disconnect(on_transition_finish)


func test_owned_stage_reentrant_hide_unwinds_before_following_show() -> void:
	var presenter := _game_scene.get_node("StageLayer") as StagePresenter
	var presenter_callback := Callable(presenter, "_on_stage_operations_requested")
	SignalBus.stage_operations_requested.disconnect(presenter_callback)
	var hide_requested := [false]
	var early_hide: Callable = func(operations: Array, force_cut: bool):
		if force_cut or operations.is_empty() or hide_requested[0]:
			return
		if String(operations[0].get("id", "")) != "hide_owned":
			return
		hide_requested[0] = true
		SignalBus.hide_dialogue.emit()
	SignalBus.stage_operations_requested.connect(early_hide)
	SignalBus.stage_operations_requested.connect(presenter_callback)
	SignalBus.show_dialogue.emit("", [{
		"text": "old", "voice": "", "presentation_ops": [],
	}], "adv")

	_dialogue._apply_segment_presentation({
		"presentation_ops": [_stage_op(
			"show",
			"hide_owned",
			{"asset": "background:bg_cafe"},
			"fade",
			10.0,
		)],
		"presentation_operation_lines": [319],
	}, false, 0, 1, _dialogue._playback_queue_gen)

	assert_true(hide_requested[0])
	assert_false(_dialogue.visible)
	assert_eq(_dialogue._presentation_dispatch_depth, 0)
	assert_true(_dialogue._presentation_dispatch_generations.is_empty())
	assert_true(_dialogue._stage_operation_request_owners.is_empty())
	SignalBus.show_dialogue.emit("", [{
		"text": "after hide", "voice": "", "presentation_ops": [],
	}], "adv")
	assert_true(_dialogue.visible)
	assert_eq(_dialogue.text_label.text, "after hide")
	assert_true(_dialogue._queued_dialogue_requests.is_empty())
	SignalBus.stage_operations_requested.disconnect(early_hide)


func test_finalization_queued_show_beats_finished_listener_backlog_replay() -> void:
	SignalBus.show_dialogue.emit("", [{
		"text": "old", "voice": "", "presentation_ops": [],
	}], "adv")
	_open_synthetic_dialogue_voice_session()
	_dialogue._dialogue_segments = [{
		"text": "old",
		"voice": "",
		"presentation_ops": [_stage_op(
			"show",
			"final_owned",
			{"asset": "background:bg_cafe"},
			"fade",
			10.0,
		)],
		"presentation_operation_lines": [350],
	}]
	_dialogue._next_stage_segment_index = 0
	_dialogue._segment_presentation_complete = false

	var show_requested := [false]
	var on_final_stage: Callable = func(operations: Array, force_cut: bool):
		if not force_cut or operations.is_empty() or show_requested[0]:
			return
		if String(operations[0].get("id", "")) != "final_owned":
			return
		show_requested[0] = true
		SignalBus.show_dialogue.emit("", [{
			"text": "winner", "voice": "", "presentation_ops": [],
		}], "adv")
	var finish_count := [0]
	var on_logical_finish: Callable = func():
		finish_count[0] += 1
		SignalBus.dialogue_voice_replay_requested.emit(
			["narration_002"], "")
	var replayed_assets: Array[String] = []
	var on_voice_play: Callable = func(asset: String, _character: String):
		replayed_assets.append(asset)
	SignalBus.stage_operations_requested.connect(on_final_stage)
	SignalBus.dialogue_voice_finished.connect(on_logical_finish)
	SignalBus.voice_play.connect(on_voice_play)

	_dialogue.finalize_current_dialogue_for_advance()

	assert_true(show_requested[0])
	assert_eq(finish_count[0], 1)
	assert_eq(_dialogue.text_label.text, "winner")
	assert_false(replayed_assets.has("narration_002"),
		"the queued replacement SHOW must discard the stale backlog replay")
	assert_true(_dialogue._queued_voice_replay_request.is_empty())
	assert_true(_dialogue._queued_dialogue_requests.is_empty())
	SignalBus.stage_operations_requested.disconnect(on_final_stage)
	SignalBus.dialogue_voice_finished.disconnect(on_logical_finish)
	SignalBus.voice_play.disconnect(on_voice_play)


func test_exit_during_final_stage_dispatch_retires_deferred_lifecycle() -> void:
	SignalBus.show_dialogue.emit("", [{
		"text": "detached during finalization",
		"voice": "",
		"presentation_ops": [],
	}], "adv")
	_open_synthetic_dialogue_voice_session()
	_dialogue._dialogue_segments = [{
		"text": "detached during finalization",
		"voice": "",
		"presentation_ops": [_stage_op(
			"show",
			"exit_owned",
			{"asset": "background:bg_cafe"},
			"fade",
			10.0,
		)],
		"presentation_operation_lines": [407],
	}]
	_dialogue._next_stage_segment_index = 0
	_dialogue._segment_presentation_complete = false
	_dialogue._indicator_candidate_dialogue_gen = _dialogue._dialogue_gen
	_dialogue._dialogue_ready = true
	var indicator_token_before: int = _dialogue._indicator_token
	var queue_gen_before: int = _dialogue._playback_queue_gen

	# Run before StagePresenter so tree exit happens while this owned raw stage
	# dispatch still has later consumers and therefore must be deferred.
	var stage_presenter := _game_scene.get_node("StageLayer") as StagePresenter
	var presenter_callback := Callable(
		stage_presenter, "_on_stage_operations_requested")
	SignalBus.stage_operations_requested.disconnect(presenter_callback)
	var retained_dialogue := _dialogue
	var removed := [false]
	var remove_during_final_stage: Callable = func(
		operations: Array, force_cut: bool,
	):
		if not force_cut or operations.is_empty() or removed[0]:
			return
		if String(operations[0].get("id", "")) != "exit_owned":
			return
		removed[0] = true
		retained_dialogue.get_parent().remove_child(retained_dialogue)
	SignalBus.stage_operations_requested.connect(remove_during_final_stage)
	SignalBus.stage_operations_requested.connect(presenter_callback)
	var logical_finish_count := [0]
	var on_logical_finish: Callable = func():
		logical_finish_count[0] += 1
	SignalBus.dialogue_voice_finished.connect(on_logical_finish)

	retained_dialogue.finalize_current_dialogue_for_advance()

	assert_true(removed[0])
	assert_false(retained_dialogue.is_inside_tree())
	assert_true(retained_dialogue._deferred_lifecycle_boundary.is_empty(),
		"the deferred exit must drain after final stage delivery unwinds")
	assert_eq(retained_dialogue._presentation_dispatch_depth, 0)
	assert_true(
		retained_dialogue._presentation_dispatch_generations.is_empty())
	assert_true(retained_dialogue._stage_operation_request_owners.is_empty())
	assert_eq(retained_dialogue._boundary_operation_depth, 0)
	assert_false(retained_dialogue._playback_queue_active)
	assert_eq(retained_dialogue._playback_owner_dialogue_gen, -1)
	assert_true(retained_dialogue._playback_aborted)
	assert_gt(retained_dialogue._playback_queue_gen, queue_gen_before)
	assert_eq(logical_finish_count[0], 1,
		"tree exit must close the logical voice exactly once while detached")
	assert_gt(retained_dialogue._indicator_token, indicator_token_before)
	assert_eq(retained_dialogue._indicator_candidate_dialogue_gen, -1)
	assert_false(retained_dialogue._dialogue_ready)

	SignalBus.stage_operations_requested.disconnect(remove_during_final_stage)
	SignalBus.dialogue_voice_finished.disconnect(on_logical_finish)
	# The scene no longer owns this retained node; transfer it to the test so GUT
	# can release it normally after after_each has restored global state.
	add_child_autoqfree(retained_dialogue)


func test_empty_stage_segment_advances_presentation_cursor() -> void:
	_dialogue._next_stage_segment_index = 0
	_dialogue._segment_presentation_complete = false
	var request_id: int = _dialogue._apply_segment_presentation(
		{"presentation_ops": []}, false, 0, 1, _dialogue._playback_queue_gen)
	assert_eq(request_id, 0)
	assert_eq(_dialogue._next_stage_segment_index, 1)
	assert_true(_dialogue._segment_presentation_complete)


func test_replay_does_not_dispatch_remaining_stage_until_advance() -> void:
	var received_ids: Array[String] = []
	var on_stage: Callable = func(operations: Array, _force_cut: bool):
		for operation in operations:
			received_ids.append(String(operation.get("id", "")))
	SignalBus.stage_operations_requested.connect(on_stage)
	_dialogue._dialogue_segments = [
		{"text": "one", "voice": "narration_001", "presentation_ops": []},
		{"text": "two", "voice": "", "presentation_ops": [
			_stage_op("show", "remaining", {"asset": "background:bg_cafe"}),
			_avatar_op("show", {"asset": "background:bg_cafe"}),
		], "presentation_operation_lines": [493, 494]},
	]
	_dialogue._dialogue_voice_character = ""
	_dialogue._next_stage_segment_index = 1
	_dialogue._segment_presentation_complete = false
	_dialogue._playback_owner_dialogue_gen = _dialogue._dialogue_gen
	_dialogue._playback_aborted = false
	_dialogue._playback_queue_active = true
	_dialogue._playback_is_dialogue = false

	SignalBus.dialogue_voice_replay_requested.emit(["narration_001"], "")
	assert_false(received_ids.has("remaining"),
		"audio replay must not redispatch or finalize remaining presentation cues")
	assert_false(StellaRuntime.presentation_state.dialogue_avatar["present"],
		"backlog voice replay cannot drive the addressable avatar timeline")
	SignalBus.emit_advance_requested()
	assert_true(received_ids.has("remaining"),
		"normal advance owns the forced-cut reduction of remaining cues")
	assert_true(StellaRuntime.presentation_state.dialogue_avatar["present"])
	SignalBus.stage_operations_requested.disconnect(on_stage)


func test_stage_dispatch_defers_replay_and_queued_show_wins() -> void:
	var replayed := [false]
	var requested := [false]
	var on_voice: Callable = func(asset: String, _character: String):
		if asset == "narration_001":
			replayed[0] = true
	var on_stage: Callable = func(operations: Array, _force_cut: bool):
		if requested[0] or operations.is_empty():
			return
		if String(operations[0].get("id", "")) != "dispatching":
			return
		requested[0] = true
		SignalBus.dialogue_voice_replay_requested.emit(["narration_001"], "")
		assert_false(_dialogue._queued_voice_replay_request.is_empty())
		SignalBus.show_dialogue.emit("", [{
			"text": "winner", "voice": "", "presentation_ops": [],
		}], "adv")
	SignalBus.voice_play.connect(on_voice)
	SignalBus.stage_operations_requested.connect(on_stage)
	SignalBus.show_dialogue.emit("", [{
		"text": "old", "voice": "", "presentation_ops": [
			_stage_op("show", "dispatching", {"asset": "background:bg_cafe"}),
		],
		"presentation_operation_lines": [534],
	}], "adv")

	assert_true(requested[0])
	assert_eq(_dialogue.text_label.text, "winner")
	assert_false(replayed[0], "queued SHOW discards the deferred replay")
	assert_true(_dialogue._queued_voice_replay_request.is_empty())
	SignalBus.voice_play.disconnect(on_voice)
	SignalBus.stage_operations_requested.disconnect(on_stage)


func test_segment_stage_batch_is_emitted_before_voice():
	var target_stage_seen := [false]
	var voice_after_target_stage := [false]
	var stage_callback = func(_operations, _force_cut):
		var request_id := SignalBus.current_stage_operation_request_id()
		if _dialogue._stage_operation_request_owners.has(request_id):
			target_stage_seen[0] = true
	var voice_callback = func(asset, _character):
		if asset == "sakura_013" and target_stage_seen[0]:
			voice_after_target_stage[0] = true
	SignalBus.stage_operations_requested.connect(stage_callback)
	SignalBus.voice_play.connect(voice_callback)
	var segments := [{
		"text": "cue",
		"voice": "sakura_013",
		"presentation_ops": [_stage_op("show", "hero", {"asset": "background:bg_cafe"})],
		"presentation_operation_lines": [561],
	}]

	SignalBus.show_dialogue.emit("sakura", segments, "adv")

	assert_true(target_stage_seen[0])
	assert_true(voice_after_target_stage[0])
	SignalBus.advance_requested.emit()
	SignalBus.stage_operations_requested.disconnect(stage_callback)
	SignalBus.voice_play.disconnect(voice_callback)


func test_missing_or_muted_voice_cannot_block_later_stage_cues():
	var received_ids: Array = []
	var callback = func(operations, _force_cut):
		for operation in operations:
			received_ids.append(operation["id"])
	SignalBus.stage_operations_requested.connect(callback)
	var segments := [
		{"text": "one", "voice": "__missing", "presentation_ops": [
			_stage_op("show", "first", {"asset": "background:bg_cafe"}),
		], "presentation_operation_lines": [581]},
		{"text": "two", "voice": "sakura_013", "presentation_ops": [
			_stage_op("show", "second", {"asset": "background:bg_cafe"}),
		], "presentation_operation_lines": [584]},
	]
	StellaRuntime.set_setting("character_voice_enabled", {"sakura": false})

	_dialogue._start_voice_playback(
		"sakura", segments, _dialogue._dialogue_gen, false, true)

	assert_eq(received_ids, ["first", "second"])
	assert_false(_dialogue._playback_queue_active)
	SignalBus.stage_operations_requested.disconnect(callback)


func test_finalize_emits_only_operations_from_undispatched_segments():
	var batches: Array = []
	var callback = func(operations, force_cut):
		batches.append([operations.duplicate(true), force_cut])
	SignalBus.stage_operations_requested.connect(callback)
	var segments := [
		{
			"presentation_ops": [_stage_op("update", "hero", {"opacity": 0.2})],
			"presentation_operation_lines": [603],
		},
		{
			"presentation_ops": [_stage_op("show", "hero", {"asset": "background:bg_cafe"})],
			"presentation_operation_lines": [604],
		},
	]
	_dialogue._next_stage_segment_index = 1

	_dialogue._apply_final_segment_presentation(segments, true)

	assert_eq(batches.size(), 1)
	assert_true(batches[0][1])
	assert_eq(batches[0][0].size(), 1)
	assert_eq(batches[0][0][0]["action"], "show")
	SignalBus.stage_operations_requested.disconnect(callback)


func test_finalize_never_replays_fully_dispatched_non_idempotent_batch():
	var batches: Array = []
	var callback = func(operations, _force_cut): batches.append(operations)
	SignalBus.stage_operations_requested.connect(callback)
	var segments := [
		{
			"presentation_ops": [_stage_op("update", "hero", {"opacity": 0.2})],
			"presentation_operation_lines": [622],
		},
		{
			"presentation_ops": [_stage_op("show", "hero", {"asset": "background:bg_cafe"})],
			"presentation_operation_lines": [623],
		},
	]
	_dialogue._next_stage_segment_index = segments.size()

	_dialogue._apply_final_segment_presentation(segments, true)

	assert_eq(batches, [], "already-applied operations must never be reduced twice")
	SignalBus.stage_operations_requested.disconnect(callback)


func test_normal_advance_force_cuts_an_already_dispatched_final_tween():
	var operation_batches: Array = []
	var finished_transition_batches: Array = []
	var operation_callback = func(operations, _force_cut):
		operation_batches.append(operations)
	var finish_callback = func(transitions):
		finished_transition_batches.append(transitions.duplicate(true))
	SignalBus.stage_operations_requested.connect(operation_callback)
	SignalBus.stage_transitions_finish_requested.connect(finish_callback)
	SignalBus.emit_stage_operations([
		_stage_payload("show", "hero", {"asset": "background:bg_cafe"}),
	], true)
	var segment := {
		"presentation_ops": [_stage_op(
			"update", "hero", {"position": [640.0, 360.0]}, "move", 1.0
		)],
		"presentation_operation_lines": [647],
	}
	_dialogue._apply_segment_presentation(segment, false)
	operation_batches.clear()
	_dialogue._dialogue_segments = [segment]
	_dialogue._segment_presentation_complete = true
	_dialogue._next_stage_segment_index = 1

	_dialogue.finalize_current_dialogue_for_advance()

	assert_eq(operation_batches, [], "the final operation must not be replayed")
	assert_eq(finished_transition_batches.size(), 1)
	var presenter := _game_scene.get_node("StageLayer") as StagePresenter
	var current_records := _records_for_presenter(
		finished_transition_batches[0],
		presenter,
	)
	assert_eq(current_records.size(), 1)
	assert_eq(current_records[0]["layer_id"], "hero")
	SignalBus.stage_operations_requested.disconnect(operation_callback)
	SignalBus.stage_transitions_finish_requested.disconnect(finish_callback)


func test_synchronous_completion_cannot_replay_the_current_segment():
	var segments := [{
		"text": "",
		"voice": "",
		"presentation_ops": [_stage_op("show", "newcomer", {"opacity": 0.2})],
		"presentation_operation_lines": [676],
	}]
	_dialogue._dialogue_segments = segments.duplicate(true)
	var presenter := _game_scene.get_node("StageLayer") as StagePresenter
	var raw_dispatches := [0]
	var on_stage := func(operations: Array, _force_cut: bool) -> void:
		for operation: Dictionary in operations:
			if String(operation.get("id", "")) == "newcomer":
				raw_dispatches[0] += 1
	SignalBus.stage_operations_requested.connect(on_stage)
	presenter.layer_transition_finished.connect(func(layer_id: String):
		if layer_id == "newcomer":
			_dialogue.finalize_current_dialogue_for_advance()
	)

	_dialogue._start_voice_playback(
		"", segments, _dialogue._dialogue_gen, false, true)

	assert_eq(raw_dispatches[0], 1,
		"synchronous finalization must not redispatch the current segment")
	assert_true(StellaRuntime.presentation_state.stage_layers.has("newcomer"))
	assert_almost_eq(
		float(StellaRuntime.presentation_state.stage_layers["newcomer"]["opacity"]),
		0.2,
		0.001,
	)
	assert_true(_dialogue._segment_presentation_complete)
	assert_true(_dialogue._stage_operation_request_owners.is_empty())
	SignalBus.stage_operations_requested.disconnect(on_stage)


func test_early_stage_listener_defers_finalize_until_presenter_consumes_batch():
	var presenter := _game_scene.get_node("StageLayer") as StagePresenter
	var presenter_callback := Callable(presenter, "_on_stage_operations_requested")
	SignalBus.stage_operations_requested.disconnect(presenter_callback)
	var reentry_count := [0]
	var early_callback = func(_operations: Array, force_cut: bool):
		if not force_cut:
			reentry_count[0] += 1
			_dialogue.finalize_current_dialogue_for_advance()
	SignalBus.stage_operations_requested.connect(early_callback)
	SignalBus.stage_operations_requested.connect(presenter_callback)
	var segments := [{
		"text": "",
		"voice": "",
		"presentation_ops": [_stage_op(
			"show", "hero", {"asset": "background:bg_cafe"}, "fade", 1.0
		)],
		"presentation_operation_lines": [712],
	}]
	_dialogue._dialogue_segments = segments.duplicate(true)

	_dialogue._start_voice_playback(
		"", segments, _dialogue._dialogue_gen, false, true)

	assert_eq(reentry_count[0], 1)
	assert_true(_dialogue._segment_presentation_complete)
	assert_false(presenter._layer_tweens.has("hero"))
	assert_eq(presenter.get_layer_node("hero").position, Vector2.ZERO)
	SignalBus.stage_operations_requested.disconnect(early_callback)


func test_complete_typewriter_during_stage_dispatch_finishes_late_tween() -> void:
	var presenter := _game_scene.get_node("StageLayer") as StagePresenter
	var presenter_callback := Callable(presenter, "_on_stage_operations_requested")
	SignalBus.stage_operations_requested.disconnect(presenter_callback)
	var completed := [false]
	var early_callback = func(operations: Array, force_cut: bool):
		if force_cut or operations.is_empty() or completed[0]:
			return
		if String(operations[0].get("id", "")) != "completion_owned":
			return
		completed[0] = true
		assert_true(_dialogue.complete_typewriter())
	SignalBus.stage_operations_requested.connect(early_callback)
	SignalBus.stage_operations_requested.connect(presenter_callback)
	SignalBus.show_dialogue.emit("", [{
		"text": "typing",
		"voice": "",
		"presentation_ops": [_stage_op(
			"show",
			"completion_owned",
			{"asset": "background:bg_cafe"},
			"fade",
			10.0,
		)],
		"presentation_operation_lines": [745],
	}], "adv")

	assert_true(completed[0])
	assert_true(_dialogue._segment_presentation_complete)
	assert_false(presenter._layer_tweens.has("completion_owned"))
	assert_false(_dialogue._finalization_pending)
	assert_true(_dialogue._stage_transition_records.is_empty())
	assert_eq(_dialogue._presentation_dispatch_depth, 0)
	SignalBus.stage_operations_requested.disconnect(early_callback)


func test_raw_advance_finalizes_retiring_stage_before_queued_show() -> void:
	var presenter := _game_scene.get_node("StageLayer") as StagePresenter
	var presenter_callback := Callable(presenter, "_on_stage_operations_requested")
	SignalBus.stage_operations_requested.disconnect(presenter_callback)
	var advanced := [false]
	var early_stage_callback = func(operations: Array, force_cut: bool):
		if force_cut or operations.is_empty() or advanced[0]:
			return
		if String(operations[0].get("id", "")) != "retiring_stage":
			return
		advanced[0] = true
		SignalBus.advance_requested.emit()
	SignalBus.stage_operations_requested.connect(early_stage_callback)
	SignalBus.stage_operations_requested.connect(presenter_callback)
	var showed_replacement := [false]
	var advance_callback = func():
		if showed_replacement[0]:
			return
		showed_replacement[0] = true
		SignalBus.show_dialogue.emit("", [{
			"text": "replacement",
			"voice": "",
			"presentation_ops": [],
		}], "adv")
	SignalBus.advance_requested.connect(advance_callback)

	SignalBus.show_dialogue.emit("", [
		{
			"text": "retiring",
			"voice": "",
			"presentation_ops": [_stage_op(
				"show",
				"retiring_stage",
				{"asset": "background:bg_cafe"},
				"fade",
				10.0,
			)],
			"presentation_operation_lines": [793],
		},
		{
			"text": "tail",
			"voice": "",
			"presentation_ops": [_stage_op(
				"show",
				"retiring_tail",
				{"asset": "background:bg_cafe"},
				"fade",
				10.0,
			)],
			"presentation_operation_lines": [804],
		},
	], "adv")

	assert_true(advanced[0])
	assert_true(showed_replacement[0])
	assert_eq(_dialogue.text_label.text, "replacement")
	assert_true(StellaRuntime.presentation_state.stage_layers.has("retiring_tail"))
	assert_false(presenter._layer_tweens.has("retiring_stage"))
	assert_false(presenter._layer_tweens.has("retiring_tail"))
	assert_eq(_dialogue._presentation_dispatch_depth, 0)
	assert_true(_dialogue._presentation_dispatch_generations.is_empty())
	assert_true(_dialogue._queued_dialogue_requests.is_empty())
	assert_false(_dialogue._finalization_pending)
	assert_false(_dialogue._finalization_in_progress)
	assert_true(_dialogue._stage_operation_request_owners.is_empty())
	SignalBus.advance_requested.disconnect(advance_callback)
	SignalBus.stage_operations_requested.disconnect(early_stage_callback)


func test_queued_batch_keeps_dispatch_guard_until_late_presenter_finishes() -> void:
	var presenter := _game_scene.get_node("StageLayer") as StagePresenter
	var presenter_callback := Callable(presenter, "_on_stage_operations_requested")
	SignalBus.stage_operations_requested.disconnect(presenter_callback)
	var finalized := [false]
	var early_finalize = func(operations: Array, force_cut: bool):
		if (
			not force_cut
			and not operations.is_empty()
			and String(operations[0].get("id", "")) == "queued_owned"
			and not finalized[0]
		):
			finalized[0] = true
			_dialogue.finalize_current_dialogue_for_advance()
	SignalBus.stage_operations_requested.connect(early_finalize)
	SignalBus.stage_operations_requested.connect(presenter_callback)
	var opened := [false]
	var outer_callback = func(operations: Array, _force_cut: bool):
		if opened[0] or operations.is_empty():
			return
		if String(operations[0].get("id", "")) != "outer_trigger":
			return
		opened[0] = true
		SignalBus.show_dialogue.emit("", [{
			"text": "queued",
			"voice": "",
			"presentation_ops": [_stage_op(
				"show",
				"queued_owned",
				{"asset": "background:bg_cafe"},
				"fade",
				10.0,
			)],
			"presentation_operation_lines": [856],
		}], "adv")
	SignalBus.stage_operations_requested.connect(outer_callback)

	SignalBus.emit_stage_operations([
		_stage_payload("show", "outer_trigger", {"opacity": 0.5}),
	], true)

	assert_true(opened[0])
	assert_true(finalized[0])
	assert_eq(_dialogue._presentation_dispatch_depth, 0)
	assert_false(_dialogue._finalization_pending)
	assert_false(presenter._layer_tweens.has("queued_owned"))
	SignalBus.stage_operations_requested.disconnect(early_finalize)
	SignalBus.stage_operations_requested.disconnect(outer_callback)


func test_reset_cancellation_stops_queued_dialogue_stage_and_voice() -> void:
	var voice_assets: Array = []
	var voice_callback = func(asset: String, _character: String):
		voice_assets.append(asset)
	SignalBus.voice_play.connect(voice_callback)
	var submitted := [false]
	var outer_callback = func(operations: Array, _force_cut: bool):
		if submitted[0] or operations.is_empty():
			return
		if String(operations[0].get("id", "")) != "reset_trigger":
			return
		submitted[0] = true
		_dialogue._start_voice_playback("sakura", [{
			"text": "stale",
			"voice": "sakura_013",
			"presentation_ops": [_stage_op(
				"show",
				"must_not_land",
				{"asset": "background:bg_cafe"},
				"fade",
				10.0,
			)],
			"presentation_operation_lines": [894],
		}], _dialogue._dialogue_gen, false, true)
		SignalBus.reset_stage_visuals()
	SignalBus.stage_operations_requested.connect(outer_callback)

	SignalBus.emit_stage_operations([
		_stage_payload("show", "reset_trigger", {"opacity": 0.5}),
	], true)

	assert_true(submitted[0])
	assert_true(voice_assets.is_empty())
	assert_false(_dialogue._playback_queue_active)
	assert_false(
		StellaRuntime.presentation_state.stage_layers.has("must_not_land")
	)
	SignalBus.voice_play.disconnect(voice_callback)
	SignalBus.stage_operations_requested.disconnect(outer_callback)


func test_force_cut_completion_cannot_reenter_final_batch():
	var presenter := _game_scene.get_node("StageLayer") as StagePresenter
	var batches: Array = []
	var operation_callback = func(operations: Array, force_cut: bool):
		if force_cut:
			batches.append(operations.duplicate(true))
	SignalBus.stage_operations_requested.connect(operation_callback)
	_dialogue._dialogue_segments = [{
		"presentation_ops": [_stage_op(
			"show", "hero", {"asset": "background:bg_cafe"}, "fade", 1.0
		)],
		"presentation_operation_lines": [927],
	}]
	presenter.layer_transition_finished.connect(func(layer_id: String):
		if layer_id == "hero":
			_dialogue.finalize_current_dialogue_for_advance()
	)

	_dialogue.finalize_current_dialogue_for_advance()

	assert_eq(batches.size(), 1, "the remaining batch must be reduced exactly once")
	assert_true(_dialogue._segment_presentation_complete)
	assert_false(_dialogue._finalization_in_progress)
	SignalBus.stage_operations_requested.disconnect(operation_callback)


func test_animated_clear_tracks_and_finishes_a_pending_remove_visual():
	var presenter := _game_scene.get_node("StageLayer") as StagePresenter
	SignalBus.emit_stage_operations([
		_stage_payload("show", "ghost", {"asset": "background:bg_cafe"}),
	], true)
	SignalBus.emit_stage_operations([
		_stage_payload("remove", "ghost", {}, "fade", 10.0),
	], false)
	assert_not_null(presenter.get_layer_node("ghost"))
	assert_false(StellaRuntime.presentation_state.stage_layers.has("ghost"))
	var segments := [{
		"text": "",
		"voice": "",
		"presentation_ops": [_stage_op("clear", "", {}, "fade", 1.0)],
		"presentation_operation_lines": [956],
	}]
	_dialogue._dialogue_segments = segments.duplicate(true)

	_dialogue._start_voice_playback(
		"", segments, _dialogue._dialogue_gen, false, true)
	var current_records := _records_for_presenter(
		_dialogue._stage_transition_records.values(),
		presenter,
	)
	assert_eq(current_records.size(), 1)
	assert_eq(current_records[0]["layer_id"], "ghost")
	_dialogue.finalize_current_dialogue_for_advance()

	assert_null(presenter.get_layer_node("ghost"))
	assert_false(presenter._layer_tweens.has("ghost"))


func test_nested_generic_stage_request_is_not_owned_by_dialogue_batch():
	var presenter := _game_scene.get_node("StageLayer") as StagePresenter
	SignalBus.emit_stage_operations([
		_stage_payload("show", "hero", {"asset": "background:bg_cafe"}),
	], true)
	var dialogue_callback := Callable(_dialogue, "_on_stage_transition_started")
	SignalBus.stage_transition_started.disconnect(dialogue_callback)
	var reentered := [false]
	var old_token := [-1]
	var new_token := [-1]
	var early_callback = func(
		presenter_instance_id: int,
		layer_id: String,
		token: int,
		_operation_request_id: int,
	):
		if presenter_instance_id != presenter.get_instance_id() or layer_id != "hero":
			return
		if reentered[0]:
			new_token[0] = maxi(new_token[0], token)
			return
		reentered[0] = true
		old_token[0] = token
		SignalBus.emit_stage_operations([
			_stage_payload(
				"update",
				"hero",
				{"position": [320.0, 240.0]},
				"move",
				10.0,
			),
		], false)
	SignalBus.stage_transition_started.connect(early_callback)
	SignalBus.stage_transition_started.connect(dialogue_callback)
	var segment := {
		"presentation_ops": [_stage_op(
			"update", "hero", {"opacity": 0.5}, "fade", 10.0
		)],
		"presentation_operation_lines": [1010],
	}
	_dialogue._dialogue_segments = [segment.duplicate(true)]
	_dialogue._next_stage_segment_index = 1

	_dialogue._apply_segment_presentation(segment, false)

	var records := _records_for_presenter(
		_dialogue._stage_transition_records.values(),
		presenter,
	)
	assert_eq(records.size(), 1)
	assert_gt(new_token[0], old_token[0])
	assert_eq(records[0]["token"], old_token[0])
	assert_eq(presenter._layer_transition_tokens["hero"], new_token[0])
	_dialogue._segment_presentation_complete = true
	_dialogue.finalize_current_dialogue_for_advance()
	assert_true(presenter._layer_tweens.has("hero"),
		"dialogue finalization must not cut a nested generic request")
	SignalBus.emit_stage_operations([
		_stage_payload("update", "hero", {"position": [0.0, 0.0]}),
	], true)
	SignalBus.stage_transition_started.disconnect(early_callback)


func test_reentrant_new_dialogue_prevents_stale_avatar_and_ui_projection():
	var reentered := [false]
	var stage_callback = func(operations: Array, _force_cut: bool):
		if reentered[0] or operations.is_empty():
			return
		if String(operations[0].get("id", "")) != "old_stage":
			return
		reentered[0] = true
		SignalBus.show_dialogue.emit("sakura", [{
			"text": "[expr:smile]NEW",
			"voice": "",
			"presentation_ops": [],
		}], "adv")
	SignalBus.stage_operations_requested.connect(stage_callback)

	SignalBus.show_dialogue.emit("sakura", [{
		"text": "[expr:sad]OLD",
		"voice": "",
		"presentation_ops": [_stage_op(
			"show", "old_stage", {"asset": "background:bg_cafe"}, "fade", 10.0
		)],
		"presentation_operation_lines": [1055],
	}], "adv")

	assert_true(reentered[0])
	assert_eq(_dialogue._avatar_expressions.get("sakura"), "smile")
	assert_eq(_dialogue.text_label.text, "NEW")
	assert_eq(_dialogue._dialogue_segments[0]["text"], "[expr:smile]NEW")
	var avatar := _dialogue._avatar_texture.texture as AtlasTexture
	assert_not_null(avatar)
	assert_true(avatar.atlas.resource_path.ends_with("sakura/smile.png"))
	assert_eq(_dialogue._presentation_dispatch_depth, 0)
	assert_true(_dialogue._presentation_dispatch_generations.is_empty())
	SignalBus.stage_operations_requested.disconnect(stage_callback)


func test_stale_outer_dispatch_drains_new_dialogue_pending_finalization():
	var presenter := _game_scene.get_node("StageLayer") as StagePresenter
	var reentered := [false]
	var requested_finalize := [false]
	var stage_callback = func(operations: Array, _force_cut: bool):
		if operations.is_empty():
			return
		var layer_id := String(operations[0].get("id", ""))
		if layer_id == "outer_stage" and not reentered[0]:
			reentered[0] = true
			SignalBus.show_dialogue.emit("", [{
				"text": "NEW",
				"voice": "",
				"presentation_ops": [_stage_op(
					"show",
					"new_stage",
					{"asset": "background:bg_cafe"},
					"fade",
					10.0,
				)],
				"presentation_operation_lines": [1085],
			}], "adv")
		elif layer_id == "new_stage" and not requested_finalize[0]:
			requested_finalize[0] = true
			_dialogue.finalize_current_dialogue_for_advance()
	SignalBus.stage_operations_requested.connect(stage_callback)

	SignalBus.show_dialogue.emit("", [{
		"text": "OLD",
		"voice": "",
		"presentation_ops": [_stage_op(
			"show",
			"outer_stage",
			{"asset": "background:bg_cafe"},
			"fade",
			10.0,
		)],
		"presentation_operation_lines": [1101],
	}], "adv")

	assert_true(reentered[0])
	assert_true(requested_finalize[0])
	assert_false(_dialogue._finalization_pending)
	assert_false(_dialogue._finalization_in_progress)
	assert_eq(_dialogue._presentation_dispatch_depth, 0)
	assert_true(_dialogue._presentation_dispatch_generations.is_empty())
	assert_false(presenter._layer_tweens.has("new_stage"))
	SignalBus.stage_operations_requested.disconnect(stage_callback)


func test_reentrant_voice_started_cannot_run_stale_segment_presentation():
	var presenter := _game_scene.get_node("StageLayer") as StagePresenter
	var reentered := [false]
	var voice_started_callback = func(_duration: float):
		if reentered[0]:
			return
		reentered[0] = true
		SignalBus.show_dialogue.emit("sakura", [{
			"text": "[expr:smile]NEW",
			"voice": "",
			"presentation_ops": [],
		}], "adv")
	SignalBus.dialogue_voice_started.connect(voice_started_callback)

	SignalBus.show_dialogue.emit("sakura", [{
		"text": "[expr:sad]OLD",
		"voice": "sakura_013",
		"presentation_ops": [_stage_op(
			"show",
			"stale_stage",
			{"asset": "background:bg_cafe"},
			"fade",
			10.0,
		)],
		"presentation_operation_lines": [1137],
	}], "adv")

	assert_true(reentered[0])
	assert_eq(_dialogue.text_label.text, "NEW")
	assert_eq(_dialogue._avatar_expressions.get("sakura"), "smile")
	assert_false(
		StellaRuntime.presentation_state.stage_layers.has("stale_stage"),
	)
	assert_null(presenter.get_layer_node("stale_stage"))
	assert_true(_dialogue._stage_transition_records.is_empty())
	SignalBus.dialogue_voice_started.disconnect(voice_started_callback)


func test_early_reentrant_show_waits_for_late_stage_presenter_listener():
	var presenter := _game_scene.get_node("StageLayer") as StagePresenter
	var presenter_callback := Callable(presenter, "_on_stage_operations_requested")
	SignalBus.stage_operations_requested.disconnect(presenter_callback)
	var reentered := [false]
	var early_callback = func(operations: Array, _force_cut: bool):
		if reentered[0] or operations.is_empty():
			return
		if String(operations[0].get("id", "")) != "shared":
			return
		reentered[0] = true
		SignalBus.show_dialogue.emit("", [{
			"text": "NEW",
			"voice": "",
			"presentation_ops": [_stage_op(
				"update",
				"shared",
				{"opacity": 0.25, "position": [640.0, 360.0]},
				"move",
				10.0,
			)],
			"presentation_operation_lines": [1171],
		}], "adv")
	SignalBus.stage_operations_requested.connect(early_callback)
	SignalBus.stage_operations_requested.connect(presenter_callback)

	SignalBus.show_dialogue.emit("", [{
		"text": "OLD",
		"voice": "",
		"presentation_ops": [_stage_op(
			"show",
			"shared",
			{"asset": "background:bg_cafe"},
			"fade",
			10.0,
		)],
		"presentation_operation_lines": [1185],
	}], "adv")

	assert_true(reentered[0])
	assert_eq(_dialogue.text_label.text, "NEW")
	assert_true(presenter._layer_tweens.has("shared"))
	var records := _records_for_presenter(
		_dialogue._stage_transition_records.values(),
		presenter,
	)
	assert_eq(records.size(), 1)
	assert_eq(
		records[0]["token"],
		presenter._layer_transition_tokens["shared"],
	)
	assert_almost_eq(
		StellaRuntime.presentation_state.stage_layers["shared"]["opacity"],
		0.25,
		0.001,
	)
	_dialogue.finalize_current_dialogue_for_advance()
	assert_false(presenter._layer_tweens.has("shared"))
	SignalBus.stage_operations_requested.disconnect(early_callback)


func test_dialogue_batch_queued_by_external_stage_dispatch_keeps_ownership():
	var presenter := _game_scene.get_node("StageLayer") as StagePresenter
	SignalBus.emit_stage_operations([
		_stage_payload("show", "hero", {"asset": "background:bg_cafe"}),
	], true)
	var opened_dialogue := [false]
	var external_callback = func(operations: Array, _force_cut: bool):
		if opened_dialogue[0] or operations.is_empty():
			return
		if String(operations[0].get("id", "")) != "external_trigger":
			return
		opened_dialogue[0] = true
		SignalBus.show_dialogue.emit("", [{
			"text": "queued",
			"voice": "",
			"presentation_ops": [_stage_op(
				"update",
				"hero",
				{"position": [640.0, 360.0]},
				"move",
				10.0,
			)],
			"presentation_operation_lines": [1231],
		}], "adv")
	SignalBus.stage_operations_requested.connect(external_callback)

	SignalBus.emit_stage_operations([
		_stage_payload("show", "external_trigger", {"opacity": 0.5}),
	], true)

	assert_true(opened_dialogue[0])
	assert_true(presenter._layer_tweens.has("hero"))
	var records := _records_for_presenter(
		_dialogue._stage_transition_records.values(),
		presenter,
	)
	assert_eq(records.size(), 1)
	assert_eq(records[0]["token"], presenter._layer_transition_tokens["hero"])
	_dialogue.finalize_current_dialogue_for_advance()
	assert_false(presenter._layer_tweens.has("hero"))
	SignalBus.stage_operations_requested.disconnect(external_callback)


func test_finalize_folds_a_dialogue_batch_that_has_not_dispatched_yet():
	var presenter := _game_scene.get_node("StageLayer") as StagePresenter
	var finalized := [false]
	var external_callback = func(operations: Array, _force_cut: bool):
		if finalized[0] or operations.is_empty():
			return
		if String(operations[0].get("id", "")) != "external_trigger":
			return
		SignalBus.show_dialogue.emit("", [{
			"text": "queued then finalized",
			"voice": "",
			"presentation_ops": [_stage_op(
				"show",
				"authored_final",
				{"asset": "background:bg_cafe"},
				"fade",
				10.0,
			)],
			"presentation_operation_lines": [1269],
		}], "adv")
		finalized[0] = true
		_dialogue.finalize_current_dialogue_for_advance()
	SignalBus.stage_operations_requested.connect(external_callback)

	SignalBus.emit_stage_operations([
		_stage_payload("show", "external_trigger", {"opacity": 0.5}),
	], true)

	assert_true(finalized[0])
	assert_true(
		StellaRuntime.presentation_state.stage_layers.has("authored_final"),
	)
	assert_not_null(presenter.get_layer_node("authored_final"))
	assert_false(presenter._layer_tweens.has("authored_final"))
	SignalBus.stage_operations_requested.disconnect(external_callback)
