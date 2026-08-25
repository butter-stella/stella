## Typed adapter for one canonical persistent loop-SE channel operation.
class_name LoopSePresentationOperation extends PresentationOperation


func _init(payload: Dictionary = {}, source: Dictionary = {}) -> void:
	var channel_id := String(payload.get("channel", "")).strip_edges()
	super(&"loop_se", StringName("loop_se:%s" % channel_id), payload, source)
