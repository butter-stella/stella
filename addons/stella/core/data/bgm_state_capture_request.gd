## Authority-bound synchronous capture of the physical incoming BGM cursor.
class_name BgmStateCaptureRequest extends RefCounted

var _authority: Object
var _state: Dictionary = {}
var _resolved: bool = false


func get_position() -> float:
	return float(_state.get("position", 0.0))


func get_state() -> Dictionary:
	return _state.duplicate(true)


func is_resolved() -> bool:
	return _resolved


func _bind_authority(authority: Object) -> bool:
	if authority == null or _authority != null:
		return false
	_authority = authority
	return true


func _resolve(state: Dictionary, authority: Object) -> bool:
	if (
		authority == null
		or authority != _authority
		or _resolved
		or not BgmChannelState.validate_snapshot_state(state, false)
	):
		return false
	_state = BgmChannelState.normalize_snapshot_state(state)
	_resolved = true
	return true
