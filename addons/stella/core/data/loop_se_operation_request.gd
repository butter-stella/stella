## Typed validation/apply envelope for one persistent loop-SE operation.
## SignalBus snapshots the Runtime-owned AudioPresenter before any mixed batch
## child mutates state, so a missing resource rejects the whole batch atomically.
class_name LoopSeOperationRequest extends RefCounted

signal finished()

enum Phase { VALIDATING, APPLYING, FINISHED, CANCELLED }

var _payload: Dictionary
var _source: Dictionary
var _phase: Phase = Phase.VALIDATING
var _request_id: int = 0
var _force_cut: bool = false
var _authority: Object
var _participant_validator: Callable
var _presenter: WeakRef
var _capability: Object
var _validated: bool = false
var _accepted: bool = false
var _applied: bool = false
var _errors: Array[String] = []


func _init(payload: Dictionary = {}, source: Dictionary = {}) -> void:
	_payload = payload.duplicate(true)
	_source = source.duplicate(true)


func get_payload() -> Dictionary:
	return _payload.duplicate(true)


func get_source() -> Dictionary:
	return _source.duplicate(true)


func get_request_id() -> int:
	return _request_id


func get_force_cut() -> bool:
	return _force_cut


func get_validation_errors() -> Array[String]:
	return _errors.duplicate()


func _bind_authority(authority: Object, participant_validator: Callable) -> bool:
	if authority == null or _authority != null:
		return false
	_authority = authority
	_participant_validator = participant_validator
	return true


func _snapshot_presenter(
	presenter: Object,
	capability: Object,
	authority: Object,
) -> bool:
	if authority != _authority or _phase != Phase.VALIDATING:
		return false
	if not _participant_is_live(presenter, capability):
		_errors.append("the Runtime-owned AudioPresenter is unavailable")
		return false
	_presenter = weakref(presenter)
	_capability = capability
	return true


func is_target(presenter: Object) -> bool:
	return (
		_presenter != null
		and presenter != null
		and _presenter.get_ref() == presenter
		and _participant_is_live(presenter, _capability)
	)


func _reject(error: String, authority: Object) -> bool:
	if authority != _authority or _phase != Phase.VALIDATING:
		return false
	var normalized := error.strip_edges()
	_errors.append(
		normalized if not normalized.is_empty() else "AudioPresenter rejected the request"
	)
	return true


func _validate(presenter: Object, authority: Object) -> bool:
	if authority != _authority or _phase != Phase.VALIDATING or not is_target(presenter):
		return false
	_validated = true
	return true


func _seal_validation(request_id: int, authority: Object) -> bool:
	if authority != _authority or _phase != Phase.VALIDATING or request_id <= 0:
		return false
	var presenter := _presenter.get_ref() if _presenter != null else null
	if not _participant_is_live(presenter, _capability):
		_errors.append("the Runtime-owned AudioPresenter changed during validation")
	if not _validated and _errors.is_empty():
		_errors.append("the Runtime-owned AudioPresenter did not validate the request")
	if not _errors.is_empty():
		return false
	_request_id = request_id
	_phase = Phase.APPLYING
	return true


func _set_force_cut(force_cut: bool, authority: Object) -> bool:
	if authority != _authority or _phase != Phase.APPLYING:
		return false
	_force_cut = force_cut
	return true


func _accept(presenter: Object, authority: Object) -> bool:
	if authority != _authority or _phase != Phase.APPLYING or not is_target(presenter):
		return false
	_accepted = true
	return true


func _apply(presenter: Object, authority: Object) -> bool:
	if (
		authority != _authority
		or _phase != Phase.APPLYING
		or not _accepted
		or not is_target(presenter)
	):
		return false
	_applied = true
	return true


func presenter_is_live() -> bool:
	var presenter := _presenter.get_ref() if _presenter != null else null
	return _participant_is_live(presenter, _capability)


func was_accepted() -> bool:
	return _phase == Phase.APPLYING and _accepted


func was_applied() -> bool:
	return _phase == Phase.APPLYING and _applied


func _finish(success: bool, cancelled: bool, authority: Object) -> void:
	if authority != _authority or _phase in [Phase.FINISHED, Phase.CANCELLED]:
		return
	_phase = Phase.FINISHED if success and not cancelled else Phase.CANCELLED
	finished.emit()


func _participant_is_live(presenter: Object, capability: Object) -> bool:
	return (
		presenter != null
		and is_instance_valid(presenter)
		and presenter is Node
		and not (presenter as Node).is_queued_for_deletion()
		and capability != null
		and _participant_validator.is_valid()
		and bool(_participant_validator.call(presenter, capability))
	)
