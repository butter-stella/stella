## Authority-bound synchronous capture of the physical incoming BGM cursor.
class_name BgmStateCaptureRequest extends RefCounted

var _authority: Object
var _position: float = 0.0
var _resolved: bool = false


func get_position() -> float:
	return _position


func is_resolved() -> bool:
	return _resolved


func _bind_authority(authority: Object) -> bool:
	if authority == null or _authority != null:
		return false
	_authority = authority
	return true


func _resolve(position: float, authority: Object) -> bool:
	if (
		authority == null
		or authority != _authority
		or _resolved
		or not is_finite(position)
		or position < 0.0
	):
		return false
	_position = position
	_resolved = true
	return true
