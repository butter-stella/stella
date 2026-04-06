## Manages game settings — read, write, persist, notify.
class_name SettingsManager extends RefCounted

signal settings_changed(key: String, value: Variant)

var settings: GameSettings = GameSettings.new()
var settings_path: String = "user://settings.json"


func set_value(key: String, value: Variant) -> void:
	if key in settings:
		settings[key] = value
		settings_changed.emit(key, value)


func save() -> void:
	var file = FileAccess.open(settings_path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(settings.to_dict()))


func load_settings() -> void:
	if not FileAccess.file_exists(settings_path):
		return
	var file = FileAccess.open(settings_path, FileAccess.READ)
	if file == null:
		return
	var data = JSON.parse_string(file.get_as_text())
	if data is Dictionary:
		settings.from_dict(data)


func reset_to_default() -> void:
	settings = GameSettings.new()


func set_character_voice_volume(character_id: String, volume: float) -> void:
	settings.character_voice_volume[character_id] = volume
	settings_changed.emit("character_voice_volume", {character_id: volume})


func get_character_voice_volume(character_id: String) -> float:
	return settings.character_voice_volume.get(character_id, 1.0)


func set_character_voice_enabled(character_id: String, enabled: bool) -> void:
	settings.character_voice_enabled[character_id] = enabled
	settings_changed.emit("character_voice_enabled", {character_id: enabled})


func is_character_voice_enabled(character_id: String) -> bool:
	return settings.character_voice_enabled.get(character_id, true)
