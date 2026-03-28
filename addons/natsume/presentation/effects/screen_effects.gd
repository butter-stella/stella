## Screen effects — shake, flash, etc.
## Attach to main scene root to shake the entire viewport.
extends Node


func _ready():
	SignalBus.effect_requested.connect(_on_effect)


func _on_effect(effect_type: String, params: Dictionary):
	match effect_type:
		"shake":
			_shake(params.get("intensity", 10.0), params.get("duration", 0.3))
		"flash":
			_flash(params.get("duration", 0.2))
		"off":
			pass  # Clear effects — reset position
			get_parent().position = Vector2.ZERO


func _shake(intensity: float, duration: float):
	var parent = get_parent()
	var original_pos = parent.position
	var tween = create_tween()
	var steps = int(duration / 0.05)
	for i in range(steps):
		var offset = Vector2(randf_range(-intensity, intensity), randf_range(-intensity, intensity))
		tween.tween_property(parent, "position", original_pos + offset, 0.05)
	tween.tween_property(parent, "position", original_pos, 0.05)


func _flash(duration: float):
	# Create a white overlay briefly
	var overlay = ColorRect.new()
	overlay.color = Color.WHITE
	overlay.anchors_preset = Control.PRESET_FULL_RECT
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	get_parent().add_child(overlay)
	overlay.modulate.a = 1.0
	var tween = create_tween()
	tween.tween_property(overlay, "modulate:a", 0.0, duration)
	tween.tween_callback(func(): overlay.queue_free())
