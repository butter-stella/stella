## Controls auto-play mode — automatically advances dialogue after a delay.
class_name AutoPlayController extends RefCounted

var is_active: bool = false


func toggle() -> void:
	is_active = not is_active


func stop() -> void:
	is_active = false
