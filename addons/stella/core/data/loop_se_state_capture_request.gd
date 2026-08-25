## Authority-bound synchronous capture of physical loop-SE playback positions.
class_name LoopSeStateCaptureRequest extends RefCounted

var _authority: Object
var _positions: Dictionary = {}
var _resolved: bool = false


func get_positions() -> Dictionary:
	return _positions.duplicate(true)


func is_resolved() -> bool:
	return _resolved


func _bind_authority(authority: Object) -> bool:
	if authority == null or _authority != null:
		return false
	_authority = authority
	return true


func _resolve(positions: Dictionary, authority: Object) -> bool:
	if authority == null or authority != _authority or _resolved:
		return false
	for raw_channel_id: Variant in positions:
		if not raw_channel_id is String:
			return false
		var value: Variant = positions[raw_channel_id]
		if (
			not (value is int or value is float)
			or not is_finite(float(value))
			or float(value) < 0.0
		):
			return false
	_positions = positions.duplicate(true)
	_resolved = true
	return true
