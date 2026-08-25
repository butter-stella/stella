## Submits one authored named-stage operation through the Runtime Director.
class_name StageLayerHandler extends CommandHandler

var _presentation_director: PresentationDirector


func _init(presentation_director: PresentationDirector = null) -> void:
	_presentation_director = presentation_director


func get_command_type() -> String:
	return "stage_layer"


func execute(data: CommandData, context: ScenarioContext) -> void:
	if (
		data == null
		or context == null
		or context.is_cancellation_requested()
		or not context.is_runtime_owner_current()
	):
		_fail_context(data, context, "missing, cancelled, or non-current execution context")
		return
	var action := data.get_string("action", "").to_lower()
	if action not in StageLayerState.VALID_ACTIONS:
		_fail_context(data, context, "unknown action '%s'" % action)
		return

	var layer_id := data.get_string("id", "").strip_edges()
	if action != "clear" and layer_id == "":
		_fail_context(data, context, "%s requires a layer id" % action)
		return

	var properties = data.params.get("properties", {})
	if not properties is Dictionary:
		_fail_context(data, context, "properties must be a Dictionary")
		return
	if action in ["hide", "remove", "clear"] and not properties.is_empty():
		_fail_context(data, context, "%s does not accept layer properties" % action)
		return
	var transition_params: Variant = data.params.get("transition_params", {})
	if not transition_params is Dictionary:
		_fail_context(data, context, "transition_params must be a Dictionary")
		return

	var operation := {
		"action": action,
		"id": layer_id,
		"properties": properties.duplicate(true),
		"transition": data.get_string("transition", "cut"),
		"transition_params": (transition_params as Dictionary).duplicate(true),
		"duration": data.get_float("duration", 0.0),
	}
	if not StageLayerState.validate_operation(operation, true):
		_fail_context(data, context, "operation failed canonical Stage validation")
		return
	if _presentation_director == null:
		_fail_context(data, context, "PresentationDirector is unavailable")
		return
	var source := _source(data, context)
	var request := _presentation_director.submit(
		[StagePresentationOperation.new(operation, source)],
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
		context,
		source,
	)
	if not request.is_settled():
		if not await CommandHandler.await_with_abort(request.settled, context):
			return
	if (
		request.get_outcome() in [
			PresentationBatchRequest.Outcome.FAILED,
			PresentationBatchRequest.Outcome.CANCELLED,
		]
		and context.is_runtime_owner_current()
	):
		context.is_finished = true


func _fail_context(
	data: CommandData,
	context: ScenarioContext,
	message: String,
) -> void:
	var source := _source(data, context)
	var label := String(source.get("source_path", "")).strip_edges()
	if label.is_empty():
		label = String(source.get("scenario_id", "")).strip_edges()
	var line := int(source.get("line", 0))
	var location := "[runtime]"
	if not label.is_empty() and line > 0:
		location = "[%s:%d]" % [label, line]
	elif not label.is_empty():
		location = "[%s]" % label
	elif line > 0:
		location = "[line %d]" % line
	push_error("%s StageLayerHandler: %s" % [location, message])
	if context != null and context.is_runtime_owner_current():
		context.is_finished = true


func _source(data: CommandData, context: ScenarioContext) -> Dictionary:
	var scenario_data := context.scenario_data if context != null else null
	return {
		"source_path": scenario_data.source_path if scenario_data != null else "",
		"scenario_id": scenario_data.id if scenario_data != null else "",
		"line": data.declared_line if data != null else 0,
	}
