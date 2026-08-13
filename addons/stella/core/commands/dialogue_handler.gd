## Emits show_dialogue signal and waits for advance_requested.
class_name DialogueHandler extends CommandHandler

var _read_flags: ReadFlagManager


func _init(read_flags: ReadFlagManager) -> void:
	assert(read_flags != null, "DialogueHandler requires a ReadFlagManager")
	_read_flags = read_flags


func get_command_type() -> String:
	return "dialogue"


func execute(data: CommandData, context: ScenarioContext) -> void:
	# Snapshot the semantic command identity before awaiting input. The context is
	# mutable and can be jumped/replaced while a dialogue is blocked.
	var scenario_id := ""
	var scene_id := ""
	var command_index := -1
	if context != null and context.scenario_data != null:
		var current_scene := context.current_scene()
		if current_scene != null:
			scenario_id = context.scenario_data.id
			scene_id = current_scene.id
			command_index = context.current_command_index

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
	var entry_id := "command:%d:object:%d" % [data.uid, data.get_instance_id()]
	if context != null:
		entry_id = context.next_dialogue_entry_id(data.uid)
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
			if not nvl_page_entries.is_empty():
				nvl_page_entries = context.materialize_nvl_page_entries(
					nvl_page_entries)
	SignalBus.emit_dialogue_request(DialogueRequest.new(
		character,
		segments,
		mode,
		presentation_profile,
		declarative_presentation,
		nvl_page_key,
		presentation_provenance,
		nvl_page_entries,
		entry_id,
		data.uid,
	))
	# Race against engine_abort_requested so backlog jump can interrupt us.
	if not await CommandHandler.await_with_abort(SignalBus.advance_requested):
		return
	# Loading/replacing a scenario stops its old context without necessarily
	# emitting the abort signal. A later run's advance must not complete that
	# abandoned command.
	if context == null or context.is_finished:
		return

	# Read state belongs to command completion, not to presentation. Aborted lines
	# return above and remain unread.
	if command_index < 0:
		push_warning(
			"DialogueHandler: cannot mark a completed dialogue without a valid position"
		)
		return
	_read_flags.mark_read(
		scenario_id,
		scene_id,
		command_index,
	)
