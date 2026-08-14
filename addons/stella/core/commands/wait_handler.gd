## Pauses engine for a duration or until player click.
class_name WaitHandler extends CommandHandler


func get_command_type() -> String:
	return "wait"


func execute(data: CommandData, context: ScenarioContext) -> void:
	var mode = data.get_string("mode", "")

	# Both branches join the context's execution generation so every context
	# replacement promptly cancels them, including timer waits whose native
	# timeout may be far in the future. The global abort remains a compatibility
	# source inside await_with_abort and is folded into the same generation.
	if mode == "click":
		await CommandHandler.await_with_abort(
			SignalBus.advance_requested, context)
	else:
		var duration = data.get_float("duration", 1.0)
		var timer = Engine.get_main_loop().create_timer(duration)
		await CommandHandler.await_with_abort(timer.timeout, context)
