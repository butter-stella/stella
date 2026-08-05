## Screen effects — shake, flash.
##
## Structure notes:
## - Shake applies one shared delta to the CanvasLayers configured in
##   `shake_target_paths` so that the stage moves as one rigid image. UILayer is
##   intentionally excluded so the dialogue box stays readable during shakes.
##   (Mutating the parent Node2D's position has no visual effect because
##   CanvasLayer children ignore Node2D transforms.)
## - Flash adds a full-screen ColorRect to a dedicated CanvasLayer with a
##   very high `layer` value so the overlay renders above all gameplay UI.
extends Node

const _FLASH_LAYER := 100
const _SHAKE_STEP := 0.05

@export var shake_target_paths: Array[NodePath] = [
	NodePath("../BackgroundLayer"),
	NodePath("../CharacterLayer"),
]

var _flash_canvas: CanvasLayer
var _flash_overlay: ColorRect
var _flash_tween: Tween
var _shake_tween: Tween
var _shake_targets: Array[CanvasLayer] = []
var _shake_baselines: Dictionary = {}


func _enter_tree() -> void:
	# `_ready` only runs once unless request_ready() is used. Reconnect here when
	# an already-initialized presenter is removed and later re-added to the tree.
	if is_instance_valid(_flash_canvas):
		_connect_signals()


func _ready():
	if not is_instance_valid(_flash_canvas):
		_flash_canvas = CanvasLayer.new()
		_flash_canvas.name = "FlashCanvas"
		_flash_canvas.layer = _FLASH_LAYER
		add_child(_flash_canvas)
	_connect_signals()


func _exit_tree() -> void:
	_clear_effects()
	if SignalBus.effect_requested.is_connected(_on_effect):
		SignalBus.effect_requested.disconnect(_on_effect)
	if SignalBus.engine_abort_requested.is_connected(_clear_effects):
		SignalBus.engine_abort_requested.disconnect(_clear_effects)


func _connect_signals() -> void:
	if not SignalBus.effect_requested.is_connected(_on_effect):
		SignalBus.effect_requested.connect(_on_effect)
	if not SignalBus.engine_abort_requested.is_connected(_clear_effects):
		SignalBus.engine_abort_requested.connect(_clear_effects)


func _on_effect(effect_type: String, params: Dictionary):
	match effect_type:
		"shake":
			_shake(params.get("intensity", 10.0), params.get("duration", 0.3))
		"flash":
			_flash(params.get("color", "white"), params.get("duration", 0.2))
		"off":
			_clear_effects()


func _shake(intensity: float, duration: float):
	_stop_shake()
	if duration <= 0.0:
		return
	var targets := _get_shake_targets()
	if targets.is_empty():
		push_warning("ScreenEffects: no valid shake targets configured")
		return

	_shake_targets = targets
	for layer in _shake_targets:
		_shake_baselines[layer] = layer.offset

	intensity = absf(intensity)
	var steps := maxi(1, int(ceil(duration / _SHAKE_STEP)))
	var step_duration := duration / float(steps)
	var tween := create_tween()
	_shake_tween = tween
	for _step in range(steps):
		tween.tween_callback(_apply_shake_delta.bind(tween, intensity))
		tween.tween_interval(step_duration)
	tween.tween_callback(_finish_shake.bind(tween))


func _apply_shake_delta(tween: Tween, intensity: float) -> void:
	if tween != _shake_tween:
		return
	var delta := Vector2(
		randf_range(-intensity, intensity),
		randf_range(-intensity, intensity),
	)
	for layer in _shake_targets:
		if is_instance_valid(layer) and _shake_baselines.has(layer):
			layer.offset = _shake_baselines[layer] + delta


func _finish_shake(tween: Tween) -> void:
	if tween != _shake_tween:
		return
	_restore_shake_baselines()
	_shake_tween = null


func _flash(color_name: String, duration: float):
	_clear_flash()
	if duration <= 0.0:
		return

	# Create a full-screen colored overlay that fades out.
	# color_name accepts Godot named colors ("white", "red", "black", ...)
	# or hex strings (e.g. "#ff0000"); falls back to white on an unknown name.
	var overlay := ColorRect.new()
	overlay.color = Color.from_string(color_name, Color.WHITE)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash_canvas.add_child(overlay)
	overlay.modulate.a = 1.0
	_flash_overlay = overlay
	var tween := create_tween()
	_flash_tween = tween
	tween.tween_property(overlay, "modulate:a", 0.0, duration)
	tween.tween_callback(_finish_flash.bind(tween, overlay))


func _finish_flash(tween: Tween, overlay: ColorRect) -> void:
	if tween != _flash_tween or overlay != _flash_overlay:
		return
	_flash_tween = null
	_flash_overlay = null
	if is_instance_valid(overlay):
		overlay.queue_free()


func _clear_effects() -> void:
	_stop_shake()
	_clear_flash()


func _stop_shake() -> void:
	if _shake_tween and _shake_tween.is_valid():
		_shake_tween.kill()
	_shake_tween = null
	_restore_shake_baselines()


func _restore_shake_baselines() -> void:
	for layer in _shake_targets:
		if is_instance_valid(layer) and _shake_baselines.has(layer):
			layer.offset = _shake_baselines[layer]
	_shake_targets.clear()
	_shake_baselines.clear()


func _clear_flash() -> void:
	if _flash_tween and _flash_tween.is_valid():
		_flash_tween.kill()
	_flash_tween = null
	if is_instance_valid(_flash_overlay):
		_flash_overlay.visible = false
		_flash_overlay.queue_free()
	_flash_overlay = null


func _get_shake_targets() -> Array[CanvasLayer]:
	var targets: Array[CanvasLayer] = []
	for target_path in shake_target_paths:
		var node := get_node_or_null(target_path)
		if node == null:
			push_warning("ScreenEffects: shake target not found: %s" % target_path)
		elif not node is CanvasLayer:
			push_warning("ScreenEffects: shake target is not a CanvasLayer: %s" % target_path)
		elif not targets.has(node):
			targets.append(node)
	return targets
