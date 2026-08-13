## Controls auto-play mode — automatically advances dialogue after a delay.
class_name AutoPlayController extends RefCounted

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
