## Submits one short-form declarative presentation clip through the Director.
class_name PresentationClipHandler extends CommandHandler

const EXACT_KEYS := ["asset", "policy"]

var _director: PresentationDirector


func _init(director: PresentationDirector = null) -> void:
	_director = director


func get_command_type() -> String:
	return "presentation_clip"


func execute(data: CommandData, context: ScenarioContext) -> void:
	if (
		data == null
		or context == null
		or context.is_cancellation_requested()
		or not context.is_runtime_owner_current()
	):
		_fail(data, context, "missing, cancelled, or non-current execution context")
		return
	var keys := data.params.keys()
	keys.sort()
	if keys != EXACT_KEYS:
		_fail(data, context, "params must contain exactly asset and policy")
		return
	var asset_value: Variant = data.params.get("asset")
	var policy_value: Variant = data.params.get("policy")
	if not asset_value is String or not PresentationClipDefinition.is_logical_id(
		String(asset_value)):
		_fail(data, context, "asset must be a canonical logical clip id")
		return
	if not policy_value is String or String(policy_value) not in [
		"join", "fire_and_forget",
	]:
		_fail(data, context, "policy must be join or fire_and_forget")
		return
	if _director == null:
		_fail(data, context, "PresentationDirector is unavailable")
		return
	var source := _source(data, context)
	var operation := PresentationClipPresentationOperation.new(
		{"asset": String(asset_value)}, source)
	var policy := (
		PresentationBatchRequest.Policy.JOIN
		if String(policy_value) == "join"
		else PresentationBatchRequest.Policy.FIRE_AND_FORGET
	)
	var request := _director.submit([operation], policy, context, source)
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


func _fail(data: CommandData, context: ScenarioContext, message: String) -> void:
	var source := _source(data, context)
	var label := String(source.get("source_path", ""))
	if label.is_empty():
		label = String(source.get("scenario_id", "runtime"))
	var line := int(source.get("line", 0))
	push_error("[%s%s] PresentationClipHandler: %s" % [
		label,
		":" + str(line) if line > 0 else "",
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
