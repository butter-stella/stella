## Instruction data container used by all command handlers.
## Each command has a type string and a params dictionary.
class_name CommandData extends RefCounted

var type: String = ""
var params: Dictionary = {}


func get_string(key: String, default: String = "") -> String:
	if not params.has(key):
		return default
	return str(params[key])


func get_float(key: String, default: float = 0.0) -> float:
	if not params.has(key):
		return default
	return float(params[key])


func get_int(key: String, default: int = 0) -> int:
	if not params.has(key):
		return default
	return int(params[key])


func get_bool(key: String, default: bool = false) -> bool:
	if not params.has(key):
		return default
	var val = params[key]
	if val is bool:
		return val
	if val is int or val is float:
		return val != 0
	return str(val).to_lower() == "true"


func has_param(key: String) -> bool:
	return params.has(key)
