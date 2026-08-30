## Authority-bound, synchronous and side-effect-free validation of a saved BGM
## projection before any restore domain is mutated.
class_name BgmStateRestoreValidationRequest extends RefCounted

var _authority: Object
var _state: Dictionary = {}
var _resolved := false
var _accepted := false


func _init(state: Dictionary) -> void:
	_state = state.duplicate(true)


func get_state() -> Dictionary:
	return _state.duplicate(true)


func is_resolved() -> bool:
	return _resolved


func was_accepted() -> bool:
	return _resolved and _accepted


func _bind_authority(authority: Object) -> bool:
	if authority == null or _authority != null:
		return false
	_authority = authority
	return true


func _resolve(accepted: bool, authority: Object) -> bool:
	if authority == null or authority != _authority or _resolved:
		return false
	_accepted = accepted
	_resolved = true
	return true
