## Typed adapter for one canonical named-stage operation.
class_name StagePresentationOperation extends PresentationOperation


func _init(payload: Dictionary = {}) -> void:
	var action := String(payload.get("action", "")).strip_edges()
	var layer_id := String(payload.get("id", "")).strip_edges()
	var channel := (
		&"stage:*"
		if action == "clear"
		else StringName("stage:%s" % layer_id)
	)
	super(&"stage", channel, payload)
