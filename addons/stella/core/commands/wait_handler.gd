## Pauses engine for a duration or until player click.
class_name WaitHandler extends CommandHandler


func get_command_type() -> String:
	return "wait"


func execute(data: CommandData, _context: ScenarioContext) -> void:
	var mode = data.get_string("mode", "")

	# Both branches race against engine_abort_requested so a backlog jump
	# can promptly cancel a wait — including the timer-mode wait that
	# previously parked the old run() coroutine until its timer fired.
	if mode == "click":
		await CommandHandler.await_with_abort(SignalBus.advance_requested)
	else:
		var duration = data.get_float("duration", 1.0)
		var timer = Engine.get_main_loop().create_timer(duration)
		await CommandHandler.await_with_abort(timer.timeout)
