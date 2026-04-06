## Controls skip mode — fast-forwards through dialogue.
## Can be configured to skip only previously read content.
class_name SkipController extends RefCounted

var is_active: bool = false
var skip_only_read: bool = true


func toggle() -> void:
	is_active = not is_active


func stop() -> void:
	is_active = false


func should_skip(scenario_id: String, scene_id: String, command_index: int, read_flags: ReadFlagManager) -> bool:
	if not is_active:
		return false
	if not skip_only_read:
		return true
	return read_flags.is_read(scenario_id, scene_id, command_index)
