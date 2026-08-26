## One bounded deterministic particle layer projected from a presentation clip's
## authoritative main AnimationPlayer position.
##
## The packed key arrays are normalized-life linear curves. They contain no
## process owner or callback and are safe to seal as part of the definition.
class_name PresentationClipParticleLayer extends Resource

const BLEND_MODES := [&"mix", &"add", &"sub", &"mul"]
const MASK_MODES := [&"none", &"alpha", &"inverse_alpha"]
const EMISSION_MODES := [&"rate", &"burst"]
const FILTER_MODES := [&"nearest", &"linear"]
const TEARDOWN_POLICIES := [&"fully_contained", &"cut"]
const MAX_KEYS_PER_CURVE := 64
const MAX_LIVE_PARTICLES := 256
const MAX_SPAWN_EVENTS := 8192

@export var id: StringName
@export var texture: Texture2D
@export var texture_filter: StringName = &"linear"
@export var mask_texture: Texture2D
@export var mask_filter: StringName = &"linear"
@export var mask_rect: Rect2
@export var mask_mode: StringName = &"none"
@export var blend_mode: StringName = &"mix"
@export_range(-4096, 4096, 1) var z_index: int = 0
@export var color: Color = Color.WHITE
@export var origin: Vector2 = Vector2.ZERO
@export var emission_mode: StringName = &"rate"
@export_range(0.0, 120.0, 0.001, "or_greater") var emission_start_seconds: float = 0.0
@export_range(0.0, 120.0, 0.001, "or_greater") var emission_end_seconds: float = 0.0
@export_range(0.0, 240.0, 0.001, "or_greater") var spawn_rate_min: float = 1.0
@export_range(0.0, 240.0, 0.001, "or_greater") var spawn_rate_max: float = 1.0
@export_range(0, MAX_LIVE_PARTICLES, 1) var burst_count_min: int = 0
@export_range(0, MAX_LIVE_PARTICLES, 1) var burst_count_max: int = 0
@export_range(0.001, 120.0, 0.001, "or_greater") var lifetime_seconds: float = 1.0
@export_range(1, MAX_LIVE_PARTICLES, 1) var maximum_live_particles: int = 1
@export var teardown_policy: StringName = &"fully_contained"
@export_range(0, 2147483647, 1) var seed: int = 0
@export var spawn_rect: Rect2
@export var projection_bounds: Rect2
@export var offset_motion_keys := PackedVector3Array([
	Vector3(0.0, 0.0, 0.0),
	Vector3(1.0, 0.0, 0.0),
])
@export var scaled_motion_keys := PackedVector3Array([
	Vector3(0.0, 0.0, 0.0),
	Vector3(1.0, 0.0, 0.0),
])
@export var opacity_keys := PackedVector2Array([
	Vector2(0.0, 1.0),
	Vector2(1.0, 1.0),
])
@export var scale_keys := PackedVector2Array([
	Vector2(0.0, 1.0),
	Vector2(1.0, 1.0),
])
@export var rotation_keys := PackedVector2Array([
	Vector2(0.0, 0.0),
	Vector2(1.0, 0.0),
])
@export_range(-64.0, 64.0, 0.001, "or_greater") var motion_scale_min: float = 1.0
@export_range(-64.0, 64.0, 0.001, "or_greater") var motion_scale_max: float = 1.0
@export_range(0.0, 64.0, 0.001, "or_greater") var initial_scale_min: float = 1.0
@export_range(0.0, 64.0, 0.001, "or_greater") var initial_scale_max: float = 1.0
@export_range(-100.0, 100.0, 0.001, "or_greater") var initial_rotation_min: float = 0.0
@export_range(-100.0, 100.0, 0.001, "or_greater") var initial_rotation_max: float = 0.0
@export var authored_source_path: String = ""
@export var authored_source_line: int = 0


func maximum_spawn_event_count() -> int:
	if (
		not is_finite(emission_start_seconds)
		or not is_finite(emission_end_seconds)
		or emission_end_seconds < emission_start_seconds
	):
		return -1
	if emission_mode == &"burst":
		return burst_count_max
	if not is_finite(spawn_rate_max) or spawn_rate_max <= 0.0:
		return -1
	return int(ceil(
		(emission_end_seconds - emission_start_seconds) * spawn_rate_max
		- 0.000001))


func validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	if not PresentationClipDefinition.is_logical_id(String(id)) or "/" in String(id):
		errors.append("id must be a canonical single-segment logical id")
	var texture_error := _static_texture_error(texture, {})
	if not texture_error.is_empty():
		errors.append("texture %s" % texture_error)
	if texture_filter not in FILTER_MODES:
		errors.append("texture_filter must be nearest or linear")
	if mask_filter not in FILTER_MODES:
		errors.append("mask_filter must be nearest or linear")
	if mask_mode not in MASK_MODES:
		errors.append("mask_mode must be none, alpha, or inverse_alpha")
	elif mask_mode == &"none":
		if mask_texture != null:
			errors.append("mask_texture requires alpha or inverse_alpha mask_mode")
	elif not _static_texture_error(mask_texture, {}).is_empty():
		errors.append(
			"mask_texture %s for the selected mask_mode"
			% _static_texture_error(mask_texture, {}))
	elif not _rect_is_finite(mask_rect) or mask_rect.size.x <= 0.0 or mask_rect.size.y <= 0.0:
		errors.append("mask_rect must be a finite positive logical rectangle")
	if blend_mode not in BLEND_MODES:
		errors.append("blend_mode must be mix, add, sub, or mul")
	if emission_mode not in EMISSION_MODES:
		errors.append("emission_mode must be rate or burst")
	if z_index < -4096 or z_index > 4096:
		errors.append("z_index must be in -4096..4096")
	if not _color_is_finite(color):
		errors.append("color must contain finite channels")
	if not _vector2_is_finite(origin):
		errors.append("origin must contain finite coordinates")
	if (
		not is_finite(emission_start_seconds)
		or not is_finite(emission_end_seconds)
		or emission_start_seconds < 0.0
		or emission_end_seconds < emission_start_seconds
		or emission_end_seconds > PresentationClipDefinition.MAX_DURATION_SECONDS
	):
		errors.append("emission window must be finite, ascending, and in 0..120")
	if emission_mode == &"rate":
		if (
			not is_finite(spawn_rate_min)
			or not is_finite(spawn_rate_max)
			or spawn_rate_min <= 0.0
			or spawn_rate_min > spawn_rate_max
			or spawn_rate_max > 240.0
		):
			errors.append("spawn_rate_min/max must be finite ascending values in (0,240]")
		if burst_count_min != 0 or burst_count_max != 0:
			errors.append("rate emission requires zero burst_count_min/max")
		if emission_end_seconds <= emission_start_seconds:
			errors.append("rate emission requires end_seconds after start_seconds")
	else:
		if (
			burst_count_min < 1
			or burst_count_min > burst_count_max
			or burst_count_max > maximum_live_particles
		):
			errors.append(
				"burst_count_min/max must be ascending positive values within maximum_live_particles")
		if spawn_rate_min != 0.0 or spawn_rate_max != 0.0:
			errors.append("burst emission requires zero spawn_rate_min/max")
		if emission_end_seconds != emission_start_seconds:
			errors.append("burst emission requires end_seconds equal to start_seconds")
	if (
		not is_finite(lifetime_seconds)
		or lifetime_seconds <= 0.0
		or lifetime_seconds > PresentationClipDefinition.MAX_DURATION_SECONDS
	):
		errors.append("lifetime_seconds must be finite and in (0,120]")
	if maximum_live_particles < 1 or maximum_live_particles > MAX_LIVE_PARTICLES:
		errors.append("maximum_live_particles must be in 1..256")
	if teardown_policy not in TEARDOWN_POLICIES:
		errors.append("teardown_policy must be fully_contained or cut")
	if seed < 0 or seed > 2147483647:
		errors.append("seed must be in 0..2147483647")
	var event_count := maximum_spawn_event_count()
	if event_count < 1 or event_count > MAX_SPAWN_EVENTS:
		errors.append("emission schedule must contain 1..8192 spawn events")
	if (
		emission_mode == &"rate"
		and ceil(lifetime_seconds * spawn_rate_max) > maximum_live_particles
	):
		errors.append(
			"maximum_live_particles must cover the worst-case rate/lifetime window")
	if not _rect_is_finite(spawn_rect) or spawn_rect.size.x < 0.0 or spawn_rect.size.y < 0.0:
		errors.append("spawn_rect must be finite with non-negative size")
	if (
		not _rect_is_finite(projection_bounds)
		or projection_bounds.size.x <= 0.0
		or projection_bounds.size.y <= 0.0
	):
		errors.append("projection_bounds must be a finite positive rectangle")
	_validate_vector_curve("offset_motion_keys", offset_motion_keys, errors)
	_validate_vector_curve("scaled_motion_keys", scaled_motion_keys, errors)
	_validate_scalar_curve("opacity_keys", opacity_keys, 0.0, 1.0, errors)
	_validate_scalar_curve("scale_keys", scale_keys, 0.0, 64.0, errors)
	_validate_scalar_curve("rotation_keys", rotation_keys, -100.0, 100.0, errors)
	if (
		not is_finite(motion_scale_min)
		or not is_finite(motion_scale_max)
		or motion_scale_min < -64.0
		or motion_scale_min > motion_scale_max
		or motion_scale_max > 64.0
	):
		errors.append("motion_scale_min/max must be finite ascending values in -64..64")
	if (
		not is_finite(initial_scale_min)
		or not is_finite(initial_scale_max)
		or initial_scale_min < 0.0
		or initial_scale_min > initial_scale_max
		or initial_scale_max > 64.0
	):
		errors.append("initial_scale_min/max must be finite ascending values in 0..64")
	if (
		not is_finite(initial_rotation_min)
		or not is_finite(initial_rotation_max)
		or initial_rotation_min < -100.0
		or initial_rotation_min > initial_rotation_max
		or initial_rotation_max > 100.0
	):
		errors.append("initial_rotation_min/max must be finite ascending values in -100..100")
	if authored_source_path.is_empty() != (authored_source_line == 0):
		errors.append("authored provenance requires both source_path and positive line")
	elif not authored_source_path.is_empty() and authored_source_line <= 0:
		errors.append("authored provenance requires both source_path and positive line")
	return errors


func _static_texture_error(
	value: Texture2D,
	visited: Dictionary,
) -> String:
	if value == null:
		return "must be a static data-only Texture2D"
	var identity := value.get_instance_id()
	if visited.has(identity):
		return "contains a cyclic texture wrapper"
	visited[identity] = true
	var class_name_value := value.get_class()
	if class_name_value in [
		"AnimatedTexture",
		"CameraTexture",
		"ExternalTexture",
		"NoiseTexture2D",
		"PlaceholderTexture2D",
		"Texture2DRD",
		"ViewportTexture",
	]:
		return "must not use live, external, procedural, or render-target texture class '%s'" % class_name_value
	if value is AtlasTexture:
		var atlas := (value as AtlasTexture).atlas
		if atlas == null:
			return "AtlasTexture must have a static backing texture"
		return _static_texture_error(atlas, visited)
	if value is CanvasTexture:
		var canvas := value as CanvasTexture
		if canvas.diffuse_texture == null:
			return "CanvasTexture must have a static diffuse texture"
		for child: Texture2D in [
			canvas.diffuse_texture,
			canvas.normal_texture,
			canvas.specular_texture,
		]:
			if child == null:
				continue
			var child_error := _static_texture_error(child, visited)
			if not child_error.is_empty():
				return child_error
		return ""
	if (
		value is ImageTexture
		or ClassDB.is_parent_class(class_name_value, "CompressedTexture2D")
		or ClassDB.is_parent_class(class_name_value, "PortableCompressedTexture2D")
	):
		return ""
	return "uses unsupported static texture class '%s'" % class_name_value


func _validate_vector_curve(
	label: String,
	keys: PackedVector3Array,
	errors: PackedStringArray,
) -> void:
	if keys.size() < 2 or keys.size() > MAX_KEYS_PER_CURVE:
		errors.append("%s must contain 2..64 keys" % label)
		return
	var previous_time := -1.0
	for key_index in range(keys.size()):
		var key := keys[key_index]
		if not is_finite(key.x) or not is_finite(key.y) or not is_finite(key.z):
			errors.append("%s[%d] must contain finite values" % [label, key_index])
			continue
		if key.x < 0.0 or key.x > 1.0 or key.x <= previous_time:
			errors.append("%s times must be strictly ascending in 0..1" % label)
		previous_time = key.x
	if keys[0].x != 0.0 or keys[keys.size() - 1].x != 1.0:
		errors.append("%s must have exact 0 and 1 endpoints" % label)


func _validate_scalar_curve(
	label: String,
	keys: PackedVector2Array,
	minimum: float,
	maximum: float,
	errors: PackedStringArray,
) -> void:
	if keys.size() < 2 or keys.size() > MAX_KEYS_PER_CURVE:
		errors.append("%s must contain 2..64 keys" % label)
		return
	var previous_time := -1.0
	for key_index in range(keys.size()):
		var key := keys[key_index]
		if not is_finite(key.x) or not is_finite(key.y):
			errors.append("%s[%d] must contain finite values" % [label, key_index])
			continue
		if key.x < 0.0 or key.x > 1.0 or key.x <= previous_time:
			errors.append("%s times must be strictly ascending in 0..1" % label)
		if key.y < minimum or key.y > maximum:
			errors.append("%s values must be in %s..%s" % [label, minimum, maximum])
		previous_time = key.x
	if keys[0].x != 0.0 or keys[keys.size() - 1].x != 1.0:
		errors.append("%s must have exact 0 and 1 endpoints" % label)


func _vector2_is_finite(value: Vector2) -> bool:
	return is_finite(value.x) and is_finite(value.y)


func _rect_is_finite(value: Rect2) -> bool:
	return _vector2_is_finite(value.position) and _vector2_is_finite(value.size)


func _color_is_finite(value: Color) -> bool:
	return (
		is_finite(value.r)
		and is_finite(value.g)
		and is_finite(value.b)
		and is_finite(value.a)
	)
