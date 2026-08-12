extends GutTest
## Named-stage cues at @combine segment boundaries.

var _game_scene: Node
var _dialogue: Control
var _original_voice_path: String
var _original_skip_active: bool
var _original_auto_active: bool
var _original_voice_enabled: Dictionary
var _original_presentation_snapshot: Dictionary


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


func _stage_op(
	action: String,
	layer_id: String,
	properties: Dictionary = {},
	transition: String = "cut",
	duration: float = 0.0,
) -> Dictionary:
	return {
		"action": action,
		"id": layer_id,
		"properties": properties,
		"transition": transition,
		"duration": duration,
	}


func _records_for_presenter(records: Array, presenter: StagePresenter) -> Array:
	return records.filter(func(record: Dictionary) -> bool:
		return int(record.get("presenter_instance_id", -1)) == presenter.get_instance_id()
	)


func test_segment_stage_batch_is_emitted_before_voice():
	var events: Array = []
	var stage_callback = func(_operations, _force_cut): events.append("stage")
	var voice_callback = func(asset, _character): events.append("voice:%s" % asset)
	SignalBus.stage_operations_requested.connect(stage_callback)
	SignalBus.voice_play.connect(voice_callback)
	var segments := [{
		"text": "cue",
		"voice": "sakura_013",
		"stage_ops": [_stage_op("show", "hero", {"asset": "stage:hero"})],
	}]

	_dialogue._start_voice_playback("sakura", segments, false, true)

	assert_eq(events, ["stage", "voice:sakura_013"])
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
		{"text": "one", "voice": "__missing", "stage_ops": [
			_stage_op("show", "first", {"asset": "stage:first"}),
		]},
		{"text": "two", "voice": "sakura_013", "stage_ops": [
			_stage_op("show", "second", {"asset": "stage:second"}),
		]},
	]
	StellaRuntime.set_setting("character_voice_enabled", {"sakura": false})

	_dialogue._start_voice_playback("sakura", segments, false, true)

	assert_eq(received_ids, ["first", "second"])
	assert_false(_dialogue._playback_queue_active)
	SignalBus.stage_operations_requested.disconnect(callback)


func test_finalize_emits_only_operations_from_undispatched_segments():
	var batches: Array = []
	var callback = func(operations, force_cut):
		batches.append([operations.duplicate(true), force_cut])
	SignalBus.stage_operations_requested.connect(callback)
	var segments := [
		{"stage_ops": [_stage_op("update", "hero", {"opacity": 0.2})]},
		{"stage_ops": [_stage_op("show", "hero", {"asset": "stage:hero"})]},
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
		{"stage_ops": [_stage_op("update", "hero", {"opacity": 0.2})]},
		{"stage_ops": [_stage_op("show", "hero", {"asset": "stage:hero"})]},
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
		_stage_op("show", "hero", {"asset": "stage:bg_cafe"}),
	], true)
	var segment := {
		"stage_ops": [_stage_op(
			"update", "hero", {"position": [640.0, 360.0]}, "move", 1.0
		)],
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
		"stage_ops": [
			_stage_op("update", "newcomer", {"opacity": 0.2}),
			_stage_op("show", "newcomer"),
		],
	}]
	_dialogue._dialogue_segments = segments.duplicate(true)
	var presenter := _game_scene.get_node("StageLayer") as StagePresenter
	presenter.layer_transition_finished.connect(func(layer_id: String):
		if layer_id == "newcomer":
			_dialogue.finalize_current_dialogue_for_advance()
	)

	_dialogue._start_voice_playback("", segments, false, true)

	assert_eq(
		StellaRuntime.presentation_state.stage_layers["newcomer"]["opacity"],
		1.0,
		"update-before-show must not be reduced a second time during re-entry",
	)


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
		"stage_ops": [_stage_op(
			"show", "hero", {"asset": "stage:bg_cafe"}, "fade", 1.0
		)],
	}]
	_dialogue._dialogue_segments = segments.duplicate(true)

	_dialogue._start_voice_playback("", segments, false, true)

	assert_eq(reentry_count[0], 1)
	assert_true(_dialogue._segment_presentation_complete)
	assert_false(presenter._layer_tweens.has("hero"))
	assert_eq(presenter.get_layer_node("hero").position, Vector2.ZERO)
	SignalBus.stage_operations_requested.disconnect(early_callback)


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
			"stage_ops": [_stage_op(
				"show",
				"queued_owned",
				{"asset": "stage:bg_cafe"},
				"fade",
				10.0,
			)],
		}], "adv")
	SignalBus.stage_operations_requested.connect(outer_callback)

	SignalBus.emit_stage_operations([
		_stage_op("show", "outer_trigger", {"opacity": 0.5}),
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
			"stage_ops": [_stage_op(
				"show",
				"must_not_land",
				{"asset": "stage:bg_cafe"},
				"fade",
				10.0,
			)],
		}], false, true)
		SignalBus.reset_stage_visuals()
	SignalBus.stage_operations_requested.connect(outer_callback)

	SignalBus.emit_stage_operations([
		_stage_op("show", "reset_trigger", {"opacity": 0.5}),
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
		"stage_ops": [_stage_op(
			"show", "hero", {"asset": "stage:bg_cafe"}, "fade", 1.0
		)],
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
		_stage_op("show", "ghost", {"asset": "stage:bg_cafe"}),
	], true)
	SignalBus.emit_stage_operations([
		_stage_op("remove", "ghost", {}, "fade", 10.0),
	], false)
	assert_not_null(presenter.get_layer_node("ghost"))
	assert_false(StellaRuntime.presentation_state.stage_layers.has("ghost"))
	var segments := [{
		"text": "",
		"voice": "",
		"stage_ops": [_stage_op("clear", "", {}, "fade", 1.0)],
	}]
	_dialogue._dialogue_segments = segments.duplicate(true)

	_dialogue._start_voice_playback("", segments, false, true)
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
		_stage_op("show", "hero", {"asset": "stage:bg_cafe"}),
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
			_stage_op(
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
		"stage_ops": [_stage_op(
			"update", "hero", {"opacity": 0.5}, "fade", 10.0
		)],
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
		_stage_op("update", "hero", {"position": [0.0, 0.0]}),
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
			"stage_ops": [],
		}], "adv")
	SignalBus.stage_operations_requested.connect(stage_callback)

	SignalBus.show_dialogue.emit("sakura", [{
		"text": "[expr:sad]OLD",
		"voice": "",
		"stage_ops": [_stage_op(
			"show", "old_stage", {"asset": "stage:bg_cafe"}, "fade", 10.0
		)],
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
				"stage_ops": [_stage_op(
					"show",
					"new_stage",
					{"asset": "stage:bg_cafe"},
					"fade",
					10.0,
				)],
			}], "adv")
		elif layer_id == "new_stage" and not requested_finalize[0]:
			requested_finalize[0] = true
			_dialogue.finalize_current_dialogue_for_advance()
	SignalBus.stage_operations_requested.connect(stage_callback)

	SignalBus.show_dialogue.emit("", [{
		"text": "OLD",
		"voice": "",
		"stage_ops": [_stage_op(
			"show",
			"outer_stage",
			{"asset": "stage:bg_cafe"},
			"fade",
			10.0,
		)],
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
			"stage_ops": [],
		}], "adv")
	SignalBus.dialogue_voice_started.connect(voice_started_callback)

	SignalBus.show_dialogue.emit("sakura", [{
		"text": "[expr:sad]OLD",
		"voice": "sakura_013",
		"stage_ops": [_stage_op(
			"show",
			"stale_stage",
			{"asset": "stage:bg_cafe"},
			"fade",
			10.0,
		)],
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
			"stage_ops": [_stage_op(
				"update",
				"shared",
				{"opacity": 0.25, "position": [640.0, 360.0]},
				"move",
				10.0,
			)],
		}], "adv")
	SignalBus.stage_operations_requested.connect(early_callback)
	SignalBus.stage_operations_requested.connect(presenter_callback)

	SignalBus.show_dialogue.emit("", [{
		"text": "OLD",
		"voice": "",
		"stage_ops": [_stage_op(
			"show",
			"shared",
			{"asset": "stage:bg_cafe"},
			"fade",
			10.0,
		)],
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
		_stage_op("show", "hero", {"asset": "stage:bg_cafe"}),
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
			"stage_ops": [_stage_op(
				"update",
				"hero",
				{"position": [640.0, 360.0]},
				"move",
				10.0,
			)],
		}], "adv")
	SignalBus.stage_operations_requested.connect(external_callback)

	SignalBus.emit_stage_operations([
		_stage_op("show", "external_trigger", {"opacity": 0.5}),
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
			"stage_ops": [_stage_op(
				"show",
				"authored_final",
				{"asset": "stage:bg_cafe"},
				"fade",
				10.0,
			)],
		}], "adv")
		finalized[0] = true
		_dialogue.finalize_current_dialogue_for_advance()
	SignalBus.stage_operations_requested.connect(external_callback)

	SignalBus.emit_stage_operations([
		_stage_op("show", "external_trigger", {"opacity": 0.5}),
	], true)

	assert_true(finalized[0])
	assert_true(
		StellaRuntime.presentation_state.stage_layers.has("authored_final"),
	)
	assert_not_null(presenter.get_layer_node("authored_final"))
	assert_false(presenter._layer_tweens.has("authored_final"))
	SignalBus.stage_operations_requested.disconnect(external_callback)
