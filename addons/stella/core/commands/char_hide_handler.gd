## Emits char_hide signal to hide a character sprite.
class_name CharHideHandler extends CommandHandler


func get_command_type() -> String:
	return "char_hide"


func execute(data: CommandData, _context: ScenarioContext) -> void:
	var character = data.get_string("character", "")
	SignalBus.char_hide.emit(character)
