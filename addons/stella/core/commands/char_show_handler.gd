## Emits char_show signal for displaying a character sprite.
class_name CharShowHandler extends CommandHandler


func get_command_type() -> String:
	return "char_show"


func execute(data: CommandData, context: ScenarioContext) -> void:
	var character = data.get_string("character", "")
	var expression = data.get_string("expression", "default")
	var position = data.get_string("position", "center")

	if context.is_replay:
		if context.presentation_state:
			context.presentation_state.apply_char_show(character, expression, position)
		return

	SignalBus.char_show.emit(character, expression, position)
