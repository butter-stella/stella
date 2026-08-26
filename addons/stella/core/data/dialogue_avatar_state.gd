## Canonical, JSON-safe stable state for the single addressable dialogue avatar.
##
## This state is independent from line-local `[expr:]` markers and named Stage
## layers. Position/origin are signed local-canvas pixels, scale is unitless,
## and rotation is radians. Vector values use number pairs so save snapshots
## remain JSON-safe; source-format numeric encodings are never stored here.
class_name DialogueAvatarState extends RefCounted

const MIN_Z_INDEX := -4096
const MAX_Z_INDEX := 4096
const VALID_ACTIONS := ["set", "show", "hide", "remove"]
const VALID_TRANSITIONS := ["cut", "fade"]
const EXACT_OPERATION_KEYS := {
	"action": true,
	"properties": true,
	"transition": true,
	"duration": true,
}
const EXACT_STATE_KEYS := {
	"present": true,
	"visible": true,
	"source_kind": true,
	"asset": true,
	"character": true,
	"expression": true,
	"position": true,
	"origin": true,
	"scale": true,
	"rotation": true,
	"z_index": true,
	"opacity": true,
}
const PROPERTY_KEYS := {
	"asset": true,
	"character": true,
	"expression": true,
	"visible": true,
	"position": true,
	"origin": true,
	"scale": true,
	"rotation": true,
	"z_index": true,
	"opacity": true,
}


static func default_state() -> Dictionary:
	return {
		"present": false,
		"visible": false,
		"source_kind": "",
		"asset": "",
		"character": "",
		"expression": "",
		"position": [0.0, 0.0],
		"origin": [0.0, 0.0],
		"scale": [1.0, 1.0],
		"rotation": 0.0,
		"z_index": 0,
		"opacity": 1.0,
	}


static func validate_snapshot_state(
	raw_state: Variant,
	report_warnings: bool = true,
) -> bool:
	if not raw_state is Dictionary:
		_warn("snapshot is not a Dictionary", report_warnings)
		return false
	var state: Dictionary = raw_state
	for raw_key: Variant in state.keys():
		if not EXACT_STATE_KEYS.has(String(raw_key)):
			_warn("unknown state key '%s'" % String(raw_key), report_warnings)
			return false
	for key: String in EXACT_STATE_KEYS:
		if not state.has(key):
			_warn("snapshot is missing '%s'" % key, report_warnings)
			return false
	if not state["present"] is bool or not state["visible"] is bool:
		_warn("present and visible must be bools", report_warnings)
		return false
	for key: String in ["source_kind", "asset", "character", "expression"]:
		if not state[key] is String:
			_warn("%s must be a String" % key, report_warnings)
			return false
	if not _valid_pair(state["position"]) or not _valid_pair(state["origin"]):
		_warn("position and origin must be finite number pairs", report_warnings)
		return false
	if not _valid_positive_pair(state["scale"]):
		_warn("scale must be a positive finite number pair", report_warnings)
		return false
	if not _finite_number(state["rotation"]):
		_warn("rotation must be finite", report_warnings)
		return false
	if not _valid_z_index(state["z_index"]):
		_warn("z_index is outside the supported integer range", report_warnings)
		return false
	if not _finite_number(state["opacity"]):
		_warn("opacity must be finite", report_warnings)
		return false
	var opacity := float(state["opacity"])
	if opacity < 0.0 or opacity > 1.0:
		_warn("opacity must be between 0 and 1", report_warnings)
		return false
	var present := bool(state["present"])
	var source_kind := String(state["source_kind"])
	var asset := String(state["asset"])
	var character := String(state["character"])
	var expression := String(state["expression"])
	if not present:
		if (
			bool(state["visible"])
			or not source_kind.is_empty()
			or not asset.is_empty()
			or not character.is_empty()
			or not expression.is_empty()
		):
			_warn("an absent avatar cannot retain source or visibility", report_warnings)
			return false
		return true
	if source_kind == "asset":
		if not _canonical_id(asset) or not character.is_empty() or not expression.is_empty():
			_warn("asset avatar source is not canonical", report_warnings)
			return false
	elif source_kind == "character":
		if not asset.is_empty() or not _canonical_id(character) or not _canonical_id(expression):
			_warn("character avatar source is not canonical", report_warnings)
			return false
	else:
		_warn("present avatar source_kind must be asset or character", report_warnings)
		return false
	return true


static func validate_operation(
	raw_operation: Variant,
	report_warnings: bool = true,
) -> bool:
	if not raw_operation is Dictionary:
		_warn("operation is not a Dictionary", report_warnings)
		return false
	var operation: Dictionary = raw_operation
	for raw_key: Variant in operation.keys():
		if not EXACT_OPERATION_KEYS.has(String(raw_key)):
			_warn("unknown operation field '%s'" % String(raw_key), report_warnings)
			return false
	for key: String in EXACT_OPERATION_KEYS:
		if not operation.has(key):
			_warn("operation is missing '%s'" % key, report_warnings)
			return false
	if not operation["action"] is String:
		_warn("action must be a String", report_warnings)
		return false
	var action := String(operation["action"])
	if action != action.strip_edges().to_lower() or action not in VALID_ACTIONS:
		_warn("action is not canonical", report_warnings)
		return false
	if not operation["properties"] is Dictionary:
		_warn("properties must be a Dictionary", report_warnings)
		return false
	var properties: Dictionary = operation["properties"]
	if action in ["hide", "remove"] and not properties.is_empty():
		_warn("%s does not accept properties" % action, report_warnings)
		return false
	if action == "set" and properties.is_empty():
		_warn("set requires at least one property", report_warnings)
		return false
	if not _validate_properties(properties, report_warnings):
		return false
	if action == "show" and properties.has("visible"):
		_warn("show owns visibility and does not accept visible", report_warnings)
		return false
	if not operation["transition"] is String:
		_warn("transition must be a String", report_warnings)
		return false
	var transition := String(operation["transition"])
	if transition != transition.strip_edges().to_lower() or transition not in VALID_TRANSITIONS:
		_warn("transition is not canonical", report_warnings)
		return false
	if not _finite_number(operation["duration"]):
		_warn("duration must be finite", report_warnings)
		return false
	var duration := float(operation["duration"])
	if duration < 0.0 or (transition == "cut" and duration != 0.0):
		_warn("cut requires duration=0 and fade duration must be non-negative", report_warnings)
		return false
	return true


static func operation_is_supported(current: Dictionary, operation: Dictionary) -> bool:
	if not validate_snapshot_state(current, false) or not validate_operation(operation, false):
		return false
	var action := String(operation["action"])
	var properties: Dictionary = operation["properties"]
	var present := bool(current["present"])
	if action in ["hide", "remove"]:
		return present
	if action in ["set", "show"]:
		var has_asset := properties.has("asset")
		var has_character := properties.has("character")
		var has_expression := properties.has("expression")
		if has_asset:
			return true
		if has_character:
			return has_expression or (
				present and String(current["source_kind"]) == "character")
		if has_expression:
			return present and String(current["source_kind"]) == "character"
		return present
	return false


static func reduce(
	current: Dictionary,
	operations: Array,
	report_warnings: bool = true,
) -> Dictionary:
	var next := (
		current.duplicate(true)
		if validate_snapshot_state(current, false)
		else default_state()
	)
	for operation_value: Variant in operations:
		if (
			not validate_operation(operation_value, report_warnings)
			or not operation_is_supported(next, operation_value)
		):
			_warn("operation is not valid for the current avatar state", report_warnings)
			return next
		var operation: Dictionary = operation_value
		var action := String(operation["action"])
		if action == "remove":
			next = default_state()
			continue
		var properties: Dictionary = operation["properties"]
		if properties.has("asset"):
			next["source_kind"] = "asset"
			next["asset"] = String(properties["asset"])
			next["character"] = ""
			next["expression"] = ""
			next["present"] = true
		elif properties.has("character"):
			next["source_kind"] = "character"
			next["asset"] = ""
			next["character"] = String(properties["character"])
			if properties.has("expression"):
				next["expression"] = String(properties["expression"])
			elif String(next["expression"]).is_empty():
				next["expression"] = "default"
			next["present"] = true
		elif properties.has("expression"):
			next["expression"] = String(properties["expression"])
		for pair_key: String in ["position", "origin", "scale"]:
			if properties.has(pair_key):
				next[pair_key] = _pair(properties[pair_key])
		for number_key: String in ["rotation", "opacity"]:
			if properties.has(number_key):
				next[number_key] = float(properties[number_key])
		if properties.has("z_index"):
			next["z_index"] = int(properties["z_index"])
		if action == "show":
			next["visible"] = true
		elif action == "hide":
			next["visible"] = false
		elif properties.has("visible"):
			next["visible"] = bool(properties["visible"])
		elif not bool(current.get("present", false)):
			next["visible"] = true
	return next


static func _validate_properties(properties: Dictionary, report_warnings: bool) -> bool:
	for raw_key: Variant in properties.keys():
		if not PROPERTY_KEYS.has(String(raw_key)):
			_warn("unknown avatar property '%s'" % String(raw_key), report_warnings)
			return false
	if properties.has("asset") and (
		properties.has("character") or properties.has("expression")
	):
		_warn("asset and character/expression sources are mutually exclusive", report_warnings)
		return false
	for key: String in ["asset", "character", "expression"]:
		if properties.has(key) and (
			not properties[key] is String or not _canonical_id(String(properties[key]))
		):
			_warn("%s must be a canonical non-empty logical id" % key, report_warnings)
			return false
	if properties.has("visible") and not properties["visible"] is bool:
		_warn("visible must be a bool", report_warnings)
		return false
	for key: String in ["position", "origin"]:
		if properties.has(key) and not _valid_pair(properties[key]):
			_warn("%s must be a finite number pair" % key, report_warnings)
			return false
	if properties.has("scale") and not _valid_positive_pair(properties["scale"]):
		_warn("scale must be a positive finite number pair", report_warnings)
		return false
	for key: String in ["rotation", "opacity"]:
		if properties.has(key) and not _finite_number(properties[key]):
			_warn("%s must be finite" % key, report_warnings)
			return false
	if properties.has("opacity") and (
		float(properties["opacity"]) < 0.0 or float(properties["opacity"]) > 1.0
	):
		_warn("opacity must be between 0 and 1", report_warnings)
		return false
	if properties.has("z_index") and not _valid_z_index(properties["z_index"]):
		_warn("z_index must be an integer in the supported range", report_warnings)
		return false
	return true


static func _canonical_id(value: String) -> bool:
	return not value.is_empty() and value == value.strip_edges()


static func _finite_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


static func _valid_pair(value: Variant) -> bool:
	return (
		value is Array
		and value.size() == 2
		and _finite_number(value[0])
		and _finite_number(value[1])
	)


static func _valid_positive_pair(value: Variant) -> bool:
	return _valid_pair(value) and float(value[0]) > 0.0 and float(value[1]) > 0.0


static func _valid_z_index(value: Variant) -> bool:
	if not value is int and not value is float:
		return false
	var numeric := float(value)
	return (
		is_finite(numeric)
		and numeric == floor(numeric)
		and numeric >= MIN_Z_INDEX
		and numeric <= MAX_Z_INDEX
	)


static func _pair(value: Variant) -> Array:
	return [float(value[0]), float(value[1])]


static func _warn(message: String, report_warnings: bool) -> void:
	if report_warnings:
		push_warning("DialogueAvatarState: %s" % message)
