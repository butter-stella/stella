## Base class for all command handlers.
## Subclass this and override get_command_type() and execute().
class_name CommandHandler extends RefCounted


func get_command_type() -> String:
	return ""


func execute(_data: CommandData, _context: ScenarioContext) -> void:
	pass


func rollback(_data: CommandData, _context: ScenarioContext) -> void:
	pass


## Internal RefCounted used by await_with_abort to multiplex completion and
## cancellation signals. Each call gets its own instance, so parallel races
## never collide and a same-tick second signal cannot resolve twice.
class _AbortRaceWaiter extends RefCounted:
	signal done(was_aborted: bool)
	var _resolved: bool = false

	func resolve(was_aborted: bool) -> void:
		if _resolved:
			return
		_resolved = true
		done.emit(was_aborted)


## Race `target` against the owning ScenarioContext generation and the legacy
## global abort notification. Returns true only if `target` completed while the
## context was still current; returns false for either cancellation source.
##
## Blocking handlers (dialogue, wait, choice, ...) should call this
## instead of bare `await`, so that backlog jump (and any future flow
## that needs to interrupt scenario execution) can promptly unblock the
## handler regardless of which native signal it was waiting for:
##
##     if not await CommandHandler.await_with_abort(
##         SignalBus.advance_requested, context):
##         return  # aborted — let the engine loop see ctx != context and exit
##
## Variadic-style accept_args is used so the helper works for signals
## with 0/1/2 arguments without per-handler bridge code.
static func await_with_abort(
	target: Signal,
	context: ScenarioContext = null,
) -> bool:
	if context != null and context.is_cancellation_requested():
		return false
	var waiter := _AbortRaceWaiter.new()

	var on_target := func(_a = null, _b = null, _c = null):
		waiter.resolve(false)
	var on_context_cancel := func():
		waiter.resolve(true)
	var on_abort := func():
		# Fold the compatibility signal into the same generation token so every
		# context-scoped waiter observes one authoritative cancellation state.
		if context != null:
			context.request_cancellation()
		waiter.resolve(true)

	target.connect(on_target, CONNECT_ONE_SHOT)
	if context != null:
		context.cancellation_requested.connect(
			on_context_cancel, CONNECT_ONE_SHOT)
	SignalBus.engine_abort_requested.connect(on_abort, CONNECT_ONE_SHOT)

	var was_aborted: bool = await waiter.done

	# Disconnect whichever didn't fire — CONNECT_ONE_SHOT auto-removes the
	# winner, but the loser is still wired and would leak.
	if target.is_connected(on_target):
		target.disconnect(on_target)
	if (
		context != null
		and context.cancellation_requested.is_connected(on_context_cancel)
	):
		context.cancellation_requested.disconnect(on_context_cancel)
	if SignalBus.engine_abort_requested.is_connected(on_abort):
		SignalBus.engine_abort_requested.disconnect(on_abort)

	return (
		not was_aborted
		and (context == null or not context.is_cancellation_requested())
	)
