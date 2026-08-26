## Typed adapter for one canonical PresentationClipDefinition invocation.
class_name PresentationClipPresentationOperation extends PresentationOperation


func _init(payload: Dictionary = {}, source: Dictionary = {}) -> void:
	var asset := String(payload.get("asset", ""))
	super(&"presentation_clip", StringName("clip:%s" % asset), payload, source)
