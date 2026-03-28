## Emits char_show signal for displaying a character sprite.
class_name CharShowHandler extends CommandHandler


func get_command_type() -> String:
	return "char_show"


func execute(data: CommandData, _context: ScenarioContext) -> void:
	var character = data.get_string("character", "")
	var expression = data.get_string("expression", "default")
	var position = data.get_string("position", "center")

	SignalBus.char_show.emit(character, expression, position)
