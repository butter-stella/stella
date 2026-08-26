## Immutable typed adapter for the single addressable dialogue-avatar channel.
class_name DialogueAvatarPresentationOperation extends PresentationOperation

var _before_state: Dictionary
var _target_state: Dictionary


func _init(
	payload: Dictionary = {},
	before_state: Dictionary = {},
	target_state: Dictionary = {},
	source: Dictionary = {},
) -> void:
	_before_state = before_state.duplicate(true)
	_target_state = target_state.duplicate(true)
	super(&"dialogue_avatar", &"dialogue:avatar", payload, source)


func get_before_state() -> Dictionary:
	return _before_state.duplicate(true)


func get_target_state() -> Dictionary:
	return _target_state.duplicate(true)
