## Typed authority for one authored chapter-indicator operation.
##
## Value getters return immutable primitives or defensive copies. Presenters
## join during validation and must explicitly accept the sealed request during
## apply; a mutable signal payload can therefore neither rewrite the operation
## nor remove another participant from the completion barrier.
extends RefCounted


enum Phase {
	VALIDATING,
	APPLYING,
	FINISHED,
	CANCELLED,
}

var _visible: bool = false
var _transition: String = "cut"
var _duration: float = 0.0
var _source: Dictionary = {}
var _phase: Phase = Phase.VALIDATING
var _request_id: int = 0
var _presenters: Dictionary = {}
var _validated_presenters: Dictionary = {}
var _accepted_presenters: Dictionary = {}
var _errors: Array[String] = []
var _success: bool = false
var _authority: Object
var _participant_validator: Callable


func _init(
	p_visible: bool = false,
	p_transition: String = "cut",
	p_duration: float = 0.0,
	p_source: Dictionary = {},
) -> void:
	_visible = p_visible
	_transition = p_transition
	_duration = p_duration
	_source = p_source.duplicate(true)


func get_visible() -> bool:
	return _visible


func get_transition() -> String:
	return _transition


func get_duration() -> float:
	return _duration


func get_source() -> Dictionary:
	return _source.duplicate(true)


func get_request_id() -> int:
	return _request_id


func is_finished() -> bool:
	return _phase in [Phase.FINISHED, Phase.CANCELLED]


func was_successful() -> bool:
	return _phase == Phase.FINISHED and _success


func was_cancelled() -> bool:
	return _phase == Phase.CANCELLED


func _bind_authority(authority: Object, participant_validator: Callable) -> bool:
	if _authority != null or authority == null:
		return false
	_authority = authority
	_participant_validator = participant_validator
	return true


## Freeze one SignalBus-registry participant into this request's authority.
func _snapshot_presenter(
	presenter: Object,
	capability: Object,
	authority: Object,
) -> bool:
	if _phase != Phase.VALIDATING or authority != _authority:
		return false
	var error := _presenter_error(presenter, capability)
	if not error.is_empty():
		_reject(error, authority)
		return false
	var presenter_id := presenter.get_instance_id()
	if _presenters.has(presenter_id):
		_reject("presenter %d registered more than once" % presenter_id, authority)
		return false
	_presenters[presenter_id] = {
		"presenter": weakref(presenter),
		"capability": capability,
	}
	return true


## Reject the complete operation during validation. Multiple independent
## validators may contribute diagnostics; callers cannot mutate the stored list.
func _reject(error: String, authority: Object) -> bool:
	if _phase != Phase.VALIDATING or authority != _authority:
		return false
	var normalized := error.strip_edges()
	if normalized.is_empty():
		normalized = "presenter rejected the request"
	_errors.append(normalized)
	return true


func get_validation_errors() -> Array[String]:
	return _errors.duplicate()


func get_presenter_ids() -> Array:
	return _presenters.keys()


## True only for the exact live object registered before sealing.
func is_target(presenter: Object) -> bool:
	if presenter == null or not is_instance_valid(presenter):
		return false
	var presenter_id := presenter.get_instance_id()
	if not _presenters.has(presenter_id):
		return false
	var entry: Dictionary = _presenters[presenter_id]
	var registered: Object = (entry.get("presenter") as WeakRef).get_ref()
	return (
		registered == presenter
		and _presenter_error(registered, entry.get("capability")).is_empty()
	)


func _validate(presenter: Object, authority: Object) -> bool:
	if authority != _authority or _phase != Phase.VALIDATING or not is_target(presenter):
		return false
	_validated_presenters[presenter.get_instance_id()] = true
	return true


## Apply acknowledgement. The Bus rejects a dispatch unless every sealed
## participant accepted; merely remaining alive is insufficient.
func _accept(presenter: Object, authority: Object) -> bool:
	if authority != _authority or _phase != Phase.APPLYING or not is_target(presenter):
		return false
	_accepted_presenters[presenter.get_instance_id()] = true
	return true


func _has_accepted_identity(
	presenter: Object,
	capability: Object,
	authority: Object,
) -> bool:
	if (
		authority != _authority
		or presenter == null
		or not is_instance_valid(presenter)
	):
		return false
	var presenter_id := presenter.get_instance_id()
	if not _presenters.has(presenter_id):
		return false
	var entry: Dictionary = _presenters[presenter_id]
	var registered: Object = (entry.get("presenter") as WeakRef).get_ref()
	return (
		registered == presenter
		and entry.get("capability") == capability
		and _accepted_presenters.has(presenter_id)
	)


func all_presenters_accepted() -> bool:
	if _phase != Phase.APPLYING:
		return false
	for presenter_id: int in _presenters:
		if not _accepted_presenters.has(presenter_id):
			return false
	return true


func presenters_are_live() -> bool:
	for entry_value: Variant in _presenters.values():
		var entry: Dictionary = entry_value
		var weak_presenter: WeakRef = entry.get("presenter")
		if weak_presenter == null or not _presenter_error(
			weak_presenter.get_ref(), entry.get("capability")).is_empty():
			return false
	return true


func _seal_validation(request_id: int, authority: Object) -> bool:
	if authority != _authority or _phase != Phase.VALIDATING or request_id <= 0:
		return false
	for presenter_id: int in _presenters:
		var entry: Dictionary = _presenters[presenter_id]
		var presenter: Object = (entry.get("presenter") as WeakRef).get_ref()
		var error := _presenter_error(presenter, entry.get("capability"))
		if not error.is_empty():
			_errors.append("presenter %d %s" % [presenter_id, error])
		elif not _validated_presenters.has(presenter_id):
			_errors.append("presenter %d did not validate the request" % presenter_id)
	if not _errors.is_empty():
		return false
	_request_id = request_id
	_phase = Phase.APPLYING
	return true


func _finish(success: bool, cancelled: bool, authority: Object) -> void:
	if authority != _authority or is_finished():
		return
	_success = success and not cancelled
	_phase = Phase.CANCELLED if cancelled else Phase.FINISHED


func _presenter_error(presenter: Object, capability: Object = null) -> String:
	if presenter == null or not is_instance_valid(presenter):
		return "is no longer valid"
	if presenter is Node and (presenter as Node).is_queued_for_deletion():
		return "is queued for deletion"
	if (
		capability == null
		or not _participant_validator.is_valid()
		or not bool(_participant_validator.call(presenter, capability))
	):
		return "is not an active registered participant"
	return ""
