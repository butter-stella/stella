## Emits bg_changed signal for background switching.
class_name BgHandler extends CommandHandler


func get_command_type() -> String:
	return "bg"


func execute(data: CommandData, context: ScenarioContext) -> void:
	var asset = data.get_string("asset", "")

	if context.is_replay:
		# Mirror state directly; runtime snaps visuals after replay finishes.
		if context.presentation_state:
			context.presentation_state.apply_bg(asset)
		return

	var transition = data.get_string("transition", "fade")
	var duration = data.get_float("duration", 0.5)
	SignalBus.bg_changed.emit(asset, transition, duration)
