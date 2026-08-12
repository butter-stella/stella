## Screen effects — shake, flash.
##
## Structure notes:
## - Shake applies one shared delta to the dedicated Control or Node2D roots
##   configured in `shake_target_paths` so the stage moves together.
##   Controls in `shake_coverage_target_paths` are temporarily scaled from
##   their center so an exact-viewport background cannot expose clear color.
##   Camera/pan code can independently use the surrounding CanvasLayer offsets.
##   UILayer is intentionally excluded so the dialogue box stays readable.
## - Flash adds a full-screen ColorRect to `flash_canvas_path`. When that path is
##   empty, a private CanvasLayer is created at `flash_canvas_layer` for backwards
##   compatibility with custom scenes that predate the explicit host setting.
extends Node

const DEFAULT_FLASH_CANVAS_LAYER := 100
const DEFAULT_MAX_SHAKE_INTENSITY := 4096.0
const ABSOLUTE_MAX_SHAKE_INTENSITY := 4096.0
const MIN_SHAKE_COVERAGE_SIDE := 1.0
const _SHAKE_STEP := 0.05

@export_group("Shake")
@export var shake_target_paths: Array[NodePath] = [
	NodePath("../BackgroundLayer/ShakeRoot"),
	NodePath("../StageLayer/ShakeRoot"),
]
@export var shake_coverage_target_paths: Array[NodePath] = []
@export var max_shake_intensity := DEFAULT_MAX_SHAKE_INTENSITY

@export_group("Flash")
@export_node_path("CanvasLayer") var flash_canvas_path: NodePath
@export var flash_canvas_layer := DEFAULT_FLASH_CANVAS_LAYER

var _flash_canvas: CanvasLayer
var _fallback_flash_canvas: CanvasLayer
var _owns_flash_canvas := false
var _tracked_flash_canvas: CanvasLayer
var _flash_canvas_exiting := false
var _flash_canvas_tree_exiting_callback := Callable()
var _flash_canvas_tree_exited_callback := Callable()
var _flash_overlay: ColorRect
var _flash_tween: Tween
var _shake_tween: Tween
var _shake_targets: Array[CanvasItem] = []
var _shake_baselines: Dictionary = {}
var _shake_motion_baselines: Dictionary = {}
var _shake_coverage_baselines: Dictionary = {}
var _shake_intensity := 0.0
var _shake_step_elapsed := 0.0
var _queued_effect_requests: Array[Dictionary] = []
var _effect_mutation_depth := 0
var _draining_effect_requests := false
var _accept_effect_requests := false


func _enter_tree() -> void:
	# `_ready` only runs once unless request_ready() is used. Always reconnect
	# when an already-initialized presenter is removed and re-added to the tree.
	_accept_effect_requests = true
	_connect_signals()
	_refresh_existing_flash_canvas_on_enter()


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
	# Reject and discard re-entrant requests caused by restoring Controls while
	# this presenter is leaving the tree. They must not revive after re-entry.
	_accept_effect_requests = false
	_queued_effect_requests.clear()
	if SignalBus.effect_requested.is_connected(_on_effect):
		SignalBus.effect_requested.disconnect(_on_effect)
	if SignalBus.engine_abort_requested.is_connected(_clear_effects):
		SignalBus.engine_abort_requested.disconnect(_clear_effects)
	_clear_effects()


func _connect_signals() -> void:
	if not SignalBus.effect_requested.is_connected(_on_effect):
		SignalBus.effect_requested.connect(_on_effect)
	if not SignalBus.engine_abort_requested.is_connected(_clear_effects):
		SignalBus.engine_abort_requested.connect(_clear_effects)


func _on_effect(effect_type: String, params: Dictionary) -> void:
	if not _accept_effect_requests:
		return
	_queued_effect_requests.append({
		"type": effect_type,
		"params": params.duplicate(true),
	})
	_drain_effect_requests()


func _drain_effect_requests() -> void:
	if not _accept_effect_requests or _effect_mutation_depth > 0 or _draining_effect_requests:
		return
	_draining_effect_requests = true
	while _accept_effect_requests \
		and _effect_mutation_depth == 0 \
		and not _queued_effect_requests.is_empty():
		var request := _queued_effect_requests.pop_front()
		_begin_effect_mutation()
		_execute_effect(request.get("type", ""), request.get("params", {}))
		_end_effect_mutation()
	if not _accept_effect_requests:
		_queued_effect_requests.clear()
	_draining_effect_requests = false


func _execute_effect(effect_type: String, params: Dictionary) -> void:
	match effect_type:
		"shake":
			_shake(params.get("intensity", 10.0), params.get("duration", 0.3))
		"flash":
			_flash(params.get("color", "white"), params.get("duration", 0.2))
		"off":
			_clear_effects()


func _begin_effect_mutation() -> void:
	_effect_mutation_depth += 1


func _end_effect_mutation() -> void:
	_effect_mutation_depth = maxi(_effect_mutation_depth - 1, 0)
	if _effect_mutation_depth == 0:
		_drain_effect_requests()


func _shake(intensity_value: Variant, duration_value: Variant) -> void:
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
	if intensity == 0.0:
		return

	var intensity_limit := max_shake_intensity
	if not is_finite(intensity_limit) or intensity_limit <= 0.0:
		push_warning(
			"ScreenEffects: max_shake_intensity must be finite and positive; using %.1f"
			% DEFAULT_MAX_SHAKE_INTENSITY
		)
		intensity_limit = DEFAULT_MAX_SHAKE_INTENSITY
	if intensity_limit > ABSOLUTE_MAX_SHAKE_INTENSITY:
		push_warning(
			"ScreenEffects: max_shake_intensity %.3f exceeds the absolute safe maximum %.3f; clamping"
			% [intensity_limit, ABSOLUTE_MAX_SHAKE_INTENSITY]
		)
		intensity_limit = ABSOLUTE_MAX_SHAKE_INTENSITY
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
	var coverage_targets := _get_shake_coverage_targets(targets)

	# Only a completely valid request supersedes the active effect. Resolve the
	# targets first, then restore the old effect before recording new baselines.
	_stop_shake()
	if not is_inside_tree() or not _accept_effect_requests:
		return
	_shake_targets = targets
	for target in _shake_targets:
		_shake_baselines[target] = _get_shake_target_position(target)
		_shake_motion_baselines[target] = _shake_baselines[target]

	_shake_intensity = intensity
	_shake_step_elapsed = 0.0
	var tween := create_tween()
	_shake_tween = tween
	for target in coverage_targets:
		_prepare_shake_coverage(target, tween)
	set_process(true)
	_apply_shake_coverage(tween)
	if tween != _shake_tween or not tween.is_valid():
		return
	_apply_shake_delta(tween)
	if tween != _shake_tween or not tween.is_valid():
		return
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
		(randf() * 2.0 - 1.0) * _shake_intensity,
		(randf() * 2.0 - 1.0) * _shake_intensity,
	)
	if not delta.is_finite():
		push_warning("ScreenEffects: sampled a non-finite shake offset; stopping the effect")
		_stop_shake()
		return
	_apply_shake_offset(tween, delta)


func _apply_shake_offset(tween: Tween, delta: Vector2) -> void:
	if tween != _shake_tween or not delta.is_finite():
		return
	_begin_effect_mutation()
	delta.x = clampf(delta.x, -_shake_intensity, _shake_intensity)
	delta.y = clampf(delta.y, -_shake_intensity, _shake_intensity)
	for target in _shake_targets:
		if is_instance_valid(target) and _shake_motion_baselines.has(target):
			_set_shake_target_position(target, _shake_motion_baselines[target] + delta)
			if tween != _shake_tween:
				break
	_end_effect_mutation()


func _finish_shake(tween: Tween) -> void:
	if tween != _shake_tween:
		return
	_stop_shake()


func _flash(color_value: Variant, duration_value: Variant) -> void:
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
	if flash_canvas == null \
		or not is_instance_valid(flash_canvas) \
		or not flash_canvas.is_inside_tree() \
		or (flash_canvas == _tracked_flash_canvas and _flash_canvas_exiting):
		return
	# Invalid requests above are true no-ops. Only a renderable replacement is
	# allowed to remove the currently active flash.
	_clear_flash()
	if not is_inside_tree() \
		or not _accept_effect_requests \
		or not is_instance_valid(flash_canvas) \
		or not flash_canvas.is_inside_tree():
		return

	# Create a full-screen colored overlay that fades out. `color_name` accepts
	# Godot named colors or hex strings and falls back to white when unknown.
	var overlay := ColorRect.new()
	overlay.color = Color.from_string(color_name, Color.WHITE)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.z_index = RenderingServer.CANVAS_ITEM_Z_MAX
	overlay.modulate.a = 1.0
	_flash_overlay = overlay
	var tween := create_tween()
	_flash_tween = tween
	overlay.tree_exiting.connect(_on_flash_overlay_exiting.bind(tween), CONNECT_ONE_SHOT)
	# Publish the token before adding the child: an external host can run
	# child_entered_tree hooks that immediately free itself or the overlay.
	flash_canvas.add_child(overlay)
	if tween != _flash_tween or not is_instance_valid(overlay):
		return
	tween.tween_property(overlay, "modulate:a", 0.0, duration)
	# Do not bind the overlay itself. An external host owns its lifetime and may
	# be freed before this callback; a typed freed-object argument prevents Godot
	# from invoking the callback at all.
	tween.tween_callback(_finish_flash.bind(tween))


func _resolve_flash_canvas() -> CanvasLayer:
	if not flash_canvas_path.is_empty():
		var configured := get_node_or_null(flash_canvas_path)
		if configured == null:
			push_warning("ScreenEffects: flash canvas not found: %s" % flash_canvas_path)
			if _flash_tween == null:
				_flash_canvas = null
				_owns_flash_canvas = false
			return null
		if not configured is CanvasLayer:
			push_warning("ScreenEffects: flash canvas is not a CanvasLayer: %s" % flash_canvas_path)
			if _flash_tween == null:
				_flash_canvas = null
				_owns_flash_canvas = false
			return null
		_flash_canvas = configured as CanvasLayer
		_owns_flash_canvas = false
		_track_flash_canvas(_flash_canvas)
		return _flash_canvas

	if is_instance_valid(_fallback_flash_canvas):
		_flash_canvas = _fallback_flash_canvas
		_flash_canvas.layer = flash_canvas_layer
		_owns_flash_canvas = true
		_track_flash_canvas(_flash_canvas)
		return _flash_canvas

	_fallback_flash_canvas = CanvasLayer.new()
	_fallback_flash_canvas.name = "FlashCanvas"
	_fallback_flash_canvas.layer = flash_canvas_layer
	add_child(_fallback_flash_canvas)
	_flash_canvas = _fallback_flash_canvas
	_owns_flash_canvas = true
	_track_flash_canvas(_flash_canvas)
	return _flash_canvas


func _refresh_existing_flash_canvas_on_enter() -> void:
	# `_ready()` is not called again when an initialized presenter is detached
	# and re-added. Restore and re-track an existing host without creating nodes
	# while the parent is still entering the tree.
	if flash_canvas_path.is_empty():
		if is_instance_valid(_fallback_flash_canvas):
			_flash_canvas = _fallback_flash_canvas
			_flash_canvas.layer = flash_canvas_layer
			_owns_flash_canvas = true
			_track_flash_canvas(_flash_canvas)
		return
	var configured := get_node_or_null(flash_canvas_path)
	if configured is CanvasLayer:
		_flash_canvas = configured as CanvasLayer
		_owns_flash_canvas = false
		_track_flash_canvas(_flash_canvas)


func _track_flash_canvas(canvas: CanvasLayer) -> void:
	# During `tree_exiting`, the one-shot exiting callback has already detached,
	# but the paired `tree_exited` callback is still our lifecycle fence. Do not
	# reset the exiting flag if a re-entrant request resolves the same host.
	if canvas == _tracked_flash_canvas \
		and _flash_canvas_exiting \
		and _flash_canvas_tree_exited_callback.is_valid() \
		and canvas.tree_exited.is_connected(_flash_canvas_tree_exited_callback):
		return
	if canvas == _tracked_flash_canvas \
		and _flash_canvas_tree_exiting_callback.is_valid() \
		and canvas.tree_exiting.is_connected(_flash_canvas_tree_exiting_callback) \
		and _flash_canvas_tree_exited_callback.is_valid() \
		and canvas.tree_exited.is_connected(_flash_canvas_tree_exited_callback):
		return
	_untrack_flash_canvas()
	_tracked_flash_canvas = canvas
	_flash_canvas_exiting = false
	_flash_canvas_tree_exiting_callback = _on_flash_canvas_exiting.bind(canvas)
	_flash_canvas_tree_exited_callback = _on_flash_canvas_exited.bind(canvas)
	canvas.tree_exiting.connect(_flash_canvas_tree_exiting_callback, CONNECT_ONE_SHOT)
	canvas.tree_exited.connect(_flash_canvas_tree_exited_callback, CONNECT_ONE_SHOT)


func _untrack_flash_canvas() -> void:
	if is_instance_valid(_tracked_flash_canvas):
		if _flash_canvas_tree_exiting_callback.is_valid() \
			and _tracked_flash_canvas.tree_exiting.is_connected(
				_flash_canvas_tree_exiting_callback
			):
			_tracked_flash_canvas.tree_exiting.disconnect(_flash_canvas_tree_exiting_callback)
		if _flash_canvas_tree_exited_callback.is_valid() \
			and _tracked_flash_canvas.tree_exited.is_connected(_flash_canvas_tree_exited_callback):
			_tracked_flash_canvas.tree_exited.disconnect(_flash_canvas_tree_exited_callback)
	_tracked_flash_canvas = null
	_flash_canvas_exiting = false
	_flash_canvas_tree_exiting_callback = Callable()
	_flash_canvas_tree_exited_callback = Callable()


func _on_flash_canvas_exiting(canvas: CanvasLayer) -> void:
	if canvas == _tracked_flash_canvas:
		_flash_canvas_exiting = true


func _on_flash_canvas_exited(canvas: CanvasLayer) -> void:
	if canvas != _tracked_flash_canvas:
		return
	_tracked_flash_canvas = null
	_flash_canvas_exiting = false
	_flash_canvas_tree_exiting_callback = Callable()
	_flash_canvas_tree_exited_callback = Callable()
	if canvas != _flash_canvas:
		return
	_clear_flash()
	_flash_canvas = null
	_owns_flash_canvas = false


func _finish_flash(tween: Tween) -> void:
	if tween != _flash_tween:
		return
	_clear_flash()


func _on_flash_overlay_exiting(tween: Tween) -> void:
	if tween != _flash_tween:
		return
	_begin_effect_mutation()
	var old_tween := _flash_tween
	var old_overlay := _flash_overlay
	_flash_tween = null
	_flash_overlay = null
	_flash_canvas = null
	_owns_flash_canvas = false
	if old_tween and old_tween.is_valid():
		old_tween.kill()
	if is_instance_valid(old_overlay):
		old_overlay.visible = false
		old_overlay.call_deferred("queue_free")
	# `tree_exiting` is emitted while Godot still holds its child-list mutation
	# lock. Keep re-entrant flash requests queued until the whole tree-change
	# stack has unwound; otherwise a replacement can try to add a child to a
	# CanvasLayer that is still being detached.
	call_deferred("_end_effect_mutation")


func _clear_effects() -> void:
	_begin_effect_mutation()
	_stop_shake()
	_clear_flash()
	_end_effect_mutation()


func _stop_shake() -> void:
	# Detach member state before mutating target Controls. Their change signals
	# are synchronous and may request a replacement effect re-entrantly.
	_begin_effect_mutation()
	set_process(false)
	var old_tween := _shake_tween
	var old_targets := _shake_targets.duplicate()
	var old_baselines := _shake_baselines.duplicate()
	var old_coverage_baselines := _shake_coverage_baselines.duplicate()
	_shake_tween = null
	_shake_targets.clear()
	_shake_baselines.clear()
	_shake_motion_baselines.clear()
	_shake_coverage_baselines.clear()
	_shake_intensity = 0.0
	_shake_step_elapsed = 0.0
	if old_tween and old_tween.is_valid():
		old_tween.kill()
	for target in old_coverage_baselines:
		if not is_instance_valid(target):
			continue
		var coverage_state: Dictionary = old_coverage_baselines[target]
		var resized_callback: Callable = coverage_state.get("resized_callback", Callable())
		if resized_callback.is_valid() \
			and (target as Control).resized.is_connected(resized_callback):
			(target as Control).resized.disconnect(resized_callback)
	for target in old_targets:
		if not is_instance_valid(target):
			continue
		if old_coverage_baselines.has(target):
			var coverage_state: Dictionary = old_coverage_baselines[target]
			(target as Control).scale = coverage_state["scale"]
			(target as Control).pivot_offset = coverage_state["pivot_offset"]
		if old_baselines.has(target):
			_set_shake_target_position(target, old_baselines[target])
	_end_effect_mutation()


func _clear_flash() -> void:
	# As with shake, detach first so visibility_changed handlers cannot cause an
	# old cleanup pass to erase a newly requested flash.
	_begin_effect_mutation()
	var old_tween := _flash_tween
	var old_overlay := _flash_overlay
	_flash_tween = null
	_flash_overlay = null
	if old_tween and old_tween.is_valid():
		old_tween.kill()
	if is_instance_valid(old_overlay):
		old_overlay.visible = false
		old_overlay.queue_free()
	_end_effect_mutation()


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


func _get_shake_coverage_targets(shake_targets: Array[CanvasItem]) -> Array[Control]:
	var targets: Array[Control] = []
	for target_path in shake_coverage_target_paths:
		var node := get_node_or_null(target_path)
		if node == null:
			push_warning("ScreenEffects: shake coverage target not found: %s" % target_path)
		elif not node is Control:
			push_warning("ScreenEffects: shake coverage target must be a Control: %s" % target_path)
		elif not shake_targets.has(node):
			push_warning(
				"ScreenEffects: shake coverage target must also be a shake target: %s"
				% target_path
			)
		elif not targets.has(node):
			targets.append(node as Control)
	return targets


func _prepare_shake_coverage(target: Control, tween: Tween) -> void:
	if not target.size.is_finite() \
		or target.size.x < MIN_SHAKE_COVERAGE_SIDE \
		or target.size.y < MIN_SHAKE_COVERAGE_SIDE:
		push_warning(
			"ScreenEffects: shake coverage target must have a finite size of at least %.1f px: %s"
			% [MIN_SHAKE_COVERAGE_SIDE, target.name]
		)
		return
	if not target.scale.is_equal_approx(Vector2.ONE) or not is_zero_approx(target.rotation):
		push_warning(
			"ScreenEffects: shake coverage target must use unit scale and zero rotation: %s"
			% target.name
		)
		return
	var resized_callback := _on_shake_coverage_resized.bind(target, tween)
	target.resized.connect(resized_callback)
	_shake_coverage_baselines[target] = {
		"scale": target.scale,
		"pivot_offset": target.pivot_offset,
		"resized_callback": resized_callback,
	}


func _apply_shake_coverage(tween: Tween) -> void:
	if tween != _shake_tween:
		return
	_begin_effect_mutation()
	for target in _shake_coverage_baselines:
		_apply_shake_coverage_target(target as Control, tween)
		if tween != _shake_tween:
			break
	_end_effect_mutation()


func _on_shake_coverage_resized(target: Control, tween: Tween) -> void:
	if tween != _shake_tween \
		or not is_instance_valid(target) \
		or not _shake_coverage_baselines.has(target):
		return
	_begin_effect_mutation()
	_apply_shake_coverage_target(target, tween)
	_end_effect_mutation()


func _apply_shake_coverage_target(control: Control, tween: Tween) -> void:
	if tween != _shake_tween or not is_instance_valid(control):
		return
	if not control.size.is_finite() \
		or control.size.x < MIN_SHAKE_COVERAGE_SIDE \
		or control.size.y < MIN_SHAKE_COVERAGE_SIDE:
		push_warning("ScreenEffects: shake coverage target size became invalid: %s" % control.name)
		return
	var shortest_side := minf(control.size.x, control.size.y)
	control.pivot_offset = control.size * 0.5
	if tween != _shake_tween:
		return
	var coverage_scale := 1.0 + (2.0 * _shake_intensity / shortest_side)
	if not is_finite(coverage_scale):
		push_warning("ScreenEffects: shake coverage scale is not finite: %s" % control.name)
		return
	control.scale = Vector2.ONE * coverage_scale
	if tween != _shake_tween:
		return
	# With the supported unit baseline, changing the pivot has no visual
	# effect. Scaling around the center creates at least `intensity` pixels
	# of bleed on every side while leaving the Control's anchor rect intact.
	_shake_motion_baselines[control] = _shake_baselines[control]


func _get_shake_target_position(target: CanvasItem) -> Vector2:
	if target is Control:
		return (target as Control).position
	return (target as Node2D).position


func _set_shake_target_position(target: CanvasItem, value: Vector2) -> void:
	if target is Control:
		(target as Control).position = value
	else:
		(target as Node2D).position = value
