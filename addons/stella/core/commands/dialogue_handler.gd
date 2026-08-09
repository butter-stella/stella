## Emits show_dialogue signal and waits for advance_requested.
class_name DialogueHandler extends CommandHandler


func get_command_type() -> String:
	return "dialogue"


func execute(data: CommandData, context: ScenarioContext) -> void:
	var character = data.get_string("character", "")
	var mode = data.get_string("mode", "adv")
	var segments: Array = data.params.get("segments", [])

	# Normalize: a non-combine dialogue has no segments field — wrap it as a
	# single-segment array so downstream consumers always see the same shape.
	if segments.is_empty():
		segments = [{
			"text": data.get_string("text", ""),
			"voice": data.get_string("voice", ""),
			"expression": "",
		}]

	var presentation_profile: Dictionary = data.params.get("presentation_profile", {})
	var nvl_block_key := ""
	var nvl_block_id := data.get_int("nvl_block_id", -1)
	if nvl_block_id >= 0:
		var scenario_instance_id := 0
		if context != null and context.scenario_data != null:
			scenario_instance_id = context.scenario_data.get_instance_id()
		nvl_block_key = "%d:%d" % [scenario_instance_id, nvl_block_id]
	SignalBus.emit_show_dialogue(
		character,
		segments,
		mode,
		presentation_profile,
		data.get_bool("declarative_presentation", false),
		nvl_block_key,
	)
	# Race against engine_abort_requested so backlog jump can interrupt us.
	await CommandHandler.await_with_abort(SignalBus.advance_requested)
