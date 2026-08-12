## Emits show_dialogue signal and waits for advance_requested.
class_name DialogueHandler extends CommandHandler


func get_command_type() -> String:
	return "dialogue"


func execute(data: CommandData, context: ScenarioContext) -> void:
	var character = data.get_string("character", "")
	var mode = data.get_string("mode", "adv")
	var segments: Array = data.params.get("segments", [])
	var presentation_from_context := data.get_bool(
		"presentation_from_context", false)

	# Normalize: a non-combine dialogue has no segments field — wrap it as a
	# single-segment array so downstream consumers always see the same shape.
	if segments.is_empty():
		segments = [{
			"text": data.get_string("text", ""),
			"voice": data.get_string("voice", ""),
			"stage_ops": data.params.get("stage_ops", []).duplicate(true),
		}]

	var presentation_profile: Dictionary = data.params.get("presentation_profile", {})
	var presentation_provenance: Dictionary = data.params.get(
		"presentation_profile_provenance", {})
	var declarative_presentation := data.get_bool(
		"declarative_presentation", false)
	var nvl_page_key := ""
	var nvl_page_entries: Array = []
	if context != null:
		if presentation_from_context:
			mode = context.current_dialogue_mode
			presentation_profile = context.resolve_current_dialogue_profile()
			presentation_provenance = (
				context.resolve_current_dialogue_profile_provenance()
			)
			declarative_presentation = (
				context.current_dialogue_uses_declarative_presentation
			)
		elif mode != "monologue":
			# Static fallback for programmatic commands and older compiled data.
			# A monologue is a one-command display style, not a persistent mode.
			context.apply_static_dialogue_presentation(mode)
		if mode == "nvl" and context.scenario_data != null:
			nvl_page_key = "%d:%d" % [
				context.get_instance_id(),
				context.nvl_page_epoch,
			]
			nvl_page_entries = context.record_nvl_page_entry(
				data.uid, character, segments)
	SignalBus.emit_dialogue_request(DialogueRequest.new(
		character,
		segments,
		mode,
		presentation_profile,
		declarative_presentation,
		nvl_page_key,
		presentation_provenance,
		nvl_page_entries,
	))
	# Race against engine_abort_requested so backlog jump can interrupt us.
	await CommandHandler.await_with_abort(SignalBus.advance_requested)
