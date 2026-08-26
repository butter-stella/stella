extends GutTest
## Public synthetic lifecycle contract for the addressable dialogue avatar.

const RuntimeTestSupport = preload("res://tests/helpers/runtime_test_support.gd")
const SOURCE_PATH := "res://tests/fixtures/scenarios/dialogue/avatar_lifecycle.stla"
const STAGE_ROOT := "res://tests/fixtures/stage/"

var _runtime: Node
var _game_scene: Node
var _dialogue: Control
var _context: ScenarioContext
var _original_engine: ScenarioEngine
var _original_stage_root := ""
var _original_snapshot: Dictionary
var _original_skip := false
var _receipts: Array[Dictionary] = []
var _terminals: Array[Dictionary] = []


func before_each() -> void:
	_runtime = get_tree().root.get_node("StellaRuntime")
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	_original_engine = _runtime.engine
	_original_stage_root = _runtime.stage_assets_path
	_original_snapshot = _runtime.presentation_state.capture_snapshot()
	_original_skip = _runtime.skip_controller.is_active
	_runtime.stage_assets_path = STAGE_ROOT
	_runtime.skip_controller.is_active = false
	_runtime.presentation_state.clear()
	_receipts.clear()
	_terminals.clear()
	var scenario := ScenarioData.new()
	scenario.id = "dialogue_avatar_lifecycle"
	scenario.source_path = SOURCE_PATH
	var scene := SceneData.new()
	scene.id = "start"
	scenario.scenes.append(scene)
	var engine := ScenarioEngine.new()
	_context = ScenarioContext.new(scenario)
	engine.context = _context
	_runtime.engine = engine
	SignalBus.dialogue_avatar_transition_receipt_started.connect(_on_receipt)
	SignalBus.dialogue_avatar_transition_terminal.connect(_on_terminal)
	await _spawn_game_scene()


func after_each() -> void:
	if SignalBus.dialogue_avatar_transition_receipt_started.is_connected(_on_receipt):
		SignalBus.dialogue_avatar_transition_receipt_started.disconnect(_on_receipt)
	if SignalBus.dialogue_avatar_transition_terminal.is_connected(_on_terminal):
		SignalBus.dialogue_avatar_transition_terminal.disconnect(_on_terminal)
	_runtime.presentation_director.cancel_all()
	if _game_scene != null and is_instance_valid(_game_scene):
		_game_scene.queue_free()
		await _game_scene.tree_exited
		# SceneTree releases killed test-owned Tween records at the first process
		# boundary after their bound game scene has exited.
		await get_tree().process_frame
	_game_scene = null
	_dialogue = null
	_runtime.presentation_state.restore_snapshot(_original_snapshot)
	_runtime.stage_assets_path = _original_stage_root
	_runtime.skip_controller.is_active = _original_skip
	_runtime.engine = _original_engine
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())


func _spawn_game_scene() -> void:
	_game_scene = load("res://addons/stella/scenes/game.tscn").instantiate()
	add_child(_game_scene)
	await get_tree().process_frame
	_dialogue = _game_scene.get_node("UILayer/DialoguePanel")


func _payload(
	action: String,
	properties: Dictionary = {},
	transition: String = "cut",
	duration: float = 0.0,
) -> Dictionary:
	return {
		"action": action,
		"properties": properties,
		"transition": transition,
		"duration": duration,
	}


func _operation(payload: Dictionary, line: int) -> DialogueAvatarPresentationOperation:
	var before: Dictionary = (
		_runtime.presentation_state.dialogue_avatar.duplicate(true))
	return DialogueAvatarPresentationOperation.new(
		payload,
		before,
		DialogueAvatarState.reduce(before, [payload], false),
		{"source_path": SOURCE_PATH, "line": line},
	)


func _stage_operation(
	layer_id: String,
	action: String,
	properties: Dictionary,
	transition: String,
	duration: float,
	line: int,
) -> StagePresentationOperation:
	return StagePresentationOperation.new({
		"action": action,
		"id": layer_id,
		"properties": properties,
		"transition": transition,
		"transition_params": {},
		"duration": duration,
	}, {"source_path": SOURCE_PATH, "line": line})


func _submit(
	payload: Dictionary,
	policy: PresentationBatchRequest.Policy,
	line: int,
	explicit_force_cut: bool = false,
) -> PresentationBatchRequest:
	var operation := _operation(payload, line)
	var operations: Array[PresentationOperation] = [operation]
	return _runtime.presentation_director.submit(
		operations,
		policy,
		_context,
		operation.get_source(),
		explicit_force_cut,
	)


func _on_receipt(
	presenter_instance_id: int,
	token: int,
	operation_request_id: int,
	generation: int,
) -> void:
	if _dialogue == null or presenter_instance_id != _dialogue.get_instance_id():
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
	_terminals.append({
		"presenter_instance_id": presenter_instance_id,
		"token": token,
		"operation_request_id": operation_request_id,
		"generation": generation,
		"outcome": outcome,
	})


func test_cut_set_creates_stable_hidden_avatar_with_exact_transform() -> void:
	var request := _submit(_payload("set", {
		"asset": "stage:redraw_source",
		"visible": false,
		"position": [-280.0, -140.0],
		"origin": [65056.0, 320.0],
		"scale": [0.45, 0.45],
		"z_index": 12,
	}), PresentationBatchRequest.Policy.JOIN, 272)
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	var state: Dictionary = _runtime.presentation_state.dialogue_avatar
	assert_true(state["present"])
	assert_false(state["visible"])
	assert_eq(state["asset"], "stage:redraw_source")
	var sprite: Sprite2D = _dialogue.get("_addressable_avatar_sprite")
	assert_not_null(sprite.texture)
	assert_false(sprite.visible)
	assert_eq(sprite.position, Vector2(-280.0, -140.0))
	assert_eq(sprite.offset, Vector2(-65056.0, -320.0))
	assert_eq(sprite.scale, Vector2(0.45, 0.45))
	assert_eq(sprite.z_index, 12)
	assert_true(_receipts.is_empty())


func test_fade_show_join_finishes_on_exact_click_without_replay() -> void:
	_submit(_payload("set", {
		"asset": "stage:redraw_source", "visible": false,
	}), PresentationBatchRequest.Policy.FIRE_AND_FORGET, 10)
	var advance_count := [0]
	var after_director := func() -> void: advance_count[0] += 1
	SignalBus.advance_requested.connect(after_director)
	var request := _submit(
		_payload("show", {}, "fade", 10.0),
		PresentationBatchRequest.Policy.JOIN,
		11,
	)
	assert_false(request.is_settled())
	assert_eq(_receipts.size(), 1)
	SignalBus.emit_advance_requested()
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(advance_count[0], 1)
	assert_eq(_terminals.size(), 1)
	assert_eq(_terminals[0]["outcome"], &"completed")
	assert_true(_runtime.presentation_state.dialogue_avatar["visible"])
	assert_null(_dialogue.get("_dialogue_avatar_tween"))
	SignalBus.advance_requested.disconnect(after_director)


func test_crossfade_a_to_b_obeys_authored_duration_before_exact_terminal() -> void:
	_submit(_payload("show", {"asset": "stage:redraw_source"}),
		PresentationBatchRequest.Policy.FIRE_AND_FORGET, 12)
	_receipts.clear()
	var request := _submit(
		_payload("set", {"asset": "stage:redraw_blur_source"}, "fade", 2.0),
		PresentationBatchRequest.Policy.JOIN,
		13,
	)
	assert_false(request.is_settled())
	assert_eq(_receipts.size(), 1)
	var tween: Tween = _dialogue.get("_dialogue_avatar_tween")
	assert_not_null(tween)
	assert_true(tween.custom_step(0.75),
		"the authored two-second transition remains active before its endpoint")
	assert_false(request.is_settled())
	assert_almost_eq(tween.get_total_elapsed_time(), 0.75, 0.0001)
	var incoming: Sprite2D = _dialogue.get("_addressable_avatar_sprite")
	var outgoing: Sprite2D = _dialogue.get("_addressable_avatar_outgoing")
	assert_not_null(outgoing)
	assert_almost_eq(incoming.modulate.a, 0.375, 0.0001)
	assert_almost_eq(outgoing.modulate.a, 0.625, 0.0001)
	tween.custom_step(1.25)
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(_runtime.presentation_state.dialogue_avatar["asset"],
		"stage:redraw_blur_source")
	assert_null(_dialogue.get("_addressable_avatar_outgoing"))
	assert_null(_dialogue.get("_dialogue_avatar_tween"))


func test_mixed_stage_avatar_visibility_is_atomic_and_obeys_join_fnf() -> void:
	var source := {"source_path": SOURCE_PATH, "line": 14}
	var invalid_avatar := _operation(_payload("show", {
		"asset": "stage:definitely_missing",
	}), 15)
	var invalid_operations: Array[PresentationOperation] = [
		_stage_operation(
			"mixed", "show", {"asset": "stage:redraw_source"}, "cut", 0.0, 14),
		invalid_avatar,
	]
	var invalid: PresentationBatchRequest = _runtime.presentation_director.submit(
		invalid_operations,
		PresentationBatchRequest.Policy.JOIN,
		_context,
		source,
	)
	assert_push_error(SOURCE_PATH + ":15")
	assert_eq(invalid.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_false(_runtime.presentation_state.stage_layers.has("mixed"),
		"later avatar resource failure prevents the earlier Stage child mutation")
	assert_false(_runtime.presentation_state.dialogue_avatar["present"])

	_dialogue.visible = true
	var avatar := _operation(_payload("show", {
		"asset": "stage:redraw_blur_source",
	}, "fade", 10.0), 17)
	var joined_operations: Array[PresentationOperation] = [
		_stage_operation(
			"mixed", "show", {"asset": "stage:redraw_source"}, "cut", 0.0, 16),
		avatar,
		DialogueVisibilityPresentationOperation.new({
			"target": "surface",
			"action": "hide",
			"transition": "fade",
			"duration": 10.0,
		}, {}, {"source_path": SOURCE_PATH, "line": 18}),
	]
	var joined: PresentationBatchRequest = _runtime.presentation_director.submit(
		joined_operations,
		PresentationBatchRequest.Policy.JOIN,
		_context,
		source,
	)
	assert_false(joined.is_settled())
	assert_true(_runtime.presentation_state.stage_layers.has("mixed"))
	assert_true(_runtime.presentation_state.dialogue_avatar["visible"])
	assert_false(_runtime.presentation_state.dialogue_visibility["surface"])
	SignalBus.emit_advance_requested()
	assert_eq(joined.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)

	var avatar_before: Dictionary = (
		_runtime.presentation_state.dialogue_avatar.duplicate(true))
	var avatar_update := DialogueAvatarPresentationOperation.new(
		_payload("set", {"opacity": 0.5}, "fade", 10.0),
		avatar_before,
		DialogueAvatarState.reduce(
			avatar_before,
			[_payload("set", {"opacity": 0.5}, "fade", 10.0)],
			false,
		),
		{"source_path": SOURCE_PATH, "line": 20},
	)
	var fnf_operations: Array[PresentationOperation] = [
		_stage_operation("mixed", "update", {"opacity": 0.5}, "fade", 10.0, 19),
		avatar_update,
		DialogueVisibilityPresentationOperation.new({
			"target": "surface",
			"action": "show",
			"transition": "fade",
			"duration": 10.0,
		}, {}, {"source_path": SOURCE_PATH, "line": 21}),
	]
	var fnf: PresentationBatchRequest = _runtime.presentation_director.submit(
		fnf_operations,
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
		_context,
		source,
	)
	assert_true(fnf.is_settled(),
		"fire-and-forget releases the command after dispatch seal")
	assert_eq(fnf.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_almost_eq(
		float(_runtime.presentation_state.dialogue_avatar["opacity"]), 0.5, 0.0001)


func test_skip_and_explicit_force_cut_still_preflight_assets_without_receipt() -> void:
	_runtime.skip_controller.is_active = true
	var valid := _submit(
		_payload("show", {"asset": "stage:redraw_source"}, "fade", 4.0),
		PresentationBatchRequest.Policy.JOIN,
		20,
	)
	assert_eq(valid.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_true(_receipts.is_empty())
	_runtime.skip_controller.is_active = false
	var before: Dictionary = (
		_runtime.presentation_state.dialogue_avatar.duplicate(true))
	var invalid := _submit(
		_payload("set", {"asset": "stage:definitely_missing"}, "fade", 1.0),
		PresentationBatchRequest.Policy.JOIN,
		21,
		true,
	)
	assert_push_error(SOURCE_PATH + ":21")
	assert_true(invalid.is_settled())
	assert_eq(invalid.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_eq(_runtime.presentation_state.dialogue_avatar, before)
	assert_true(_receipts.is_empty())


func test_load_reset_retires_old_fade_and_stale_terminal_cannot_overwrite() -> void:
	_submit(_payload("show", {"asset": "stage:redraw_source"}),
		PresentationBatchRequest.Policy.FIRE_AND_FORGET, 30)
	var request := _submit(
		_payload("set", {"asset": "stage:redraw_blur_source"}, "fade", 10.0),
		PresentationBatchRequest.Policy.JOIN,
		31,
	)
	assert_false(request.is_settled())
	var stale := _receipts[0].duplicate(true)
	var restored := DialogueAvatarState.reduce(
		DialogueAvatarState.default_state(),
		[_payload("set", {
			"asset": "stage:redraw_mask", "visible": false,
		})],
		false,
	)
	_runtime.presentation_state.dialogue_avatar = restored.duplicate(true)
	SignalBus.reset_and_apply_dialogue_avatar_state(restored)
	assert_eq(_runtime.presentation_state.dialogue_avatar, restored)
	assert_eq(_dialogue.get("_addressable_avatar_state"), restored)
	assert_null(_dialogue.get("_dialogue_avatar_tween"))
	SignalBus.dialogue_avatar_transition_terminal.emit(
		stale["presenter_instance_id"],
		stale["token"],
		stale["operation_request_id"],
		stale["generation"],
		&"completed",
	)
	assert_eq(_runtime.presentation_state.dialogue_avatar, restored)
	assert_eq(_dialogue.get("_addressable_avatar_state"), restored)


func test_scene_replacement_projects_saved_stable_state_on_new_presenter() -> void:
	_submit(_payload("show", {
		"asset": "stage:redraw_source", "position": [12.0, 34.0],
	}), PresentationBatchRequest.Policy.FIRE_AND_FORGET, 40)
	var expected: Dictionary = (
		_runtime.presentation_state.dialogue_avatar.duplicate(true))
	var old_dialogue_id := _dialogue.get_instance_id()
	_game_scene.queue_free()
	await _game_scene.tree_exited
	_game_scene = null
	_dialogue = null
	await _spawn_game_scene()
	assert_ne(_dialogue.get_instance_id(), old_dialogue_id)
	assert_eq(_dialogue.get("_addressable_avatar_state"), expected)
	var sprite: Sprite2D = _dialogue.get("_addressable_avatar_sprite")
	assert_true(sprite.visible)
	assert_eq(sprite.position, Vector2(12.0, 34.0))
	assert_not_null(sprite.texture)


func test_snapshot_round_trip_cut_projects_stable_target_without_replaying_operation() -> void:
	_submit(_payload("show", {
		"asset": "stage:redraw_source",
		"position": [21.0, 43.0],
		"opacity": 0.75,
	}), PresentationBatchRequest.Policy.FIRE_AND_FORGET, 45)
	var snapshot: Dictionary = _runtime.presentation_state.capture_snapshot()
	var persisted: Variant = JSON.parse_string(JSON.stringify(snapshot))
	assert_true(persisted is Dictionary)
	if not persisted is Dictionary:
		return
	_submit(_payload("set", {
		"asset": "stage:redraw_blur_source",
	}), PresentationBatchRequest.Policy.FIRE_AND_FORGET, 46)
	var committed := [0]
	var on_commit := func(
		_operation: DialogueAvatarPresentationOperation,
	) -> void:
		committed[0] += 1
	SignalBus.dialogue_avatar_operation_committed.connect(on_commit)
	_receipts.clear()
	_runtime.presentation_state.restore_snapshot(persisted)
	_runtime.presentation_state.apply_to_presenters()
	assert_eq(committed[0], 0,
		"snapshot projection is not a replayed authored operation")
	assert_true(_receipts.is_empty())
	assert_eq(_runtime.presentation_state.dialogue_avatar,
		persisted["dialogue_avatar"])
	assert_eq(_dialogue.get("_addressable_avatar_state"),
		persisted["dialogue_avatar"])
	var sprite: Sprite2D = _dialogue.get("_addressable_avatar_sprite")
	assert_eq(sprite.position, Vector2(21.0, 43.0))
	assert_almost_eq(sprite.modulate.a, 0.75, 0.0001)
	SignalBus.dialogue_avatar_operation_committed.disconnect(on_commit)


func test_no_registered_presenter_fails_before_state_or_public_commit() -> void:
	_game_scene.queue_free()
	await _game_scene.tree_exited
	await get_tree().process_frame
	_game_scene = null
	_dialogue = null
	var before: Dictionary = (
		_runtime.presentation_state.dialogue_avatar.duplicate(true))
	var commits := [0]
	var on_commit := func(_operation: DialogueAvatarPresentationOperation) -> void:
		commits[0] += 1
	SignalBus.dialogue_avatar_operation_committed.connect(on_commit)
	var request := _submit(
		_payload("show", {"asset": "stage:redraw_source"}),
		PresentationBatchRequest.Policy.JOIN,
		51,
	)
	assert_push_error(SOURCE_PATH + ":51")
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_eq(_runtime.presentation_state.dialogue_avatar, before)
	assert_eq(commits[0], 0)
	SignalBus.dialogue_avatar_operation_committed.disconnect(on_commit)
