## Centralized display settings logic — resolution presets and window mode management.
class_name DisplayHelper extends RefCounted


## Single source of truth — labels and keys derived from this list.
const PRESETS: Array[Dictionary] = [
	{"key": "1920x1080", "size": Vector2i(1920, 1080), "label": "1920x1080 (1080p)"},
	{"key": "1280x720", "size": Vector2i(1280, 720), "label": "1280x720 (720p)"},
]


static func parse_resolution(resolution_str: String) -> Vector2i:
	for p in PRESETS:
		if p["key"] == resolution_str:
			return p["size"]
	return PRESETS[0]["size"]


static func get_preset_labels() -> Array[String]:
	var labels: Array[String] = []
	for p in PRESETS:
		labels.append(p["label"])
	return labels


static func get_preset_keys() -> Array[String]:
	var keys: Array[String] = []
	for p in PRESETS:
		keys.append(p["key"])
	return keys


static func apply(settings: GameSettings) -> void:
	if not _can_manage_window():
		return
	if settings.fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		var size = parse_resolution(settings.resolution)
		DisplayServer.window_set_size(size)
		_center_window(size)


static func _can_manage_window() -> bool:
	if DisplayServer.get_name() == "headless":
		return false
	# Godot 4.6 embedded editor window doesn't support mode/size changes
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--embedded"):
			return false
	return true


static func _center_window(size: Vector2i) -> void:
	var screen = DisplayServer.window_get_current_screen()
	var screen_size = DisplayServer.screen_get_size(screen)
	var screen_pos = DisplayServer.screen_get_position(screen)
	var pos = screen_pos + (screen_size - size) / 2
	DisplayServer.window_set_position(pos)
