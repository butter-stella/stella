## Emits show_dialogue signal and waits for advance_requested.
class_name DialogueHandler extends CommandHandler


func get_command_type() -> String:
	return "dialogue"


func execute(data: CommandData, context: ScenarioContext) -> void:
	if context.is_replay:
		# Replay mode (jumping from backlog): don't display or await.
		return

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

	SignalBus.show_dialogue.emit(character, segments, mode)
	await SignalBus.advance_requested
