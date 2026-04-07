## Emits se_play or se_stop signal for sound effects.
class_name SeHandler extends CommandHandler


func get_command_type() -> String:
	return "se"


func execute(data: CommandData, context: ScenarioContext) -> void:
	if context.is_replay:
		return

	var asset = data.get_string("asset", "")

	if data.get_bool("off"):
		SignalBus.se_stop.emit(asset)
	else:
		var loop = data.get_bool("loop")
		SignalBus.se_play.emit(asset, loop)
