## Pauses engine for a duration or until player click.
class_name WaitHandler extends CommandHandler


func get_command_type() -> String:
	return "wait"


func execute(data: CommandData, context: ScenarioContext) -> void:
	if context.is_replay:
		return

	var mode = data.get_string("mode", "")

	if mode == "click":
		await SignalBus.advance_requested
	else:
		var duration = data.get_float("duration", 1.0)
		await Engine.get_main_loop().create_timer(duration).timeout
