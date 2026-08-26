## Runtime-only entry contract for one ScenarioContext execution.
##
## Story playback carries no caller. Recollection playback carries one explicit
## zero-argument continuation that is validated before entry and consumed at
## most once after Runtime has retired the scenario and all presentation owners.
## This object is deliberately excluded from save snapshots: a Callable cannot
## be reconstructed safely across process, scene, or script revisions.
class_name ScenarioPlaybackContext extends RefCounted

enum Mode {
	STORY,
	RECOLLECTION,
}

enum Status {
	ACTIVE,
	RETURNING,
	RETURNED,
	CANCELLED,
}

var _mode: int = Mode.STORY
var _status: int = Status.ACTIVE
var _return_continuation: Callable
var _entry_validated: bool = true


static func story() -> ScenarioPlaybackContext:
	return ScenarioPlaybackContext.new()


static func recollection(
	return_continuation: Callable,
) -> ScenarioPlaybackContext:
	var context := ScenarioPlaybackContext.new()
	context._mode = Mode.RECOLLECTION
	context._return_continuation = return_continuation
	# Freeze the entry precondition at construction time. A valid target may be
	# freed by the accepted scene handoff before ScenarioContext is installed;
	# that later lifetime loss must not turn an accepted recollection back into
	# story playback or skip its deterministic return cleanup.
	context._entry_validated = continuation_is_valid(return_continuation)
	return context


static func continuation_is_valid(return_continuation: Callable) -> bool:
	return (
		return_continuation.is_valid()
		and return_continuation.get_argument_count() == 0
	)


func is_valid_for_entry() -> bool:
	if _mode == Mode.STORY:
		return _status == Status.ACTIVE
	return (
		_mode == Mode.RECOLLECTION
		and _status == Status.ACTIVE
		and _entry_validated
	)


func is_recollection() -> bool:
	return _mode == Mode.RECOLLECTION


func get_status() -> int:
	return _status


## Claim the unique terminal return before any cleanup signal can re-enter
## Runtime. Continuation validity is intentionally checked only by complete:
## a target may disappear after entry, but Runtime must still retire the whole
## execution/presentation generation before reporting that failure.
func try_begin_return() -> bool:
	if (
		_mode != Mode.RECOLLECTION
		or _status != Status.ACTIVE
		or not _entry_validated
	):
		return false
	_status = Status.RETURNING
	return true


## Settle before invoking caller code. A synchronous callback may start another
## story/recollection or return to title; the retired owner has no tail after
## this call that could cancel that replacement.
func complete_return() -> bool:
	if _mode != Mode.RECOLLECTION or _status != Status.RETURNING:
		return false
	var continuation := _return_continuation
	_return_continuation = Callable()
	if not continuation_is_valid(continuation):
		_status = Status.CANCELLED
		return false
	_status = Status.RETURNED
	continuation.call()
	return true


## A winning normal load/start/title navigation supersedes a recollection
## caller rather than reopening the old gallery surface behind the new owner.
func cancel() -> bool:
	if _mode != Mode.RECOLLECTION or _status in [Status.RETURNED, Status.CANCELLED]:
		return false
	_status = Status.CANCELLED
	_return_continuation = Callable()
	return true
