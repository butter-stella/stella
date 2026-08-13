## Canonical, JSON-safe state reducer for Stella's named stage layers.
##
## Both PresentationState and StagePresenter use this reducer so authored
## show/update/hide/remove semantics cannot drift between save data and the
## visible scene. Vector-like values are stored as two-number Arrays rather
## than Vector2 so snapshots remain JSON serializable.
class_name StageLayerState extends RefCounted

const MIN_Z_INDEX := -4096
const MAX_Z_INDEX := 4096
const MAX_REDRAW_EFFECTS := 16
const MAX_BLUR_RADIUS := 32
const MAX_BLUR_PASSES := 4
const VALID_ACTIONS := ["show", "update", "hide", "remove", "clear"]
const VALID_TRANSITIONS := [
	"cut", "none", "fade", "move",
	"slide_left", "slide_right", "slide_up", "slide_down",
]
const VALID_FIT_MODES := ["native", "contain", "cover", "stretch"]
const _KNOWN_OPERATION_KEYS := {
	"action": true,
	"id": true,
	"properties": true,
	"transition": true,
	"duration": true,
}
const _PAIR_PROPERTY_KEYS := [
	"position", "origin", "scale", "zoom",
	"asset_offset", "body_offset", "face_offset",
]
const _NUMBER_PROPERTY_KEYS := [
	"x", "y", "origin_x", "origin_y", "scale_x", "scale_y",
	"zoom_x", "zoom_y", "asset_x", "asset_y", "body_x", "body_y",
	"face_x", "face_y", "depth_scale", "rotation", "z", "z_index",
	"opacity",
]
const _BOOL_PROPERTY_KEYS := ["visible", "flip_x", "flip_y"]

const _KNOWN_PROPERTY_KEYS := {
	"kind": true,
	"asset": true,
	"body": true,
	"face": true,
	"asset_offset": true,
	"body_offset": true,
	"face_offset": true,
	"asset_x": true,
	"asset_y": true,
	"body_x": true,
	"body_y": true,
	"face_x": true,
	"face_y": true,
	"position": true,
	"x": true,
	"y": true,
	"origin": true,
	"origin_x": true,
	"origin_y": true,
	"scale": true,
	"scale_x": true,
	"scale_y": true,
	"zoom": true,
	"zoom_x": true,
	"zoom_y": true,
	"depth_scale": true,
	"rotation": true,
	"z": true,
	"z_index": true,
	"visible": true,
	"opacity": true,
	"fit": true,
	"redraw": true,
	"flip_x": true,
	"flip_y": true,
	"metadata": true,
}
const VALID_COLOR_OVERLAY_BLEND_MODES := ["normal", "soft_light"]
const _REDRAW_EFFECT_KEYS := {
	"color_overlay": {"type": true, "color": true, "blend": true},
	"brightness_contrast": {"type": true, "brightness": true, "contrast": true},
	"grayscale": {"type": true, "amount": true},
	"tint": {"type": true, "color": true},
	"blur": {"type": true, "radius": true},
	"clip": {
		"type": true,
		"asset": true,
		"offset": true,
		"fit": true,
	},
}


static func default_state() -> Dictionary:
	return {
		"kind": "image",
		"asset": "",
		"body": "",
		"face": "",
		"asset_offset": [0.0, 0.0],
		"body_offset": [0.0, 0.0],
		"face_offset": [0.0, 0.0],
		"position": [0.0, 0.0],
		"origin": [0.0, 0.0],
		"scale": [1.0, 1.0],
		"zoom": [1.0, 1.0],
		"depth_scale": 1.0,
		"rotation": 0.0,
		"z_index": 0,
		"visible": true,
		"opacity": 1.0,
		"fit": "native",
		"flip_x": false,
		"flip_y": false,
		"redraw": [],
		"metadata": {},
	}


static func normalize_full(
	state: Dictionary,
	report_warnings: bool = true,
) -> Dictionary:
	return _apply_patch_to_normalized(
		default_state(),
		state,
		report_warnings,
	)


static func apply_patch(
	current: Dictionary,
	patch: Dictionary,
	report_warnings: bool = true,
) -> Dictionary:
	return _apply_patch_to_normalized(
		normalize_full(current, false),
		patch,
		report_warnings,
	)


## Validate the complete operation shared by state trackers and presenters.
## The full property payload is checked here so every consumer can reject an
## invalid operation before any part of it is applied.
static func validate_operation(
	raw_operation: Variant,
	report_warnings: bool = true,
) -> bool:
	if not raw_operation is Dictionary:
		_warn("operation is not a Dictionary", report_warnings)
		return false
	var operation: Dictionary = raw_operation
	for raw_key in operation:
		if not _KNOWN_OPERATION_KEYS.has(str(raw_key)):
			_warn(
				"unknown operation field '%s'" % str(raw_key),
				report_warnings,
			)
			return false
	var action := str(operation.get("action", "")).to_lower()
	if action not in VALID_ACTIONS:
		_warn("unknown action '%s'" % action, report_warnings)
		return false
	var properties = operation.get("properties", {})
	if not properties is Dictionary:
		_warn("%s operation has invalid properties" % action, report_warnings)
		return false
	if action in ["hide", "remove", "clear"] and not properties.is_empty():
		_warn(
			"%s operation does not accept layer properties" % action,
			report_warnings,
		)
		return false
	if action == "clear" and str(operation.get("id", "")).strip_edges() != "":
		_warn("clear operation must not have a layer id", report_warnings)
		return false
	if action != "clear" and str(operation.get("id", "")).strip_edges() == "":
		_warn("%s operation is missing a layer id" % action, report_warnings)
		return false
	for raw_key in properties:
		if not _KNOWN_PROPERTY_KEYS.has(str(raw_key)):
			_warn(
				"unknown layer property '%s'" % str(raw_key),
				report_warnings,
			)
			return false
	if not _validate_property_values(properties, report_warnings):
		return false
	var raw_transition = operation.get("transition", "cut")
	if not raw_transition is String and not raw_transition is StringName:
		_warn("operation transition must be a String", report_warnings)
		return false
	var transition := str(raw_transition).strip_edges().to_lower()
	if transition not in VALID_TRANSITIONS:
		_warn("unknown transition '%s'" % str(raw_transition), report_warnings)
		return false
	var raw_duration = operation.get("duration", 0.0)
	if (
		not (raw_duration is int or raw_duration is float)
		or not is_finite(float(raw_duration))
		or float(raw_duration) < 0.0
	):
		_warn("operation duration must be a finite non-negative number", report_warnings)
		return false
	return true


## Validate a persisted layer snapshot without normalizing or partially
## applying it. Save-load preflight uses this before replacing a live scene.
static func validate_snapshot_state(
	raw_state: Variant,
	report_warnings: bool = true,
) -> bool:
	if not raw_state is Dictionary:
		_warn("snapshot state is not a Dictionary", report_warnings)
		return false
	var state: Dictionary = raw_state
	for raw_key in state:
		if not _KNOWN_PROPERTY_KEYS.has(str(raw_key)):
			_warn(
				"unknown layer property '%s'" % str(raw_key),
				report_warnings,
			)
			return false
	return _validate_property_values(state, report_warnings)


## Apply authored operations to a complete layer dictionary and return a new
## dictionary. The input is never mutated.
static func reduce(
	current: Dictionary,
	operations: Array,
	report_warnings: bool = true,
) -> Dictionary:
	var result: Dictionary = {}
	for raw_id in current:
		var layer_id := str(raw_id).strip_edges()
		if layer_id == "":
			_warn("current state contains an empty layer id", report_warnings)
			continue
		var raw_state = current[raw_id]
		if not raw_state is Dictionary:
			_warn(
				"layer '%s' state is not a Dictionary" % str(raw_id),
				report_warnings,
			)
			continue
		result[layer_id] = normalize_full(raw_state, report_warnings)

	for raw_operation in operations:
		if not validate_operation(raw_operation, report_warnings):
			continue
		var operation: Dictionary = raw_operation
		var action := str(operation.get("action", "")).to_lower()
		var properties: Dictionary = operation.get("properties", {})
		if action == "clear":
			result.clear()
			continue

		var layer_id := str(operation.get("id", "")).strip_edges()

		match action:
			"show":
				var base: Dictionary = result.get(layer_id, default_state())
				var shown := apply_patch(base, properties, report_warnings)
				shown["visible"] = true
				result[layer_id] = shown
			"update":
				if not result.has(layer_id):
					_warn(
						"cannot update unknown layer '%s'; use show first"
						% layer_id,
						report_warnings,
					)
					continue
				result[layer_id] = apply_patch(
					result[layer_id],
					properties,
					report_warnings,
				)
			"hide":
				if not result.has(layer_id):
					_warn(
						"cannot hide unknown layer '%s'" % layer_id,
						report_warnings,
					)
					continue
				var hidden: Dictionary = result[layer_id].duplicate(true)
				hidden["visible"] = false
				result[layer_id] = hidden
			"remove":
				if not result.has(layer_id):
					_warn(
						"cannot remove unknown layer '%s'" % layer_id,
						report_warnings,
					)
					continue
				result.erase(layer_id)

	return result

static func _apply_patch_to_normalized(
	base: Dictionary,
	patch: Dictionary,
	report_warnings: bool,
) -> Dictionary:
	var result := base.duplicate(true)
	for key in patch:
		if not _KNOWN_PROPERTY_KEYS.has(str(key)):
			_warn("unknown layer property '%s'" % str(key), report_warnings)
			return result
	if not _validate_property_values(patch, report_warnings):
		return result

	if patch.has("kind"):
		result["kind"] = str(patch["kind"])
	for key in ["asset", "body", "face"]:
		if patch.has(key):
			var asset_id := str(patch[key])
			result[key] = "" if asset_id.to_lower() == "none" else asset_id

	result["position"] = _patched_pair(
		result["position"], patch, "position", "x", "y"
	)
	result["origin"] = _patched_pair(
		result["origin"], patch, "origin", "origin_x", "origin_y"
	)
	result["scale"] = _patched_pair(
		result["scale"], patch, "scale", "scale_x", "scale_y"
	)
	result["zoom"] = _patched_pair(
		result["zoom"], patch, "zoom", "zoom_x", "zoom_y"
	)
	result["asset_offset"] = _patched_pair(
		result["asset_offset"], patch, "asset_offset", "asset_x", "asset_y"
	)
	result["body_offset"] = _patched_pair(
		result["body_offset"], patch, "body_offset", "body_x", "body_y"
	)
	result["face_offset"] = _patched_pair(
		result["face_offset"], patch, "face_offset", "face_x", "face_y"
	)

	for vector_key in ["scale", "zoom"]:
		var pair: Array = result[vector_key]
		for axis in range(2):
			if float(pair[axis]) <= 0.0:
				_warn(
					"%s components must be positive; keeping 1.0"
					% vector_key,
					report_warnings,
				)
				pair[axis] = 1.0
		result[vector_key] = pair

	if patch.has("depth_scale"):
		var depth_scale := _as_float(
			patch["depth_scale"],
			result["depth_scale"],
		)
		if depth_scale <= 0.0:
			_warn("depth_scale must be positive", report_warnings)
		else:
			result["depth_scale"] = depth_scale

	if patch.has("rotation"):
		result["rotation"] = _as_float(
			patch["rotation"],
			result["rotation"],
		)

	if patch.has("z_index") or patch.has("z"):
		var raw_z = patch.get("z_index", patch.get("z", 0))
		var z_index := int(_as_float(raw_z, result["z_index"]))
		if z_index < MIN_Z_INDEX or z_index > MAX_Z_INDEX:
			_warn(
				"z_index %d is outside Godot's supported range" % z_index,
				report_warnings,
			)
		result["z_index"] = clampi(z_index, MIN_Z_INDEX, MAX_Z_INDEX)

	if patch.has("visible"):
		if _is_valid_bool(patch["visible"]):
			result["visible"] = _as_bool(patch["visible"])
	if patch.has("opacity"):
		var opacity := _as_float(patch["opacity"], result["opacity"])
		if opacity < 0.0 or opacity > 1.0:
			_warn("opacity is clamped to 0..1", report_warnings)
		result["opacity"] = clampf(opacity, 0.0, 1.0)
	if patch.has("fit"):
		var fit := str(patch["fit"]).to_lower()
		if fit not in VALID_FIT_MODES:
			_warn("unknown fit mode '%s'" % fit, report_warnings)
		else:
			result["fit"] = fit

	if patch.has("redraw"):
		result["redraw"] = _normalize_redraw_effects(
			patch["redraw"],
			report_warnings,
		)
	if patch.has("flip_x"):
		result["flip_x"] = _as_bool(patch["flip_x"])
	if patch.has("flip_y"):
		result["flip_y"] = _as_bool(patch["flip_y"])

	if patch.has("metadata"):
		if patch["metadata"] is Dictionary:
			result["metadata"] = _json_safe_value(
				patch["metadata"],
				report_warnings,
			)
		else:
			_warn("metadata must be a Dictionary", report_warnings)

	return result


static func _validate_property_values(
	patch: Dictionary,
	report_warnings: bool,
) -> bool:
	var valid := true
	for key in _PAIR_PROPERTY_KEYS:
		if patch.has(key) and not _is_valid_pair(patch[key]):
			_warn("%s must be a finite number or numeric pair" % key, report_warnings)
			valid = false
	for key in _NUMBER_PROPERTY_KEYS:
		if patch.has(key) and not _is_valid_number(patch[key]):
			_warn("%s must be a finite number" % key, report_warnings)
			valid = false
	for key in _BOOL_PROPERTY_KEYS:
		if patch.has(key) and not _is_valid_bool(patch[key]):
			_warn("%s must be a boolean" % key, report_warnings)
			valid = false
	for key in ["kind", "asset", "body", "face"]:
		if patch.has(key) and not patch[key] is String:
			_warn("%s must be a String" % key, report_warnings)
			valid = false
	for key in ["asset", "body", "face"]:
		if patch.has(key) and patch[key] is String:
			var asset_id := String(patch[key]).strip_edges().to_lower()
			if asset_id in ["null", "off"]:
				_warn(
					"%s clear value '%s' is invalid; use 'none'"
					% [key, String(patch[key])],
					report_warnings,
				)
				valid = false
	for key in ["scale", "zoom"]:
		if patch.has(key):
			var pair := [0.0, 0.0]
			if _is_valid_number(patch[key]):
				var scalar := float(patch[key])
				pair = [scalar, scalar]
			else:
				pair = _as_pair(patch[key], pair)
			if float(pair[0]) <= 0.0 or float(pair[1]) <= 0.0:
				_warn("%s components must be positive" % key, report_warnings)
				valid = false
	for key in ["scale_x", "scale_y", "zoom_x", "zoom_y", "depth_scale"]:
		if patch.has(key) and (
			not _is_valid_number(patch[key]) or float(patch[key]) <= 0.0
		):
			_warn("%s must be a positive finite number" % key, report_warnings)
			valid = false
	if patch.has("opacity") and (
		not _is_valid_number(patch["opacity"])
		or float(patch["opacity"]) < 0.0
		or float(patch["opacity"]) > 1.0
	):
		_warn("opacity must be between 0 and 1", report_warnings)
		valid = false
	if patch.has("z") and patch.has("z_index"):
		_warn("use either z or z_index, not both", report_warnings)
		valid = false
	for key in ["z", "z_index"]:
		if not patch.has(key):
			continue
		var raw_z = patch[key]
		if (
			not _is_integer_number(raw_z)
			or int(float(raw_z)) < MIN_Z_INDEX
			or int(float(raw_z)) > MAX_Z_INDEX
		):
			_warn(
				"%s must be an integer in Godot's supported z-index range" % key,
				report_warnings,
			)
			valid = false
	if patch.has("fit") and str(patch["fit"]).to_lower() not in VALID_FIT_MODES:
		_warn("unknown fit mode '%s'" % str(patch["fit"]), report_warnings)
		valid = false
	if patch.has("metadata") and not patch["metadata"] is Dictionary:
		_warn("metadata must be a Dictionary", report_warnings)
		valid = false
	if patch.has("redraw") and not _validate_redraw_effects(
		patch["redraw"],
		report_warnings,
	):
		valid = false
	return valid


static func _validate_redraw_effects(
	raw_effects: Variant,
	report_warnings: bool,
) -> bool:
	if not raw_effects is Array:
		_warn("redraw must be an Array", report_warnings)
		return false
	var effects: Array = raw_effects
	if effects.size() > MAX_REDRAW_EFFECTS:
		_warn(
			"redraw accepts at most %d effects" % MAX_REDRAW_EFFECTS,
			report_warnings,
		)
		return false
	var clip_count := 0
	var blur_count := 0
	for index in range(effects.size()):
		var raw_effect = effects[index]
		if not raw_effect is Dictionary:
			_warn("redraw effect %d must be a Dictionary" % index, report_warnings)
			return false
		var effect: Dictionary = raw_effect
		if not effect.get("type", null) is String:
			_warn("redraw effect %d type must be a String" % index, report_warnings)
			return false
		var effect_type := String(effect["type"]).strip_edges().to_lower()
		if not _REDRAW_EFFECT_KEYS.has(effect_type):
			_warn(
				"unknown redraw effect type '%s'" % String(effect["type"]),
				report_warnings,
			)
			return false
		if effect_type == "clip":
			clip_count += 1
			if clip_count > 1:
				_warn(
					"redraw accepts at most one clip effect",
					report_warnings,
				)
				return false
		elif effect_type == "blur":
			blur_count += 1
			if blur_count > MAX_BLUR_PASSES:
				_warn(
					"redraw accepts at most %d blur effects" % MAX_BLUR_PASSES,
					report_warnings,
				)
				return false
		var known_keys: Dictionary = _REDRAW_EFFECT_KEYS[effect_type]
		for raw_key in effect:
			if not raw_key is String or not known_keys.has(String(raw_key)):
				_warn(
					"unknown %s redraw field '%s'"
					% [effect_type, str(raw_key)],
					report_warnings,
				)
				return false
		for required_key in known_keys:
			if not effect.has(required_key):
				_warn(
					"%s redraw effect is missing '%s'"
					% [effect_type, required_key],
					report_warnings,
				)
				return false

		match effect_type:
			"color_overlay", "tint":
				if _normalize_hex_color(effect["color"]) == "":
					_warn(
						"%s redraw color must be #RRGGBB or #RRGGBBAA"
						% effect_type,
						report_warnings,
					)
					return false
				if effect_type == "color_overlay" and (
					not effect["blend"] is String
					or String(effect["blend"]).to_lower()
						not in VALID_COLOR_OVERLAY_BLEND_MODES
				):
					_warn("color_overlay blend must be 'normal' or 'soft_light'", report_warnings)
					return false
			"brightness_contrast":
				if (
					not _is_integer_number(effect["brightness"])
					or int(effect["brightness"]) < -255
					or int(effect["brightness"]) > 255
				):
					_warn("brightness_contrast effect brightness must be an integer from -255 to 255", report_warnings)
					return false
				if (
					not _is_integer_number(effect["contrast"])
					or int(effect["contrast"]) < -100
					or int(effect["contrast"]) > 100
				):
					_warn("brightness_contrast effect contrast must be an integer from -100 to 100", report_warnings)
					return false
			"grayscale":
				if (
					not _is_json_number(effect["amount"])
					or float(effect["amount"]) < 0.0
					or float(effect["amount"]) > 1.0
				):
					_warn("grayscale amount must be between 0 and 1", report_warnings)
					return false
			"blur":
				if not _is_integer_pair_in_range(
					effect["radius"],
					0,
					MAX_BLUR_RADIUS,
				):
					_warn(
						"blur radius must be two integers from 0 to %d"
						% MAX_BLUR_RADIUS,
						report_warnings,
					)
					return false
			"clip":
				if (
					not effect["asset"] is String
					or String(effect["asset"]).strip_edges() == ""
				):
					_warn("clip asset must be a non-empty String", report_warnings)
					return false
				if not _is_exact_json_pair(effect["offset"]):
					_warn("clip offset must be a two-number Array", report_warnings)
					return false
				if (
					not effect["fit"] is String
					or String(effect["fit"]).to_lower() not in VALID_FIT_MODES
				):
					_warn("clip fit must be a supported fit mode", report_warnings)
					return false
	return true


static func _normalize_redraw_effects(
	raw_effects: Variant,
	report_warnings: bool,
) -> Array:
	if not _validate_redraw_effects(raw_effects, report_warnings):
		return []
	var normalized: Array = []
	var effects: Array = raw_effects
	for raw_effect in effects:
		var effect: Dictionary = raw_effect
		var effect_type := String(effect["type"]).strip_edges().to_lower()
		var canonical := {"type": effect_type}
		match effect_type:
			"color_overlay", "tint":
				canonical["color"] = _normalize_hex_color(effect["color"])
				if effect_type == "color_overlay":
					canonical["blend"] = String(effect["blend"]).to_lower()
			"brightness_contrast":
				canonical["brightness"] = int(effect["brightness"])
				canonical["contrast"] = int(effect["contrast"])
			"grayscale":
				canonical["amount"] = float(effect["amount"])
			"blur":
				var radius: Array = effect["radius"]
				canonical["radius"] = [int(radius[0]), int(radius[1])]
			"clip":
				var offset: Array = effect["offset"]
				canonical["asset"] = String(effect["asset"]).strip_edges()
				canonical["offset"] = [float(offset[0]), float(offset[1])]
				canonical["fit"] = String(effect["fit"]).to_lower()
		normalized.append(canonical)
	return normalized


static func _normalize_hex_color(value: Variant) -> String:
	if not value is String:
		return ""
	var encoded := String(value).strip_edges().to_lower()
	if not encoded.begins_with("#") or encoded.length() not in [7, 9]:
		return ""
	for index in range(1, encoded.length()):
		if encoded.substr(index, 1) not in "0123456789abcdef":
			return ""
	if encoded.length() == 7:
		encoded += "ff"
	return encoded


static func _is_json_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


static func _is_integer_number(value: Variant) -> bool:
	return _is_json_number(value) and float(value) == floorf(float(value))


static func _is_exact_json_pair(value: Variant) -> bool:
	return (
		value is Array
		and value.size() == 2
		and _is_json_number(value[0])
		and _is_json_number(value[1])
	)


static func _is_integer_pair_in_range(
	value: Variant,
	minimum: int,
	maximum: int,
) -> bool:
	if not value is Array or value.size() != 2:
		return false
	for component in value:
		if (
			not _is_integer_number(component)
			or int(component) < minimum
			or int(component) > maximum
		):
			return false
	return true


static func _is_valid_pair(value: Variant) -> bool:
	if _is_valid_number(value):
		return true
	if value is Vector2 or value is Vector2i:
		return is_finite(float(value.x)) and is_finite(float(value.y))
	if value is Array:
		return (
			value.size() >= 2
			and _is_valid_number(value[0])
			and _is_valid_number(value[1])
		)
	if value is Dictionary:
		if not value.has("x") and not value.has("y"):
			return false
		return (
			(not value.has("x") or _is_valid_number(value["x"]))
			and (not value.has("y") or _is_valid_number(value["y"]))
		)
	return false


static func _is_valid_number(value: Variant) -> bool:
	if value is int or value is float:
		return is_finite(float(value))
	var encoded := str(value)
	return encoded.is_valid_float() and is_finite(float(encoded))


static func _is_valid_bool(value: Variant) -> bool:
	return value is bool


static func _patched_pair(
	current,
	patch: Dictionary,
	pair_key: String,
	x_key: String,
	y_key: String,
) -> Array:
	var result := _as_pair(current, [0.0, 0.0])
	if patch.has(pair_key):
		var value = patch[pair_key]
		if value is int or value is float or (
			value is String and str(value).is_valid_float()
		):
			var scalar := _as_float(value, result[0])
			result = [scalar, scalar]
		else:
			result = _as_pair(value, result)
	if patch.has(x_key):
		result[0] = _as_float(patch[x_key], result[0])
	if patch.has(y_key):
		result[1] = _as_float(patch[y_key], result[1])
	return result


static func _as_pair(value, fallback: Array) -> Array:
	if value is Vector2:
		return [float(value.x), float(value.y)]
	if value is Array and value.size() >= 2:
		return [
			_as_float(value[0], fallback[0]),
			_as_float(value[1], fallback[1]),
		]
	if value is Dictionary:
		return [
			_as_float(value.get("x", fallback[0]), fallback[0]),
			_as_float(value.get("y", fallback[1]), fallback[1]),
		]
	return fallback.duplicate()


static func _as_float(value, fallback: float) -> float:
	var parsed := fallback
	if value is int or value is float:
		parsed = float(value)
	else:
		var encoded := str(value)
		if encoded.is_valid_float():
			parsed = float(encoded)
	return parsed if is_finite(parsed) else fallback


static func _as_bool(value) -> bool:
	if value is bool:
		return value
	return false


static func _json_safe_value(value: Variant, report_warnings: bool) -> Variant:
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING:
			return value
		TYPE_FLOAT:
			if is_finite(float(value)):
				return value
			_warn("non-finite metadata number was converted to null", report_warnings)
			return null
		TYPE_STRING_NAME:
			return str(value)
		TYPE_VECTOR2, TYPE_VECTOR2I:
			return [
				_json_safe_finite_component(float(value.x), report_warnings),
				_json_safe_finite_component(float(value.y), report_warnings),
			]
		TYPE_COLOR:
			var color_value: Color = value
			if not (
				is_finite(color_value.r)
				and is_finite(color_value.g)
				and is_finite(color_value.b)
				and is_finite(color_value.a)
			):
				_warn("non-finite metadata Color was converted to white", report_warnings)
				return "ffffffff"
			return color_value.to_html(true)
		TYPE_ARRAY:
			var array_result: Array = []
			for item in value:
				array_result.append(_json_safe_value(item, report_warnings))
			return array_result
		TYPE_DICTIONARY:
			var dictionary_result: Dictionary = {}
			for key in value:
				dictionary_result[str(key)] = _json_safe_value(
					value[key],
					report_warnings,
				)
			return dictionary_result
		_:
			_warn(
				"metadata value of type %s was converted to String"
				% type_string(typeof(value)),
				report_warnings,
			)
			return str(value)


static func _json_safe_finite_component(
	value: float,
	report_warnings: bool,
) -> float:
	if is_finite(value):
		return value
	_warn("non-finite metadata vector component was converted to 0", report_warnings)
	return 0.0


static func _warn(message: String, enabled: bool) -> void:
	if enabled:
		push_warning("StageLayerState: %s" % message)
