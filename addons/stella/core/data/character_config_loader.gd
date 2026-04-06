## Loads and caches CharacterConfig from config.json files.
## Falls back to sprite mode if no config file exists.
class_name CharacterConfigLoader extends RefCounted

var _cache: Dictionary = {}  # character_id -> CharacterConfig
var _base_path: String = ""


func set_base_path(path: String) -> void:
	_base_path = path


func get_config(character_id: String) -> CharacterConfig:
	if _cache.has(character_id):
		return _cache[character_id]

	var config = CharacterConfig.new()
	var config_path = _base_path + "%s/config.json" % character_id

	if FileAccess.file_exists(config_path):
		var file = FileAccess.open(config_path, FileAccess.READ)
		if file:
			var data = JSON.parse_string(file.get_as_text())
			if data is Dictionary:
				config.load_from_dict(data)

	_cache[character_id] = config
	return config


func clear_cache() -> void:
	_cache.clear()
