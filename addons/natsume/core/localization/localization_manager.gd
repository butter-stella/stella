## Simple key-based localization manager.
## Supports multiple locales, fallback to key when translation missing.
class_name LocalizationManager extends RefCounted

var _locale: String = ""
var _tables: Dictionary = {}  # locale -> {key -> text}


func set_locale(locale: String) -> void:
	_locale = locale


func get_locale() -> String:
	return _locale


func load_from_dict(locale: String, data: Dictionary) -> void:
	_tables[locale] = data


func translate(key: String) -> String:
	if _tables.has(_locale):
		var table = _tables[_locale]
		if table.has(key):
			return table[key]
	return key


func get_available_locales() -> Array:
	return _tables.keys()
