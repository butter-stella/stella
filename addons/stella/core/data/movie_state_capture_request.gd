## Authority-bound synchronous capture of one physical movie generation.
class_name MovieStateCaptureRequest extends RefCounted

var _authority: Object
var _state: Dictionary = {}
var _resolved := false
var _stable := false


func get_state() -> Dictionary:
	return _state.duplicate(true)


func is_resolved() -> bool:
	return _resolved


func is_stable() -> bool:
	return _resolved and _stable


func _bind_authority(authority: Object) -> bool:
	if authority == null or _authority != null:
		return false
	_authority = authority
	return true


func _resolve(state: Dictionary, stable: bool, authority: Object) -> bool:
	if (
		authority == null
		or authority != _authority
		or _resolved
		or not MovieChannelState.validate_snapshot_state(state, false)
	):
		return false
	_state = state.duplicate(true)
	_stable = stable
	_resolved = true
	return true
