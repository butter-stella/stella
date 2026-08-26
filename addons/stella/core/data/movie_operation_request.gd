## Authority-bound validation/apply envelope for one canonical movie operation.
class_name MovieOperationRequest extends RefCounted

signal finished()

enum Phase { VALIDATING, APPLYING, FINISHED, CANCELLED }

var _operation: MoviePresentationOperation
var _phase := Phase.VALIDATING
var _request_id := 0
var _authority: Object
var _participant_validator: Callable
var _presenter: WeakRef
var _capability: RefCounted
var _validated := false
var _accepted := false
var _applied := false
var _committed_state: Dictionary = {}
var _errors: Array[String] = []


func _init(operation: MoviePresentationOperation = null) -> void:
	_operation = operation


func get_operation() -> MoviePresentationOperation:
	return _operation


func get_payload() -> Dictionary:
	return _operation.get_payload() if _operation != null else {}


func get_source() -> Dictionary:
	return _operation.get_source() if _operation != null else {}


func get_request_id() -> int:
	return _request_id


func get_validation_errors() -> Array[String]:
	return _errors.duplicate()


func get_committed_state() -> Dictionary:
	return _committed_state.duplicate(true)


func _bind_authority(authority: Object, participant_validator: Callable) -> bool:
	if authority == null or _authority != null:
		return false
	_authority = authority
	_participant_validator = participant_validator
	return true


func _snapshot_presenter(
	presenter: Object,
	capability: RefCounted,
	authority: Object,
) -> bool:
	if authority != _authority or _phase != Phase.VALIDATING:
		return false
	if not _participant_is_live(presenter, capability):
		_errors.append("the Runtime-owned MoviePresenter is unavailable")
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
		normalized if not normalized.is_empty()
		else "MoviePresenter rejected the request")
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
		_errors.append("the Runtime-owned MoviePresenter changed during validation")
	if not _validated and _errors.is_empty():
		_errors.append("the Runtime-owned MoviePresenter did not validate the request")
	if not _errors.is_empty():
		return false
	_request_id = request_id
	_phase = Phase.APPLYING
	return true


func _accept(presenter: Object, authority: Object) -> bool:
	if authority != _authority or _phase != Phase.APPLYING or not is_target(presenter):
		return false
	_accepted = true
	return true


func _apply(
	presenter: Object,
	committed_state: Dictionary,
	authority: Object,
) -> bool:
	if (
		authority != _authority
		or _phase != Phase.APPLYING
		or not _accepted
		or not is_target(presenter)
		or not MovieChannelState.validate_snapshot_state(committed_state, false)
	):
		return false
	_committed_state = committed_state.duplicate(true)
	_applied = true
	return true


func _fail_apply(error: String, authority: Object) -> bool:
	if authority != _authority or _phase != Phase.APPLYING:
		return false
	var normalized := error.strip_edges()
	_errors.append(
		normalized if not normalized.is_empty()
		else "MoviePresenter failed the sealed apply")
	return true


func was_accepted() -> bool:
	return _phase == Phase.APPLYING and _accepted


func was_applied() -> bool:
	return _phase == Phase.APPLYING and _applied


func presenter_is_live() -> bool:
	var presenter := _presenter.get_ref() if _presenter != null else null
	return _participant_is_live(presenter, _capability)


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
