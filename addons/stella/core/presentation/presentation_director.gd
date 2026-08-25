## Runtime-owned generic composition authority for typed presentation batches.
##
## The Director registers ownership before synchronous SignalBus delivery,
## seals the exact receipt set at the serialized dispatch tail, and settles a
## JOIN only from terminal acknowledgements for that sealed set.
class_name PresentationDirector extends RefCounted

const EXACT_STAGE_OPERATION_KEYS := [
	"action", "duration", "id", "properties", "transition",
]
const EXACT_DIALOGUE_VISIBILITY_KEYS := [
	"action", "duration", "target", "transition",
]

var _authority := RefCounted.new()
var _presentation_state: PresentationState
var _skip_active: Callable
var _entries: Dictionary = {}
var _external_blockers: Dictionary = {}
var _generation: int = 1
var _dialogue_visibility_reset_allows_next_apply: bool = false
var _retired_presentation_projection_lifecycle_id: int = 0


func _init(
	presentation_state: PresentationState = null,
	skip_active: Callable = Callable(),
) -> void:
	_presentation_state = presentation_state
	_skip_active = skip_active
	SignalBus.stage_transition_receipt_started.connect(
		_on_stage_transition_receipt_started)
	SignalBus.stage_operation_request_finished.connect(
		_on_stage_operation_request_finished)
	SignalBus.stage_transition_terminal.connect(_on_stage_transition_terminal)
	if SignalBus.has_signal(&"dialogue_visibility_transition_receipt_started"):
		(SignalBus.get(&"dialogue_visibility_transition_receipt_started") as Signal).connect(
			_on_dialogue_visibility_transition_receipt_started
		)
	if SignalBus.has_signal(&"presentation_operation_request_finished"):
		(SignalBus.get(&"presentation_operation_request_finished") as Signal).connect(
			_on_presentation_operation_request_finished
		)
	SignalBus.presentation_projection_lifecycle_finished.connect(
		_on_presentation_projection_lifecycle_finished
	)
	if SignalBus.has_signal(&"dialogue_visibility_transition_terminal"):
		(SignalBus.get(&"dialogue_visibility_transition_terminal") as Signal).connect(
			_on_dialogue_visibility_transition_terminal
		)
	if SignalBus.has_signal(&"dialogue_visibility_visuals_reset_requested"):
		(SignalBus.get(&"dialogue_visibility_visuals_reset_requested") as Signal).connect(
			_on_dialogue_visibility_visuals_reset_requested
		)
	if SignalBus.has_signal(&"dialogue_visibility_state_apply_requested"):
		(SignalBus.get(&"dialogue_visibility_state_apply_requested") as Signal).connect(
			_on_dialogue_visibility_state_apply_requested
		)
	SignalBus.advance_requested.connect(_on_advance_requested)
	SignalBus.stage_visuals_reset_requested.connect(
		_on_stage_visuals_reset_requested)
	SignalBus.engine_abort_requested.connect(_on_engine_abort_requested)


func submit(
	operations: Array[PresentationOperation],
	policy: PresentationBatchRequest.Policy,
	context: ScenarioContext,
	source: Dictionary,
) -> PresentationBatchRequest:
	var authored: Array = []
	for operation: PresentationOperation in operations:
		authored.append(operation)
	var request := PresentationBatchRequest.new(policy, authored)
	request._bind_authority(_authority)
	if not _context_accepts_submission(context):
		_report_submit_error(
			_diagnostic_source(source),
			"ScenarioContext is missing, cancelled, or not current",
		)
		request._settle(PresentationBatchRequest.Outcome.FAILED, _authority)
		return request
	var preflight := _preflight_operations(operations, policy)
	if not bool(preflight.get("valid", false)):
		_report_submit_error(
			_diagnostic_source(source),
			String(preflight.get("error", "invalid presentation batch")),
		)
		request._settle(PresentationBatchRequest.Outcome.FAILED, _authority)
		return request
	if bool(preflight.get("no_work", false)):
		var authored_targets: Array = preflight.get("dialogue_targets", [])
		var has_target_owner := false
		for target_value: Variant in authored_targets:
			if _has_active_dialogue_visibility_owner(String(target_value)):
				has_target_owner = true
				break
		if not has_target_owner:
			request._settle(PresentationBatchRequest.Outcome.COMPLETED, _authority)
			return request

	var request_id := SignalBus.reserve_stage_operation_request_id()
	var entry := {
		"request": request,
		"context": context,
		"source": _diagnostic_source(source),
		"previous_stage_layers": (
			preflight["before_state"] as Dictionary).duplicate(true),
		"previous_dialogue_visibility": (
			preflight["before_visibility"] as Dictionary).duplicate(true),
		"policy": policy,
		"receipts": [],
		"receipt_keys": {},
		"receipt_invalid": false,
		"terminal_keys": {},
		"sealed": false,
		"generation": _generation,
		"accept_advance_serial": SignalBus.current_advance_dispatch_serial(),
		"context_cancel": Callable(),
		"dialogue_targets": (preflight.get("dialogue_targets", []) as Array).duplicate(),
	}
	_entries[request_id] = entry
	if context != null:
		var on_context_cancel := func() -> void:
			_cancel_entry(request_id, PresentationBatchRequest.Outcome.CANCELLED)
		entry["context_cancel"] = on_context_cancel
		context.cancellation_requested.connect(on_context_cancel, CONNECT_ONE_SHOT)

	var payloads: Dictionary = preflight["payloads"]
	var force_cut := _is_skip_active()
	var stage_payloads: Array = payloads.get("stage", [])
	var visibility_payloads: Array = payloads.get("dialogue_visibility", [])
	if not visibility_payloads.is_empty():
		SignalBus.emit_presentation_operations(
			stage_payloads,
			visibility_payloads,
			force_cut,
			request_id,
		)
	elif not stage_payloads.is_empty():
		SignalBus.emit_stage_operations(stage_payloads, force_cut, request_id)
	return request


func has_blocking_waiter(context: ScenarioContext = null) -> bool:
	for request_id_value: Variant in _entries:
		var entry: Dictionary = _entries[request_id_value]
		var request: PresentationBatchRequest = entry["request"]
		if (
			int(entry["policy"]) == PresentationBatchRequest.Policy.JOIN
			and not request.is_settled()
			and (context == null or entry["context"] == context)
		):
			return true
	if context == null:
		return not _external_blockers.is_empty()
	return _external_blockers.has(context.get_instance_id())


## Cancel generic blocking work before a lifecycle reset. Reversible scene
## navigation may restore a Stage JOIN's pre-command canonical state so a
## rejected handoff can fresh-dispatch the retained cursor exactly once.
func cancel_blocking_waiters(
	context: ScenarioContext = null,
	restore_for_replay: bool = false,
) -> bool:
	var entry_snapshot: Dictionary = {}
	var blocker_snapshot: Dictionary = {}
	var had_blocking_waiter := false
	var restore_state: Dictionary = {}
	var restore_visibility: Dictionary = {}
	var has_stage_restore := false
	var has_visibility_restore := false
	for request_id_value: Variant in _entries.keys():
		var request_id := int(request_id_value)
		var entry: Dictionary = _entries[request_id]
		if context != null and entry.get("context") != context:
			continue
		entry_snapshot[request_id] = entry
		var request: PresentationBatchRequest = entry["request"]
		if (
			int(entry["policy"]) == PresentationBatchRequest.Policy.JOIN
			and not request.is_settled()
		):
			had_blocking_waiter = true
			if restore_for_replay and not has_stage_restore:
				var previous: Variant = entry.get("previous_stage_layers", {})
				if previous is Dictionary:
					restore_state = (previous as Dictionary).duplicate(true)
					has_stage_restore = true
			if restore_for_replay and not has_visibility_restore:
				var previous_visibility: Variant = entry.get(
					"previous_dialogue_visibility",
					{},
				)
				if previous_visibility is Dictionary:
					restore_visibility = (
						previous_visibility as Dictionary
					).duplicate(true)
					has_visibility_restore = true

	var context_ids: Array = (
		_external_blockers.keys().duplicate()
		if context == null
		else [context.get_instance_id()]
	)
	for context_id: Variant in context_ids:
		var blockers: Array = _external_blockers.get(context_id, [])
		if blockers.is_empty():
			continue
		blocker_snapshot[context_id] = blockers.duplicate()
		had_blocking_waiter = true

	# Retire the complete old lifecycle before any request settlement or external
	# blocker callback can synchronously install a winning replacement.
	_generation += 1
	for request_id_value: Variant in entry_snapshot:
		_entries.erase(int(request_id_value))
	for context_id: Variant in blocker_snapshot:
		_external_blockers.erase(context_id)
	for entry_value: Variant in entry_snapshot.values():
		_disconnect_entry_context(entry_value)
	if (
		restore_for_replay
		and _presentation_state != null
	):
		if has_stage_restore:
			_presentation_state.stage_layers = restore_state.duplicate(true)
		if has_visibility_restore:
			_presentation_state.dialogue_visibility = restore_visibility.duplicate(
				true
			)

	for request_id_value: Variant in entry_snapshot:
		_cancel_detached_entry(
			int(request_id_value),
			entry_snapshot[request_id_value],
			PresentationBatchRequest.Outcome.CANCELLED,
		)
	for context_id: Variant in blocker_snapshot:
		for blocker_value: Variant in blocker_snapshot[context_id]:
			var blocker: Dictionary = blocker_value
			var cancel: Callable = blocker.get("cancel", Callable())
			if cancel.is_valid():
				cancel.call()
	return had_blocking_waiter


func cancel_all() -> void:
	var entry_snapshot := _entries.duplicate()
	var blocker_snapshot := _external_blockers.duplicate(true)
	_generation += 1
	_entries.clear()
	_external_blockers.clear()
	for entry_value: Variant in entry_snapshot.values():
		_disconnect_entry_context(entry_value)
	for request_id_value: Variant in entry_snapshot:
		_cancel_detached_entry(
			int(request_id_value),
			entry_snapshot[request_id_value],
			PresentationBatchRequest.Outcome.CANCELLED,
		)
	for context_id: Variant in blocker_snapshot:
		for blocker_value: Variant in (
			blocker_snapshot.get(context_id, []) as Array
		):
			var cancel: Callable = (blocker_value as Dictionary).get(
				"cancel", Callable())
			if cancel.is_valid():
				cancel.call()


func _register_blocking_waiter(
	context: ScenarioContext,
	owner: Object,
	cancel: Callable,
) -> bool:
	if (
		not _context_accepts_submission(context)
		or owner == null
		or not cancel.is_valid()
	):
		return false
	var context_id := context.get_instance_id()
	var blockers: Array = _external_blockers.get(context_id, [])
	for blocker_value: Variant in blockers:
		if (blocker_value as Dictionary).get("owner") == owner:
			return false
	blockers.append({"owner": owner, "cancel": cancel})
	_external_blockers[context_id] = blockers
	return true


func _unregister_blocking_waiter(
	context: ScenarioContext,
	owner: Object,
) -> bool:
	if context == null or owner == null:
		return false
	var context_id := context.get_instance_id()
	var blockers: Array = _external_blockers.get(context_id, [])
	for index in range(blockers.size()):
		if (blockers[index] as Dictionary).get("owner") != owner:
			continue
		blockers.remove_at(index)
		if blockers.is_empty():
			_external_blockers.erase(context_id)
		else:
			_external_blockers[context_id] = blockers
		return true
	return false


func _preflight_operations(
	operations: Array[PresentationOperation],
	policy: PresentationBatchRequest.Policy,
) -> Dictionary:
	if policy not in [
		PresentationBatchRequest.Policy.JOIN,
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
	]:
		return {"valid": false, "error": "unsupported batch policy"}
	if operations.is_empty():
		return {"valid": false, "error": "operations must not be empty"}
	if _presentation_state == null:
		return {"valid": false, "error": "PresentationState is unavailable"}
	var stage_payloads: Array = []
	var visibility_payloads: Array = []
	var visibility_canonical_payloads: Array = []
	var seen_layers := {}
	var seen_targets := {}
	var saw_clear := false
	var saw_visibility := false
	for operation: PresentationOperation in operations:
		var payload := operation.get_payload() if operation != null else {}
		var payload_keys := payload.keys()
		payload_keys.sort()
		if operation is StagePresentationOperation:
			if payload_keys != EXACT_STAGE_OPERATION_KEYS:
				return {
					"valid": false,
					"error": "stage payload must use the canonical five-field schema",
				}
			if (
				not payload["action"] is String
				or not payload["id"] is String
				or not payload["properties"] is Dictionary
				or not payload["transition"] is String
				or not (
					payload["duration"] is int
					or payload["duration"] is float
				)
			):
				return {"valid": false, "error": "stage payload has invalid types"}
			var action := String(payload.get("action", ""))
			var raw_layer_id := String(payload.get("id", ""))
			var layer_id := raw_layer_id.strip_edges()
			var expected_channel := (
				"stage:*" if action == "clear" else "stage:%s" % layer_id
			)
			if (
				operation == null
				or raw_layer_id != layer_id
				or String(operation.get_channel()) != expected_channel
			):
				return {"valid": false, "error": "invalid typed Stage ownership"}
			if (
				action not in StageLayerState.VALID_ACTIONS
				or String(payload["transition"])
				not in StageLayerState.VALID_TRANSITIONS
				or not StageLayerState.validate_operation(payload, false)
			):
				return {"valid": false, "error": "stage payload is not canonical"}
			if action == "clear":
				if saw_clear or not stage_payloads.is_empty():
					return {"valid": false, "error": "clear must be the only Stage operation"}
				saw_clear = true
			elif layer_id == "*" or saw_clear or seen_layers.has(layer_id):
				return {
					"valid": false,
					"error": "duplicate or invalid Stage channel '%s'" % layer_id,
				}
			else:
				seen_layers[layer_id] = true
			stage_payloads.append(payload.duplicate(true))
		elif operation is DialogueVisibilityPresentationOperation:
			if payload_keys != EXACT_DIALOGUE_VISIBILITY_KEYS:
				return {
					"valid": false,
					"error": "dialogue visibility payload must use the canonical four-field schema",
				}
			var target := String(payload.get("target", "")).strip_edges()
			if (
				String(operation.get_channel()) != "dialogue:%s" % target
				or not DialogueVisibilityState.validate_operation(payload, false)
			):
				return {"valid": false, "error": "invalid typed dialogue visibility ownership"}
			if seen_targets.has(target):
				return {
					"valid": false,
					"error": "duplicate dialogue visibility channel '%s'" % target,
			}
			seen_targets[target] = true
			saw_visibility = true
			visibility_canonical_payloads.append(payload.duplicate(true))
			visibility_payloads.append(operation)
		else:
			return {"valid": false, "error": "unsupported presentation operation kind"}

	var before_state := _presentation_state.stage_layers.duplicate(true)
	var before_visibility := _presentation_state.dialogue_visibility.duplicate(true)
	var simulated := before_state.duplicate(true)
	for payload_value: Variant in stage_payloads:
		var payload: Dictionary = payload_value
		var action := String(payload["action"])
		var layer_id := String(payload["id"])
		if action in ["update", "hide"] and not simulated.has(layer_id):
			return {
				"valid": false,
				"error": "cannot %s unknown layer '%s'" % [action, layer_id],
			}
		simulated = StageLayerState.reduce(simulated, [payload], false)
	var target_visibility := DialogueVisibilityState.reduce(
		before_visibility,
		visibility_canonical_payloads,
		false,
	)
	return {
		"valid": true,
		"payloads": {
			"stage": stage_payloads,
			"dialogue_visibility": visibility_payloads,
		},
		"before_state": before_state,
		"before_visibility": before_visibility,
		"target_state": simulated,
		"target_visibility": target_visibility,
		"dialogue_targets": seen_targets.keys(),
		"no_work": (
			simulated == before_state
			and target_visibility == before_visibility
			and not saw_clear
		),
	}


func _has_active_dialogue_visibility_owner(target: String) -> bool:
	for request_id_value: Variant in _entries:
		var entry: Dictionary = _entries[request_id_value]
		if int(entry.get("generation", -1)) != _generation:
			continue
		if target not in (entry.get("dialogue_targets", []) as Array):
			continue
		var terminal_keys: Dictionary = entry.get("terminal_keys", {})
		if not bool(entry.get("sealed", false)):
			return true
		for receipt_value: Variant in entry.get("receipts", []):
			if not receipt_value is PresentationOperationReceipt:
				continue
			var receipt: PresentationOperationReceipt = receipt_value
			if (
				String(receipt.get_channel()) == "dialogue:%s" % target
				and not terminal_keys.has(_receipt_key(receipt))
			):
				return true
	return false


func _diagnostic_source(source: Dictionary) -> Dictionary:
	return {
		"source_path": String(source.get("source_path", "")),
		"scenario_id": String(source.get("scenario_id", "")),
		"line": int(source.get("line", 0)),
	}


func _report_submit_error(source: Dictionary, message: String) -> void:
	var source_path := String(source.get("source_path", "")).strip_edges()
	var scenario_id := String(source.get("scenario_id", "")).strip_edges()
	var label := source_path if not source_path.is_empty() else scenario_id
	var line := int(source.get("line", 0))
	if not label.is_empty() and line > 0:
		label = "%s:%d" % [label, line]
	elif label.is_empty() and line > 0:
		label = "line %d" % line
	elif label.is_empty():
		label = "runtime"
	push_error("[%s] PresentationDirector: %s" % [label, message])


func _on_stage_transition_receipt_started(
	presenter_instance_id: int,
	layer_id: String,
	token: int,
	operation_request_id: int,
	generation: int,
) -> void:
	var entry: Dictionary = _entries.get(operation_request_id, {})
	if (
		entry.is_empty()
		or bool(entry.get("sealed", false))
		or int(entry.get("generation", -1)) != _generation
	):
		return
	if (
		presenter_instance_id <= 0
		or layer_id != layer_id.strip_edges()
		or layer_id.is_empty()
		or layer_id == "*"
		or token <= 0
		or generation <= 0
	):
		entry["receipt_invalid"] = true
		return
	var channel := StringName("stage:%s" % layer_id)
	var receipt := PresentationOperationReceipt.new(
		operation_request_id,
		presenter_instance_id,
		channel,
		token,
		generation,
	)
	var key := _receipt_key(receipt)
	if (entry["receipt_keys"] as Dictionary).has(key):
		return
	(entry["receipt_keys"] as Dictionary)[key] = true
	(entry["receipts"] as Array).append(receipt)


func _on_stage_operation_request_finished(
	request_id: int,
	delivered: bool,
) -> void:
	_on_generic_request_finished(request_id, delivered)


func _on_presentation_operation_request_finished(
	request_id: int,
	delivered: bool,
) -> void:
	_on_generic_request_finished(request_id, delivered)


func _on_generic_request_finished(
	request_id: int,
	delivered: bool,
) -> void:
	var entry: Dictionary = _entries.get(request_id, {})
	if entry.is_empty() or bool(entry.get("sealed", false)):
		return
	var request: PresentationBatchRequest = entry["request"]
	var receipts: Array = entry["receipts"]
	if not delivered:
		if not _seal_entry(request_id, entry):
			request._settle(PresentationBatchRequest.Outcome.FAILED, _authority)
		else:
			request._settle(
				PresentationBatchRequest.Outcome.CANCELLED, _authority)
		_cleanup_entry(request_id)
		return
	if not _seal_entry(request_id, entry):
		request._settle(
			PresentationBatchRequest.Outcome.FAILED, _authority)
		_cleanup_entry(request_id)
		return
	entry["sealed"] = true
	if int(entry["policy"]) == PresentationBatchRequest.Policy.FIRE_AND_FORGET:
		request._settle(PresentationBatchRequest.Outcome.COMPLETED, _authority)
	if receipts.is_empty():
		request._settle(PresentationBatchRequest.Outcome.COMPLETED, _authority)
		_cleanup_entry(request_id)
		return
	if (
		int(entry["policy"]) == PresentationBatchRequest.Policy.JOIN
		and _is_skip_active()
	):
		_finish_join(request_id)
	_evaluate_terminal_state(request_id)


func _on_stage_transition_terminal(
	presenter_instance_id: int,
	layer_id: String,
	token: int,
	operation_request_id: int,
	generation: int,
	outcome: StringName,
) -> void:
	if outcome not in [&"completed", &"superseded", &"cancelled"]:
		return
	var entry: Dictionary = _entries.get(operation_request_id, {})
	if (
		entry.is_empty()
		or int(entry.get("generation", -1)) != _generation
	):
		return
	var key := _receipt_key_parts(
		operation_request_id,
		presenter_instance_id,
		StringName("stage:%s" % layer_id),
		token,
		generation,
	)
	if (
		not (entry["receipt_keys"] as Dictionary).has(key)
		or (entry["terminal_keys"] as Dictionary).has(key)
	):
		return
	(entry["terminal_keys"] as Dictionary)[key] = outcome
	if not bool(entry.get("sealed", false)):
		return
	_evaluate_terminal_state(operation_request_id)


func _on_dialogue_visibility_transition_receipt_started(
	presenter_instance_id: int,
	target: String,
	token: int,
	operation_request_id: int,
	generation: int,
) -> void:
	var entry: Dictionary = _entries.get(operation_request_id, {})
	if (
		entry.is_empty()
		or bool(entry.get("sealed", false))
		or int(entry.get("generation", -1)) != _generation
	):
		return
	if (
		presenter_instance_id <= 0
		or target != target.strip_edges()
		or target.is_empty()
		or token <= 0
		or generation <= 0
	):
		entry["receipt_invalid"] = true
		return
	var receipt := PresentationOperationReceipt.new(
		operation_request_id,
		presenter_instance_id,
		StringName("dialogue:%s" % target),
		token,
		generation,
	)
	var key := _receipt_key(receipt)
	if (entry["receipt_keys"] as Dictionary).has(key):
		return
	(entry["receipt_keys"] as Dictionary)[key] = true
	(entry["receipts"] as Array).append(receipt)


func _on_dialogue_visibility_transition_terminal(
	presenter_instance_id: int,
	target: String,
	token: int,
	operation_request_id: int,
	generation: int,
	outcome: StringName,
) -> void:
	if outcome not in [&"completed", &"superseded", &"cancelled"]:
		return
	var entry: Dictionary = _entries.get(operation_request_id, {})
	if entry.is_empty() or int(entry.get("generation", -1)) != _generation:
		return
	var key := _receipt_key_parts(
		operation_request_id,
		presenter_instance_id,
		StringName("dialogue:%s" % target),
		token,
		generation,
	)
	if (
		not (entry["receipt_keys"] as Dictionary).has(key)
		or (entry["terminal_keys"] as Dictionary).has(key)
	):
		return
	(entry["terminal_keys"] as Dictionary)[key] = outcome
	if not bool(entry.get("sealed", false)):
		return
	_evaluate_terminal_state(operation_request_id)


func _evaluate_terminal_state(request_id: int) -> void:
	var entry: Dictionary = _entries.get(request_id, {})
	if entry.is_empty() or not bool(entry.get("sealed", false)):
		return
	var terminal_keys: Dictionary = entry["terminal_keys"]
	var receipt_keys: Dictionary = entry["receipt_keys"]
	var request: PresentationBatchRequest = entry["request"]
	if int(entry["policy"]) == PresentationBatchRequest.Policy.JOIN:
		for outcome_value: Variant in terminal_keys.values():
			if StringName(outcome_value) == &"completed":
				continue
			var context: ScenarioContext = entry.get("context")
			request._settle(
				PresentationBatchRequest.Outcome.FAILED
				if context != null and context.is_runtime_owner_current()
				else PresentationBatchRequest.Outcome.CANCELLED,
				_authority,
			)
			_cleanup_entry(request_id)
			return
		if terminal_keys.size() == receipt_keys.size():
			request._settle(
				PresentationBatchRequest.Outcome.COMPLETED, _authority)
			_cleanup_entry(request_id)
	elif terminal_keys.size() == receipt_keys.size():
		_cleanup_entry(request_id)


func _on_advance_requested() -> void:
	var current_serial := SignalBus.current_advance_dispatch_serial()
	_finish_latest_join(current_serial, true)


func on_skip_active_changed(active: bool) -> void:
	if active:
		_finish_latest_join(0, false)


func _is_skip_active() -> bool:
	return _skip_active.is_valid() and bool(_skip_active.call())


func _finish_latest_join(
	current_serial: int,
	require_newer_serial: bool,
) -> void:
	var winner_id := 0
	for request_id_value: Variant in _entries:
		var request_id := int(request_id_value)
		var entry: Dictionary = _entries[request_id]
		var request: PresentationBatchRequest = entry["request"]
		var context: ScenarioContext = entry.get("context")
		if (
			int(entry["policy"]) != PresentationBatchRequest.Policy.JOIN
			or not bool(entry.get("sealed", false))
			or request.is_settled()
			or (
				require_newer_serial
				and current_serial
				<= int(entry.get("accept_advance_serial", -1))
			)
			or (context != null and not context.is_runtime_owner_current())
		):
			continue
		winner_id = maxi(winner_id, request_id)
	_finish_join(winner_id)


func _finish_join(request_id: int) -> void:
	var entry: Dictionary = _entries.get(request_id, {})
	if entry.is_empty() or not bool(entry.get("sealed", false)):
		return
	var stage_records: Array = []
	var visibility_records: Array = []
	for receipt_value: Variant in entry["receipts"]:
		var receipt: PresentationOperationReceipt = receipt_value
		var channel := String(receipt.get_channel())
		if channel.begins_with("stage:"):
			stage_records.append({
				"presenter_instance_id": receipt.get_presenter_instance_id(),
				"layer_id": channel.trim_prefix("stage:"),
				"token": receipt.get_token(),
				"operation_request_id": receipt.get_batch_id(),
				"generation": receipt.get_generation(),
			})
		elif channel.begins_with("dialogue:"):
			visibility_records.append({
				"presenter_instance_id": receipt.get_presenter_instance_id(),
				"target": channel.trim_prefix("dialogue:"),
				"token": receipt.get_token(),
				"operation_request_id": receipt.get_batch_id(),
				"generation": receipt.get_generation(),
			})
	if not stage_records.is_empty():
		SignalBus.stage_transition_receipts_finish_requested.emit(stage_records)
	if not visibility_records.is_empty():
		(SignalBus.get(
			&"dialogue_visibility_transition_receipts_finish_requested"
		) as Signal).emit(visibility_records)


func _cancel_entry(
	request_id: int,
	outcome: PresentationBatchRequest.Outcome,
) -> void:
	var entry: Dictionary = _entries.get(request_id, {})
	if entry.is_empty():
		return
	var request: PresentationBatchRequest = entry["request"]
	if not bool(entry.get("sealed", false)):
		if not _seal_entry(request_id, entry):
			if not request.is_settled():
				request._settle(
					PresentationBatchRequest.Outcome.FAILED, _authority)
			SignalBus.cancel_stage_operation_request(request_id)
			_cleanup_entry(request_id)
			return
		entry["sealed"] = true
	if not request.is_settled():
		request._settle(outcome, _authority)
	SignalBus.cancel_stage_operation_request(request_id)
	SignalBus.cancel_presentation_operation_request(request_id)
	SignalBus.cancel_dialogue_visibility_operation_request(request_id)
	_cleanup_entry(request_id)


func _cancel_detached_entry(
	request_id: int,
	entry: Dictionary,
	outcome: PresentationBatchRequest.Outcome,
) -> void:
	if entry.is_empty():
		return
	var request: PresentationBatchRequest = entry["request"]
	if not bool(entry.get("sealed", false)):
		if not _seal_entry(request_id, entry):
			if not request.is_settled():
				request._settle(
					PresentationBatchRequest.Outcome.FAILED, _authority)
			SignalBus.cancel_stage_operation_request(request_id)
			return
		entry["sealed"] = true
	if not request.is_settled():
		request._settle(outcome, _authority)
	SignalBus.cancel_stage_operation_request(request_id)
	SignalBus.cancel_presentation_operation_request(request_id)
	SignalBus.cancel_dialogue_visibility_operation_request(request_id)


func _cleanup_entry(request_id: int) -> void:
	var entry: Dictionary = _entries.get(request_id, {})
	if entry.is_empty():
		return
	_disconnect_entry_context(entry)
	_entries.erase(request_id)


func _disconnect_entry_context(entry: Dictionary) -> void:
	var context: ScenarioContext = entry.get("context")
	var on_context_cancel: Callable = entry.get("context_cancel", Callable())
	if (
		context != null
		and on_context_cancel.is_valid()
		and context.cancellation_requested.is_connected(on_context_cancel)
	):
		context.cancellation_requested.disconnect(on_context_cancel)
	entry["context_cancel"] = Callable()


func _context_accepts_submission(context: ScenarioContext) -> bool:
	return (
		context != null
		and not context.is_cancellation_requested()
		and context.is_runtime_owner_current()
	)


func _seal_entry(request_id: int, entry: Dictionary) -> bool:
	if request_id <= 0 or bool(entry.get("sealed", false)):
		return false
	var receipts: Array = entry.get("receipts", [])
	if (
		bool(entry.get("receipt_invalid", false))
		or not _receipts_are_valid(
			request_id,
			receipts,
		)
	):
		return false
	var request: PresentationBatchRequest = entry["request"]
	return request._seal(request_id, receipts, _authority)


func _receipts_are_valid(
	batch_id: int,
	receipts: Array,
) -> bool:
	if batch_id <= 0:
		return false
	var keys := {}
	for receipt_value: Variant in receipts:
		if not receipt_value is PresentationOperationReceipt:
			return false
		var receipt: PresentationOperationReceipt = receipt_value
		var channel := String(receipt.get_channel())
		if (
			receipt.get_batch_id() != batch_id
			or receipt.get_presenter_instance_id() <= 0
			or not (
				(
					channel.begins_with("stage:")
					and channel != "stage:"
					and channel != "stage:*"
					and (
						channel.trim_prefix("stage:")
						== channel.trim_prefix("stage:").strip_edges()
					)
				)
				or (
					channel.begins_with("dialogue:")
					and channel != "dialogue:"
					and (
						channel.trim_prefix("dialogue:")
						== channel.trim_prefix("dialogue:").strip_edges()
					)
				)
			)
			or receipt.get_token() <= 0
			or receipt.get_generation() <= 0
		):
			return false
		var key := _receipt_key(receipt)
		if keys.has(key):
			return false
		keys[key] = true
	return true


func _receipt_key(receipt: PresentationOperationReceipt) -> String:
	return _receipt_key_parts(
		receipt.get_batch_id(),
		receipt.get_presenter_instance_id(),
		receipt.get_channel(),
		receipt.get_token(),
		receipt.get_generation(),
	)


func _receipt_key_parts(
	batch_id: int,
	presenter_instance_id: int,
	channel: StringName,
	token: int,
	generation: int,
) -> String:
	return "%d|%d|%s|%d|%d" % [
		batch_id,
		presenter_instance_id,
		String(channel),
		token,
		generation,
	]


func _on_stage_visuals_reset_requested() -> void:
	if not SignalBus.is_current_stage_reset_valid():
		return
	_cancel_for_presentation_reset()


func _on_dialogue_visibility_visuals_reset_requested() -> void:
	_dialogue_visibility_reset_allows_next_apply = true
	_cancel_for_presentation_reset()
	call_deferred("_clear_dialogue_visibility_reset_apply_marker")


func _on_dialogue_visibility_state_apply_requested(
	visibility: Dictionary,
	content: Dictionary,
	runtime_binding: Dictionary,
) -> void:
	if _dialogue_visibility_reset_allows_next_apply:
		_dialogue_visibility_reset_allows_next_apply = false
		return
	cancel_all()


func _clear_dialogue_visibility_reset_apply_marker() -> void:
	_dialogue_visibility_reset_allows_next_apply = false


func _cancel_for_presentation_reset() -> void:
	var lifecycle_id := SignalBus.current_presentation_projection_lifecycle_id()
	if lifecycle_id <= 0:
		_retired_presentation_projection_lifecycle_id = 0
		cancel_all()
		return
	if lifecycle_id == _retired_presentation_projection_lifecycle_id:
		return
	_retired_presentation_projection_lifecycle_id = lifecycle_id
	cancel_all()


func _on_presentation_projection_lifecycle_finished(lifecycle_id: int) -> void:
	if lifecycle_id == _retired_presentation_projection_lifecycle_id:
		_retired_presentation_projection_lifecycle_id = 0


func _on_engine_abort_requested() -> void:
	_retired_presentation_projection_lifecycle_id = 0
	cancel_all()
