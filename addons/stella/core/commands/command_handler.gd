## Base class for all command handlers.
## Subclass this and override get_command_type() and execute().
class_name CommandHandler extends RefCounted


func get_command_type() -> String:
	return ""


func execute(_data: CommandData, _context: ScenarioContext) -> void:
	pass


func rollback(_data: CommandData, _context: ScenarioContext) -> void:
	pass


## Internal RefCounted used by await_with_abort to multiplex two signals
## into one awaitable result. Each await_with_abort call gets its own
## instance, so multiple parallel races never collide.
class _AbortRaceWaiter extends RefCounted:
	signal done(was_aborted: bool)


## Race `target` against SignalBus.engine_abort_requested. Returns true if
## `target` fired first (normal completion), false if abort fired first.
##
## Blocking handlers (dialogue, wait, choice, ...) should call this
## instead of bare `await`, so that backlog jump (and any future flow
## that needs to interrupt scenario execution) can promptly unblock the
## handler regardless of which native signal it was waiting for:
##
##     if not await CommandHandler.await_with_abort(SignalBus.advance_requested):
##         return  # aborted — let the engine loop see ctx != context and exit
##
## Variadic-style accept_args is used so the helper works for signals
## with 0/1/2 arguments without per-handler bridge code.
static func await_with_abort(target: Signal) -> bool:
	var waiter := _AbortRaceWaiter.new()

	var on_target := func(_a = null, _b = null, _c = null):
		waiter.done.emit(false)
	var on_abort := func():
		waiter.done.emit(true)

	target.connect(on_target, CONNECT_ONE_SHOT)
	SignalBus.engine_abort_requested.connect(on_abort, CONNECT_ONE_SHOT)

	var was_aborted: bool = await waiter.done

	# Disconnect whichever didn't fire — CONNECT_ONE_SHOT auto-removes the
	# winner, but the loser is still wired and would leak.
	if target.is_connected(on_target):
		target.disconnect(on_target)
	if SignalBus.engine_abort_requested.is_connected(on_abort):
		SignalBus.engine_abort_requested.disconnect(on_abort)

	return not was_aborted
