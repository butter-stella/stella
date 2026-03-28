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


func clear_temp() -> void:
	_stores[Scope.TEMP].clear()


func capture_snapshot() -> Dictionary:
	return {
		"scenario": _stores[Scope.SCENARIO].duplicate(),
		"global": _stores[Scope.GLOBAL].duplicate(),
	}


func restore_snapshot(snapshot: Dictionary) -> void:
	_stores[Scope.SCENARIO] = snapshot["scenario"].duplicate()
	_stores[Scope.GLOBAL] = snapshot["global"].duplicate()
