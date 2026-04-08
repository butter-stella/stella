## Three-scope variable storage.
## Priority: Temp → Scenario → Global.
class_name VariableStore extends RefCounted

enum Scope { GLOBAL, SCENARIO, TEMP }

var _stores: Dictionary = {
	Scope.GLOBAL: {},
	Scope.SCENARIO: {},
	Scope.TEMP: {},
}


func set_var(name: String, value: Variant, scope: int = Scope.SCENARIO, op: String = "=") -> void:
	if op == "+=":
		var current = get_var(name, 0)
		_stores[scope][name] = current + value
	elif op == "-=":
		var current = get_var(name, 0)
		_stores[scope][name] = current - value
	else:
		_stores[scope][name] = value


func get_var(name: String, default: Variant = null) -> Variant:
	for scope in [Scope.TEMP, Scope.SCENARIO, Scope.GLOBAL]:
		if _stores[scope].has(name):
			return _stores[scope][name]
	return default


func get_provider_id() -> String:
	return "variable_store"


func clear_temp() -> void:
	_stores[Scope.TEMP].clear()


## Full snapshot — used by SaveManager for disk persistence (save/load slots).
## Includes BOTH scenario and global scopes; both should round-trip through
## save files.
func capture_snapshot() -> Dictionary:
	return {
		"scenario": _stores[Scope.SCENARIO].duplicate(),
		"global": _stores[Scope.GLOBAL].duplicate(),
	}


func restore_snapshot(snapshot: Dictionary) -> void:
	_stores[Scope.SCENARIO] = snapshot.get("scenario", {}).duplicate()
	_stores[Scope.GLOBAL] = snapshot.get("global", {}).duplicate()


## Scenario-scope-only snapshot — used by rollback paths (backlog jump,
## flowchart jump in #97). Scope.GLOBAL is monotonic (cross-playthrough
## persistent state like CG unlock flags) and MUST NOT be rolled back when
## navigating to a prior point in history. See issue #98.
func capture_scenario_scope() -> Dictionary:
	return _stores[Scope.SCENARIO].duplicate()


## Restore only the scenario scope. Leaves Scope.GLOBAL untouched.
##
## Tolerates two input shapes for backwards compatibility:
##   1. Plain scenario dict: {"hp": 100, ...}
##   2. Legacy full snapshot: {"scenario": {...}, "global": {...}}
##      (only the "scenario" sub-dict is applied; "global" is ignored.)
func restore_scenario_scope(snapshot: Dictionary) -> void:
	var scenario_data: Dictionary
	if snapshot.has("scenario") and snapshot["scenario"] is Dictionary:
		scenario_data = snapshot["scenario"]
	else:
		scenario_data = snapshot
	_stores[Scope.SCENARIO] = scenario_data.duplicate()
