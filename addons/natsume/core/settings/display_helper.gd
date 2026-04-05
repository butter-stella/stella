## Centralized display settings logic — resolution presets and window mode management.
class_name DisplayHelper extends RefCounted


const RESOLUTION_PRESETS: Dictionary = {
	"1920x1080": Vector2i(1920, 1080),
	"1280x720": Vector2i(1280, 720),
}

const PRESET_LABELS: Array[String] = [
	"1920x1080 (1080p)",
	"1280x720 (720p)",
]

const PRESET_KEYS: Array[String] = [
	"1920x1080",
	"1280x720",
]


static func parse_resolution(resolution_str: String) -> Vector2i:
	if RESOLUTION_PRESETS.has(resolution_str):
		return RESOLUTION_PRESETS[resolution_str]
	return Vector2i(1920, 1080)


static func get_preset_labels() -> Array[String]:
	return PRESET_LABELS


static func get_preset_keys() -> Array[String]:
	return PRESET_KEYS


static func apply(settings: GameSettings) -> void:
	if settings.fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		var size = parse_resolution(settings.resolution)
		DisplayServer.window_set_size(size)
		_center_window(size)


static func _center_window(size: Vector2i) -> void:
	var screen_size = DisplayServer.screen_get_size()
	var pos = (screen_size - size) / 2
	DisplayServer.window_set_position(pos)
