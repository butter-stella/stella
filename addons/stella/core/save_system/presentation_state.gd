## Tracks presentation-layer state (background, stage, BGM, dialogue gates/content) for save/load.
class_name PresentationState extends RefCounted

var current_bg: String = ""
var stage_layers: Dictionary = {}
var current_bgm: Dictionary = {}
var loop_se_channels: Dictionary = {}
var dialogue_visibility: Dictionary = DialogueVisibilityState.default_state()
var dialogue_content: Dictionary = _inactive_dialogue_content()

var _connected: bool = false


func get_provider_id() -> String:
	return "presentation_state"


func connect_signals() -> void:
	if _connected:
		return
	SignalBus.bg_changed.connect(_on_bg_changed)
	SignalBus.stage_operations_requested.connect(_on_stage_operations)
	SignalBus.bgm_operation_committed.connect(_on_bgm_operation_committed)
	SignalBus.bgm_position_committed.connect(_on_bgm_position_committed)
	SignalBus.bgm_natural_stop_committed.connect(_on_bgm_natural_stop_committed)
	SignalBus.bgm_presenter_registered.connect(_on_bgm_presenter_registered)
	SignalBus.loop_se_operation_committed.connect(_on_loop_se_operation_committed)
	SignalBus.loop_se_positions_committed.connect(_on_loop_se_positions_committed)
	SignalBus.loop_se_presenter_registered.connect(_on_loop_se_presenter_registered)
	if SignalBus.has_signal(&"dialogue_visibility_operations_requested"):
		(SignalBus.get(&"dialogue_visibility_operations_requested") as Signal).connect(
			_on_dialogue_visibility_operations
		)
	_connected = true


func disconnect_signals() -> void:
	if not _connected:
		return
	SignalBus.bg_changed.disconnect(_on_bg_changed)
	SignalBus.stage_operations_requested.disconnect(_on_stage_operations)
	SignalBus.bgm_operation_committed.disconnect(_on_bgm_operation_committed)
	SignalBus.bgm_position_committed.disconnect(_on_bgm_position_committed)
	SignalBus.bgm_natural_stop_committed.disconnect(_on_bgm_natural_stop_committed)
	SignalBus.bgm_presenter_registered.disconnect(_on_bgm_presenter_registered)
	SignalBus.loop_se_operation_committed.disconnect(_on_loop_se_operation_committed)
	SignalBus.loop_se_positions_committed.disconnect(_on_loop_se_positions_committed)
	SignalBus.loop_se_presenter_registered.disconnect(_on_loop_se_presenter_registered)
	if SignalBus.has_signal(&"dialogue_visibility_operations_requested"):
		var visibility_signal: Signal = SignalBus.get(&"dialogue_visibility_operations_requested")
		if visibility_signal.is_connected(_on_dialogue_visibility_operations):
			visibility_signal.disconnect(_on_dialogue_visibility_operations)
	_connected = false


func clear() -> void:
	current_bg = ""
	stage_layers.clear()
	current_bgm.clear()
	loop_se_channels.clear()
	dialogue_visibility = DialogueVisibilityState.default_state()
	dialogue_content = _inactive_dialogue_content()


func capture_snapshot() -> Dictionary:
	var captured_bgm := BgmChannelState.with_position(
		current_bgm, SignalBus.capture_bgm_position())
	var captured_loop_se := LoopSeChannelState.with_positions(
		loop_se_channels,
		SignalBus.capture_loop_se_positions(),
	)
	return {
		"bg": current_bg,
		"stage_layers": stage_layers.duplicate(true),
		"bgm": captured_bgm,
		"loop_se_channels": captured_loop_se,
		"dialogue_visibility": dialogue_visibility.duplicate(true),
		"dialogue_content": dialogue_content.duplicate(true),
	}


func restore_snapshot(snapshot: Dictionary) -> void:
	current_bg = String(snapshot.get("bg", ""))
	current_bgm.clear()
	var restored_bgm: Variant = snapshot.get("bgm", {})
	if BgmChannelState.validate_snapshot_state(restored_bgm, false):
		current_bgm = (restored_bgm as Dictionary).duplicate(true)
	else:
		push_warning("PresentationState: invalid BGM snapshot; using stopped state")
	loop_se_channels.clear()
	var restored_loop_se: Variant = snapshot.get("loop_se_channels", {})
	if LoopSeChannelState.validate_channels(restored_loop_se, false):
		loop_se_channels = (restored_loop_se as Dictionary).duplicate(true)
	else:
		push_warning(
			"PresentationState: invalid loop_se_channels snapshot; using empty state"
		)
	stage_layers.clear()
	var restored_layers = snapshot.get("stage_layers", {})
	if restored_layers is Dictionary:
		for id in restored_layers:
			var layer_id := str(id).strip_edges()
			if layer_id == "":
				push_warning("PresentationState: ignored empty stage layer id")
				continue
			var layer_state = restored_layers[id]
			if layer_state is Dictionary:
				stage_layers[layer_id] = StageLayerState.normalize_full(layer_state)
			else:
				push_warning(
					"PresentationState: invalid stage layer '%s' in snapshot"
					% str(id)
				)
	var restored_visibility: Variant = snapshot.get(
		"dialogue_visibility",
		DialogueVisibilityState.default_state(),
	)
	if DialogueVisibilityState.validate_snapshot_state(restored_visibility, false):
		dialogue_visibility = (restored_visibility as Dictionary).duplicate(true)
	else:
		push_warning(
			"PresentationState: invalid dialogue_visibility snapshot; using defaults"
		)
		dialogue_visibility = DialogueVisibilityState.default_state()
	var restored_content: Variant = snapshot.get(
		"dialogue_content",
		_inactive_dialogue_content(),
	)
	if _validate_dialogue_content(restored_content, false):
		dialogue_content = _normalize_dialogue_content(restored_content as Dictionary)
	else:
		push_warning(
			"PresentationState: invalid dialogue_content snapshot; resetting dialogue projection"
		)
		dialogue_visibility = DialogueVisibilityState.default_state()
		dialogue_content = _inactive_dialogue_content()


func record_dialogue_content(
	request: DialogueRequest,
	context: ScenarioContext,
) -> void:
	if request == null or context == null:
		dialogue_content = _inactive_dialogue_content()
		return
	var mode := String(
		context.current_dialogue_mode
		if context.current_dialogue_mode != ""
		else request.get_mode()
	)
	var segments := _text_only_segments(request.get_segments())
	if segments.is_empty():
		dialogue_content = _inactive_dialogue_content()
		return
	var content := {
		"version": 1,
		"active": true,
		"mode": mode if mode in ["adv", "nvl", "overlay", "monologue"] else "adv",
		"profile_name": String(context.current_dialogue_profile_name),
		"declarative_presentation": bool(
			context.current_dialogue_uses_declarative_presentation
		),
		"character": request.get_character(),
		"segments": segments,
		"avatar_expression": _final_avatar_expression(request.get_segments()),
		"nvl_entries": [],
	}
	if content["mode"] == "nvl":
		var entries: Array = []
		for entry_value: Variant in context.nvl_page_entries:
			if not entry_value is Dictionary:
				continue
			var entry: Dictionary = entry_value
			entries.append({
				"profile_name": String(entry.get("profile_name", "")),
				"character": String(entry.get("character", "")),
				"segments": _text_only_segments(entry.get("segments", [])),
			})
		content["nvl_entries"] = entries
	dialogue_content = (
		_normalize_dialogue_content(content)
		if _validate_dialogue_content(content, false)
		else _inactive_dialogue_content()
	)


func apply_to_presenters(runtime_binding: Dictionary = {}) -> void:
	SignalBus.run_presentation_projection(func() -> void:
		SignalBus.reset_dialogue_visibility_visuals()
		if SignalBus.has_signal(&"dialogue_visibility_state_apply_requested"):
			(SignalBus.get(&"dialogue_visibility_state_apply_requested") as Signal).emit(
				dialogue_visibility.duplicate(true),
				dialogue_content.duplicate(true),
				runtime_binding.duplicate(true),
			)
		SignalBus.reset_and_apply_stage_state(stage_layers)
		SignalBus.reset_and_apply_loop_se_state(loop_se_channels)
		SignalBus.reset_and_apply_bgm_state(current_bgm)
		SignalBus.bg_changed.emit(current_bg, "none", 0.0)
	)


func _on_bg_changed(asset: String, _transition: String, _duration: float) -> void:
	current_bg = asset


func _on_stage_operations(operations: Array, _force_cut: bool) -> void:
	if not SignalBus.is_current_stage_operation_valid():
		return
	stage_layers = StageLayerState.reduce(stage_layers, operations)


func _on_bgm_operation_committed(
	operation: BgmPresentationOperation,
	state: Dictionary,
) -> void:
	if (
		operation == null
		or not SignalBus.is_current_bgm_operation_valid()
		or not BgmChannelState.validate_snapshot_state(state, false)
	):
		return
	current_bgm = state.duplicate(true)


func _on_bgm_position_committed(position: float) -> void:
	current_bgm = BgmChannelState.with_position(current_bgm, position)


func _on_bgm_natural_stop_committed() -> void:
	current_bgm.clear()


func _on_bgm_presenter_registered() -> void:
	SignalBus.reset_and_apply_bgm_state(current_bgm)


func _on_loop_se_operation_committed(operation: LoopSePresentationOperation) -> void:
	if operation == null or not SignalBus.is_current_loop_se_operation_valid():
		return
	var payload := operation.get_payload()
	if not LoopSeChannelState.operation_has_work(loop_se_channels, payload):
		return
	# Commit from the physical incoming cursor after Presenter apply. The reducer
	# then preserves that cursor for same-asset volume changes while asset
	# replacements use their authored resume_position.
	var positions := SignalBus.capture_loop_se_positions()
	if not SignalBus.is_current_loop_se_operation_valid():
		return
	loop_se_channels = LoopSeChannelState.with_positions(
		loop_se_channels, positions)
	loop_se_channels = LoopSeChannelState.reduce(
		loop_se_channels,
		[payload],
		false,
	)


func _on_loop_se_positions_committed(positions: Dictionary) -> void:
	loop_se_channels = LoopSeChannelState.with_positions(
		loop_se_channels, positions)


func _on_loop_se_presenter_registered() -> void:
	# A replacement Runtime-owned presenter inherits the canonical persistent
	# channels. This is a projection boundary, not a session reset.
	SignalBus.reset_and_apply_loop_se_state(loop_se_channels)


func _on_dialogue_visibility_operations(
	operations: Array,
	_force_cut: bool,
) -> void:
	var payloads: Array = []
	for operation_value: Variant in operations:
		if operation_value is PresentationOperation:
			payloads.append((operation_value as PresentationOperation).get_payload())
		else:
			payloads.append(operation_value)
	dialogue_visibility = DialogueVisibilityState.reduce(
		dialogue_visibility,
		payloads,
		false,
	)


static func _inactive_dialogue_content() -> Dictionary:
	return {
		"version": 1,
		"active": false,
		"mode": "adv",
		"profile_name": "",
		"declarative_presentation": false,
		"character": "",
		"segments": [],
		"avatar_expression": "",
		"nvl_entries": [],
	}


static func _validate_dialogue_content(
	raw_content: Variant,
	_report_warnings: bool,
) -> bool:
	if not raw_content is Dictionary:
		return false
	var content: Dictionary = raw_content
	var keys := content.keys()
	keys.sort()
	if keys != [
		"active",
		"avatar_expression",
		"character",
		"declarative_presentation",
		"mode",
		"nvl_entries",
		"profile_name",
		"segments",
		"version",
	]:
		return false
	if int(content.get("version", -1)) != 1:
		return false
	if not content.get("active", null) is bool:
		return false
	if not content.get("declarative_presentation", null) is bool:
		return false
	if not content.get("mode", null) is String:
		return false
	if String(content["mode"]) not in ["adv", "nvl", "overlay", "monologue"]:
		return false
	for key: String in ["profile_name", "character", "avatar_expression"]:
		if not content.get(key, null) is String:
			return false
	if not _segments_are_valid(content.get("segments", [])):
		return false
	if not content.get("nvl_entries", null) is Array:
		return false
	for entry_value: Variant in content["nvl_entries"]:
		if not entry_value is Dictionary:
			return false
		var entry: Dictionary = entry_value
		var entry_keys := entry.keys()
		entry_keys.sort()
		if entry_keys != ["character", "profile_name", "segments"]:
			return false
		if not entry.get("profile_name", null) is String:
			return false
		if not entry.get("character", null) is String:
			return false
		if not _segments_are_valid(entry.get("segments", [])):
			return false
	if not bool(content["active"]):
		return (
			String(content["mode"]) == "adv"
			and String(content["profile_name"]) == ""
			and not bool(content["declarative_presentation"])
			and String(content["character"]) == ""
			and String(content["avatar_expression"]) == ""
			and (content["segments"] as Array).is_empty()
			and (content["nvl_entries"] as Array).is_empty()
		)
	if (content["segments"] as Array).is_empty():
		return false
	if String(content["mode"]) == "nvl":
		var entries: Array = content["nvl_entries"]
		if entries.is_empty():
			return false
		var tail: Dictionary = entries[-1]
		if (
			String(tail.get("profile_name", "")) != String(content["profile_name"])
			or String(tail.get("character", "")) != String(content["character"])
			or tail.get("segments", []) != content["segments"]
		):
			return false
	elif not (content["nvl_entries"] as Array).is_empty():
		return false
	return true


static func _normalize_dialogue_content(content: Dictionary) -> Dictionary:
	if not bool(content.get("active", false)):
		return _inactive_dialogue_content()
	return {
		"version": 1,
		"active": true,
		"mode": String(content.get("mode", "adv")),
		"profile_name": String(content.get("profile_name", "")),
		"declarative_presentation": bool(content.get("declarative_presentation", false)),
		"character": String(content.get("character", "")),
		"segments": (content.get("segments", []) as Array).duplicate(true),
		"avatar_expression": String(content.get("avatar_expression", "")),
		"nvl_entries": (content.get("nvl_entries", []) as Array).duplicate(true),
	}


static func dialogue_content_profiles_exist(
	content: Dictionary,
	scenario_data: ScenarioData,
) -> bool:
	if scenario_data == null:
		return false
	if not bool(content.get("active", false)):
		return true
	var profile_name := String(content.get("profile_name", ""))
	if not profile_name.is_empty() and not scenario_data.dialogue_profiles.has(profile_name):
		return false
	for entry_value: Variant in content.get("nvl_entries", []):
		if not entry_value is Dictionary:
			return false
		var entry: Dictionary = entry_value
		var entry_profile := String(entry.get("profile_name", ""))
		if not entry_profile.is_empty() and not scenario_data.dialogue_profiles.has(entry_profile):
			return false
	return true


static func _segments_are_valid(raw_segments: Variant) -> bool:
	if not raw_segments is Array:
		return false
	for segment_value: Variant in raw_segments:
		if not segment_value is Dictionary:
			return false
		var segment: Dictionary = segment_value
		var keys := segment.keys()
		keys.sort()
		if keys != ["text"] or not segment.get("text", null) is String:
			return false
	return true


static func _text_only_segments(raw_segments: Array) -> Array:
	var segments: Array = []
	for segment_value: Variant in raw_segments:
		if not segment_value is Dictionary:
			continue
		segments.append({
			"text": String((segment_value as Dictionary).get("text", "")),
		})
	return segments


static func _final_avatar_expression(raw_segments: Array) -> String:
	var expression := ""
	for segment_value: Variant in raw_segments:
		if not segment_value is Dictionary:
			continue
		var text := String((segment_value as Dictionary).get("text", ""))
		var cursor := 0
		while true:
			var expr_at := text.find("[expr:", cursor)
			if expr_at < 0:
				break
			var end_at := text.find("]", expr_at)
			if end_at < 0:
				break
			expression = text.substr(expr_at + 6, end_at - expr_at - 6)
			cursor = end_at + 1
	return expression
