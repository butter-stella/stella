## Canonical JSON-safe state and operation validation for the one movie surface.
class_name MovieChannelState extends RefCounted

const VALID_ACTIONS := ["play", "stop"]
const EXACT_OPERATION_KEYS := ["action", "asset", "loop", "skippable"]
const EXACT_STATE_KEYS := [
	"asset", "length", "loop", "position", "skippable", "status",
]


static func empty_state() -> Dictionary:
	return {}


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


static func validate_operation(raw_operation: Variant, report: bool = true) -> bool:
	if not raw_operation is Dictionary:
		return _reject(report, "operation must be a Dictionary")
	var operation: Dictionary = raw_operation
	var keys := operation.keys()
	keys.sort()
	if keys != EXACT_OPERATION_KEYS:
		return _reject(report, "operation must use the canonical four-field schema")
	if (
		not operation.get("action", null) is String
		or not operation.get("asset", null) is String
		or not operation.get("loop", null) is bool
		or not operation.get("skippable", null) is bool
	):
		return _reject(report, "operation has invalid field types")
	var action := String(operation["action"])
	var asset := String(operation["asset"])
	if action not in VALID_ACTIONS:
		return _reject(report, "action must be play or stop")
	if action == "play":
		if not is_logical_id(asset):
			return _reject(report, "play requires a canonical logical asset id")
	else:
		if not asset.is_empty() or bool(operation["loop"]) or not bool(
			operation["skippable"]):
			return _reject(
				report,
				"stop requires empty asset, loop=false, and skippable=true",
			)
	return true


static func validate_snapshot_state(raw_state: Variant, report: bool = true) -> bool:
	if not raw_state is Dictionary:
		return _reject(report, "movie state must be a Dictionary")
	var state: Dictionary = raw_state
	if state.is_empty():
		return true
	var keys := state.keys()
	keys.sort()
	if keys != EXACT_STATE_KEYS:
		return _reject(report, "active movie state must use the canonical six-field schema")
	if (
		not state.get("asset", null) is String
		or not is_logical_id(String(state["asset"]))
		or not state.get("loop", null) is bool
		or not state.get("skippable", null) is bool
		or state.get("status", null) != "playing"
	):
		return _reject(report, "active movie state has invalid identity or lifecycle fields")
	for key: String in ["length", "position"]:
		var value: Variant = state.get(key, null)
		if not (value is int or value is float) or not is_finite(float(value)):
			return _reject(report, "%s must be finite" % key)
	var length := float(state["length"])
	var position := float(state["position"])
	if length <= 0.0 or position < 0.0:
		return _reject(report, "length must be positive and position non-negative")
	if position >= length:
		return _reject(
			report,
			"position must be strictly below length after loop normalization",
		)
	return true


static func state_for_play(
	asset: String,
	loop: bool,
	skippable: bool,
	length: float,
	position: float = 0.0,
) -> Dictionary:
	if not is_finite(length) or length <= 0.0:
		return {}
	var normalized := position
	if loop:
		normalized = fposmod(position, length)
	var result := {
		"asset": asset,
		"length": length,
		"loop": loop,
		"position": normalized,
		"skippable": skippable,
		"status": "playing",
	}
	return result if validate_snapshot_state(result, false) else {}


static func operation_matches_state(state: Dictionary, operation: Dictionary) -> bool:
	return (
		validate_snapshot_state(state, false)
		and not state.is_empty()
		and validate_operation(operation, false)
		and operation["action"] == "play"
		and state["asset"] == operation["asset"]
		and state["loop"] == operation["loop"]
		and state["skippable"] == operation["skippable"]
	)


static func _reject(report: bool, message: String) -> bool:
	if report:
		push_warning("MovieChannelState: %s" % message)
	return false
