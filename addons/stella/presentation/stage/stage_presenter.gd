## Generic renderer for reusable named visual layers.
##
## Each layer owns stable Asset/Body/Face Sprite2D nodes. Updates touch only
## explicitly changed textures, so cycling face differences never reloads or
## recreates an unchanged background or character body.
class_name StagePresenter extends CanvasLayer

signal layer_transition_finished(layer_id: String)

const REDRAW_SHADER_PATH := (
	"res://addons/stella/presentation/stage/shaders/stage_redraw.gdshader"
)
const TEXTURE_EXTENSIONS := [".png", ".jpg", ".jpeg", ".webp", ".svg", ".tres", ".res"]
const DEFAULT_VIEWPORT_SIZE := Vector2(1920.0, 1080.0)

static var _next_transition_token: int = 1

var _layers: Dictionary = {}
var _states: Dictionary = {}
var _layer_tweens: Dictionary = {}
var _layer_transition_tokens: Dictionary = {}
var _layer_generations: Dictionary = {}
var _next_node_index: int = 0
var _redraw_shader: Shader
var _completion_batch_depth: int = 0
var _queued_transition_completions: Array = []
var _flushing_transition_completions: bool = false
var _active_stage_operation_request_id: int = 0


func _ready() -> void:
	_redraw_shader = load(REDRAW_SHADER_PATH) as Shader
	SignalBus.stage_operations_requested.connect(_on_stage_operations_requested)
	SignalBus.stage_visuals_reset_requested.connect(
		_on_stage_visuals_reset_requested
	)
	SignalBus.stage_state_apply_requested.connect(_on_stage_state_apply_requested)
	SignalBus.stage_transitions_finish_requested.connect(
		_on_stage_transitions_finish_requested
	)
	SignalBus.engine_abort_requested.connect(_on_engine_abort_requested)

	var viewport := get_viewport()
	if viewport and not viewport.size_changed.is_connected(_on_viewport_size_changed):
		viewport.size_changed.connect(_on_viewport_size_changed)


## Return the live Node2D for a named layer id. Primarily useful to custom
## presenters and deterministic tests; callers must not retain it after remove.
func get_layer_node(layer_id: String) -> Node2D:
	var record: Dictionary = _layers.get(layer_id, {})
	return record.get("root") as Node2D


func get_layer_state(layer_id: String) -> Dictionary:
	if not _states.has(layer_id):
		return {}
	return (_states[layer_id] as Dictionary).duplicate(true)


func get_layer_ids() -> Array:
	return _states.keys()


func _on_stage_operations_requested(operations: Array, force_cut: bool) -> void:
	if not SignalBus.is_current_stage_operation_valid():
		return
	var previous_request_id := _active_stage_operation_request_id
	_active_stage_operation_request_id = SignalBus.current_stage_operation_request_id()
	_apply_operations(operations.duplicate(true), force_cut)
	_active_stage_operation_request_id = previous_request_id


func _apply_operations(operations: Array, force_cut: bool) -> void:
	_begin_completion_batch()
	if force_cut:
		_apply_operations_cut(operations)
		_end_completion_batch()
		return

	for raw_operation in operations:
		if not StageLayerState.validate_operation(raw_operation, true):
			continue
		var operation: Dictionary = raw_operation
		var before := _states.duplicate(true)
		var reduced = StageLayerState.reduce(_states, [operation], true)
		if not reduced is Dictionary:
			push_warning("StagePresenter: StageLayerState.reduce returned invalid state")
			continue

		_states = (reduced as Dictionary).duplicate(true)
		var transition := _normalize_transition(
			"cut" if force_cut else String(operation.get("transition", "cut"))
		)
		var duration := (
			0.0 if force_cut
			else maxf(0.0, float(operation.get("duration", 0.0)))
		)
		var action := String(operation.get("action", "update")).to_lower()
		var layer_id := String(operation.get("id", "")).strip_edges()

		if action == "clear":
			# Clear is the one authored action that also owns visuals whose
			# canonical state was already removed while a fade is still running.
			var clear_ids := {}
			for old_id in before:
				clear_ids[String(old_id)] = true
			for live_id in _layers:
				clear_ids[String(live_id)] = true
			var ordered_clear_ids := clear_ids.keys()
			ordered_clear_ids.sort()
			for clear_id in ordered_clear_ids:
				_remove_layer(String(clear_id), transition, duration)
			continue

		if layer_id == "":
			continue
		# Reducer-rejected unknown update/hide/remove operations must not touch
		# a same-id visual that is merely finishing an earlier fade-remove.
		if before == _states:
			continue
		var old_state: Dictionary = before.get(layer_id, {})
		if _states.has(layer_id):
			_apply_layer(
				layer_id,
				old_state,
				_states[layer_id],
				transition,
				duration,
			)
		elif before.has(layer_id):
			_remove_layer(layer_id, transition, duration)
	_end_completion_batch()


## Skip/final-restore batches are reduced before any texture is touched. This
## makes the projection atomic and avoids loading every intermediate face from
## a long dialogue batch when only the final authored state can be visible.
func _apply_operations_cut(operations: Array) -> void:
	var before := _states.duplicate(true)
	var valid_operations: Array = []
	for operation in operations:
		if StageLayerState.validate_operation(operation, true):
			valid_operations.append(operation)
	var affected_ids := _cut_batch_affected_ids(before, valid_operations)
	var reduced = StageLayerState.reduce(_states, valid_operations, true)
	if not reduced is Dictionary:
		push_warning("StagePresenter: StageLayerState.reduce returned invalid state")
		return
	_states = (reduced as Dictionary).duplicate(true)

	for layer_id in affected_ids:
		var id := String(layer_id)
		if _states.has(id):
			_apply_layer(id, before.get(id, {}), _states[id], "cut", 0.0)
		elif _layers.has(id):
			_remove_layer(id, "cut", 0.0)


func _cut_batch_affected_ids(before: Dictionary, operations: Array) -> Dictionary:
	var affected_ids := {}
	var simulated := before.duplicate(true)

	for raw_operation in operations:
		var operation: Dictionary = raw_operation
		var action := String(operation.get("action", "")).to_lower()
		if action == "clear":
			for layer_id in simulated:
				affected_ids[String(layer_id)] = true
			# A non-cut remove drops canonical state immediately while its visual
			# may still be fading. Clear explicitly owns those pending visuals.
			for layer_id in _layers:
				affected_ids[String(layer_id)] = true
		var next = StageLayerState.reduce(simulated, [operation], false)
		if not next is Dictionary:
			continue
		var next_state: Dictionary = next
		if action != "clear":
			var layer_id := String(operation.get("id", "")).strip_edges()
			if layer_id != "" and simulated != next_state:
				affected_ids[layer_id] = true
		simulated = next_state
	return affected_ids


## Restore is a presentation-only exact projection of the named-stage target
## in one synchronous, transition-free pass. Matching ids retain their nodes and
## resident textures; absent ids are removed.
func _on_stage_state_apply_requested(layers: Dictionary) -> void:
	_begin_completion_batch()
	# Build the exact target first, then update matching ids in place.
	# Save/load still removes ids absent from the snapshot, while dialogue
	# finalization can cancel an active tween without throwing away an unchanged
	# background/body node and its resident texture references.
	var target_states: Dictionary = {}
	for raw_id in layers:
		var layer_id := String(raw_id).strip_edges()
		if layer_id == "":
			push_warning("StagePresenter: ignored restored layer with empty id")
			continue
		var raw_state = layers[raw_id]
		if not raw_state is Dictionary:
			push_warning("StagePresenter: ignored invalid restored layer '%s'" % layer_id)
			continue
		var state = StageLayerState.normalize_full(raw_state)
		if not state is Dictionary:
			push_warning("StagePresenter: failed to normalize restored layer '%s'" % layer_id)
			continue
		target_states[layer_id] = (state as Dictionary).duplicate(true)

	for raw_id in _layers.keys().duplicate():
		var layer_id := String(raw_id)
		if not target_states.has(layer_id):
			_free_layer(layer_id)
	for raw_id in _states.keys().duplicate():
		var layer_id := String(raw_id)
		if not target_states.has(layer_id):
			_states.erase(layer_id)

	for raw_id in target_states:
		var layer_id := String(raw_id)
		var old_state: Dictionary = _states.get(layer_id, {})
		_states[layer_id] = (target_states[layer_id] as Dictionary).duplicate(true)
		_apply_layer(layer_id, old_state, _states[layer_id], "cut", 0.0)
	_end_completion_batch()


## Finish only exact transitions previously acknowledged by this presenter.
## Layer ids alone are insufficient: a later command may have replaced a
## dialogue-owned tween on the same id before the dialogue completes.
func _on_stage_transitions_finish_requested(transitions: Array) -> void:
	_begin_completion_batch()
	for raw_transition in transitions:
		if not raw_transition is Dictionary:
			continue
		var transition_record: Dictionary = raw_transition
		if (
			int(transition_record.get("presenter_instance_id", -1))
			!= get_instance_id()
		):
			continue
		var layer_id := String(transition_record.get("layer_id", "")).strip_edges()
		var token := int(transition_record.get("token", -1))
		if (
			layer_id == ""
			or token < 1
			or int(_layer_transition_tokens.get(layer_id, -1)) != token
			or not _layer_tweens.has(layer_id)
		):
			continue
		if _states.has(layer_id):
			var target_state: Dictionary = _states[layer_id]
			_apply_layer(
				layer_id,
				target_state,
				target_state,
				"cut",
				0.0,
			)
		elif _layers.has(layer_id):
			# A fading remove has already left canonical state but still owns a
			# live node until its transition finishes.
			_remove_layer(layer_id, "cut", 0.0)
	_end_completion_batch()


func _on_stage_visuals_reset_requested() -> void:
	_clear_visuals()
	_states.clear()
	_layer_tweens.clear()
	_layer_transition_tokens.clear()
	_layer_generations.clear()
	_queued_transition_completions.clear()


func _apply_layer(
	layer_id: String,
	old_state: Dictionary,
	new_state: Dictionary,
	transition: String,
	duration: float,
) -> void:
	var record := _ensure_layer(layer_id)
	var generation := _begin_layer_change(layer_id)
	var root := record["root"] as Node2D
	var composite := record["composite"] as CanvasGroup
	var was_visible := root.visible and composite.self_modulate.a > 0.0001
	var old_target_visible := bool(old_state.get("visible", false))
	var target_visible := bool(new_state.get("visible", true))
	var target_opacity := clampf(float(new_state.get("opacity", 1.0)), 0.0, 1.0)
	var animate := (
		duration > 0.0
		and transition not in ["cut", "none"]
		and (old_target_visible or target_visible)
	)

	if not animate:
		_apply_channels_cut(record, new_state)
		_apply_redraw(record, new_state)
		_apply_transform_cut(record, new_state)
		root.visible = target_visible
		composite.self_modulate.a = target_opacity
		_emit_or_queue_transition_finished(layer_id, generation, true)
		return

	root.visible = true
	if not was_visible:
		# A fade-in should not also fly from Node2D's default origin. Slide
		# transitions establish their own off-screen starting point below.
		_apply_transform_cut(record, new_state)
	var tween := create_tween().set_parallel(true)
	_layer_tweens[layer_id] = tween

	var crossfade_textures := transition == "fade" and target_visible and was_visible
	_apply_channels_animated(record, new_state, tween, crossfade_textures, duration)
	_apply_redraw(record, new_state)
	_tween_transform(
		record,
		new_state,
		tween,
		duration,
		not transition.begins_with("slide"),
	)

	if transition == "fade":
		if not was_visible and target_visible:
			composite.self_modulate.a = 0.0
		tween.tween_property(
			composite,
			"self_modulate:a",
			target_opacity if target_visible else 0.0,
			duration,
		)
	elif transition.begins_with("slide"):
		var target_position := _state_position(new_state)
		var delta := _slide_delta(transition)
		if not was_visible and target_visible:
			root.position = target_position - delta
		elif not target_visible:
			target_position += delta
		tween.tween_property(root, "position", target_position, duration) \
			.set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
		tween.tween_property(
			composite,
			"self_modulate:a",
			target_opacity if target_visible else 0.0,
			duration,
		)
	else:
		# "move" and future transform transitions interpolate authored values
		# without inventing an off-screen start position.
		tween.tween_property(
			composite,
			"self_modulate:a",
			target_opacity if target_visible else 0.0,
			duration,
		)

	var token := _claim_layer_transition(layer_id)
	tween.finished.connect(func() -> void:
		if generation != int(_layer_generations.get(layer_id, -1)):
			return
		_layer_tweens.erase(layer_id)
		_clear_layer_transition_token(layer_id, token)
		_cleanup_outgoing(record)
		_apply_channels_cut(record, new_state)
		_apply_transform_cut(record, new_state)
		composite.self_modulate.a = target_opacity
		root.visible = target_visible
		_emit_or_queue_transition_finished(layer_id, generation, true)
	)
	_emit_stage_transition_started(layer_id, token)


func _remove_layer(layer_id: String, transition: String, duration: float) -> void:
	if not _layers.has(layer_id):
		return
	var record: Dictionary = _layers[layer_id]
	var generation := _begin_layer_change(layer_id)
	var root := record["root"] as Node2D
	var composite := record["composite"] as CanvasGroup

	if duration <= 0.0 or transition in ["cut", "none"]:
		_free_layer(layer_id)
		_emit_or_queue_transition_finished(layer_id, generation, false)
		return

	var tween := create_tween().set_parallel(true)
	_layer_tweens[layer_id] = tween
	if transition.begins_with("slide"):
		tween.tween_property(
			root,
			"position",
			root.position + _slide_delta(transition),
			duration,
		).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	else:
		tween.tween_property(composite, "self_modulate:a", 0.0, duration)

	var token := _claim_layer_transition(layer_id)
	tween.finished.connect(func() -> void:
		if generation != int(_layer_generations.get(layer_id, -1)):
			return
		_layer_tweens.erase(layer_id)
		_clear_layer_transition_token(layer_id, token)
		_free_layer(layer_id)
		_emit_or_queue_transition_finished(layer_id, generation, false)
	)
	_emit_stage_transition_started(layer_id, token)


func _begin_completion_batch() -> void:
	_completion_batch_depth += 1


func _end_completion_batch() -> void:
	_completion_batch_depth = maxi(0, _completion_batch_depth - 1)
	if _completion_batch_depth == 0 and not _flushing_transition_completions:
		_flush_transition_completions()


func _emit_or_queue_transition_finished(
	layer_id: String,
	generation: int,
	expects_layer: bool,
) -> void:
	var completion := {
		"id": layer_id,
		"generation": generation,
		"expects_layer": expects_layer,
	}
	if _completion_batch_depth > 0 or _flushing_transition_completions:
		_queued_transition_completions.append(completion)
		return
	if _is_transition_completion_current(completion):
		layer_transition_finished.emit(layer_id)


func _flush_transition_completions() -> void:
	if _flushing_transition_completions:
		return
	_flushing_transition_completions = true
	while not _queued_transition_completions.is_empty():
		var completion: Dictionary = _queued_transition_completions.pop_front()
		if _is_transition_completion_current(completion):
			layer_transition_finished.emit(String(completion["id"]))
	_flushing_transition_completions = false


func _is_transition_completion_current(completion: Dictionary) -> bool:
	var layer_id := String(completion.get("id", ""))
	if bool(completion.get("expects_layer", false)):
		return (
			_states.has(layer_id)
			and _layers.has(layer_id)
			and int(_layer_generations.get(layer_id, -1))
				== int(completion.get("generation", -2))
		)
	return not _states.has(layer_id) and not _layers.has(layer_id)


func _layer_host() -> Node:
	var shake_root := get_node_or_null("ShakeRoot")
	return shake_root if shake_root != null else self


func _ensure_layer(layer_id: String) -> Dictionary:
	if _layers.has(layer_id):
		return _layers[layer_id]

	var root := Node2D.new()
	root.name = "Layer_%d" % _next_node_index
	_next_node_index += 1
	root.set_meta("stage_layer_id", layer_id)
	root.z_as_relative = false
	root.visible = false
	_layer_host().add_child(root)

	var composite := CanvasGroup.new()
	composite.name = "Composite"
	root.add_child(composite)

	var sprites := {}
	var asset_ids := {}
	for channel in ["asset", "body", "face"]:
		var sprite := Sprite2D.new()
		sprite.name = "%sSprite" % channel.capitalize()
		sprite.centered = false
		sprite.z_index = {"asset": 0, "body": 1, "face": 2}[channel]
		composite.add_child(sprite)
		sprites[channel] = sprite
		asset_ids[channel] = ""

	var record := {
		"root": root,
		"composite": composite,
		"sprites": sprites,
		"asset_ids": asset_ids,
		"outgoing": [],
	}
	_layers[layer_id] = record
	_layer_generations[layer_id] = 0
	return record


func _begin_layer_change(layer_id: String) -> int:
	var generation := int(_layer_generations.get(layer_id, 0)) + 1
	_layer_generations[layer_id] = generation
	_layer_transition_tokens.erase(layer_id)
	if _layer_tweens.has(layer_id):
		var tween = _layer_tweens[layer_id]
		if tween and tween.is_valid():
			tween.kill()
		_layer_tweens.erase(layer_id)
	if _layers.has(layer_id):
		var record: Dictionary = _layers[layer_id]
		_cleanup_outgoing(record)
		for sprite in (record["sprites"] as Dictionary).values():
			(sprite as Sprite2D).modulate.a = 1.0
	return generation


func _claim_layer_transition(layer_id: String) -> int:
	var token := _next_transition_token
	_next_transition_token += 1
	_layer_transition_tokens[layer_id] = token
	return token


func _emit_stage_transition_started(layer_id: String, token: int) -> void:
	SignalBus.stage_transition_started.emit(
		get_instance_id(),
		layer_id,
		token,
		_active_stage_operation_request_id,
	)


func _clear_layer_transition_token(layer_id: String, token: int) -> void:
	if int(_layer_transition_tokens.get(layer_id, -1)) == token:
		_layer_transition_tokens.erase(layer_id)


func _cleanup_outgoing(record: Dictionary) -> void:
	for node in record.get("outgoing", []):
		if not is_instance_valid(node):
			continue
		var parent := (node as Node).get_parent()
		if parent:
			parent.remove_child(node)
		(node as Node).queue_free()
	record["outgoing"] = []


func _free_layer(layer_id: String) -> void:
	_layer_transition_tokens.erase(layer_id)
	if not _layers.has(layer_id):
		return
	if _layer_tweens.has(layer_id):
		var tween = _layer_tweens[layer_id]
		if tween and tween.is_valid():
			tween.kill()
		_layer_tweens.erase(layer_id)
	var record: Dictionary = _layers[layer_id]
	_cleanup_outgoing(record)
	var root := record["root"] as Node2D
	if is_instance_valid(root):
		if root.get_parent():
			root.get_parent().remove_child(root)
		root.queue_free()
	_layers.erase(layer_id)
	_layer_generations.erase(layer_id)


func _clear_visuals() -> void:
	for layer_id in _layers.keys().duplicate():
		_free_layer(String(layer_id))


func _apply_channels_cut(record: Dictionary, state: Dictionary) -> void:
	for channel in ["asset", "body", "face"]:
		_set_channel_texture(record, channel, String(state.get(channel, "")), null, false)
		_apply_channel_layout(record, channel, state)


func _apply_channels_animated(
	record: Dictionary,
	state: Dictionary,
	tween: Tween,
	crossfade: bool,
	duration: float,
) -> void:
	for channel in ["asset", "body", "face"]:
		var changed := _set_channel_texture(
			record,
			channel,
			String(state.get(channel, "")),
			tween,
			crossfade,
			duration,
		)
		var sprite := (record["sprites"] as Dictionary)[channel] as Sprite2D
		var target := _channel_layout(sprite, channel, state)
		tween.tween_property(sprite, "position", target["position"], duration)
		tween.tween_property(sprite, "scale", target["scale"], duration)
		sprite.centered = target["centered"]
		if crossfade and changed and sprite.texture != null:
			tween.tween_property(sprite, "modulate:a", 1.0, duration)


func _set_channel_texture(
	record: Dictionary,
	channel: String,
	asset_id: String,
	tween: Tween,
	crossfade: bool,
	duration: float = 0.0,
) -> bool:
	var asset_ids := record["asset_ids"] as Dictionary
	if String(asset_ids.get(channel, "")) == asset_id:
		return false

	var sprite := (record["sprites"] as Dictionary)[channel] as Sprite2D
	var new_texture: Texture2D = null
	if asset_id != "":
		new_texture = _load_stage_texture(asset_id)
		if new_texture == null:
			push_warning("StagePresenter: texture not found: %s" % asset_id)
			# Keep the visible projection deterministic with the canonical state:
			# a missing target clears this channel both now and after save/restore,
			# rather than retaining an old texture that the snapshot cannot name.

	if crossfade and tween != null and sprite.texture != null:
		var outgoing := _clone_sprite(sprite)
		outgoing.name = "Outgoing_%s" % channel
		(record["composite"] as CanvasGroup).add_child(outgoing)
		(record["outgoing"] as Array).append(outgoing)
		tween.tween_property(outgoing, "modulate:a", 0.0, duration)

	sprite.texture = new_texture
	asset_ids[channel] = asset_id
	if crossfade and tween != null and new_texture != null:
		sprite.modulate.a = 0.0
		# The caller adds the real-duration alpha track below after this helper.
	return true


func _clone_sprite(source: Sprite2D) -> Sprite2D:
	var clone := Sprite2D.new()
	clone.texture = source.texture
	clone.position = source.position
	clone.scale = source.scale
	clone.rotation = source.rotation
	clone.centered = source.centered
	clone.offset = source.offset
	clone.flip_h = source.flip_h
	clone.flip_v = source.flip_v
	clone.z_index = source.z_index
	clone.modulate = source.modulate
	return clone


func _apply_channel_layout(record: Dictionary, channel: String, state: Dictionary) -> void:
	var sprite := (record["sprites"] as Dictionary)[channel] as Sprite2D
	var layout := _channel_layout(sprite, channel, state)
	sprite.centered = layout["centered"]
	sprite.position = layout["position"]
	sprite.scale = layout["scale"]
	sprite.modulate.a = 1.0


func _channel_layout(sprite: Sprite2D, channel: String, state: Dictionary) -> Dictionary:
	var offset := _array_to_vector2(state.get("%s_offset" % channel, [0.0, 0.0]))
	if channel != "asset" or sprite.texture == null:
		return {"centered": false, "position": offset, "scale": Vector2.ONE}

	var fit := String(state.get("fit", "native"))
	if fit in ["native", "none", ""]:
		return {"centered": false, "position": offset, "scale": Vector2.ONE}

	var texture_size := sprite.texture.get_size()
	if texture_size.x <= 0.0 or texture_size.y <= 0.0:
		return {"centered": false, "position": offset, "scale": Vector2.ONE}
	var viewport_size := _viewport_size()
	var fit_scale := Vector2.ONE
	match fit:
		"cover":
			var factor := maxf(
				viewport_size.x / texture_size.x,
				viewport_size.y / texture_size.y,
			)
			fit_scale = Vector2(factor, factor)
		"contain":
			var factor := minf(
				viewport_size.x / texture_size.x,
				viewport_size.y / texture_size.y,
			)
			fit_scale = Vector2(factor, factor)
		"stretch":
			fit_scale = Vector2(
				viewport_size.x / texture_size.x,
				viewport_size.y / texture_size.y,
			)
		_:
			push_warning("StagePresenter: unknown fit mode '%s'; using native" % fit)
			return {"centered": false, "position": offset, "scale": Vector2.ONE}
	return {
		"centered": true,
		"position": viewport_size * 0.5 + offset,
		"scale": fit_scale,
	}


func _apply_transform_cut(record: Dictionary, state: Dictionary) -> void:
	var root := record["root"] as Node2D
	var composite := record["composite"] as CanvasGroup
	root.position = _state_position(state)
	root.rotation_degrees = float(state.get("rotation", 0.0))
	root.scale = _state_scale(state)
	root.z_index = clampi(
		int(state.get("z_index", 0)),
		RenderingServer.CANVAS_ITEM_Z_MIN,
		RenderingServer.CANVAS_ITEM_Z_MAX,
	)
	composite.position = _composite_origin_position(state)
	var redraw := state.get("redraw", {}) as Dictionary
	composite.scale = Vector2(
		-1.0 if bool(redraw.get("flip_x", false)) else 1.0,
		-1.0 if bool(redraw.get("flip_y", false)) else 1.0,
	)


func _tween_transform(
	record: Dictionary,
	state: Dictionary,
	tween: Tween,
	duration: float,
	tween_position: bool = true,
) -> void:
	var root := record["root"] as Node2D
	var composite := record["composite"] as CanvasGroup
	root.z_index = clampi(
		int(state.get("z_index", 0)),
		RenderingServer.CANVAS_ITEM_Z_MIN,
		RenderingServer.CANVAS_ITEM_Z_MAX,
	)
	if tween_position:
		tween.tween_property(root, "position", _state_position(state), duration)
	tween.tween_property(
		root,
		"rotation_degrees",
		float(state.get("rotation", 0.0)),
		duration,
	)
	tween.tween_property(root, "scale", _state_scale(state), duration)
	tween.tween_property(
		composite,
		"position",
		_composite_origin_position(state),
		duration,
	)
	var redraw := state.get("redraw", {}) as Dictionary
	composite.scale = Vector2(
		-1.0 if bool(redraw.get("flip_x", false)) else 1.0,
		-1.0 if bool(redraw.get("flip_y", false)) else 1.0,
	)


func _state_position(state: Dictionary) -> Vector2:
	return _array_to_vector2(state.get("position", [0.0, 0.0]))


func _state_scale(state: Dictionary) -> Vector2:
	var scale_value := _array_to_vector2(state.get("scale", [1.0, 1.0]), Vector2.ONE)
	var zoom := _array_to_vector2(state.get("zoom", [1.0, 1.0]), Vector2.ONE)
	var depth_scale := float(state.get("depth_scale", 1.0))
	return scale_value * zoom * depth_scale


func _composite_origin_position(state: Dictionary) -> Vector2:
	var origin := _array_to_vector2(state.get("origin", [0.0, 0.0]))
	var redraw_value = state.get("redraw", {})
	var redraw: Dictionary = redraw_value if redraw_value is Dictionary else {}
	var flip := Vector2(
		-1.0 if bool(redraw.get("flip_x", false)) else 1.0,
		-1.0 if bool(redraw.get("flip_y", false)) else 1.0,
	)
	return -(flip * origin)


func _apply_redraw(record: Dictionary, state: Dictionary) -> void:
	var composite := record["composite"] as CanvasGroup
	var redraw_value = state.get("redraw", {})
	var redraw: Dictionary = redraw_value if redraw_value is Dictionary else {}
	var grayscale := clampf(float(redraw.get("grayscale", 0.0)), 0.0, 1.0)
	var blur := _array_to_vector2(redraw.get("blur", [0.0, 0.0])).abs()
	var tint := _to_color(redraw.get("tint", "#ffffffff"))
	var needs_material := (
		grayscale > 0.0001
		or blur.x > 0.0001
		or blur.y > 0.0001
		or not tint.is_equal_approx(Color.WHITE)
	)
	if not needs_material or _redraw_shader == null:
		composite.material = null
		composite.use_mipmaps = false
		composite.fit_margin = 10.0
		composite.clear_margin = 10.0
		return

	var material := composite.material as ShaderMaterial
	if material == null or material.shader != _redraw_shader:
		material = ShaderMaterial.new()
		material.shader = _redraw_shader
		composite.material = material
	material.set_shader_parameter("grayscale_amount", grayscale)
	material.set_shader_parameter("blur_radius", blur)
	material.set_shader_parameter("tint_color", tint)
	var margin := maxf(10.0, maxf(blur.x, blur.y) + 2.0)
	composite.fit_margin = margin
	composite.clear_margin = margin
	composite.use_mipmaps = maxf(blur.x, blur.y) > 2.0


func _slide_delta(transition: String) -> Vector2:
	var viewport_size := _viewport_size()
	match transition:
		"slide_right":
			return Vector2(viewport_size.x, 0.0)
		"slide_up":
			return Vector2(0.0, -viewport_size.y)
		"slide_down":
			return Vector2(0.0, viewport_size.y)
		_:
			return Vector2(-viewport_size.x, 0.0)


func _normalize_transition(raw_transition: String) -> String:
	var transition := raw_transition.to_lower().strip_edges()
	if transition == "":
		return "cut"
	if transition not in StageLayerState.VALID_TRANSITIONS:
		push_warning(
			"StagePresenter: unknown transition '%s'; using cut" % raw_transition
		)
		return "cut"
	return transition


func _load_stage_texture(asset_id: String) -> Texture2D:
	var path := asset_id
	if asset_id.begins_with("background:"):
		path = StellaRuntime.backgrounds_path + asset_id.trim_prefix("background:")
	elif asset_id.begins_with("character:"):
		path = StellaRuntime.characters_path + asset_id.trim_prefix("character:")
	elif asset_id.begins_with("stage:"):
		path = StellaRuntime.stage_assets_path + asset_id.trim_prefix("stage:")
	elif not asset_id.begins_with("res://"):
		path = StellaRuntime.stage_assets_path + asset_id

	if ResourceLoader.exists(path):
		return ResourceLoader.load(path, "Texture2D", ResourceLoader.CACHE_MODE_REUSE) as Texture2D
	if path.get_extension() != "":
		return null
	for extension in TEXTURE_EXTENSIONS:
		var candidate: String = path + String(extension)
		if ResourceLoader.exists(candidate):
			return ResourceLoader.load(
				candidate,
				"Texture2D",
				ResourceLoader.CACHE_MODE_REUSE,
			) as Texture2D
	return null


func _array_to_vector2(value: Variant, fallback: Vector2 = Vector2.ZERO) -> Vector2:
	if value is Vector2:
		return value
	if value is Array and value.size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	if value is Dictionary:
		return Vector2(float(value.get("x", fallback.x)), float(value.get("y", fallback.y)))
	if value is int or value is float:
		return Vector2(float(value), float(value))
	return fallback


func _to_color(value: Variant) -> Color:
	if value is Color:
		return value
	if value is String:
		return Color.from_string(value, Color.WHITE)
	if value is Array and value.size() >= 3:
		return Color(
			float(value[0]),
			float(value[1]),
			float(value[2]),
			float(value[3]) if value.size() >= 4 else 1.0,
		)
	if value is Dictionary:
		return Color(
			float(value.get("r", 1.0)),
			float(value.get("g", 1.0)),
			float(value.get("b", 1.0)),
			float(value.get("a", 1.0)),
		)
	return Color.WHITE


func _viewport_size() -> Vector2:
	var size := get_viewport().get_visible_rect().size
	return DEFAULT_VIEWPORT_SIZE if size == Vector2.ZERO else size


func _on_viewport_size_changed() -> void:
	for layer_id in _states:
		if not _layers.has(layer_id):
			continue
		var record: Dictionary = _layers[layer_id]
		_apply_channel_layout(record, "asset", _states[layer_id])

## Cancel visual work without changing authored target state. Removed layers
## finish removal immediately; retained layers snap to their current target.
func _on_engine_abort_requested() -> void:
	for layer_id in _layers.keys().duplicate():
		var id := String(layer_id)
		_begin_layer_change(id)
		if not _states.has(id):
			_free_layer(id)
			continue
		var record: Dictionary = _layers[id]
		var state: Dictionary = _states[id]
		_apply_channels_cut(record, state)
		_apply_redraw(record, state)
		_apply_transform_cut(record, state)
		(record["root"] as Node2D).visible = bool(state.get("visible", true))
		(record["composite"] as CanvasGroup).self_modulate.a = clampf(
			float(state.get("opacity", 1.0)), 0.0, 1.0
		)
