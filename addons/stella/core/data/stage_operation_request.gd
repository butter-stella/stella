## Typed participant transaction for one contiguous run of named-stage operations.
##
## The Runtime-owned Director submits immutable StagePresentationOperations.
## SignalBus snapshots every admitted StagePresenter, then requires validation,
## acceptance, and synchronous apply acknowledgement before the run is
## considered delivered. Presenter-private plans may contain resolved resources
## and allocation decisions, but never replace the authored operations.
class_name StageOperationRequest extends RefCounted

signal settled

enum Phase {
	VALIDATING,
	APPLYING,
	FINISHED,
	CANCELLED,
}

var _operations: Array[StagePresentationOperation] = []
var _force_cut := false
var _phase: Phase = Phase.VALIDATING
var _request_id := 0
var _presenters: Dictionary = {}
var _validated_presenters: Dictionary = {}
var _accepted_presenters: Dictionary = {}
var _apply_ready_presenters: Dictionary = {}
var _apply_claimed_presenters: Dictionary = {}
var _applied_presenters: Dictionary = {}
var _apply_failed_presenters: Dictionary = {}
var _plans: Dictionary = {}
var _errors: Array[Dictionary] = []
var _success := false
var _authority: Object
var _participant_validator: Callable
var _preflight_chain_id := 0
var _preflight_run_index := 0
var _preflight_run_count := 1


func _init(
	operations: Array[StagePresentationOperation] = [],
	force_cut: bool = false,
) -> void:
	_operations = operations.duplicate()
	_force_cut = force_cut


func get_operations() -> Array[StagePresentationOperation]:
	return _operations.duplicate()


func get_payloads() -> Array:
	var payloads: Array = []
	for operation: StagePresentationOperation in _operations:
		payloads.append(operation.get_payload())
	return payloads


func get_force_cut() -> bool:
	return _force_cut


func get_request_id() -> int:
	return _request_id


func get_preflight_chain_id() -> int:
	return _preflight_chain_id


func get_preflight_run_index() -> int:
	return _preflight_run_index


func get_preflight_run_count() -> int:
	return _preflight_run_count


func get_validation_errors() -> Array[Dictionary]:
	return _errors.duplicate(true)


func get_presenter_count() -> int:
	return _presenters.size()


func is_finished() -> bool:
	return _phase in [Phase.FINISHED, Phase.CANCELLED]


func was_successful() -> bool:
	return _phase == Phase.FINISHED and _success


func is_target(presenter: Object) -> bool:
	if presenter == null or not is_instance_valid(presenter):
		return false
	var presenter_id := presenter.get_instance_id()
	if not _presenters.has(presenter_id):
		return false
	var entry: Dictionary = _presenters[presenter_id]
	var weak_presenter: WeakRef = entry.get("presenter")
	var registered: Object = weak_presenter.get_ref() if weak_presenter != null else null
	return (
		registered == presenter
		and _presenter_error(registered, entry.get("capability")).is_empty()
	)


func get_plan(presenter: Object) -> Dictionary:
	if not is_target(presenter):
		return {}
	return (_plans.get(presenter.get_instance_id(), {}) as Dictionary).duplicate(true)


func _bind_authority(authority: Object, participant_validator: Callable) -> bool:
	if _authority != null or authority == null:
		return false
	_authority = authority
	_participant_validator = participant_validator
	return true


func _bind_preflight_chain(
	chain_id: int,
	run_index: int,
	run_count: int,
	authority: Object,
) -> bool:
	if (
		authority != _authority
		or _phase != Phase.VALIDATING
		or chain_id <= 0
		or run_index < 0
		or run_count <= 0
		or run_index >= run_count
	):
		return false
	_preflight_chain_id = chain_id
	_preflight_run_index = run_index
	_preflight_run_count = run_count
	return true


func _snapshot_presenter(
	presenter: Object,
	capability: Object,
	authority: Object,
	transaction: Callable = Callable(),
) -> bool:
	if _phase != Phase.VALIDATING or authority != _authority:
		return false
	var error := _presenter_error(presenter, capability)
	if not error.is_empty():
		_reject(-1, error, authority)
		return false
	var presenter_id := presenter.get_instance_id()
	if _presenters.has(presenter_id):
		_reject(-1, "presenter %d registered more than once" % presenter_id, authority)
		return false
	_presenters[presenter_id] = {
		"presenter": weakref(presenter),
		"capability": capability,
		"transaction": transaction,
	}
	return true


func _reject(operation_index: int, error: String, authority: Object) -> bool:
	if _phase != Phase.VALIDATING or authority != _authority:
		return false
	var source := {}
	if operation_index >= 0 and operation_index < _operations.size():
		source = _operations[operation_index].get_source()
	_errors.append({
		"source": source,
		"error": (
			error.strip_edges()
			if not error.strip_edges().is_empty()
			else "presenter rejected the Stage run"
		),
	})
	return true


func _validate(
	presenter: Object,
	plan: Dictionary,
	authority: Object,
) -> bool:
	if authority != _authority or _phase != Phase.VALIDATING or not is_target(presenter):
		return false
	var presenter_id := presenter.get_instance_id()
	_validated_presenters[presenter_id] = true
	_plans[presenter_id] = plan.duplicate(true)
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
		or not _apply_ready_presenters.has(presenter.get_instance_id())
		or not _apply_claimed_presenters.has(presenter.get_instance_id())
		or _apply_failed_presenters.has(presenter.get_instance_id())
	):
		return false
	_applied_presenters[presenter.get_instance_id()] = true
	return true


func _mark_apply_ready(presenter: Object, authority: Object) -> bool:
	if (
		authority != _authority
		or _phase != Phase.APPLYING
		or not is_target(presenter)
		or not _accepted_presenters.has(presenter.get_instance_id())
		or _apply_failed_presenters.has(presenter.get_instance_id())
	):
		return false
	_apply_ready_presenters[presenter.get_instance_id()] = true
	return true


func _mark_apply_claimed(presenter: Object, authority: Object) -> bool:
	if (
		authority != _authority
		or _phase != Phase.APPLYING
		or not is_target(presenter)
		or not _accepted_presenters.has(presenter.get_instance_id())
		or not _apply_ready_presenters.has(presenter.get_instance_id())
		or _apply_failed_presenters.has(presenter.get_instance_id())
	):
		return false
	_apply_claimed_presenters[presenter.get_instance_id()] = true
	return true


func _fail_apply(
	presenter: Object,
	operation_index: int,
	error: String,
	authority: Object,
) -> bool:
	if (
		authority != _authority
		or _phase != Phase.APPLYING
		or not is_target(presenter)
		or not _accepted_presenters.has(presenter.get_instance_id())
	):
		return false
	var presenter_id := presenter.get_instance_id()
	if _apply_failed_presenters.has(presenter_id):
		return false
	_apply_failed_presenters[presenter_id] = true
	var source := {}
	if operation_index >= 0 and operation_index < _operations.size():
		source = _operations[operation_index].get_source()
	_errors.append({
		"source": source,
		"error": (
			error.strip_edges()
			if not error.strip_edges().is_empty()
			else "presenter could not apply the sealed Stage run"
		),
	})
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


func all_presenters_apply_ready() -> bool:
	if _phase != Phase.APPLYING or not _apply_failed_presenters.is_empty():
		return false
	for presenter_id: int in _presenters:
		if not _apply_ready_presenters.has(presenter_id):
			return false
	return true


func all_presenters_apply_claimed() -> bool:
	if _phase != Phase.APPLYING or not _apply_failed_presenters.is_empty():
		return false
	for presenter_id: int in _presenters:
		if not _apply_claimed_presenters.has(presenter_id):
			return false
	return true


func _get_transaction_participants(authority: Object) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if authority != _authority or _phase != Phase.APPLYING:
		return result
	for presenter_id: int in _presenters:
		var entry: Dictionary = _presenters[presenter_id]
		var weak_presenter: WeakRef = entry.get("presenter")
		var presenter: Object = (
			weak_presenter.get_ref() if weak_presenter != null else null)
		result.append({
			"presenter": presenter,
			"capability": entry.get("capability"),
			"transaction": entry.get("transaction", Callable()),
		})
	return result


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
		or _operations.is_empty()
	):
		return false
	if _presenters.is_empty() and _errors.is_empty():
		_reject(
			0,
			"no live Runtime-owned StagePresenter is available",
			authority,
		)
	for presenter_id: int in _presenters:
		var entry: Dictionary = _presenters[presenter_id]
		var weak_presenter: WeakRef = entry.get("presenter")
		var presenter: Object = weak_presenter.get_ref() if weak_presenter != null else null
		var error := _presenter_error(presenter, entry.get("capability"))
		if not error.is_empty():
			_reject(-1, "presenter %d %s" % [presenter_id, error], authority)
		elif not _validated_presenters.has(presenter_id):
			_reject(-1, "presenter %d did not validate the Stage run" % presenter_id, authority)
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
	settled.emit()


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
