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
			_flash(params.get("color", "white"), params.get("duration", 0.2))
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


func _flash(color_name: String, duration: float):
	# Create a full-screen colored overlay that fades out.
	# color_name accepts Godot named colors ("white", "red", "black", ...)
	# or hex strings (e.g. "#ff0000"); falls back to white on an unknown name.
	var overlay = ColorRect.new()
	overlay.color = Color.from_string(color_name, Color.WHITE)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	get_parent().add_child(overlay)
	overlay.modulate.a = 1.0
	var tween = create_tween()
	tween.tween_property(overlay, "modulate:a", 0.0, duration)
	tween.tween_callback(func(): overlay.queue_free())
