## Emits char_expression_changed signal to switch character expression.
class_name CharExprHandler extends CommandHandler


func get_command_type() -> String:
	return "char_expr"


func execute(data: CommandData, context: ScenarioContext) -> void:
	var character = data.get_string("character", "")
	var expression = data.get_string("expression", "default")

	if context.is_replay:
		if context.presentation_state:
			context.presentation_state.apply_char_expr(character, expression)
		return

	SignalBus.char_expression_changed.emit(character, expression)
