## Tracks which dialogue lines have been read.
## Used by SkipController to implement "skip only read" behavior.
class_name ReadFlagManager extends RefCounted

var _flags: Dictionary = {}  # "scenario:scene:index" -> true


func mark_read(scenario_id: String, scene_id: String, command_index: int) -> void:
	_flags[_key(scenario_id, scene_id, command_index)] = true


func is_read(scenario_id: String, scene_id: String, command_index: int) -> bool:
	return _flags.has(_key(scenario_id, scene_id, command_index))


func get_provider_id() -> String:
	return "read_flags"


func capture_snapshot() -> Dictionary:
	return _flags.duplicate()


## Read history is global, cross-playthrough progress. Loading an older save
## adds the flags it knew about without erasing lines read since it was made.
## Durable cross-session storage still requires a separate global progress file.
func restore_snapshot(snapshot: Dictionary) -> void:
	for key in snapshot:
		_flags[key] = true


func _key(scenario_id: String, scene_id: String, command_index: int) -> String:
	return "%s:%s:%d" % [scenario_id, scene_id, command_index]
