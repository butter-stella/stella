## Applies one authored named-stage operation through SignalBus.
class_name StageLayerHandler extends CommandHandler


func get_command_type() -> String:
	return "stage_layer"


func execute(data: CommandData, _context: ScenarioContext) -> void:
	var action := data.get_string("action", "").to_lower()
	if action not in StageLayerState.VALID_ACTIONS:
		push_warning("StageLayerHandler: unknown action '%s'" % action)
		return

	var layer_id := data.get_string("id", "").strip_edges()
	if action != "clear" and layer_id == "":
		push_warning("StageLayerHandler: %s requires a layer id" % action)
		return

	var properties = data.params.get("properties", {})
	if not properties is Dictionary:
		push_warning("StageLayerHandler: properties must be a Dictionary")
		return
	if action in ["hide", "remove", "clear"] and not properties.is_empty():
		push_warning("StageLayerHandler: %s does not accept layer properties" % action)
		return

	var operation := {
		"action": action,
		"id": layer_id,
		"properties": properties.duplicate(true),
		"transition": data.get_string("transition", "cut"),
		"duration": data.get_float("duration", 0.0),
	}
	if not StageLayerState.validate_operation(operation, true):
		return
	SignalBus.emit_stage_operations([operation], false)
