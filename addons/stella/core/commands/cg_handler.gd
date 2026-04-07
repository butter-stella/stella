## Emits cg_show or cg_hide signal for CG display.
class_name CgHandler extends CommandHandler


func get_command_type() -> String:
	return "cg"


func execute(data: CommandData, _context: ScenarioContext) -> void:
	if data.get_bool("off"):
		var transition = data.get_string("transition", "fade")
		var duration = data.get_float("duration", 0.5)
		SignalBus.cg_hide.emit(transition, duration)
	else:
		var asset = data.get_string("asset", "")
		var mode = data.get_string("mode", "fullscreen")
		var transition = data.get_string("transition", "fade")
		var duration = data.get_float("duration", 0.5)
		SignalBus.cg_show.emit(asset, mode, transition, duration)
