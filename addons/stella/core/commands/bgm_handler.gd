## Emits bgm_play or bgm_stop signal for background music control.
class_name BgmHandler extends CommandHandler


func get_command_type() -> String:
	return "bgm"


func execute(data: CommandData, context: ScenarioContext) -> void:
	var fade = data.get_float("fade_duration", 1.0)
	var off = data.get_bool("off")

	if context.is_replay:
		if context.presentation_state:
			if off:
				context.presentation_state.apply_bgm_stop()
			else:
				context.presentation_state.apply_bgm_play(data.get_string("asset", ""))
		return

	if off:
		SignalBus.bgm_stop.emit(fade)
	else:
		var asset = data.get_string("asset", "")
		SignalBus.bgm_play.emit(asset, fade)
