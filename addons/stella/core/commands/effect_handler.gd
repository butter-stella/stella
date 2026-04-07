## Emits effect_requested signal for screen effects (shake, flash, blur).
class_name EffectHandler extends CommandHandler


func get_command_type() -> String:
	return "effect"


func execute(data: CommandData, context: ScenarioContext) -> void:
	if context.is_replay:
		return

	var effect_type = data.get_string("effect_type", "")
	var params = data.params.duplicate()
	params.erase("effect_type")
	SignalBus.effect_requested.emit(effect_type, params)
