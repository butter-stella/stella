## Canonical, JSON-safe reducer for authored dialogue visibility gates.
class_name DialogueVisibilityState extends RefCounted

const VALID_TARGETS := ["surface", "quick_menu"]
const VALID_ACTIONS := ["show", "hide"]
const VALID_TRANSITIONS := ["cut", "fade"]
const EXACT_STATE_KEYS := {
	"surface": true,
	"quick_menu": true,
}
const EXACT_OPERATION_KEYS := {
	"target": true,
	"action": true,
	"transition": true,
	"duration": true,
}


static func default_state() -> Dictionary:
	return {
		"surface": true,
		"quick_menu": true,
	}


static func validate_snapshot_state(
	raw_state: Variant,
	report_warnings: bool = true,
) -> bool:
	if not raw_state is Dictionary:
		_warn("dialogue visibility snapshot is not a Dictionary", report_warnings)
		return false
	var state: Dictionary = raw_state
	for key_value: Variant in state.keys():
		var key := String(key_value)
		if not EXACT_STATE_KEYS.has(key):
			_warn(
				"unknown dialogue visibility state key '%s'" % key,
				report_warnings,
			)
			return false
	for key: String in EXACT_STATE_KEYS.keys():
		if not state.has(key) or not state[key] is bool:
			_warn(
				"dialogue visibility state '%s' must be a bool" % key,
				report_warnings,
			)
			return false
	return true


static func validate_operation(
	raw_operation: Variant,
	report_warnings: bool = true,
) -> bool:
	if not raw_operation is Dictionary:
		_warn("dialogue visibility operation is not a Dictionary", report_warnings)
		return false
	var operation: Dictionary = raw_operation
	for key_value: Variant in operation.keys():
		var key := String(key_value)
		if not EXACT_OPERATION_KEYS.has(key):
			_warn(
				"unknown dialogue visibility field '%s'" % key,
				report_warnings,
			)
			return false
	if not operation.get("target", null) is String:
		_warn("dialogue visibility target must be a String", report_warnings)
		return false
	if not operation.get("action", null) is String:
		_warn("dialogue visibility action must be a String", report_warnings)
		return false
	if not operation.get("transition", null) is String:
		_warn("dialogue visibility transition must be a String", report_warnings)
		return false
	if not (
		operation.get("duration", null) is int
		or operation.get("duration", null) is float
	):
		_warn("dialogue visibility duration must be numeric", report_warnings)
		return false
	var target := String(operation["target"]).strip_edges()
	var action := String(operation["action"]).strip_edges()
	var transition := String(operation["transition"]).strip_edges()
	var duration := float(operation["duration"])
	if target not in VALID_TARGETS:
		_warn("unknown dialogue visibility target '%s'" % target, report_warnings)
		return false
	if action not in VALID_ACTIONS:
		_warn("unknown dialogue visibility action '%s'" % action, report_warnings)
		return false
	if transition not in VALID_TRANSITIONS:
		_warn(
			"unknown dialogue visibility transition '%s'" % transition,
			report_warnings,
		)
		return false
	if not is_finite(duration) or duration < 0.0:
		_warn(
			"dialogue visibility duration must be finite and non-negative",
			report_warnings,
		)
		return false
	if transition == "cut" and duration != 0.0:
		_warn(
			"dialogue visibility cut transition requires duration 0",
			report_warnings,
		)
		return false
	return true


static func reduce(
	current: Dictionary,
	operations: Array,
	report_warnings: bool = true,
) -> Dictionary:
	var base := (
		current.duplicate(true)
		if validate_snapshot_state(current, false)
		else default_state()
	)
	for operation_value: Variant in operations:
		if not validate_operation(operation_value, report_warnings):
			return base.duplicate(true)
	var next := base.duplicate(true)
	for operation_value: Variant in operations:
		var operation: Dictionary = operation_value
		next[String(operation["target"])] = String(operation["action"]) == "show"
	return next


static func _warn(message: String, report_warnings: bool) -> void:
	if report_warnings:
		push_warning("DialogueVisibilityState: %s" % message)
