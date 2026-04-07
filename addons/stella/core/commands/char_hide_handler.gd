## Emits char_hide signal to hide a character sprite.
class_name CharHideHandler extends CommandHandler


func get_command_type() -> String:
	return "char_hide"


func execute(data: CommandData, context: ScenarioContext) -> void:
	var character = data.get_string("character", "")

	if context.is_replay:
		if context.presentation_state:
			context.presentation_state.apply_char_hide(character)
		return

	SignalBus.char_hide.emit(character)
