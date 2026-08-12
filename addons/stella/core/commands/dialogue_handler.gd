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
			"stage_ops": data.params.get("stage_ops", []).duplicate(true),
		}]

	var presentation_profile: Dictionary = data.params.get("presentation_profile", {})
	var nvl_page_key := ""
	if context != null:
		# Defensive synchronization supports programmatically constructed commands,
		# old compiled data, and snapshots that resume in the middle of a block.
		context.apply_dialogue_mode(mode)
		if mode == "nvl" and context.scenario_data != null:
			nvl_page_key = "%d:%d" % [
				context.get_instance_id(),
				context.nvl_page_epoch,
			]
	SignalBus.emit_show_dialogue(
		character,
		segments,
		mode,
		presentation_profile,
		data.get_bool("declarative_presentation", false),
		nvl_page_key,
	)
	# Race against engine_abort_requested so backlog jump can interrupt us.
	await CommandHandler.await_with_abort(SignalBus.advance_requested)
