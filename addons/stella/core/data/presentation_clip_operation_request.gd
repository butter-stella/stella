## Authority-bound composite quorum for one declarative presentation clip.
##
## The definition is prepared before the Bus snapshots the exact visual, UI,
## and audio owners. Every participant validates and claims detached work before
## any participant commits its private projection.
class_name PresentationClipOperationRequest extends RefCounted

const ROLE_VISUAL := &"visual"
const ROLE_DIALOGUE := &"dialogue"
const ROLE_AUDIO := &"audio"

enum Phase {
	PREPARING,
	VALIDATING,
	ACCEPTING,
	READYING,
	APPLYING,
	PUBLISH_READYING,
	COMMITTING,
	FINISHED,
	CANCELLED,
}

var _operation: PresentationClipPresentationOperation
var _source: Dictionary = {}
var _force_cut := false
var _phase := Phase.PREPARING
var _request_id := 0
var _definition: PresentationClipDefinition
var _definition_value: Dictionary = {}
var _participants: Dictionary = {}
var _validated: Dictionary = {}
var _accepted: Dictionary = {}
var _ready: Dictionary = {}
var _applied: Dictionary = {}
var _publish_ready: Dictionary = {}
var _errors: Array[String] = []
var _authority: Object


func _init(
	operation: PresentationClipPresentationOperation = null,
	force_cut: bool = false,
) -> void:
	_operation = operation
	_source = operation.get_source() if operation != null else {}
	_force_cut = force_cut


func get_operation() -> PresentationClipPresentationOperation:
	return _operation


func get_asset() -> String:
	return String(_operation.get_payload().get("asset", "")) if _operation != null else ""


func get_source() -> Dictionary:
	return _source.duplicate(true)


func get_force_cut() -> bool:
	return _force_cut


func get_request_id() -> int:
	return _request_id


func get_definition() -> Dictionary:
	return _definition_value.duplicate(true)


func get_validation_errors() -> Array[String]:
	return _errors.duplicate()


func all_participants_accepted() -> bool:
	return _all_participants_recorded(_accepted)


func all_participants_ready() -> bool:
	return _all_participants_recorded(_ready)


func all_participants_applied() -> bool:
	return _all_participants_recorded(_applied)


func all_participants_publish_ready() -> bool:
	return _all_participants_recorded(_publish_ready)


func participants_are_live() -> bool:
	for key: String in _participants:
		if not _participant_error(_participants[key]).is_empty():
			return false
	return true


func has_role(role: StringName) -> bool:
	for entry_value: Variant in _participants.values():
		if StringName((entry_value as Dictionary).get("role")) == role:
			return true
	return false


func is_target(presenter: Object, role: StringName) -> bool:
	if presenter == null or not is_instance_valid(presenter):
		return false
	var key := _participant_key(role, presenter.get_instance_id())
	if not _participants.has(key):
		return false
	var entry: Dictionary = _participants[key]
	var weak_presenter: WeakRef = entry.get("presenter")
	return (
		weak_presenter != null
		and weak_presenter.get_ref() == presenter
		and _participant_error(entry).is_empty()
	)


func _bind_authority(authority: Object) -> bool:
	if authority == null or _authority != null:
		return false
	_authority = authority
	return true


func _set_definition(
	definition: PresentationClipDefinition,
	authority: Object,
) -> bool:
	if authority != _authority or _phase != Phase.PREPARING or definition == null:
		return false
	_definition = definition
	_definition_value = definition.canonical_value_snapshot()
	return true


func _get_sealed_definition(authority: Object) -> PresentationClipDefinition:
	if authority != _authority:
		return null
	return _definition


func _reject_prepare(error: String, authority: Object) -> bool:
	if authority != _authority or _phase != Phase.PREPARING:
		return false
	var normalized := error.strip_edges()
	_errors.append(
		normalized if not normalized.is_empty() else "clip definition preparation failed")
	return true


func _finish_prepare(authority: Object) -> bool:
	if authority != _authority or _phase != Phase.PREPARING:
		return false
	if _definition == null:
		if _errors.is_empty():
			_errors.append("clip definition was not prepared")
		return false
	_phase = Phase.VALIDATING
	return true


func _snapshot_participant(
	role: StringName,
	presenter: Object,
	capability: RefCounted,
	validator: Callable,
	transaction: Callable,
	authority: Object,
) -> bool:
	if authority != _authority or _phase != Phase.VALIDATING:
		return false
	if (
		role not in [ROLE_VISUAL, ROLE_DIALOGUE, ROLE_AUDIO]
		or presenter == null
		or capability == null
		or not validator.is_valid()
		or not transaction.is_valid()
	):
		_errors.append("required '%s' clip participant is unavailable" % role)
		return false
	var key := _participant_key(role, presenter.get_instance_id())
	if _participants.has(key):
		_errors.append("clip participant '%s' was registered more than once" % key)
		return false
	var entry := {
		"role": role,
		"presenter": weakref(presenter),
		"capability": capability,
		"validator": validator,
		"transaction": transaction,
	}
	_participants[key] = entry
	var error := _participant_error(entry)
	if not error.is_empty():
		_errors.append(error)
		return false
	return true


func _reject(
	presenter: Object,
	role: StringName,
	error: String,
	authority: Object,
) -> bool:
	if authority != _authority or _phase != Phase.VALIDATING:
		return false
	if not is_target(presenter, role):
		return false
	var normalized := error.strip_edges()
	_errors.append("%s participant: %s" % [
		role,
		normalized if not normalized.is_empty() else "rejected the request",
	])
	return true


func _validate(
	presenter: Object,
	role: StringName,
	authority: Object,
) -> bool:
	if authority != _authority or _phase != Phase.VALIDATING or not is_target(
		presenter, role):
		return false
	_validated[_participant_key(role, presenter.get_instance_id())] = true
	return true


func _seal_validation(request_id: int, authority: Object) -> bool:
	if authority != _authority or _phase != Phase.VALIDATING or request_id <= 0:
		return false
	for key: String in _participants:
		var error := _participant_error(_participants[key])
		if not error.is_empty():
			_errors.append(error)
		elif not _validated.has(key):
			_errors.append("clip participant '%s' did not validate" % key)
	if not _errors.is_empty() or _participants.is_empty():
		return false
	_request_id = request_id
	_phase = Phase.ACCEPTING
	return true


func _accept(
	presenter: Object,
	role: StringName,
	authority: Object,
) -> bool:
	if authority != _authority or _phase != Phase.ACCEPTING or not is_target(
		presenter, role):
		return false
	_accepted[_participant_key(role, presenter.get_instance_id())] = true
	return true


func _seal_accept(authority: Object) -> bool:
	if authority != _authority or _phase != Phase.ACCEPTING:
		return false
	_record_participant_phase_failures(&"accept", _accepted)
	if not all_participants_accepted() or not participants_are_live():
		return false
	_phase = Phase.READYING
	return true


func _mark_ready(
	presenter: Object,
	role: StringName,
	authority: Object,
) -> bool:
	if authority != _authority or _phase != Phase.READYING or not is_target(
		presenter, role):
		return false
	_ready[_participant_key(role, presenter.get_instance_id())] = true
	return true


func _seal_readiness(authority: Object) -> bool:
	if authority != _authority or _phase != Phase.READYING:
		return false
	_record_participant_phase_failures(&"apply readiness", _ready)
	if not all_participants_ready() or not participants_are_live():
		return false
	_phase = Phase.APPLYING
	return true


func _apply(
	presenter: Object,
	role: StringName,
	authority: Object,
) -> bool:
	if authority != _authority or _phase != Phase.APPLYING or not is_target(
		presenter, role):
		return false
	_applied[_participant_key(role, presenter.get_instance_id())] = true
	return true


func _fail_current(error: String, authority: Object) -> bool:
	if (
		authority != _authority
		or _phase not in [
			Phase.READYING,
			Phase.APPLYING,
			Phase.PUBLISH_READYING,
			Phase.COMMITTING,
		]
	):
		return false
	var normalized := error.strip_edges()
	_errors.append(
		normalized if not normalized.is_empty()
		else "sealed clip transaction changed after validation")
	return true


func _begin_publish_readiness(authority: Object) -> bool:
	if authority != _authority or _phase != Phase.APPLYING:
		return false
	_record_participant_phase_failures(&"apply", _applied)
	if not all_participants_applied() or not participants_are_live():
		return false
	_phase = Phase.PUBLISH_READYING
	return true


func _mark_publish_ready(
	presenter: Object,
	role: StringName,
	authority: Object,
) -> bool:
	if (
		authority != _authority
		or _phase != Phase.PUBLISH_READYING
		or not is_target(presenter, role)
	):
		return false
	_publish_ready[_participant_key(role, presenter.get_instance_id())] = true
	return true


func _seal_publish_readiness(authority: Object) -> bool:
	if authority != _authority or _phase != Phase.PUBLISH_READYING:
		return false
	_record_participant_phase_failures(&"publish readiness", _publish_ready)
	if not all_participants_publish_ready() or not participants_are_live():
		return false
	_phase = Phase.COMMITTING
	return true


func _get_transaction_participants(authority: Object) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if authority != _authority or _phase != Phase.COMMITTING:
		return result
	for key: String in _participants:
		var entry: Dictionary = _participants[key]
		var weak_presenter: WeakRef = entry.get("presenter")
		result.append({
			"role": entry.get("role"),
			"presenter": (
				weak_presenter.get_ref() if weak_presenter != null else null),
			"capability": entry.get("capability"),
			"transaction": entry.get("transaction", Callable()),
		})
	return result


func _record_transaction_liveness_failures(
	phase_label: StringName,
	authority: Object,
) -> void:
	if authority != _authority or _phase != Phase.COMMITTING:
		return
	_record_participant_phase_failures(phase_label, _participants)


func _finish(_success: bool, cancelled: bool, authority: Object) -> void:
	if authority != _authority or _phase in [Phase.FINISHED, Phase.CANCELLED]:
		return
	_phase = Phase.CANCELLED if cancelled else Phase.FINISHED


func _all_participants_recorded(records: Dictionary) -> bool:
	if _participants.is_empty():
		return false
	for key: String in _participants:
		if not records.has(key):
			return false
	return true


func _participant_error(entry: Dictionary) -> String:
	var status := _participant_status(entry)
	match status:
		&"retired":
			return "clip participant '%s' is no longer live" % entry.get("role")
		&"binding_changed":
			return "clip participant '%s' changed during validation" % entry.get("role")
	return ""


func _participant_status(entry: Dictionary) -> StringName:
	var weak_presenter: WeakRef = entry.get("presenter")
	var presenter: Object = weak_presenter.get_ref() if weak_presenter != null else null
	if presenter == null or not is_instance_valid(presenter):
		return &"retired"
	if presenter is Node and (presenter as Node).is_queued_for_deletion():
		return &"retired"
	var validator: Callable = entry.get("validator", Callable())
	if (
		not validator.is_valid()
		or not bool(validator.call(presenter, entry.get("capability")))
	):
		return &"binding_changed"
	return &"current"


func _record_participant_phase_failures(
	phase_label: StringName,
	records: Dictionary,
) -> void:
	for key: String in _participants:
		var entry: Dictionary = _participants[key]
		var role := String(entry.get("role", "unknown"))
		var status := _participant_status(entry)
		var message := ""
		if status == &"retired":
			message = "%s participant retired during %s" % [role, phase_label]
		elif status == &"binding_changed":
			message = "%s participant binding changed during %s" % [role, phase_label]
		elif not records.has(key):
			message = "%s participant did not acknowledge %s" % [role, phase_label]
		if not message.is_empty() and message not in _errors:
			_errors.append(message)


func _participant_key(role: StringName, instance_id: int) -> String:
	return "%s:%d" % [role, instance_id]
