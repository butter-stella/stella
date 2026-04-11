## Screen effects — shake, flash.
##
## Structure notes:
## - Shake tweens the `offset` of BackgroundLayer and CharacterLayer sibling
##   CanvasLayers so that content visibly moves. UILayer is intentionally
##   excluded so the dialogue box stays readable during shakes.
##   (Mutating the parent Node2D's position has no visual effect because
##   CanvasLayer children ignore Node2D transforms.)
## - Flash adds a full-screen ColorRect to a dedicated CanvasLayer with a
##   very high `layer` value so the overlay renders above all gameplay UI.
extends Node

const _FLASH_LAYER := 100
const _SHAKE_STEP := 0.05

var _flash_canvas: CanvasLayer


func _ready():
	SignalBus.effect_requested.connect(_on_effect)
	_flash_canvas = CanvasLayer.new()
	_flash_canvas.name = "FlashCanvas"
	_flash_canvas.layer = _FLASH_LAYER
	add_child(_flash_canvas)


func _on_effect(effect_type: String, params: Dictionary):
	match effect_type:
		"shake":
			_shake(params.get("intensity", 10.0), params.get("duration", 0.3))
		"flash":
			_flash(params.get("color", "white"), params.get("duration", 0.2))
		"off":
			_clear_shake()


func _shake(intensity: float, duration: float):
	var targets := _get_shake_targets()
	if targets.is_empty():
		return
	var tween := create_tween()
	var steps := int(duration / _SHAKE_STEP)
	if steps <= 0:
		steps = 1
	for i in range(steps):
		tween.tween_callback(func():
			for layer in targets:
				layer.offset = Vector2(
					randf_range(-intensity, intensity),
					randf_range(-intensity, intensity),
				)
		)
		tween.tween_interval(_SHAKE_STEP)
	tween.tween_callback(func():
		for layer in targets:
			layer.offset = Vector2.ZERO
	)


func _flash(color_name: String, duration: float):
	# Create a full-screen colored overlay that fades out.
	# color_name accepts Godot named colors ("white", "red", "black", ...)
	# or hex strings (e.g. "#ff0000"); falls back to white on an unknown name.
	var overlay = ColorRect.new()
	overlay.color = Color.from_string(color_name, Color.WHITE)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash_canvas.add_child(overlay)
	overlay.modulate.a = 1.0
	var tween = create_tween()
	tween.tween_property(overlay, "modulate:a", 0.0, duration)
	tween.tween_callback(func(): overlay.queue_free())


func _clear_shake():
	for layer in _get_shake_targets():
		layer.offset = Vector2.ZERO


func _get_shake_targets() -> Array[CanvasLayer]:
	# Return content layers that should respond to shake (excludes UI/Fade).
	var targets: Array[CanvasLayer] = []
	var game := get_parent()
	if game == null:
		return targets
	for child in game.get_children():
		if child is CanvasLayer and child.name in ["BackgroundLayer", "CharacterLayer"]:
			targets.append(child)
	return targets
