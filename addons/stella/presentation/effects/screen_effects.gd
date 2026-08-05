## Screen effects — shake, flash.
##
## Structure notes:
## - Shake applies one shared delta to the dedicated Control or Node2D roots
##   configured in `shake_target_paths` so the stage moves as one rigid image.
##   Camera/pan code can independently use the surrounding CanvasLayer offsets.
##   UILayer is intentionally excluded so the dialogue box stays readable.
## - Flash adds a full-screen ColorRect to `flash_canvas_path`. When that path is
##   empty, a private CanvasLayer is created at `flash_canvas_layer` for backwards
##   compatibility with custom scenes that predate the explicit host setting.
extends Node

const DEFAULT_FLASH_CANVAS_LAYER := 100
const DEFAULT_MAX_SHAKE_INTENSITY := 4096.0
const _SHAKE_STEP := 0.05

@export_group("Shake")
@export var shake_target_paths: Array[NodePath] = [
	NodePath("../BackgroundLayer/ShakeRoot"),
	NodePath("../CharacterLayer/ShakeRoot"),
]
@export var max_shake_intensity := DEFAULT_MAX_SHAKE_INTENSITY

@export_group("Flash")
@export_node_path("CanvasLayer") var flash_canvas_path: NodePath
@export var flash_canvas_layer := DEFAULT_FLASH_CANVAS_LAYER

var _flash_canvas: CanvasLayer
var _fallback_flash_canvas: CanvasLayer
var _owns_flash_canvas := false
var _flash_overlay: ColorRect
var _flash_tween: Tween
var _shake_tween: Tween
var _shake_targets: Array[CanvasItem] = []
var _shake_baselines: Dictionary = {}
var _shake_intensity := 0.0
var _shake_step_elapsed := 0.0


func _enter_tree() -> void:
	# `_ready` only runs once unless request_ready() is used. Always reconnect
	# when an already-initialized presenter is removed and re-added to the tree.
	_connect_signals()


func _ready() -> void:
	# A sibling may emit an effect from `_ready()` after this node has connected
	# in `_enter_tree()` but before this callback runs. Do not pause that shake.
	if _shake_tween == null:
		set_process(false)
	_resolve_flash_canvas()


func _process(delta: float) -> void:
	if _shake_tween == null:
		set_process(false)
		return
	_shake_step_elapsed += delta
	if _shake_step_elapsed < _SHAKE_STEP:
		return
	_shake_step_elapsed = fmod(_shake_step_elapsed, _SHAKE_STEP)
	_apply_shake_delta(_shake_tween)


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


func _on_effect(effect_type: String, params: Dictionary) -> void:
	match effect_type:
		"shake":
			_shake(params.get("intensity", 10.0), params.get("duration", 0.3))
		"flash":
			_flash(params.get("color", "white"), params.get("duration", 0.2))
		"off":
			_clear_effects()


func _shake(intensity_value: Variant, duration_value: Variant) -> void:
	# A new request always supersedes the old one, even when the new payload is
	# invalid. This prevents a malformed plugin request from leaving stale motion.
	_stop_shake()

	var parsed_duration: Variant = _finite_number(duration_value, "shake duration")
	var parsed_intensity: Variant = _finite_number(intensity_value, "shake intensity")
	if parsed_duration == null or parsed_intensity == null:
		return

	var duration := float(parsed_duration)
	if duration < 0.0:
		push_warning("ScreenEffects: shake duration must be non-negative")
		return
	if duration == 0.0:
		return

	var intensity := float(parsed_intensity)
	if intensity < 0.0:
		push_warning("ScreenEffects: negative shake intensity normalized to its absolute value")
		intensity = absf(intensity)

	var intensity_limit := max_shake_intensity
	if not is_finite(intensity_limit) or intensity_limit <= 0.0:
		push_warning(
			"ScreenEffects: max_shake_intensity must be finite and positive; using %.1f"
			% DEFAULT_MAX_SHAKE_INTENSITY
		)
		intensity_limit = DEFAULT_MAX_SHAKE_INTENSITY
	if intensity > intensity_limit:
		push_warning(
			"ScreenEffects: shake intensity %.3f exceeds the configured maximum %.3f; clamping"
			% [intensity, intensity_limit]
		)
		intensity = intensity_limit

	var targets := _get_shake_targets()
	if targets.is_empty():
		push_warning("ScreenEffects: no valid shake targets configured")
		return

	_shake_targets = targets
	for target in _shake_targets:
		_shake_baselines[target] = _get_shake_target_position(target)

	_shake_intensity = intensity
	_shake_step_elapsed = 0.0
	var tween := create_tween()
	_shake_tween = tween
	set_process(true)
	_apply_shake_delta(tween)
	# One interval and one callback keep setup cost and memory constant even for
	# intentionally long durations. `_process` supplies the random samples.
	tween.tween_interval(duration)
	tween.tween_callback(_finish_shake.bind(tween))


func _finite_number(value: Variant, parameter_name: String) -> Variant:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		push_warning("ScreenEffects: %s must be a finite number" % parameter_name)
		return null
	var number := float(value)
	if not is_finite(number):
		push_warning("ScreenEffects: %s must be finite" % parameter_name)
		return null
	return number


func _apply_shake_delta(tween: Tween) -> void:
	if tween != _shake_tween:
		return
	var delta := Vector2(
		randf_range(-_shake_intensity, _shake_intensity),
		randf_range(-_shake_intensity, _shake_intensity),
	)
	for target in _shake_targets:
		if is_instance_valid(target) and _shake_baselines.has(target):
			_set_shake_target_position(target, _shake_baselines[target] + delta)


func _finish_shake(tween: Tween) -> void:
	if tween != _shake_tween:
		return
	_restore_shake_baselines()
	_shake_tween = null
	_shake_intensity = 0.0
	_shake_step_elapsed = 0.0
	set_process(false)


func _flash(color_value: Variant, duration_value: Variant) -> void:
	_clear_flash()

	var parsed_duration: Variant = _finite_number(duration_value, "flash duration")
	if parsed_duration == null:
		return
	var duration := float(parsed_duration)
	if duration < 0.0:
		push_warning("ScreenEffects: flash duration must be non-negative")
		return
	if duration == 0.0:
		return

	var color_name := "white"
	if typeof(color_value) == TYPE_STRING or typeof(color_value) == TYPE_STRING_NAME:
		color_name = String(color_value)
	else:
		push_warning("ScreenEffects: flash color must be a string; using white")

	var flash_canvas := _resolve_flash_canvas()
	if flash_canvas == null:
		return

	# Create a full-screen colored overlay that fades out. `color_name` accepts
	# Godot named colors or hex strings and falls back to white when unknown.
	var overlay := ColorRect.new()
	overlay.color = Color.from_string(color_name, Color.WHITE)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.z_index = RenderingServer.CANVAS_ITEM_Z_MAX
	flash_canvas.add_child(overlay)
	overlay.modulate.a = 1.0
	_flash_overlay = overlay
	var tween := create_tween()
	_flash_tween = tween
	tween.tween_property(overlay, "modulate:a", 0.0, duration)
	tween.tween_callback(_finish_flash.bind(tween, overlay))


func _resolve_flash_canvas() -> CanvasLayer:
	if not flash_canvas_path.is_empty():
		var configured := get_node_or_null(flash_canvas_path)
		if configured == null:
			push_warning("ScreenEffects: flash canvas not found: %s" % flash_canvas_path)
			_flash_canvas = null
			_owns_flash_canvas = false
			return null
		if not configured is CanvasLayer:
			push_warning("ScreenEffects: flash canvas is not a CanvasLayer: %s" % flash_canvas_path)
			_flash_canvas = null
			_owns_flash_canvas = false
			return null
		_flash_canvas = configured as CanvasLayer
		_owns_flash_canvas = false
		return _flash_canvas

	if is_instance_valid(_fallback_flash_canvas):
		_flash_canvas = _fallback_flash_canvas
		_flash_canvas.layer = flash_canvas_layer
		_owns_flash_canvas = true
		return _flash_canvas

	_fallback_flash_canvas = CanvasLayer.new()
	_fallback_flash_canvas.name = "FlashCanvas"
	_fallback_flash_canvas.layer = flash_canvas_layer
	add_child(_fallback_flash_canvas)
	_flash_canvas = _fallback_flash_canvas
	_owns_flash_canvas = true
	return _flash_canvas


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
	set_process(false)
	if _shake_tween and _shake_tween.is_valid():
		_shake_tween.kill()
	_shake_tween = null
	_shake_intensity = 0.0
	_shake_step_elapsed = 0.0
	_restore_shake_baselines()


func _restore_shake_baselines() -> void:
	for target in _shake_targets:
		if is_instance_valid(target) and _shake_baselines.has(target):
			_set_shake_target_position(target, _shake_baselines[target])
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


func _get_shake_targets() -> Array[CanvasItem]:
	var targets: Array[CanvasItem] = []
	for target_path in shake_target_paths:
		var node := get_node_or_null(target_path)
		if node == null:
			push_warning("ScreenEffects: shake target not found: %s" % target_path)
		elif not node is Node2D and not node is Control:
			push_warning(
				"ScreenEffects: shake target must be a Control or Node2D: %s" % target_path
			)
		elif not targets.has(node):
			targets.append(node as CanvasItem)
	return targets


func _get_shake_target_position(target: CanvasItem) -> Vector2:
	if target is Control:
		return (target as Control).position
	return (target as Node2D).position


func _set_shake_target_position(target: CanvasItem, value: Vector2) -> void:
	if target is Control:
		(target as Control).position = value
	else:
		(target as Node2D).position = value
