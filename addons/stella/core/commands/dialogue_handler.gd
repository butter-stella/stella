## Emits show_dialogue signal and waits for advance_requested.
class_name DialogueHandler extends CommandHandler


func get_command_type() -> String:
	return "dialogue"


func execute(data: CommandData, _context: ScenarioContext) -> void:
	var character = data.get_string("character", "")
	var mode = data.get_string("mode", "adv")
	var segments = data.params.get("segments", [])

	if segments is Array and segments.size() > 0:
		SignalBus.show_dialogue_combined.emit(character, segments, mode)
	else:
		var text = data.get_string("text", "")
		var voice = data.get_string("voice", "")
		SignalBus.show_dialogue.emit(character, text, voice, mode)

	await SignalBus.advance_requested
