## Emits a request-scoped dialogue activation and waits for its acknowledgement.
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
	var scenario_identity := ""
	var scene_id := ""
	var command_index := -1
	if context != null and context.scenario_data != null:
		var current_scene := context.current_scene()
		if current_scene != null:
			scenario_id = context.scenario_data.id
			scenario_identity = context.scenario_data.get_read_identity()
			scene_id = current_scene.id
			command_index = context.current_command_index
	var command_uid := data.uid if data.uid >= 0 else command_index

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
			"voice_dsp": data.get_string("voice_dsp", ""),
			"voice_dsp_line": data.get_int("voice_dsp_line", 0),
			"stage_ops": data.params.get("stage_ops", []).duplicate(true),
			"stage_operation_lines": data.params.get(
				"stage_operation_lines", []).duplicate(),
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
	var activation := DialogueActivation.new()
	if context != null and not context.install_dialogue_activation(activation):
		return
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
		command_uid,
		activation,
		scenario_identity,
		scenario_id,
		scene_id,
		command_index,
	))
	var outcome := activation.get_outcome()
	if activation.is_pending():
		outcome = await activation.resolved
	var owns_activation := (
		context != null and context.owns_dialogue_activation(activation)
	)
	if context != null:
		context.clear_dialogue_activation(activation)
	if outcome == DialogueActivation.Outcome.ABORTED:
		# A consumer-facing request.abort() cancels the authored command; it must
		# not look like successful completion to ScenarioEngine and advance the
		# cursor into the next line. Stale/rejected activations do not own the
		# context and therefore cannot stop a replacement run.
		if owns_activation and context != null:
			context.is_finished = true
		return
	if outcome != DialogueActivation.Outcome.ADVANCED or not owns_activation:
		return

	# Read state belongs to command completion, not to presentation. Aborted lines
	# return above and remain unread.
	if command_uid < 0 or scenario_identity.is_empty() or scene_id.is_empty():
		push_warning(
			"DialogueHandler: cannot mark a completed dialogue without a valid identity"
		)
	else:
		_read_flags.mark_dialogue_read(
			scenario_identity,
			scene_id,
			command_uid,
		)
	# Compatibility presentation notifications are deliberately last. A
	# synchronous extension may re-enter Core from this signal, but the durable
	# commit and owner release above are already complete.
	SignalBus.emit_dialogue_advance_committed(activation)
