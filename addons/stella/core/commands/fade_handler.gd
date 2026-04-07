## Emits fade_requested signal for screen fade in/out.
class_name FadeHandler extends CommandHandler


func get_command_type() -> String:
	return "fade"


func execute(data: CommandData, context: ScenarioContext) -> void:
	if context.is_replay:
		return

	var direction = data.get_string("direction", "out")
	var duration = data.get_float("duration", 0.5)
	SignalBus.fade_requested.emit(direction, duration)
