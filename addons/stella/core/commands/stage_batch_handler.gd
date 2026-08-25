## Validates and submits one authored atomic named-stage composition batch.
class_name StageBatchHandler extends CommandHandler

const EXACT_PARAM_KEYS := ["operation_lines", "operations", "policy"]
const EXACT_OPERATION_KEYS := [
	"action", "duration", "id", "properties", "transition", "transition_params",
]

var _director: PresentationDirector
var _presentation_state: PresentationState


func _init(
	director: PresentationDirector = null,
	presentation_state: PresentationState = null,
) -> void:
	_director = director
	_presentation_state = presentation_state


func get_command_type() -> String:
	return "stage_batch"


func execute(data: CommandData, context: ScenarioContext) -> void:
	if (
		context == null
		or context.is_cancellation_requested()
		or not context.is_runtime_owner_current()
	):
		_fail_context(
			data,
			context,
			"ScenarioContext is missing, cancelled, or not current",
		)
		return
	var validation := _validate_and_reduce(data)
	if not bool(validation.get("valid", false)):
		_fail_context(
			data,
			context,
			String(validation.get("error", "invalid stage batch")),
			int(validation.get("line", data.declared_line if data != null else 0)),
		)
		return
	if _director == null:
		_fail_context(data, context, "PresentationDirector is unavailable")
		return

	var typed_operations: Array[PresentationOperation] = []
	for operation_index in range((validation["operations"] as Array).size()):
		var operation_value: Variant = validation["operations"][operation_index]
		var operation_source := _source(data, context)
		operation_source["line"] = int(
			(data.params["operation_lines"] as Array)[operation_index])
		typed_operations.append(StagePresentationOperation.new(
			(operation_value as Dictionary).duplicate(true),
			operation_source,
		))
	var policy := (
		PresentationBatchRequest.Policy.JOIN
		if String(validation["policy"]) == "join"
		else PresentationBatchRequest.Policy.FIRE_AND_FORGET
	)
	var source := _source(data, context)
	var request := _director.submit(
		typed_operations,
		policy,
		context,
		source,
	)
	if request.is_settled():
		_finish_request(request, context)
		return
	if not await CommandHandler.await_with_abort(request.settled, context):
		return
	_finish_request(request, context)


func _finish_request(
	request: PresentationBatchRequest,
	context: ScenarioContext,
) -> void:
	if (
		request.get_outcome() in [
			PresentationBatchRequest.Outcome.FAILED,
			PresentationBatchRequest.Outcome.CANCELLED,
		]
		and context != null
		and context.is_runtime_owner_current()
	):
		context.is_finished = true


func _validate_and_reduce(data: CommandData) -> Dictionary:
	if data == null:
		return {"valid": false, "error": "missing CommandData", "line": 0}
	if data.type != "stage_batch":
		return {
			"valid": false,
			"error": "command type must be stage_batch",
			"line": data.declared_line,
		}
	var param_keys := data.params.keys()
	param_keys.sort()
	if param_keys != EXACT_PARAM_KEYS:
		return {
			"valid": false,
			"error": "params must contain exactly policy, operations, and operation_lines",
			"line": data.declared_line,
		}
	if not data.params["policy"] is String:
		return {
			"valid": false,
			"error": "policy must be a String",
			"line": data.declared_line,
		}
	var policy := String(data.params["policy"])
	if policy not in ["join", "fire_and_forget"]:
		return {
			"valid": false,
			"error": "policy must be exactly join or fire_and_forget",
			"line": data.declared_line,
		}
	if not data.params["operations"] is Array:
		return {
			"valid": false,
			"error": "operations must be an Array",
			"line": data.declared_line,
		}
	if not data.params["operation_lines"] is Array:
		return {
			"valid": false,
			"error": "operation_lines must be an Array",
			"line": data.declared_line,
		}
	var operations: Array = data.params["operations"]
	var operation_lines: Array = data.params["operation_lines"]
	if operations.is_empty():
		return {
			"valid": false,
			"error": "operations must not be empty",
			"line": data.declared_line,
		}
	if operation_lines.size() != operations.size():
		return {
			"valid": false,
			"error": "operation_lines must match operations one-for-one",
			"line": data.declared_line,
		}

	var seen_layers := {}
	var saw_clear := false
	var canonical_operations: Array = []
	for index in range(operations.size()):
		var line_value: Variant = operation_lines[index]
		var line := (
			int(line_value)
			if line_value is int
			else data.declared_line
		)
		if not line_value is int or line <= 0:
			return {
				"valid": false,
				"error": "operation line must be a positive integer",
				"line": data.declared_line,
			}
		var operation_value: Variant = operations[index]
		if not operation_value is Dictionary:
			return {
				"valid": false,
				"error": "operation must be a Dictionary",
				"line": line,
			}
		var operation: Dictionary = operation_value
		var operation_keys := operation.keys()
		operation_keys.sort()
		if operation_keys != EXACT_OPERATION_KEYS:
			return {
				"valid": false,
				"error": "operation must use the canonical six-field schema",
				"line": line,
			}
		if (
			not operation["action"] is String
			or not operation["id"] is String
			or not operation["properties"] is Dictionary
			or not operation["transition"] is String
			or not operation["transition_params"] is Dictionary
			or not (
				operation["duration"] is float
				or operation["duration"] is int
			)
		):
			return {
				"valid": false,
				"error": "operation fields have invalid types",
				"line": line,
			}
		var action := String(operation["action"])
		var raw_layer_id := String(operation["id"])
		var layer_id := raw_layer_id.strip_edges()
		if raw_layer_id != layer_id:
			return {
				"valid": false,
				"error": "operation layer id must be canonical",
				"line": line,
			}
		if action != "clear" and layer_id == "*":
			return {
				"valid": false,
				"error": "'*' is reserved for the clear wildcard channel",
				"line": line,
			}
		if action not in StageLayerState.VALID_ACTIONS:
			return {
				"valid": false,
				"error": "operation action is not canonical",
				"line": line,
			}
		if not StageLayerState.validate_operation(operation, false):
			return {
				"valid": false,
				"error": "operation failed canonical Stage validation",
				"line": line,
			}
		if action == "clear":
			if saw_clear or not canonical_operations.is_empty():
				return {
					"valid": false,
					"error": "clear must be the only operation",
					"line": line,
				}
			saw_clear = true
		elif saw_clear or seen_layers.has(layer_id):
			return {
				"valid": false,
				"error": "duplicate or clear-conflicting layer '%s'" % layer_id,
				"line": line,
			}
		else:
			seen_layers[layer_id] = true
		canonical_operations.append(operation.duplicate(true))

	var before_state := (
		_presentation_state.stage_layers.duplicate(true)
		if _presentation_state != null
		else {}
	)
	var simulated: Dictionary = before_state.duplicate(true)
	for index in range(operations.size()):
		var operation: Dictionary = operations[index]
		var action := String(operation["action"])
		var layer_id := String(operation["id"]).strip_edges()
		if action in ["update", "hide"] and not simulated.has(layer_id):
			return {
				"valid": false,
				"error": "cannot %s unknown layer '%s'" % [action, layer_id],
				"line": int(operation_lines[index]),
			}
		var next := StageLayerState.reduce(simulated, [operation], false)
		if not next is Dictionary:
			return {
				"valid": false,
				"error": "operation cannot be reduced",
				"line": int(operation_lines[index]),
			}
		simulated = (next as Dictionary).duplicate(true)

	return {
		"valid": true,
		"policy": policy,
		"operations": operations.duplicate(true),
		"before_state": before_state,
		"target_state": simulated,
		# Every authored Stage run reaches the participant gate, including a
		# same-target update, so resource/provider bindings cannot be skipped.
		"no_work": false,
	}


func _fail_context(
	data: CommandData,
	context: ScenarioContext,
	message: String,
	line_override: int = -1,
) -> void:
	var source := _source(data, context)
	if line_override >= 0:
		source["line"] = line_override
	push_error("%s StageBatchHandler: %s" % [
		_source_label(source),
		message,
	])
	if context != null and context.is_runtime_owner_current():
		context.is_finished = true


func _source(data: CommandData, context: ScenarioContext) -> Dictionary:
	var scenario_data := context.scenario_data if context != null else null
	return {
		"source_path": (
			scenario_data.source_path if scenario_data != null else ""
		),
		"scenario_id": scenario_data.id if scenario_data != null else "",
		"line": data.declared_line if data != null else 0,
	}


func _source_label(source: Dictionary) -> String:
	var source_path := String(source.get("source_path", "")).strip_edges()
	var scenario_id := String(source.get("scenario_id", "")).strip_edges()
	var label := source_path if not source_path.is_empty() else scenario_id
	var line := int(source.get("line", 0))
	if not label.is_empty() and line > 0:
		return "[%s:%d]" % [label, line]
	if not label.is_empty():
		return "[%s]" % label
	if line > 0:
		return "[line %d]" % line
	return "[runtime]"
