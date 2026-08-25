extends GutTest

const SOURCE_PATH := "res://tests/fixtures/scenarios/stage_transition_lifecycle.stla"
const STAGE_ROOT := "res://tests/fixtures/stage/"


class CountingProjectionProvider extends StageTransitionProvider:
	var validation_count := 0

	func get_transition_kind() -> StringName:
		return &"counted_projection"

	func validate_transition(
		params: Dictionary,
		_texture_resolver: Callable,
	) -> Dictionary:
		validation_count += 1
		if not params.is_empty():
			return {"valid": false, "error": "counted_projection accepts no params"}
		return {"valid": true, "plan": {}}

	func create_material(
		_plan: Dictionary,
		source_texture: Texture2D,
		target_texture: Texture2D,
		viewport_size: Vector2,
	) -> ShaderMaterial:
		var shader := load(
			"res://addons/stella/presentation/stage/shaders/stage_transition_mosaic.gdshader"
		) as Shader
		if shader == null or source_texture == null or target_texture == null:
			return null
		var material := ShaderMaterial.new()
		material.shader = shader
		material.set_shader_parameter("source_texture", source_texture)
		material.set_shader_parameter("target_texture", target_texture)
		material.set_shader_parameter("viewport_size", viewport_size)
		material.set_shader_parameter("max_cell", 16.0)
		material.set_shader_parameter("progress", 0.0)
		return material

var _runtime: Node
var _presenter: StagePresenter
var _context: ScenarioContext
var _original_stage_root := ""
var _original_snapshot: Dictionary
var _original_skip_active := false
var _receipts: Array[Dictionary] = []


func before_each() -> void:
	_runtime = get_tree().root.get_node("StellaRuntime")
	_original_stage_root = _runtime.stage_assets_path
	_original_snapshot = _runtime.presentation_state.capture_snapshot()
	_original_skip_active = _runtime.skip_controller.is_active
	_runtime.skip_controller.is_active = false
	_runtime.stage_assets_path = STAGE_ROOT
	_runtime.presentation_state.clear()
	SignalBus.reset_stage_visuals()
	_presenter = StagePresenter.new()
	add_child_autoqfree(_presenter)
	var scenario := ScenarioData.new()
	scenario.id = "stage_transition_lifecycle"
	scenario.source_path = SOURCE_PATH
	var scene := SceneData.new()
	scene.id = "start"
	scenario.scenes.append(scene)
	_context = ScenarioContext.new(scenario)
	_receipts.clear()
	SignalBus.stage_transition_receipt_started.connect(_on_receipt)


func after_each() -> void:
	if SignalBus.stage_transition_receipt_started.is_connected(_on_receipt):
		SignalBus.stage_transition_receipt_started.disconnect(_on_receipt)
	SignalBus.reset_stage_visuals()
	_runtime.presentation_state.restore_snapshot(_original_snapshot)
	_runtime.stage_assets_path = _original_stage_root
	_runtime.skip_controller.is_active = _original_skip_active


func _on_receipt(
	presenter_instance_id: int,
	layer_id: String,
	token: int,
	operation_request_id: int,
	generation: int,
) -> void:
	if presenter_instance_id != _presenter.get_instance_id():
		return
	_receipts.append({
		"presenter_instance_id": presenter_instance_id,
		"layer_id": layer_id,
		"token": token,
		"operation_request_id": operation_request_id,
		"generation": generation,
	})


func _operation(
	action: String,
	layer_id: String,
	properties: Dictionary,
	transition: String,
	transition_params: Dictionary,
	duration: float,
	line: int,
) -> StagePresentationOperation:
	return StagePresentationOperation.new({
		"action": action,
		"id": layer_id,
		"properties": properties,
		"transition": transition,
		"transition_params": transition_params,
		"duration": duration,
	}, {"source_path": SOURCE_PATH, "line": line})


func _submit(
	operation: StagePresentationOperation,
	policy: PresentationBatchRequest.Policy,
) -> PresentationBatchRequest:
	var operations: Array[PresentationOperation] = [operation]
	return _submit_operations(operations, policy)


func _submit_operations(
	operations: Array[PresentationOperation],
	policy: PresentationBatchRequest.Policy,
) -> PresentationBatchRequest:
	var source := (
		operations[0].get_source() if not operations.is_empty() else {})
	return _runtime.presentation_director.submit(
		operations,
		policy,
		_context,
		source,
	)


func _visibility_operation(action: String, line: int) -> PresentationOperation:
	return DialogueVisibilityPresentationOperation.new({
		"target": "surface",
		"action": action,
		"transition": "cut",
		"duration": 0.0,
	}, {"source_path": SOURCE_PATH, "line": line})


func _show_source(layer_id: String = "event") -> void:
	SignalBus.emit_stage_operations([{
		"action": "show",
		"id": layer_id,
		"properties": {"asset": "stage:redraw_source"},
		"transition": "cut",
		"transition_params": {},
		"duration": 0.0,
	}], true)


func _take_receipts() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for value: Variant in _receipts:
		result.append((value as Dictionary).duplicate(true))
	_receipts.clear()
	return result


func _finish_receipts(records: Array[Dictionary]) -> void:
	SignalBus.stage_transition_receipts_finish_requested.emit(
		records.duplicate(true))


func test_missing_rule_mask_fails_at_child_source_before_stage_mutation() -> void:
	_show_source()
	var before: Dictionary = _runtime.presentation_state.stage_layers.duplicate(true)
	var before_node := _presenter.get_layer_node("event")
	var request := _submit(_operation(
		"update",
		"event",
		{"asset": "stage:redraw_blur_order"},
		"rule",
		{"mask": "stage:definitely_missing", "softness": 0.0, "invert": false},
		1.0,
		19,
	), PresentationBatchRequest.Policy.JOIN)
	assert_push_error(SOURCE_PATH + ":19")
	assert_push_error("[runtime] Stage request rejected: presenter ")
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_eq(_runtime.presentation_state.stage_layers, before)
	assert_same(_presenter.get_layer_node("event"), before_node)
	assert_true(_presenter._layer_tweens.is_empty())
	assert_true(_presenter._layer_transition_projections.is_empty())


func test_apply_readiness_barrier_rejects_late_participant_material_atomically() -> void:
	var second_presenter := StagePresenter.new()
	add_child_autoqfree(second_presenter)
	_show_source()
	# Keep a pre-existing owner live on the first participant. A rejected typed
	# transaction must not cut, replace, or republish that private lifecycle.
	_presenter._apply_operations([{
		"action": "update",
		"id": "event",
		"properties": {"opacity": 0.75},
		"transition": "fade",
		"transition_params": {},
		"duration": 10.0,
	}], false)
	var active_tween: Tween = _presenter._layer_tweens.get("event")
	var active_token := int(_presenter._layer_transition_tokens.get("event", -1))
	var active_generation := int(_presenter._layer_transition_generations.get(
		"event", -1))
	_receipts.clear()
	var before_state: Dictionary = _runtime.presentation_state.capture_snapshot()
	var first_before: Dictionary = _presenter._states.duplicate(true)
	var second_before: Dictionary = second_presenter._states.duplicate(true)
	var raw_dispatches := [0]
	var on_stage := func(_operations: Array, _force_cut: bool) -> void:
		raw_dispatches[0] += 1
	SignalBus.stage_operations_requested.connect(on_stage)
	var prepared_holders: Array[WeakRef] = []
	var invalidated := [false]
	var invalidate_second := func(request: StageOperationRequest) -> void:
		if invalidated[0] or not request.is_target(second_presenter):
			return
		var plan := request.get_plan(second_presenter)
		var operation_plans: Array = plan.get("operation_plans", [])
		if operation_plans.size() < 2:
			return
		var projections: Array = (operation_plans[1] as Dictionary).get(
			"projections", [])
		if projections.is_empty():
			return
		var prepared: Dictionary = (projections[0] as Dictionary).get(
			"prepared", {})
		var holder := prepared.get("holder") as Node2D
		var material := prepared.get("material") as ShaderMaterial
		if holder == null or material == null:
			return
		prepared_holders.append(weakref(holder))
		material.shader = null
		invalidated[0] = true
	# Put an ordinary listener between the two Presenter claim handlers. The
	# first participant may claim its sealed plan, but no participant may mutate
	# until the later participant has also claimed successfully.
	var second_claim := Callable(second_presenter, "_on_stage_apply_requested")
	SignalBus.stage_apply_requested.disconnect(second_claim)
	SignalBus.stage_apply_requested.connect(invalidate_second)
	SignalBus.stage_apply_requested.connect(second_claim)
	var operations: Array[PresentationOperation] = [
		_operation(
			"show", "must_not_commit", {"asset": "stage:redraw_source"},
			"cut", {}, 0.0, 25),
		_operation(
			"update", "event", {"asset": "stage:redraw_blur_order"},
			"rule",
			{"mask": "stage:redraw_mask", "softness": 0.0, "invert": false},
			1.0, 26),
	]
	var request := _submit_operations(
		operations, PresentationBatchRequest.Policy.JOIN)
	assert_push_error(SOURCE_PATH + ":26")
	SignalBus.stage_apply_requested.disconnect(invalidate_second)
	SignalBus.stage_operations_requested.disconnect(on_stage)
	assert_true(invalidated[0])
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_eq(raw_dispatches[0], 0)
	assert_eq(_receipts, [])
	assert_eq(_runtime.presentation_state.capture_snapshot(), before_state)
	assert_eq(_presenter._states, first_before)
	assert_eq(second_presenter._states, second_before)
	assert_same(_presenter._layer_tweens.get("event"), active_tween)
	assert_eq(int(_presenter._layer_transition_tokens.get("event", -1)), active_token)
	assert_eq(int(_presenter._layer_transition_generations.get(
		"event", -1)), active_generation)
	assert_true(second_presenter._layer_tweens.is_empty())
	assert_true(_presenter._pending_stage_request_plans.is_empty())
	assert_true(second_presenter._pending_stage_request_plans.is_empty())
	assert_eq(_presenter._pending_transition_snapshot_bytes, 0)
	assert_eq(second_presenter._pending_transition_snapshot_bytes, 0)
	assert_eq(prepared_holders.size(), 1)
	if not prepared_holders.is_empty():
		assert_null(prepared_holders[0].get_ref())


func test_receipt_publication_reset_suppresses_stale_raw_and_keeps_new_boundary() -> void:
	_show_source()
	_receipts.clear()
	var restored: Dictionary = _runtime.presentation_state.stage_layers.duplicate(true)
	var raw_dispatches := [0]
	var reset_once := [false]
	var on_stage := func(_operations: Array, _force_cut: bool) -> void:
		raw_dispatches[0] += 1
	var on_receipt_reset := func(
		presenter_instance_id: int,
		layer_id: String,
		_token: int,
		_operation_request_id: int,
		_generation: int,
	) -> void:
		if (
			reset_once[0]
			or presenter_instance_id != _presenter.get_instance_id()
			or layer_id != "event"
		):
			return
		reset_once[0] = true
		_runtime.presentation_state.stage_layers = restored.duplicate(true)
		SignalBus.reset_and_apply_stage_state(restored)
	SignalBus.stage_operations_requested.connect(on_stage)
	SignalBus.stage_transition_receipt_started.connect(on_receipt_reset)
	var request := _submit(_operation(
		"update", "event", {"asset": "stage:redraw_blur_order"},
		"rule",
		{"mask": "stage:redraw_mask", "softness": 0.0, "invert": false},
		10.0, 28,
	), PresentationBatchRequest.Policy.JOIN)
	SignalBus.stage_transition_receipt_started.disconnect(on_receipt_reset)
	SignalBus.stage_operations_requested.disconnect(on_stage)
	assert_true(reset_once[0])
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.CANCELLED)
	assert_eq(raw_dispatches[0], 0)
	assert_eq(_runtime.presentation_state.stage_layers, restored)
	assert_eq(_presenter.get_layer_state("event")["asset"], "stage:redraw_source")
	assert_true(_presenter._layer_tweens.is_empty())
	assert_true(_presenter._layer_transition_projections.is_empty())
	assert_true(_presenter._pending_stage_request_plans.is_empty())
	assert_true(_presenter._held_stage_transactions.is_empty())
	assert_eq(_presenter._pending_transition_snapshot_bytes, 0)
	assert_eq(_presenter._active_transition_snapshot_bytes, 0)


func test_publication_retirement_suppresses_raw_and_rolls_back_live_presenter() -> void:
	var second_presenter := StagePresenter.new()
	add_child_autoqfree(second_presenter)
	_show_source()
	_receipts.clear()
	var before: Dictionary = _runtime.presentation_state.stage_layers.duplicate(true)
	var first_before: Dictionary = _presenter._states.duplicate(true)
	var raw_dispatches := [0]
	var retired := [false]
	var on_stage := func(_operations: Array, _force_cut: bool) -> void:
		raw_dispatches[0] += 1
	var retire_second := func(
		presenter_instance_id: int,
		layer_id: String,
		_token: int,
		_operation_request_id: int,
		_generation: int,
	) -> void:
		if (
			retired[0]
			or presenter_instance_id != _presenter.get_instance_id()
			or layer_id != "event"
		):
			return
		retired[0] = true
		second_presenter.get_parent().remove_child(second_presenter)
	SignalBus.stage_operations_requested.connect(on_stage)
	SignalBus.stage_transition_receipt_started.connect(retire_second)
	var request := _submit(_operation(
		"update", "event", {"asset": "stage:redraw_blur_order"},
		"mosaic", {"cell": 24}, 10.0, 29,
	), PresentationBatchRequest.Policy.JOIN)
	SignalBus.stage_transition_receipt_started.disconnect(retire_second)
	SignalBus.stage_operations_requested.disconnect(on_stage)
	assert_true(retired[0])
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_eq(raw_dispatches[0], 0)
	assert_eq(_runtime.presentation_state.stage_layers, before)
	assert_eq(_presenter._states, first_before)
	assert_true(_presenter._layer_tweens.is_empty())
	assert_true(_presenter._layer_transition_projections.is_empty())
	assert_true(_presenter._pending_stage_request_plans.is_empty())
	assert_true(_presenter._held_stage_transactions.is_empty())
	assert_eq(_presenter._pending_transition_snapshot_bytes, 0)
	assert_eq(_presenter._active_transition_snapshot_bytes, 0)
	assert_null(second_presenter.get_parent())
	assert_true(second_presenter._pending_stage_request_plans.is_empty())
	assert_true(second_presenter._held_stage_transactions.is_empty())
	assert_eq(second_presenter._pending_transition_snapshot_bytes, 0)
	assert_eq(second_presenter._active_transition_snapshot_bytes, 0)


func test_director_reservation_is_authority_bound_and_single_consume() -> void:
	var director: PresentationDirector = _runtime.presentation_director
	var raw_dispatches := [0]
	var on_stage := func(_operations: Array, _force_cut: bool) -> void:
		raw_dispatches[0] += 1
	SignalBus.stage_operations_requested.connect(on_stage)
	var reservation := director.reserve_request()
	var request_id := reservation.get_request_id()
	var operation := _operation(
		"show", "reserved_once", {"asset": "stage:redraw_source"},
		"cut", {}, 0.0, 30)
	var operations: Array[PresentationOperation] = [operation]
	var request := director.submit(
		operations,
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
		_context,
		operation.get_source(),
		true,
		reservation,
	)
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(request.get_batch_id(), request_id)
	assert_eq(raw_dispatches[0], 1)
	assert_false(reservation.is_active())
	assert_true(director._pending_request_reservations.is_empty())

	var second := director.submit(
		operations,
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
		_context,
		{"source_path": SOURCE_PATH, "line": 31},
		true,
		reservation,
	)
	assert_push_error(SOURCE_PATH + ":31")
	assert_true(second.is_settled())
	assert_eq(second.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_eq(raw_dispatches[0], 1)

	var fabricated := PresentationRequestReservation.new()
	var fabricated_request := director.submit(
		operations,
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
		_context,
		{"source_path": SOURCE_PATH, "line": 32},
		true,
		fabricated,
	)
	assert_push_error(SOURCE_PATH + ":32")
	assert_eq(fabricated_request.get_outcome(), PresentationBatchRequest.Outcome.FAILED)

	var foreign_director := PresentationDirector.new()
	var foreign := foreign_director.reserve_request()
	var foreign_request := director.submit(
		operations,
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
		_context,
		{"source_path": SOURCE_PATH, "line": 33},
		true,
		foreign,
	)
	assert_push_error(SOURCE_PATH + ":33")
	assert_eq(foreign_request.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_true(foreign_director.abandon_request_reservation(foreign))
	assert_true(foreign_director._pending_request_reservations.is_empty())
	foreign_director.cancel_all()
	SignalBus.stage_operations_requested.disconnect(on_stage)


func test_cancelled_reservation_and_active_raw_id_collision_fail_before_submit() -> void:
	var director: PresentationDirector = _runtime.presentation_director
	var operation := _operation(
		"show", "reservation_rejected", {"asset": "stage:redraw_source"},
		"cut", {}, 0.0, 34)
	var operations: Array[PresentationOperation] = [operation]
	var cancelled := director.reserve_request()
	director.cancel_all()
	var cancelled_request := director.submit(
		operations,
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
		_context,
		{"source_path": SOURCE_PATH, "line": 34},
		true,
		cancelled,
	)
	assert_push_error(SOURCE_PATH + ":34")
	assert_eq(cancelled_request.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_false(cancelled.is_active())

	var collision := director.reserve_request()
	var collision_id := collision.get_request_id()
	var collision_request: Array[PresentationBatchRequest] = [null]
	var collided := [false]
	var on_stage := func(raw_operations: Array, _force_cut: bool) -> void:
		if (
			collided[0]
			or raw_operations.is_empty()
			or String(raw_operations[0].get("id", "")) != "raw_collision"
		):
			return
		collided[0] = true
		assert_true(SignalBus.is_stage_operation_request_active(collision_id))
		collision_request[0] = director.submit(
			operations,
			PresentationBatchRequest.Policy.FIRE_AND_FORGET,
			_context,
			{"source_path": SOURCE_PATH, "line": 35},
			true,
			collision,
		)
	SignalBus.stage_operations_requested.connect(on_stage)
	SignalBus.emit_stage_operations([{
		"action": "show",
		"id": "raw_collision",
		"properties": {"asset": "stage:redraw_source"},
		"transition": "cut",
		"transition_params": {},
		"duration": 0.0,
	}], true, collision_id)
	assert_push_error(SOURCE_PATH + ":35")
	SignalBus.stage_operations_requested.disconnect(on_stage)
	assert_true(collided[0])
	assert_not_null(collision_request[0])
	assert_true(collision_request[0].is_settled())
	assert_eq(
		collision_request[0].get_outcome(),
		PresentationBatchRequest.Outcome.FAILED,
	)
	assert_false(collision.is_active())
	assert_false(director._entries.has(collision_id))
	assert_true(director._pending_request_reservations.is_empty())
	assert_true(_runtime.presentation_state.stage_layers.has("raw_collision"))
	assert_false(_runtime.presentation_state.stage_layers.has("reservation_rejected"))


func test_participant_rejection_settles_all_reserved_stage_plans() -> void:
	_show_source()
	_receipts.clear()
	var before_state: Dictionary = _runtime.presentation_state.capture_snapshot()
	var first_before: Dictionary = _presenter._states.duplicate(true)
	var raw_stage := [0]
	var raw_visibility := [0]
	var on_stage := func(_operations: Array, _force_cut: bool) -> void:
		raw_stage[0] += 1
	var on_visibility := func(_operations: Array, _force_cut: bool) -> void:
		raw_visibility[0] += 1
	SignalBus.stage_operations_requested.connect(on_stage)
	SignalBus.dialogue_visibility_operations_requested.connect(on_visibility)
	var detached_holders: Array[WeakRef] = []
	var capture_first_plan := func(request: StageOperationRequest) -> void:
		if not request.is_target(_presenter):
			return
		var plan := request.get_plan(_presenter)
		for operation_plan_value: Variant in plan.get("operation_plans", []):
			var operation_plan: Dictionary = operation_plan_value
			for projection_value: Variant in operation_plan.get("projections", []):
				var projection: Dictionary = projection_value
				var prepared: Dictionary = projection.get("prepared", {})
				var holder := prepared.get("holder") as Node2D
				if holder != null:
					detached_holders.append(weakref(holder))
	SignalBus.stage_validate_requested.connect(capture_first_plan)
	var rejecting_presenter := StagePresenter.new()
	rejecting_presenter._transition_registry._providers.erase("rule")
	add_child_autoqfree(rejecting_presenter)
	var operations: Array[PresentationOperation] = [
		_operation(
			"update", "event", {"asset": "stage:redraw_blur_order"},
			"rule",
			{"mask": "stage:redraw_mask", "softness": 0.0, "invert": false},
			1.0, 31),
		_visibility_operation("hide", 32),
	]
	var request := _submit_operations(
		operations, PresentationBatchRequest.Policy.JOIN)
	assert_push_error(SOURCE_PATH + ":31")
	assert_push_error("[runtime] Stage request rejected: presenter ")
	SignalBus.stage_validate_requested.disconnect(capture_first_plan)
	SignalBus.stage_operations_requested.disconnect(on_stage)
	SignalBus.dialogue_visibility_operations_requested.disconnect(on_visibility)
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_gt(detached_holders.size(), 0)
	for holder_ref: WeakRef in detached_holders:
		assert_null(holder_ref.get_ref())
	assert_true(_presenter._pending_stage_request_plans.is_empty())
	assert_true(_presenter._pending_stage_preflight_states.is_empty())
	assert_eq(_presenter._pending_transition_snapshot_bytes, 0)
	assert_eq(_presenter._states, first_before)
	assert_eq(_runtime.presentation_state.capture_snapshot(), before_state)
	assert_eq(raw_stage[0], 0)
	assert_eq(raw_visibility[0], 0)
	assert_eq(_receipts, [])


func test_participant_retirement_before_accept_releases_every_reserved_plan() -> void:
	var second_holder: Array[StagePresenter] = [null]
	var retired := [false]
	var retire_second := func(request: StageOperationRequest) -> void:
		var second: StagePresenter = second_holder[0]
		if retired[0] or second == null or not request.is_target(second):
			return
		retired[0] = true
		second.get_parent().remove_child(second)
	SignalBus.stage_accept_requested.connect(retire_second)
	var second_presenter := StagePresenter.new()
	second_holder[0] = second_presenter
	add_child_autoqfree(second_presenter)
	_show_source()
	_receipts.clear()
	var before_state: Dictionary = _runtime.presentation_state.capture_snapshot()
	var first_before: Dictionary = _presenter._states.duplicate(true)
	var second_before: Dictionary = second_presenter._states.duplicate(true)
	var raw_dispatches := [0]
	var on_stage := func(_operations: Array, _force_cut: bool) -> void:
		raw_dispatches[0] += 1
	SignalBus.stage_operations_requested.connect(on_stage)
	var request := _submit(_operation(
		"update", "event", {"asset": "stage:redraw_blur_order"},
		"rule",
		{"mask": "stage:redraw_mask", "softness": 0.0, "invert": false},
		1.0, 35,
	), PresentationBatchRequest.Policy.JOIN)
	assert_push_error(SOURCE_PATH + ":35")
	SignalBus.stage_operations_requested.disconnect(on_stage)
	SignalBus.stage_accept_requested.disconnect(retire_second)
	assert_true(retired[0])
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_eq(raw_dispatches[0], 0)
	assert_eq(_receipts, [])
	assert_eq(_runtime.presentation_state.capture_snapshot(), before_state)
	assert_eq(_presenter._states, first_before)
	assert_eq(second_presenter._states, second_before)
	assert_true(_presenter._pending_stage_request_plans.is_empty())
	assert_true(second_presenter._pending_stage_request_plans.is_empty())
	assert_eq(_presenter._pending_transition_snapshot_bytes, 0)
	assert_eq(second_presenter._pending_transition_snapshot_bytes, 0)
	assert_null(second_presenter.get_parent())


func test_separated_stage_runs_preflight_against_authored_shadow_in_order() -> void:
	_receipts.clear()
	var captured_source_textures: Array[Texture2D] = []
	var capture_second_run := func(request: StageOperationRequest) -> void:
		if (
			not request.is_target(_presenter)
			or request.get_preflight_run_index() != 1
		):
			return
		var plan := request.get_plan(_presenter)
		var operation_plans: Array = plan.get("operation_plans", [])
		if operation_plans.is_empty():
			return
		var projections: Array = (operation_plans[0] as Dictionary).get(
			"projections", [])
		if projections.is_empty():
			return
		var source_root := (projections[0] as Dictionary).get(
			"source_root") as Node2D
		if source_root == null:
			return
		var source_sprite := source_root.get_node_or_null(
			"Composite/Source/AssetSprite") as Sprite2D
		if source_sprite != null and source_sprite.texture != null:
			captured_source_textures.append(source_sprite.texture)
	SignalBus.stage_accept_requested.connect(capture_second_run)
	var operations: Array[PresentationOperation] = [
		_operation(
			"show", "chain", {"asset": "stage:redraw_source"},
			"cut", {}, 0.0, 37),
		_visibility_operation("show", 38),
		_operation(
			"update", "chain", {"asset": "stage:redraw_blur_order"},
			"mosaic", {"cell": 24}, 10.0, 39),
	]
	var request := _submit_operations(
		operations, PresentationBatchRequest.Policy.JOIN)
	SignalBus.stage_accept_requested.disconnect(capture_second_run)
	assert_false(request.is_settled())
	assert_eq(captured_source_textures.size(), 1)
	if not captured_source_textures.is_empty():
		assert_same(
			captured_source_textures[0],
			_presenter._load_stage_transition_texture("stage:redraw_source"),
			"the later projection snapshots the preceding Stage run target",
		)
	assert_eq(_runtime.presentation_state.stage_layers["chain"]["asset"],
		"stage:redraw_blur_order")
	assert_eq(_receipts.size(), 1)
	_finish_receipts(_take_receipts())
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_true(_presenter._pending_stage_preflight_states.is_empty())


func test_invalid_later_separated_stage_run_rejects_entire_mixed_batch() -> void:
	var before_state: Dictionary = _runtime.presentation_state.capture_snapshot()
	var before_presenter: Dictionary = _presenter._states.duplicate(true)
	_receipts.clear()
	var raw_stage := [0]
	var raw_visibility := [0]
	var on_stage := func(_operations: Array, _force_cut: bool) -> void:
		raw_stage[0] += 1
	var on_visibility := func(_operations: Array, _force_cut: bool) -> void:
		raw_visibility[0] += 1
	SignalBus.stage_operations_requested.connect(on_stage)
	SignalBus.dialogue_visibility_operations_requested.connect(on_visibility)
	var operations: Array[PresentationOperation] = [
		_operation(
			"show", "chain_invalid", {"asset": "stage:redraw_source"},
			"cut", {}, 0.0, 43),
		_visibility_operation("hide", 44),
		_operation(
			"update", "chain_invalid", {"asset": "stage:redraw_blur_order"},
			"rule",
			{"mask": "stage:definitely_missing", "softness": 0.0, "invert": false},
			1.0, 45),
	]
	var request := _submit_operations(
		operations, PresentationBatchRequest.Policy.JOIN)
	assert_push_error(SOURCE_PATH + ":45")
	assert_push_error("[runtime] Stage request rejected: presenter ")
	SignalBus.stage_operations_requested.disconnect(on_stage)
	SignalBus.dialogue_visibility_operations_requested.disconnect(on_visibility)
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_eq(_runtime.presentation_state.capture_snapshot(), before_state)
	assert_eq(_presenter._states, before_presenter)
	assert_eq(raw_stage[0], 0)
	assert_eq(raw_visibility[0], 0)
	assert_eq(_receipts, [])
	assert_true(_presenter._pending_stage_request_plans.is_empty())
	assert_true(_presenter._pending_stage_preflight_states.is_empty())
	assert_eq(_presenter._pending_transition_snapshot_bytes, 0)


func test_typed_stage_request_without_presenter_fails_closed() -> void:
	var participants := SignalBus._stage_participant_snapshot()
	assert_eq(participants.size(), 1,
		"the focused harness owns one explicit Runtime StagePresenter")
	var presenter_parent := _presenter.get_parent()
	presenter_parent.remove_child(_presenter)
	assert_eq(SignalBus._stage_participant_snapshot(), [])
	var before_state: Dictionary = _runtime.presentation_state.capture_snapshot()
	var raw_dispatches := [0]
	var on_stage := func(_operations: Array, _force_cut: bool) -> void:
		raw_dispatches[0] += 1
	SignalBus.stage_operations_requested.connect(on_stage)
	var request := _submit(_operation(
		"show", "no_presenter", {"asset": "stage:redraw_source"},
		"mosaic", {"cell": 24}, 1.0, 51,
	), PresentationBatchRequest.Policy.JOIN)
	assert_push_error(SOURCE_PATH + ":51")
	SignalBus.stage_operations_requested.disconnect(on_stage)
	presenter_parent.add_child(_presenter)
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_eq(raw_dispatches[0], 0)
	assert_eq(_runtime.presentation_state.capture_snapshot(), before_state)
	assert_eq(_receipts, [])


func test_mosaic_join_uses_existing_exact_receipt_and_releases_snapshot_budget() -> void:
	_show_source()
	var request := _submit(_operation(
		"update",
		"event",
		{"asset": "stage:redraw_blur_order"},
		"mosaic",
		{"cell": 24},
		10.0,
		24,
	), PresentationBatchRequest.Policy.JOIN)
	assert_false(request.is_settled())
	assert_eq(_receipts.size(), 1)
	assert_true(_presenter._layer_transition_projections.has("event"))
	assert_gt(_presenter._active_transition_snapshot_bytes, 0)
	assert_eq(
		_runtime.presentation_state.stage_layers["event"]["asset"],
		"stage:redraw_blur_order",
		"canonical target commits at authored apply, not at Tween completion",
	)
	SignalBus.stage_transition_receipts_finish_requested.emit(_receipts.duplicate(true))
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_true(_presenter._layer_transition_projections.is_empty())
	assert_eq(_presenter._active_transition_snapshot_bytes, 0)
	assert_eq(
		_presenter.get_layer_state("event")["asset"],
		"stage:redraw_blur_order",
	)


func test_rule_fire_and_forget_does_not_claim_ordinary_advance() -> void:
	_show_source()
	var request := _submit(_operation(
		"update",
		"event",
		{"asset": "stage:redraw_blur_order"},
		"rule",
		{"mask": "stage:redraw_mask", "softness": 0.1, "invert": false},
		10.0,
		31,
	), PresentationBatchRequest.Policy.FIRE_AND_FORGET)
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(_receipts.size(), 1)
	var token := int(_receipts[0]["token"])
	SignalBus.emit_advance_requested()
	assert_eq(
		int(_presenter._layer_transition_tokens.get("event", -1)),
		token,
		"FNF does not consume or replay ordinary advance",
	)
	SignalBus.stage_transition_receipts_finish_requested.emit(_receipts.duplicate(true))
	assert_true(_presenter._layer_transition_tokens.is_empty())


func test_mid_transition_restore_cuts_to_sealed_target_and_rejects_old_receipt() -> void:
	_show_source()
	var request := _submit(_operation(
		"update",
		"event",
		{"asset": "stage:redraw_blur_order"},
		"mosaic",
		{"cell": 32},
		10.0,
		37,
	), PresentationBatchRequest.Policy.FIRE_AND_FORGET)
	assert_true(request.is_settled())
	var stale_receipts := _receipts.duplicate(true)
	var target: Dictionary = _runtime.presentation_state.stage_layers.duplicate(true)
	SignalBus.reset_and_apply_stage_state(target)
	assert_true(_presenter._layer_transition_tokens.is_empty())
	assert_true(_presenter._layer_transition_projections.is_empty())
	assert_eq(_presenter.get_layer_state("event")["asset"], "stage:redraw_blur_order")
	SignalBus.stage_transition_receipts_finish_requested.emit(stale_receipts)
	assert_eq(_presenter.get_layer_state("event")["asset"], "stage:redraw_blur_order")
	assert_true(_presenter._layer_transition_tokens.is_empty())


func test_projection_effects_cover_show_hide_remove_and_clear() -> void:
	var show_request := _submit(_operation(
		"show", "event", {"asset": "stage:redraw_source"},
		"rule", {"mask": "stage:redraw_mask", "softness": 0.0, "invert": false},
		10.0, 43,
	), PresentationBatchRequest.Policy.FIRE_AND_FORGET)
	assert_true(show_request.is_settled())
	var show_receipts := _take_receipts()
	assert_eq(show_receipts.size(), 1)
	_finish_receipts(show_receipts)
	assert_true(_presenter.get_layer_node("event").visible)

	var hide_request := _submit(_operation(
		"hide", "event", {}, "mosaic", {"cell": 20}, 10.0, 44,
	), PresentationBatchRequest.Policy.FIRE_AND_FORGET)
	assert_true(hide_request.is_settled())
	var hide_receipts := _take_receipts()
	assert_eq(hide_receipts.size(), 1)
	_finish_receipts(hide_receipts)
	assert_not_null(_presenter.get_layer_node("event"))
	assert_false(_presenter.get_layer_node("event").visible)

	var reveal_request := _submit(_operation(
		"show", "event", {},
		"rule", {"mask": "stage:redraw_mask", "softness": 0.15, "invert": true},
		10.0, 45,
	), PresentationBatchRequest.Policy.FIRE_AND_FORGET)
	assert_true(reveal_request.is_settled())
	var reveal_receipts := _take_receipts()
	assert_eq(reveal_receipts.size(), 1)
	_finish_receipts(reveal_receipts)
	assert_true(_presenter.get_layer_node("event").visible)

	var remove_request := _submit(_operation(
		"remove", "event", {}, "mosaic", {"cell": 48}, 10.0, 46,
	), PresentationBatchRequest.Policy.FIRE_AND_FORGET)
	assert_true(remove_request.is_settled())
	var remove_receipts := _take_receipts()
	assert_eq(remove_receipts.size(), 1)
	assert_not_null(_presenter.get_layer_node("event"),
		"remove keeps only its sealed outgoing projection until exact completion")
	_finish_receipts(remove_receipts)
	assert_null(_presenter.get_layer_node("event"))

	_show_source("left")
	_show_source("right")
	_receipts.clear()
	var clear_request := _submit(_operation(
		"clear", "", {},
		"rule", {"mask": "stage:redraw_mask", "softness": 0.0, "invert": false},
		10.0, 47,
	), PresentationBatchRequest.Policy.JOIN)
	assert_false(clear_request.is_settled())
	var clear_receipts := _take_receipts()
	assert_eq(clear_receipts.size(), 2)
	_finish_receipts(clear_receipts)
	assert_true(clear_request.is_settled())
	assert_eq(clear_request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_null(_presenter.get_layer_node("left"))
	assert_null(_presenter.get_layer_node("right"))


func test_overlap_replacement_rejects_old_rule_receipt_for_new_mosaic_owner() -> void:
	_show_source()
	_receipts.clear()
	var first := _submit(_operation(
		"update", "event", {"asset": "stage:redraw_blur_order"},
		"rule", {"mask": "stage:redraw_mask", "softness": 0.0, "invert": false},
		10.0, 52,
	), PresentationBatchRequest.Policy.FIRE_AND_FORGET)
	assert_true(first.is_settled())
	var first_receipts := _take_receipts()
	assert_eq(first_receipts.size(), 1)
	var second := _submit(_operation(
		"update", "event", {"asset": "stage:redraw_source"},
		"mosaic", {"cell": 32}, 10.0, 53,
	), PresentationBatchRequest.Policy.FIRE_AND_FORGET)
	assert_true(second.is_settled())
	var second_receipts := _take_receipts()
	assert_eq(second_receipts.size(), 1)
	assert_ne(first_receipts[0]["token"], second_receipts[0]["token"])
	assert_ne(first_receipts[0]["generation"], second_receipts[0]["generation"])
	var winning_token := int(second_receipts[0]["token"])
	_finish_receipts(first_receipts)
	assert_eq(int(_presenter._layer_transition_tokens["event"]), winning_token)
	assert_eq(_presenter.get_layer_state("event")["asset"], "stage:redraw_source")
	_finish_receipts(second_receipts)
	assert_true(_presenter._layer_transition_tokens.is_empty())


func test_click_finishes_only_current_projection_join_and_is_not_replayed() -> void:
	_show_source()
	_receipts.clear()
	var first := _submit(_operation(
		"update", "event", {"asset": "stage:redraw_blur_order"},
		"mosaic", {"cell": 32}, 10.0, 58,
	), PresentationBatchRequest.Policy.JOIN)
	assert_false(first.is_settled())
	SignalBus.emit_advance_requested()
	assert_true(first.is_settled())
	assert_eq(first.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	_receipts.clear()
	var second := _submit(_operation(
		"update", "event", {"asset": "stage:redraw_source"},
		"rule", {"mask": "stage:redraw_mask", "softness": 0.0, "invert": false},
		10.0, 59,
	), PresentationBatchRequest.Policy.JOIN)
	assert_false(second.is_settled(),
		"the first click cannot be replayed into a later sealed JOIN")
	assert_eq(_receipts.size(), 1)
	SignalBus.emit_advance_requested()
	assert_true(second.is_settled())
	assert_eq(second.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)


func test_persistent_skip_force_cuts_projection_without_receipt_or_advance() -> void:
	_show_source()
	_receipts.clear()
	_runtime.skip_controller.is_active = true
	var request := _submit(_operation(
		"update", "event", {"asset": "stage:redraw_blur_order"},
		"rule", {"mask": "stage:redraw_mask", "softness": 0.2, "invert": false},
		10.0, 64,
	), PresentationBatchRequest.Policy.JOIN)
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(request.get_receipts(), [])
	assert_eq(_receipts, [])
	assert_true(_presenter._layer_transition_projections.is_empty())
	assert_eq(_presenter.get_layer_state("event")["asset"],
		"stage:redraw_blur_order")
	_runtime.skip_controller.is_active = false


func test_explicit_facade_force_cut_keeps_typed_projection_preflight() -> void:
	_show_source()
	_receipts.clear()
	var provider := CountingProjectionProvider.new()
	assert_true(_presenter.register_transition_provider(provider))
	var original_engine: ScenarioEngine = _runtime.engine
	var facade_engine := ScenarioEngine.new()
	facade_engine.context = _context
	_runtime.engine = facade_engine
	var raw_dispatches: Array[Dictionary] = []
	var on_stage := func(operations: Array, force_cut: bool) -> void:
		raw_dispatches.append({
			"operations": operations.duplicate(true),
			"force_cut": force_cut,
		})
	SignalBus.stage_operations_requested.connect(on_stage)
	var payload := {
		"action": "update",
		"id": "event",
		"properties": {"asset": "stage:redraw_blur_order"},
		"transition": "counted_projection",
		"transition_params": {},
		"duration": 10.0,
	}
	_runtime.apply_stage_operations([payload], true)
	assert_eq(provider.validation_count, 1)
	assert_eq(raw_dispatches.size(), 1)
	assert_true(bool(raw_dispatches[0].get("force_cut", false)))
	assert_eq(_receipts, [])
	assert_true(_presenter._layer_tweens.is_empty())
	assert_true(_presenter._layer_transition_projections.is_empty())
	assert_eq(_presenter.get_layer_state("event")["asset"],
		"stage:redraw_blur_order")

	payload["properties"] = {"asset": "stage:redraw_source"}
	_runtime.apply_stage_operations([payload], false)
	assert_eq(provider.validation_count, 2)
	assert_eq(raw_dispatches.size(), 2)
	assert_false(bool(raw_dispatches[1].get("force_cut", true)))
	assert_eq(_receipts.size(), 1)
	_finish_receipts(_take_receipts())
	assert_true(_presenter.unregister_transition_provider(&"counted_projection"))
	var before: Dictionary = _runtime.presentation_state.stage_layers.duplicate(true)
	payload["properties"] = {"opacity": 0.25}
	_runtime.apply_stage_operations([payload], true)
	assert_push_error("counted_projection")
	assert_push_error("[runtime] Stage request rejected: presenter ")
	assert_eq(raw_dispatches.size(), 2)
	assert_eq(_runtime.presentation_state.stage_layers, before)
	assert_true(_presenter._layer_tweens.is_empty())
	assert_true(_presenter._layer_transition_projections.is_empty())
	SignalBus.stage_operations_requested.disconnect(on_stage)
	_runtime.engine = original_engine


func test_raw_projection_ingress_rejects_before_any_listener() -> void:
	_show_source()
	var before: Dictionary = _runtime.presentation_state.stage_layers.duplicate(true)
	var raw_dispatches := [0]
	var finished: Array[Dictionary] = []
	var on_stage := func(_operations: Array, _force_cut: bool) -> void:
		raw_dispatches[0] += 1
	var on_finished := func(request_id: int, delivered: bool) -> void:
		finished.append({"request_id": request_id, "delivered": delivered})
	SignalBus.stage_operations_requested.connect(on_stage)
	SignalBus.stage_operation_request_finished.connect(on_finished)
	SignalBus.emit_stage_operations([{
		"action": "update",
		"id": "event",
		"properties": {"opacity": 0.5},
		"transition": "mosaic",
		"transition_params": {"cell": 16},
		"duration": 0.0,
	}], true)
	assert_push_error("requires the typed PresentationDirector")
	assert_eq(raw_dispatches[0], 0)
	assert_eq(finished.size(), 1)
	assert_false(bool(finished[0].get("delivered", true)))
	assert_eq(_runtime.presentation_state.stage_layers, before)
	SignalBus.stage_operation_request_finished.disconnect(on_finished)
	SignalBus.stage_operations_requested.disconnect(on_stage)


func test_abort_cuts_to_canonical_target_and_retires_old_projection_owner() -> void:
	_show_source()
	_receipts.clear()
	var request := _submit(_operation(
		"update", "event", {"asset": "stage:redraw_blur_order"},
		"mosaic", {"cell": 32}, 10.0, 69,
	), PresentationBatchRequest.Policy.JOIN)
	assert_false(request.is_settled())
	var stale_receipts := _take_receipts()
	SignalBus.engine_abort_requested.emit()
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.CANCELLED)
	assert_true(_presenter._layer_transition_tokens.is_empty())
	assert_true(_presenter._layer_transition_projections.is_empty())
	assert_eq(_presenter.get_layer_state("event")["asset"],
		"stage:redraw_blur_order")
	_finish_receipts(stale_receipts)
	assert_eq(_presenter.get_layer_state("event")["asset"],
		"stage:redraw_blur_order")


func test_rollback_and_restart_restore_only_sealed_canonical_snapshots() -> void:
	_show_source()
	var before: Dictionary = _runtime.presentation_state.stage_layers.duplicate(true)
	_receipts.clear()
	var request := _submit(_operation(
		"update", "event", {"asset": "stage:redraw_blur_order"},
		"rule", {"mask": "stage:redraw_mask", "softness": 0.1, "invert": false},
		10.0, 74,
	), PresentationBatchRequest.Policy.JOIN)
	assert_false(request.is_settled())
	var stale_receipts := _take_receipts()
	_runtime.presentation_state.stage_layers = before.duplicate(true)
	SignalBus.reset_and_apply_stage_state(before)
	assert_true(request.is_settled())
	assert_eq(_presenter.get_layer_state("event")["asset"], "stage:redraw_source")
	_finish_receipts(stale_receipts)
	assert_eq(_presenter.get_layer_state("event")["asset"], "stage:redraw_source")

	_receipts.clear()
	var restart_owner := _submit(_operation(
		"update", "event", {"asset": "stage:redraw_blur_order"},
		"mosaic", {"cell": 32}, 10.0, 75,
	), PresentationBatchRequest.Policy.FIRE_AND_FORGET)
	assert_true(restart_owner.is_settled())
	var restart_stale := _take_receipts()
	_runtime.presentation_state.stage_layers.clear()
	SignalBus.reset_and_apply_stage_state({})
	assert_eq(_presenter.get_layer_ids(), [])
	assert_true(_presenter._layer_transition_projections.is_empty())
	_finish_receipts(restart_stale)
	assert_eq(_presenter.get_layer_ids(), [])


func test_scene_replacement_retires_receipt_then_projects_canonical_target() -> void:
	_show_source()
	_receipts.clear()
	var request := _submit(_operation(
		"update", "event", {"asset": "stage:redraw_blur_order"},
		"mosaic", {"cell": 32}, 10.0, 81,
	), PresentationBatchRequest.Policy.JOIN)
	assert_false(request.is_settled())
	var stale_receipts := _take_receipts()
	var target: Dictionary = _runtime.presentation_state.stage_layers.duplicate(true)
	var old_presenter := _presenter
	var old_parent := old_presenter.get_parent()
	old_parent.remove_child(old_presenter)
	assert_true(request.is_settled(),
		"Presenter exit publishes a terminal for every unreachable exact owner")
	assert_ne(request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	old_presenter.free()
	var replacement := StagePresenter.new()
	add_child_autoqfree(replacement)
	SignalBus.reset_and_apply_stage_state(target)
	assert_eq(replacement.get_layer_state("event")["asset"],
		"stage:redraw_blur_order")
	_finish_receipts(stale_receipts)
	assert_eq(replacement.get_layer_state("event")["asset"],
		"stage:redraw_blur_order")
	_presenter = replacement


func test_snapshot_budget_fails_before_projection_allocation_or_mutation() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(4096, 4096)
	viewport.transparent_bg = true
	viewport.disable_3d = true
	add_child_autoqfree(viewport)
	var presenter := StagePresenter.new()
	viewport.add_child(presenter)
	for layer_id in ["budget_a", "budget_b", "budget_c"]:
		presenter._apply_operations([{
			"action": "show",
			"id": layer_id,
			"properties": {"asset": "stage:redraw_source"},
			"transition": "cut",
			"transition_params": {},
			"duration": 0.0,
		}], true)
	var before := presenter._states.duplicate(true)
	var operation := _operation(
		"clear", "", {}, "mosaic", {"cell": 32}, 1.0, 87)
	var validation := presenter._build_stage_request_plan(
		StageOperationRequest.new([operation], false))
	assert_false(validation["valid"])
	assert_string_contains(String(validation["error"]), "budget")
	assert_eq(presenter._states, before)
	assert_true(presenter._layer_transition_projections.is_empty())
	assert_eq(presenter._active_transition_snapshot_bytes, 0)
	assert_eq(presenter._pending_transition_snapshot_bytes, 0)


func test_transition_texture_cache_is_bounded_lru_and_reuses_resources() -> void:
	var logical_ids := [
		"stage:redraw_source", "redraw_source",
		"stage:redraw_source.png", "redraw_source.png",
		"stage:redraw_mask", "redraw_mask",
		"stage:redraw_mask.png", "redraw_mask.png",
		"stage:redraw_blur_source", "redraw_blur_source",
		"stage:redraw_blur_source.png", "redraw_blur_source.png",
		"stage:redraw_blur_order", "redraw_blur_order",
		"stage:redraw_blur_order.png", "redraw_blur_order.png",
		"stage:redraw_blur_edge",
	]
	for index in range(StagePresenter.MAX_TRANSITION_TEXTURE_CACHE):
		assert_not_null(_presenter._load_stage_transition_texture(logical_ids[index]))
	var first_texture: Texture2D = (
		_presenter._transition_texture_cache[logical_ids[0]] as Texture2D)
	assert_same(
		_presenter._load_stage_transition_texture(logical_ids[0]), first_texture,
		"cache hits reuse the ResourceLoader texture and refresh LRU order",
	)
	assert_not_null(_presenter._load_stage_transition_texture(logical_ids[-1]))
	assert_eq(_presenter._transition_texture_cache.size(),
		StagePresenter.MAX_TRANSITION_TEXTURE_CACHE)
	assert_true(_presenter._transition_texture_cache.has(logical_ids[0]))
	assert_false(_presenter._transition_texture_cache.has(logical_ids[1]),
		"the least-recently used logical id is evicted exactly at the bound")
