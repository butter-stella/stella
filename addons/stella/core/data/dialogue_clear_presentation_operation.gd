## Typed adapter for the canonical dialogue-page clear presentation operation.
class_name DialogueClearPresentationOperation extends PresentationOperation

var _target_content: Dictionary
var _runtime_binding: Dictionary


func _init(
	payload: Dictionary = {},
	target_content: Dictionary = {},
	runtime_binding: Dictionary = {},
	source: Dictionary = {},
) -> void:
	_target_content = target_content.duplicate(true)
	_runtime_binding = runtime_binding.duplicate(true)
	super(&"dialogue_clear", &"dialogue:content", payload, source)


func get_target_content() -> Dictionary:
	return _target_content.duplicate(true)


func get_runtime_binding() -> Dictionary:
	return _runtime_binding.duplicate(true)
