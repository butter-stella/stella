## Emits char_move_requested signal for character movement.
class_name MoveHandler extends CommandHandler


func get_command_type() -> String:
	return "char_move"


func execute(data: CommandData, _context: ScenarioContext) -> void:
	var character = data.get_string("character", "")
	var position = data.get_string("position", "center")
	var duration = data.get_float("duration", 0.5)
	SignalBus.char_move_requested.emit(character, position, duration)
