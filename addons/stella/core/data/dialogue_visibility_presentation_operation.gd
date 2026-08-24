## Typed adapter for one canonical dialogue-visibility presentation operation.
class_name DialogueVisibilityPresentationOperation extends PresentationOperation

var _runtime_binding: Dictionary


func _init(
	payload: Dictionary = {},
	runtime_binding: Dictionary = {},
) -> void:
	var target := String(payload.get("target", "")).strip_edges()
	_runtime_binding = runtime_binding.duplicate(true)
	super(&"dialogue_visibility", StringName("dialogue:%s" % target), payload)


func get_runtime_binding() -> Dictionary:
	return _runtime_binding.duplicate(true)
