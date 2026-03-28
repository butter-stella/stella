## Emits bgm_play or bgm_stop signal for background music control.
class_name BgmHandler extends CommandHandler


func get_command_type() -> String:
	return "bgm"


func execute(data: CommandData, _context: ScenarioContext) -> void:
	var fade = data.get_float("fade_duration", 1.0)

	if data.get_bool("off"):
		SignalBus.bgm_stop.emit(fade)
	else:
		var asset = data.get_string("asset", "")
		SignalBus.bgm_play.emit(asset, fade)
