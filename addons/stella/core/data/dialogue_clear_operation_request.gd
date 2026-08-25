## Typed synchronous participant transaction for one dialogue-page clear.
##
## The immutable PresentationOperation remains the authored value. This request
## snapshots the Runtime-owned DialoguePresenter quorum before any mixed batch
## child is applied, then requires every captured participant to validate,
## accept, and acknowledge the synchronous cut projection. It deliberately has
## no transition receipt: clearing content never creates a Tween or wall-clock
## wait.
extends RefCounted


enum Phase {
	VALIDATING,
	APPLYING,
	FINISHED,
	CANCELLED,
}

var _operation: DialogueClearPresentationOperation
var _phase: Phase = Phase.VALIDATING
var _request_id := 0
var _presenters: Dictionary = {}
var _validated_presenters: Dictionary = {}
var _accepted_presenters: Dictionary = {}
var _applied_presenters: Dictionary = {}
var _errors: Array[String] = []
var _success := false
var _authority: Object
var _participant_validator: Callable


func _init(operation: DialogueClearPresentationOperation = null) -> void:
	_operation = operation


func get_operation() -> DialogueClearPresentationOperation:
	return _operation


func get_request_id() -> int:
	return _request_id


func get_validation_errors() -> Array[String]:
	return _errors.duplicate()


func get_presenter_ids() -> Array:
	return _presenters.keys()


func get_presenter_count() -> int:
	return _presenters.size()


func get_applied_presenter_count() -> int:
	return _applied_presenters.size()


func is_finished() -> bool:
	return _phase in [Phase.FINISHED, Phase.CANCELLED]


func was_successful() -> bool:
	return _phase == Phase.FINISHED and _success


func _bind_authority(authority: Object, participant_validator: Callable) -> bool:
	if _authority != null or authority == null:
		return false
	_authority = authority
	_participant_validator = participant_validator
	return true


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


func _reject(error: String, authority: Object) -> bool:
	if _phase != Phase.VALIDATING or authority != _authority:
		return false
	var normalized := error.strip_edges()
	_errors.append(
		normalized if not normalized.is_empty() else "presenter rejected the request")
	return true


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


func _accept(presenter: Object, authority: Object) -> bool:
	if authority != _authority or _phase != Phase.APPLYING or not is_target(presenter):
		return false
	_accepted_presenters[presenter.get_instance_id()] = true
	return true


func _apply(presenter: Object, authority: Object) -> bool:
	if (
		authority != _authority
		or _phase != Phase.APPLYING
		or not is_target(presenter)
		or not _accepted_presenters.has(presenter.get_instance_id())
	):
		return false
	_applied_presenters[presenter.get_instance_id()] = true
	return true


func all_presenters_accepted() -> bool:
	if _phase != Phase.APPLYING:
		return false
	for presenter_id: int in _presenters:
		if not _accepted_presenters.has(presenter_id):
			return false
	return true


func all_presenters_applied() -> bool:
	if _phase != Phase.APPLYING:
		return false
	for presenter_id: int in _presenters:
		if not _applied_presenters.has(presenter_id):
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
	if (
		authority != _authority
		or _phase != Phase.VALIDATING
		or request_id <= 0
		or _operation == null
	):
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
