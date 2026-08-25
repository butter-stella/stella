## Validates and submits one authored mixed Stage/dialogue visibility batch.
class_name PresentationBatchHandler extends CommandHandler

const EXACT_PARAM_KEYS := ["operation_lines", "operations", "policy"]
const EXACT_ENVELOPE_KEYS := ["kind", "payload"]
const EXACT_STAGE_PAYLOAD_KEYS := [
	"action", "duration", "id", "properties", "transition",
]
const EXACT_VISIBILITY_PAYLOAD_KEYS := [
	"action", "duration", "target", "transition",
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
	return "presentation_batch"


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
			String(validation.get("error", "invalid presentation batch")),
			int(validation.get("line", data.declared_line if data != null else 0)),
		)
		return
	if bool(validation.get("no_work", false)):
		return
	if _director == null:
		_fail_context(data, context, "PresentationDirector is unavailable")
		return

	var typed_operations: Array[PresentationOperation] = []
	var runtime_binding := StellaRuntime._runtime_dialogue_visibility_binding(
		context
	)
	for operation_value: Variant in validation["operations"]:
		var operation: Dictionary = operation_value
		var kind := String(operation.get("kind", ""))
		var payload: Dictionary = (operation.get("payload", {}) as Dictionary).duplicate(true)
		match kind:
			"stage":
				typed_operations.append(StagePresentationOperation.new(payload))
			"dialogue_visibility":
				typed_operations.append(
					DialogueVisibilityPresentationOperation.new(
						payload,
						runtime_binding,
					)
				)
	var policy := (
		PresentationBatchRequest.Policy.JOIN
		if String(validation["policy"]) == "join"
		else PresentationBatchRequest.Policy.FIRE_AND_FORGET
	)
	var request := _director.submit(
		typed_operations,
		policy,
		context,
		_source(data, context),
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
	if data.type != "presentation_batch":
		return {
			"valid": false,
			"error": "command type must be presentation_batch",
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
	if not data.params.get("policy", null) is String:
		return {"valid": false, "error": "policy must be a String", "line": data.declared_line}
	if not data.params.get("operations", null) is Array:
		return {"valid": false, "error": "operations must be an Array", "line": data.declared_line}
	if not data.params.get("operation_lines", null) is Array:
		return {"valid": false, "error": "operation_lines must be an Array", "line": data.declared_line}
	var policy := String(data.params["policy"])
	if policy not in ["join", "fire_and_forget"]:
		return {"valid": false, "error": "invalid batch policy", "line": data.declared_line}
	var operations: Array = data.params["operations"]
	var operation_lines: Array = data.params["operation_lines"]
	if operations.is_empty():
		return {"valid": false, "error": "operations must not be empty", "line": data.declared_line}
	if operation_lines.size() != operations.size():
		return {"valid": false, "error": "operation_lines must match operations one-for-one", "line": data.declared_line}

	var seen_stage_layers: Dictionary = {}
	var seen_targets: Dictionary = {}
	var canonical_operations: Array = []
	var stage_operations: Array = []
	var visibility_operations: Array = []
	for index in range(operations.size()):
		if not operation_lines[index] is int or int(operation_lines[index]) <= 0:
			return {"valid": false, "error": "operation line must be a positive integer", "line": data.declared_line}
		if not operations[index] is Dictionary:
			return {"valid": false, "error": "operation must be a Dictionary", "line": int(operation_lines[index])}
		var envelope: Dictionary = operations[index]
		var envelope_keys := envelope.keys()
		envelope_keys.sort()
		if envelope_keys != EXACT_ENVELOPE_KEYS:
			return {"valid": false, "error": "operation envelope must use exactly kind and payload", "line": int(operation_lines[index])}
		var kind := String(envelope.get("kind", ""))
		if not envelope.get("payload", null) is Dictionary:
			return {"valid": false, "error": "operation payload must be a Dictionary", "line": int(operation_lines[index])}
		var payload: Dictionary = (envelope["payload"] as Dictionary).duplicate(true)
		match kind:
			"stage":
				var stage_keys := payload.keys()
				stage_keys.sort()
				if stage_keys != EXACT_STAGE_PAYLOAD_KEYS:
					return {"valid": false, "error": "stage payload must use the canonical five-field schema", "line": int(operation_lines[index])}
				if not StageLayerState.validate_operation(payload, false):
					return {"valid": false, "error": "stage payload failed canonical validation", "line": int(operation_lines[index])}
				var action := String(payload.get("action", ""))
				var layer_id := String(payload.get("id", "")).strip_edges()
				if action != "clear" and seen_stage_layers.has(layer_id):
					return {"valid": false, "error": "duplicate stage layer '%s'" % layer_id, "line": int(operation_lines[index])}
				if action == "clear":
					for prior_value: Variant in stage_operations:
						var prior: Dictionary = prior_value
						if String(prior.get("action", "")) != "clear":
							return {"valid": false, "error": "stage clear conflicts with another Stage sibling", "line": int(operation_lines[index])}
				else:
					for prior_value: Variant in stage_operations:
						var prior: Dictionary = prior_value
						if String(prior.get("action", "")) == "clear":
							return {"valid": false, "error": "stage clear conflicts with another Stage sibling", "line": int(operation_lines[index])}
					seen_stage_layers[layer_id] = true
				stage_operations.append(payload.duplicate(true))
			"dialogue_visibility":
				var visibility_keys := payload.keys()
				visibility_keys.sort()
				if visibility_keys != EXACT_VISIBILITY_PAYLOAD_KEYS:
					return {"valid": false, "error": "dialogue visibility payload must use the canonical four-field schema", "line": int(operation_lines[index])}
				if not DialogueVisibilityState.validate_operation(payload, false):
					return {"valid": false, "error": "dialogue visibility payload failed canonical validation", "line": int(operation_lines[index])}
				var target := String(payload.get("target", ""))
				if seen_targets.has(target):
					return {"valid": false, "error": "duplicate dialogue visibility target '%s'" % target, "line": int(operation_lines[index])}
				seen_targets[target] = true
				visibility_operations.append(payload.duplicate(true))
			_:
				return {"valid": false, "error": "unsupported presentation operation kind '%s'" % kind, "line": int(operation_lines[index])}
		canonical_operations.append({
			"kind": kind,
			"payload": payload.duplicate(true),
		})

	var stage_before := (
		_presentation_state.stage_layers.duplicate(true)
		if _presentation_state != null
		else {}
	)
	var visibility_before := (
		_presentation_state.dialogue_visibility.duplicate(true)
		if _presentation_state != null
		else DialogueVisibilityState.default_state()
	)
	var stage_target := StageLayerState.reduce(stage_before, stage_operations, false)
	var visibility_target := DialogueVisibilityState.reduce(visibility_before, visibility_operations, false)
	return {
		"valid": true,
		"policy": policy,
		"operations": canonical_operations,
		"before_stage": stage_before,
		"before_visibility": visibility_before,
		"target_stage": stage_target,
		"target_visibility": visibility_target,
		"no_work": (
			stage_target == stage_before
			and visibility_target == visibility_before
			and visibility_operations.is_empty()
		),
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
	push_error("%s PresentationBatchHandler: %s" % [
		_source_label(source),
		message,
	])
	if context != null and context.is_runtime_owner_current():
		context.is_finished = true


func _source(data: CommandData, context: ScenarioContext) -> Dictionary:
	var scenario_data := context.scenario_data if context != null else null
	return {
		"source_path": scenario_data.source_path if scenario_data != null else "",
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
