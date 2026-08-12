## Loads and caches CharacterConfig from config.json files.
## A missing config yields an empty avatar crop and direct expression asset names.
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
		if file == null:
			push_warning(
				"CharacterConfigLoader: cannot open %s" % config_path
			)
		else:
			var parser := JSON.new()
			var error := parser.parse(file.get_as_text())
			if error != OK:
				push_warning(
					(
						"CharacterConfigLoader: invalid JSON in %s at line %d: %s"
						% [
							config_path,
							parser.get_error_line(),
							parser.get_error_message(),
						]
					)
				)
			elif parser.data is Dictionary:
				config.load_from_dict(parser.data)
			else:
				push_warning(
					"CharacterConfigLoader: root of %s must be a Dictionary"
					% config_path
				)

	_cache[character_id] = config
	return config


func clear_cache() -> void:
	_cache.clear()
