## Emits bg_changed signal for background switching.
class_name BgHandler extends CommandHandler


func get_command_type() -> String:
	return "bg"


func execute(data: CommandData, _context: ScenarioContext) -> void:
	var asset = data.get_string("asset", "")
	var transition = data.get_string("transition", "fade")
	var duration = data.get_float("duration", 0.5)

	SignalBus.bg_changed.emit(asset, transition, duration)
