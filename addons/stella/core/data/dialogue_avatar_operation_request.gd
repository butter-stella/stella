## Typed participant barrier for one addressable dialogue-avatar operation.
##
## Presenters validate and prepare all resources before the request is sealed.
## Readiness is a second synchronous quorum immediately before the infallible
## private apply phase, so no participant may discover a missing resource after
## another participant has started mutating its avatar projection.
extends RefCounted

signal settled(success: bool, cancelled: bool)

enum Phase {
	VALIDATING,
	APPLYING,
	FINISHED,
	CANCELLED,
}

var _operation: DialogueAvatarPresentationOperation
var _target_state: Dictionary = {}
var _force_cut: bool = false
var _phase: Phase = Phase.VALIDATING
var _request_id: int = 0
var _chain_index: int = 0
var _chain_size: int = 1
var _presenters: Dictionary = {}
var _validated: Dictionary = {}
var _accepted: Dictionary = {}
var _ready_presenters: Dictionary = {}
var _applied: Dictionary = {}
var _errors: Array[String] = []
var _success: bool = false
var _authority: Object
var _participant_validator: Callable


func _init(
	operation: DialogueAvatarPresentationOperation = null,
	target_state: Dictionary = {},
	force_cut: bool = false,
) -> void:
	_operation = operation
	_target_state = target_state.duplicate(true)
	_force_cut = force_cut


func get_operation() -> DialogueAvatarPresentationOperation:
	return _operation


func get_target_state() -> Dictionary:
	return _target_state.duplicate(true)


func get_request_id() -> int:
	return _request_id


func get_force_cut() -> bool:
	return _force_cut


func get_chain_index() -> int:
	return _chain_index


func get_chain_size() -> int:
	return _chain_size


func get_validation_errors() -> Array[String]:
	return _errors.duplicate()


func get_presenter_ids() -> Array:
	return _presenters.keys()


func is_finished() -> bool:
	return _phase in [Phase.FINISHED, Phase.CANCELLED]


func was_successful() -> bool:
	return _phase == Phase.FINISHED and _success


func _bind_authority(authority: Object, participant_validator: Callable) -> bool:
	if authority == null or _authority != null:
		return false
	_authority = authority
	_participant_validator = participant_validator
	return true


func _bind_preflight_chain(
	chain_index: int,
	chain_size: int,
	authority: Object,
) -> bool:
	if (
		authority != _authority
		or _phase != Phase.VALIDATING
		or chain_index < 0
		or chain_size <= 0
		or chain_index >= chain_size
	):
		return false
	_chain_index = chain_index
	_chain_size = chain_size
	return true


func _snapshot_presenter(
	presenter: Object,
	capability: Object,
	authority: Object,
) -> bool:
	if authority != _authority or _phase != Phase.VALIDATING:
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
	if authority != _authority or _phase != Phase.VALIDATING:
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
	return (
		(entry.get("presenter") as WeakRef).get_ref() == presenter
		and _presenter_error(presenter, entry.get("capability")).is_empty()
	)


func _validate(presenter: Object, authority: Object) -> bool:
	if authority != _authority or _phase != Phase.VALIDATING or not is_target(presenter):
		return false
	_validated[presenter.get_instance_id()] = true
	return true


func _accept(presenter: Object, authority: Object) -> bool:
	if authority != _authority or _phase != Phase.APPLYING or not is_target(presenter):
		return false
	_accepted[presenter.get_instance_id()] = true
	return true


func _ready(presenter: Object, authority: Object) -> bool:
	if (
		authority != _authority
		or _phase != Phase.APPLYING
		or not is_target(presenter)
		or not _accepted.has(presenter.get_instance_id())
	):
		return false
	_ready_presenters[presenter.get_instance_id()] = true
	return true


func _apply(presenter: Object, authority: Object) -> bool:
	if (
		authority != _authority
		or _phase != Phase.APPLYING
		or not is_target(presenter)
		or not _ready_presenters.has(presenter.get_instance_id())
	):
		return false
	_applied[presenter.get_instance_id()] = true
	return true


func _seal_validation(request_id: int, authority: Object) -> bool:
	if (
		authority != _authority
		or _phase != Phase.VALIDATING
		or request_id <= 0
		or _operation == null
		or not DialogueAvatarState.validate_snapshot_state(_target_state, false)
	):
		return false
	if _presenters.is_empty():
		_errors.append("no Runtime-owned DialoguePresenter is registered")
	for presenter_id: int in _presenters:
		var entry: Dictionary = _presenters[presenter_id]
		var presenter: Object = (entry.get("presenter") as WeakRef).get_ref()
		var error := _presenter_error(presenter, entry.get("capability"))
		if not error.is_empty():
			_errors.append("presenter %d %s" % [presenter_id, error])
		elif not _validated.has(presenter_id):
			_errors.append("presenter %d did not validate the request" % presenter_id)
	if not _errors.is_empty():
		return false
	_request_id = request_id
	_phase = Phase.APPLYING
	return true


func all_presenters_accepted() -> bool:
	return _all_presenters_recorded(_accepted)


func all_presenters_ready() -> bool:
	return _all_presenters_recorded(_ready_presenters)


func all_presenters_applied() -> bool:
	return _all_presenters_recorded(_applied)


func presenters_are_live() -> bool:
	if _presenters.is_empty():
		return false
	for entry_value: Variant in _presenters.values():
		var entry: Dictionary = entry_value
		var weak_presenter: WeakRef = entry.get("presenter")
		if (
			weak_presenter == null
			or not _presenter_error(
				weak_presenter.get_ref(), entry.get("capability")).is_empty()
		):
			return false
	return true


func _finish(success: bool, cancelled: bool, authority: Object) -> void:
	if authority != _authority or is_finished():
		return
	_success = success and not cancelled
	_phase = Phase.CANCELLED if cancelled else Phase.FINISHED
	settled.emit(_success, cancelled)


func _all_presenters_recorded(records: Dictionary) -> bool:
	if _phase != Phase.APPLYING or _presenters.is_empty():
		return false
	for presenter_id: int in _presenters:
		if not records.has(presenter_id):
			return false
	return true


func _presenter_error(presenter: Object, capability: Object) -> String:
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
