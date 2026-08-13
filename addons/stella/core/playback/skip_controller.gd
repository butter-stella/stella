## Controls skip mode — fast-forwards through dialogue.
## `skip_only_read` is the single source of truth in GameSettings; callers
## pass it into should_skip() so this class stays pure state + one decision
## function, with no risk of a shadow copy drifting from the user setting.
class_name SkipController extends RefCounted

signal active_changed(active: bool)

var is_active: bool = false:
	set(value):
		if is_active == value:
			return
		is_active = value
		active_changed.emit(is_active)


func toggle() -> void:
	is_active = not is_active


func stop() -> void:
	is_active = false


func should_skip(scenario_id: String, scene_id: String, command_index: int,
		read_flags: ReadFlagManager, skip_only_read: bool) -> bool:
	if not is_active:
		return false
	if not skip_only_read:
		return true
	return read_flags.is_read(scenario_id, scene_id, command_index)
