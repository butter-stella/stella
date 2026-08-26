## Declarative, reusable definition for one bounded animated presentation clip.
##
## Project importers translate source animation data into a normal Godot scene
## and AnimationPlayer timeline. Stella never parses project/source-engine
## formats and never accepts arbitrary paths from scenario DSL.
class_name PresentationClipDefinition extends Resource

const MAX_DURATION_SECONDS := 120.0
const MAX_CUES := 96
const MAX_SCENE_NODES := 512
const MAX_PARTICLE_LAYERS := 16
const MAX_TOTAL_LIVE_PARTICLES := 1024
const TRANSITIONS := [&"cut", &"turn"]
const FIT_MODES := [&"contain", &"cover", &"stretch"]

@export var scene: PackedScene
@export var animation_player_path: NodePath = NodePath("AnimationPlayer")
@export var animation_name: StringName = &"clip"
@export var logical_viewport_size: Vector2i = Vector2i(1920, 1080)
@export var fit_mode: StringName = &"contain"
@export var entry_transition: StringName = &"cut"
@export_range(0.0, 10.0, 0.001, "or_greater") var entry_duration: float = 0.0
@export var exit_transition: StringName = &"turn"
@export_range(0.0, 10.0, 0.001, "or_greater") var exit_duration: float = 0.5
@export var suppress_dialogue_surface: bool = true
@export var suppress_quick_menu: bool = true
@export var skippable: bool = true
@export var cues: Array[PresentationClipCue] = []
@export var particle_layers: Array[PresentationClipParticleLayer] = []


static func is_logical_id(value: String) -> bool:
	if value.is_empty() or value != value.strip_edges() or value.length() > 256:
		return false
	if (
		value.begins_with("/")
		or value.ends_with("/")
		or "//" in value
		or "\\" in value
		or value.begins_with("res://")
		or value.begins_with("user://")
	):
		return false
	for part_value: Variant in value.split("/", false):
		var part := String(part_value)
		if part.is_empty() or part in [".", ".."]:
			return false
		for index in range(part.length()):
			var code := part.unicode_at(index)
			if not (
				(code >= 48 and code <= 57)
				or (code >= 65 and code <= 90)
				or (code >= 97 and code <= 122)
				or code in [45, 95]
			):
				return false
	return true


func validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	if scene == null:
		errors.append("scene must be a PackedScene")
	if animation_player_path.is_empty():
		errors.append("animation_player_path must not be empty")
	if String(animation_name).is_empty():
		errors.append("animation_name must not be empty")
	if logical_viewport_size.x <= 0 or logical_viewport_size.y <= 0:
		errors.append("logical_viewport_size must contain positive pixel dimensions")
	if fit_mode not in FIT_MODES:
		errors.append("fit_mode must be contain, cover, or stretch")
	_validate_transition(
		"entry", entry_transition, entry_duration, errors)
	_validate_transition(
		"exit", exit_transition, exit_duration, errors)
	if cues.size() > MAX_CUES:
		errors.append("cues exceeds the 96-cue limit")
	if particle_layers.size() > MAX_PARTICLE_LAYERS:
		errors.append("particle_layers exceeds the 16-layer limit")
	var particle_ids: Dictionary = {}
	var total_live_particles := 0
	var logical_viewport_rect := Rect2(Vector2.ZERO, Vector2(logical_viewport_size))
	for layer_index in range(particle_layers.size()):
		var layer := particle_layers[layer_index]
		if layer == null:
			errors.append("particle_layers[%d] is null" % layer_index)
			continue
		for detail: String in layer.validation_errors():
			errors.append("particle_layers[%d].%s" % [layer_index, detail])
		var layer_id := String(layer.id)
		if particle_ids.has(layer_id):
			errors.append("particle_layers contains duplicate id '%s'" % layer_id)
		particle_ids[layer_id] = true
		total_live_particles += layer.maximum_live_particles
		if not logical_viewport_rect.encloses(layer.spawn_rect):
			errors.append(
				"particle_layers[%d].spawn_rect must lie inside logical_viewport_size"
				% layer_index)
		if not logical_viewport_rect.encloses(layer.projection_bounds):
			errors.append(
				"particle_layers[%d].projection_bounds must lie inside logical_viewport_size"
				% layer_index)
		if layer.mask_mode != &"none" and not logical_viewport_rect.encloses(
			layer.mask_rect):
			errors.append(
				"particle_layers[%d].mask_rect must lie inside logical_viewport_size"
				% layer_index)
	if total_live_particles > MAX_TOTAL_LIVE_PARTICLES:
		errors.append("particle_layers exceeds the 1024 total-live-particle limit")
	var previous_offset := -1.0
	for index in range(cues.size()):
		var cue := cues[index]
		if cue == null:
			errors.append("cues[%d] is null" % index)
			continue
		if (
			not is_finite(cue.offset_seconds)
			or cue.offset_seconds < 0.0
			or cue.offset_seconds > MAX_DURATION_SECONDS
		):
			errors.append(
				"cues[%d].offset_seconds must be finite and in 0..120"
				% index)
		elif cue.offset_seconds < previous_offset:
			errors.append("cues must preserve ascending authored offsets and order")
		previous_offset = cue.offset_seconds
		if cue is PresentationClipAudioCue:
			var audio_cue := cue as PresentationClipAudioCue
			if not is_logical_id(audio_cue.asset):
				errors.append(
					"cues[%d].asset must be a canonical logical id" % index)
			if (
				not is_finite(audio_cue.volume_db)
				or audio_cue.volume_db < -80.0
				or audio_cue.volume_db > 24.0
			):
				errors.append(
					"cues[%d].volume_db must be finite and in -80..24" % index)
		elif cue is PresentationClipStateCue:
			var state_cue := cue as PresentationClipStateCue
			if state_cue.animation_player_path.is_empty():
				errors.append(
					"cues[%d].animation_player_path must not be empty" % index)
			if String(state_cue.animation_name).is_empty():
				errors.append("cues[%d].animation_name must not be empty" % index)
		else:
			errors.append(
				"cues[%d] must be an exact state or system-audio cue" % index)
		_validate_cue_provenance(
			"cues[%d]" % index,
			cue.authored_source_path,
			cue.authored_source_line,
			errors,
		)
	return errors


func has_audio_cues() -> bool:
	for cue: PresentationClipCue in cues:
		if cue is PresentationClipAudioCue:
			return true
	return false


func canonical_value_snapshot() -> Dictionary:
	var ordered_cues: Array[Dictionary] = []
	for cue_index in range(cues.size()):
		var cue := cues[cue_index]
		var cue_value := {
			"ordinal": cue_index,
			"offset_seconds": cue.offset_seconds,
			"authored_source_path": cue.authored_source_path,
			"authored_source_line": cue.authored_source_line,
		}
		if cue is PresentationClipAudioCue:
			var audio_cue := cue as PresentationClipAudioCue
			cue_value["kind"] = "system_audio"
			cue_value["asset"] = audio_cue.asset
			cue_value["volume_db"] = audio_cue.volume_db
		elif cue is PresentationClipStateCue:
			var state_cue := cue as PresentationClipStateCue
			cue_value["kind"] = "state"
			cue_value["animation_player_path"] = String(
				state_cue.animation_player_path)
			cue_value["animation_name"] = String(state_cue.animation_name)
		ordered_cues.append(cue_value)
	var ordered_particle_layers: Array[Dictionary] = []
	for layer_index in range(particle_layers.size()):
		var layer := particle_layers[layer_index]
		ordered_particle_layers.append({
			"ordinal": layer_index,
			"id": String(layer.id),
			"texture_path": layer.texture.resource_path if layer.texture != null else "",
			"texture_filter": String(layer.texture_filter),
			"mask_texture_path": (
				layer.mask_texture.resource_path if layer.mask_texture != null else ""),
			"mask_filter": String(layer.mask_filter),
			"mask_rect": layer.mask_rect,
			"mask_mode": String(layer.mask_mode),
			"blend_mode": String(layer.blend_mode),
			"z_index": layer.z_index,
			"color": layer.color,
			"origin": layer.origin,
			"emission_mode": String(layer.emission_mode),
			"emission_start_seconds": layer.emission_start_seconds,
			"emission_end_seconds": layer.emission_end_seconds,
			"spawn_rate_min": layer.spawn_rate_min,
			"spawn_rate_max": layer.spawn_rate_max,
			"burst_count_min": layer.burst_count_min,
			"burst_count_max": layer.burst_count_max,
			"lifetime_seconds": layer.lifetime_seconds,
			"maximum_live_particles": layer.maximum_live_particles,
			"seed": layer.seed,
			"spawn_rect": layer.spawn_rect,
			"projection_bounds": layer.projection_bounds,
			"offset_motion_keys": layer.offset_motion_keys,
			"scaled_motion_keys": layer.scaled_motion_keys,
			"opacity_keys": layer.opacity_keys,
			"scale_keys": layer.scale_keys,
			"rotation_keys": layer.rotation_keys,
			"motion_scale_min": layer.motion_scale_min,
			"motion_scale_max": layer.motion_scale_max,
			"initial_scale_min": layer.initial_scale_min,
			"initial_scale_max": layer.initial_scale_max,
			"initial_rotation_min": layer.initial_rotation_min,
			"initial_rotation_max": layer.initial_rotation_max,
			"authored_source_path": layer.authored_source_path,
			"authored_source_line": layer.authored_source_line,
		})
	return {
		"animation_player_path": String(animation_player_path),
		"animation_name": String(animation_name),
		"logical_viewport_size": logical_viewport_size,
		"fit_mode": String(fit_mode),
		"entry_transition": String(entry_transition),
		"entry_duration": entry_duration,
		"exit_transition": String(exit_transition),
		"exit_duration": exit_duration,
		"suppress_dialogue_surface": suppress_dialogue_surface,
		"suppress_quick_menu": suppress_quick_menu,
		"skippable": skippable,
		"cues": ordered_cues,
		"particle_layers": ordered_particle_layers,
		"semantic_fingerprint": semantic_fingerprint(),
	}


func _validate_cue_provenance(
	label: String,
	source_path: String,
	source_line: int,
	errors: PackedStringArray,
) -> void:
	if source_path.is_empty() and source_line == 0:
		return
	if source_path.is_empty() or source_line <= 0:
		errors.append(
			"%s authored provenance requires both source_path and positive line"
			% label)


func semantic_fingerprint() -> String:
	var visited: Dictionary = {}
	return JSON.stringify(_fingerprint_variant(self, visited)).sha256_text()


func _fingerprint_variant(value: Variant, visited: Dictionary) -> Variant:
	if value is PackedScene:
		var packed := value as PackedScene
		var state := packed.get_state()
		var nodes: Array = []
		for node_index in range(state.get_node_count()):
			var properties: Array = []
			for property_index in range(
				state.get_node_property_count(node_index)):
				properties.append([
					String(state.get_node_property_name(node_index, property_index)),
					_fingerprint_variant(
						state.get_node_property_value(node_index, property_index),
						visited,
					),
				])
			nodes.append([
				String(state.get_node_path(node_index)),
				String(state.get_node_type(node_index)),
				properties,
			])
		return ["PackedScene", packed.resource_path, nodes]
	if value is Resource:
		var resource := value as Resource
		var identity := resource.get_instance_id()
		if visited.has(identity):
			return ["ResourceRef", visited[identity]]
		var serial := visited.size() + 1
		visited[identity] = serial
		var properties: Array = []
		for property_value: Variant in resource.get_property_list():
			var property: Dictionary = property_value
			if not (int(property.get("usage", 0)) & PROPERTY_USAGE_STORAGE):
				continue
			var property_name := StringName(property.get("name", ""))
			properties.append([
				String(property_name),
				_fingerprint_variant(resource.get(property_name), visited),
			])
		return [
			"Resource",
			resource.get_class(),
			resource.resource_path,
			properties,
		]
	if value is Array:
		var array_result: Array = []
		for child_value: Variant in value:
			array_result.append(_fingerprint_variant(child_value, visited))
		return array_result
	if value is Dictionary:
		var dictionary_result: Array = []
		var keys: Array = (value as Dictionary).keys()
		keys.sort_custom(func(left: Variant, right: Variant) -> bool:
			return str(left) < str(right))
		for key: Variant in keys:
			dictionary_result.append([
				str(key),
				_fingerprint_variant((value as Dictionary)[key], visited),
			])
		return dictionary_result
	if value is PackedByteArray:
		return ["PackedByteArray", (value as PackedByteArray).hex_encode()]
	if value is PackedInt32Array or value is PackedInt64Array:
		return [typeof(value), Array(value)]
	if value is PackedFloat32Array or value is PackedFloat64Array:
		return [typeof(value), Array(value)]
	if value is PackedStringArray or value is PackedVector2Array \
		or value is PackedVector3Array or value is PackedColorArray:
		return [typeof(value), str(value)]
	return [typeof(value), var_to_str(value)]


func _validate_transition(
	label: String,
	kind: StringName,
	duration: float,
	errors: PackedStringArray,
) -> void:
	if kind not in TRANSITIONS:
		errors.append("%s_transition must be cut or turn" % label)
	if not is_finite(duration) or duration < 0.0 or duration > 10.0:
		errors.append("%s_duration must be finite and in 0..10" % label)
	elif kind == &"cut" and duration != 0.0:
		errors.append("%s cut transition requires duration=0" % label)
	elif kind == &"turn" and duration <= 0.0:
		errors.append("%s turn transition requires duration>0" % label)
