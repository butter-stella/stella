## Canonical typed parameters for one named-stage transition kind.
##
## The DSL parser uses this boundary for built-in schemas. Presentation
## registries use the same boundary for programmatic operations before a
## provider may inspect resources or mutate a layer.
class_name StageTransitionSpec extends RefCounted

const DEFAULT_MOSAIC_CELL := 32
const MIN_MOSAIC_CELL := 2
const MAX_MOSAIC_CELL := 256
const MAX_KIND_LENGTH := 64
const MAX_PARAMETER_NAME_LENGTH := 64
const MAX_STRING_VALUE_LENGTH := 1024
const SIMPLE_KINDS := [
	"cut", "fade", "move",
	"slide_left", "slide_right", "slide_up", "slide_down",
]
const BUILTIN_KINDS := [
	"cut", "fade", "move",
	"slide_left", "slide_right", "slide_up", "slide_down",
	"rule", "mosaic",
]


static func canonicalize(kind_value: Variant, params_value: Variant) -> Dictionary:
	if not kind_value is String and not kind_value is StringName:
		return _failure("transition kind must be a String")
	var kind := String(kind_value).strip_edges()
	if kind == "none":
		kind = "cut"
	if not _valid_identifier(kind, MAX_KIND_LENGTH):
		return _failure(
			"transition kind must match [A-Za-z_][A-Za-z0-9_]* and be at most %d characters"
			% MAX_KIND_LENGTH
		)
	if kind != kind.to_lower():
		return _failure("transition kind must use lowercase ASCII characters")
	if not params_value is Dictionary:
		return _failure("transition_params must be a Dictionary")
	var typed := _canonical_typed_params(params_value)
	if not bool(typed.get("valid", false)):
		return typed
	var params: Dictionary = typed["params"]
	match kind:
		"cut", "fade", "move", "slide_left", "slide_right", "slide_up", "slide_down":
			if not params.is_empty():
				return _failure("%s transition does not accept parameters" % kind)
			return _success(kind, {})
		"rule":
			return _canonical_rule(params)
		"mosaic":
			return _canonical_mosaic(params)
		_:
			# Project providers receive the same finite primitive-only typed map.
			# Their exact closed schema is validated by the registered participant
			# before any Stage mutation or transition receipt claim.
			return _success(kind, params)


static func is_builtin(kind: String) -> bool:
	return kind in BUILTIN_KINDS


static func is_projection_effect(kind: String) -> bool:
	return kind in ["rule", "mosaic"] or kind not in SIMPLE_KINDS


static func is_logical_texture_id(value: String) -> bool:
	var normalized := value.strip_edges()
	if (
		normalized.is_empty()
		or normalized.length() > MAX_STRING_VALUE_LENGTH
		or normalized != value
		or normalized.begins_with("/")
		or normalized.contains("\\")
		or normalized.contains("://")
	):
		return false
	var resource_id := normalized
	var colon := normalized.find(":")
	if colon >= 0:
		var domain := normalized.substr(0, colon)
		if domain not in ["background", "character", "stage"]:
			return false
		resource_id = normalized.substr(colon + 1)
	if resource_id.is_empty() or resource_id.contains(":"):
		return false
	for segment: String in resource_id.split("/", true):
		if segment in ["", ".", ".."]:
			return false
	return true


static func _canonical_rule(params: Dictionary) -> Dictionary:
	for key: String in params:
		if key not in ["mask", "softness", "invert"]:
			return _failure("unknown rule transition parameter '%s'" % key)
	if not params.has("mask"):
		return _failure("rule transition requires 'mask'")
	if not params["mask"] is String:
		return _failure("rule transition mask must be a logical texture id String")
	var raw_mask := String(params["mask"])
	var mask := raw_mask.strip_edges()
	if not is_logical_texture_id(raw_mask):
		return _failure(
			"rule transition mask must be a bounded Stella logical texture id")
	var softness_value: Variant = params.get("softness", 0.0)
	if (
		not (softness_value is int or softness_value is float)
		or not is_finite(float(softness_value))
		or float(softness_value) < 0.0
		or float(softness_value) > 1.0
	):
		return _failure("rule transition softness must be a finite number from 0 to 1")
	var invert_value: Variant = params.get("invert", false)
	if not invert_value is bool:
		return _failure("rule transition invert must be a boolean")
	return _success("rule", {
		"mask": mask,
		"softness": float(softness_value),
		"invert": bool(invert_value),
	})


static func _canonical_mosaic(params: Dictionary) -> Dictionary:
	for key: String in params:
		if key != "cell":
			return _failure("unknown mosaic transition parameter '%s'" % key)
	var cell_value: Variant = params.get("cell", DEFAULT_MOSAIC_CELL)
	if (
		not cell_value is int
		or int(cell_value) < MIN_MOSAIC_CELL
		or int(cell_value) > MAX_MOSAIC_CELL
	):
		return _failure(
			"mosaic transition cell must be an integer from %d to %d"
			% [MIN_MOSAIC_CELL, MAX_MOSAIC_CELL]
		)
	return _success("mosaic", {"cell": int(cell_value)})


static func _canonical_typed_params(params: Dictionary) -> Dictionary:
	var result := {}
	var ordered_keys: Array[String] = []
	var values_by_key := {}
	for raw_key: Variant in params:
		if not raw_key is String and not raw_key is StringName:
			return _failure("transition parameter names must be Strings")
		var raw_key_string := String(raw_key)
		var key := raw_key_string.strip_edges()
		if key != raw_key_string:
			return _failure(
				"transition parameter name '%s' is not canonical" % raw_key_string)
		if not _valid_identifier(key, MAX_PARAMETER_NAME_LENGTH):
			return _failure(
				"transition parameter name '%s' must be a bounded identifier" % key)
		if values_by_key.has(key):
			return _failure("duplicate transition parameter '%s'" % key)
		ordered_keys.append(key)
		values_by_key[key] = params[raw_key]
	ordered_keys.sort()
	for key: String in ordered_keys:
		var value: Variant = values_by_key[key]
		if value is float and not is_finite(value):
			return _failure("transition parameter '%s' must be finite" % key)
		if value is String and String(value).length() > MAX_STRING_VALUE_LENGTH:
			return _failure("transition parameter '%s' String is too long" % key)
		if not (value is bool or value is int or value is float or value is String):
			return _failure(
				"transition parameter '%s' must be a bool, int, float, or String" % key)
		result[key] = value
	return {"valid": true, "params": result}


static func _valid_identifier(value: String, maximum_length: int) -> bool:
	if value.is_empty() or value.length() > maximum_length:
		return false
	var first := value.unicode_at(0)
	if not _is_ascii_letter(first) and first != 95:
		return false
	for index in range(1, value.length()):
		var code := value.unicode_at(index)
		if not _is_ascii_letter(code) and not (code >= 48 and code <= 57) and code != 95:
			return false
	return true


static func _is_ascii_letter(code: int) -> bool:
	return (code >= 65 and code <= 90) or (code >= 97 and code <= 122)


static func _success(kind: String, params: Dictionary) -> Dictionary:
	return {
		"valid": true,
		"kind": kind,
		"params": params.duplicate(true),
	}


static func _failure(error: String) -> Dictionary:
	return {"valid": false, "error": error}
