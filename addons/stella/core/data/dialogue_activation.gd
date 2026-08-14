## Request-scoped completion for one dialogue command activation.
##
## A DialogueRequest owns this handle. Consumers acknowledge that exact request
## through advance() or abort(); global input signals are presentation
## notifications and cannot complete a different command activation.
class_name DialogueActivation extends RefCounted

enum Outcome {
	PENDING,
	ADVANCED,
	ABORTED,
}

signal resolved(outcome: Outcome)

var _outcome: Outcome = Outcome.PENDING


func _init() -> void:
	SignalBus.engine_abort_requested.connect(_on_engine_abort_requested)


func advance() -> bool:
	return _resolve(Outcome.ADVANCED)


func abort() -> bool:
	return _resolve(Outcome.ABORTED)


func get_outcome() -> Outcome:
	return _outcome


func is_pending() -> bool:
	return _outcome == Outcome.PENDING


func _resolve(outcome: Outcome) -> bool:
	if _outcome != Outcome.PENDING:
		return false
	_outcome = outcome
	_disconnect_abort_signal()
	resolved.emit(_outcome)
	return true


func _on_engine_abort_requested() -> void:
	abort()


func _disconnect_abort_signal() -> void:
	if SignalBus.engine_abort_requested.is_connected(
		_on_engine_abort_requested
	):
		SignalBus.engine_abort_requested.disconnect(_on_engine_abort_requested)
