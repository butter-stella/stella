## Owns the single validated settings model: built-ins plus optional,
## declaratively registered project settings.
class_name SettingsManager extends RefCounted

signal settings_changed(key: String, value: Variant)

const PERSISTENCE_FORMAT_KEYS := ["schema_version", "values"]
const MAX_PERSISTED_BYTES := 1024 * 1024
const _TYPEWRITER_MILLISECOND_KEYS := [
	"character_interval",
	"punctuation_pause",
]

var settings: GameSettings = GameSettings.new()
var settings_path: String = "user://settings.json"

var last_error: Error = OK
var last_error_source: String = ""
var last_error_field: String = ""
var last_error_detail: String = ""

var _schema := SettingsSchema.new()
var _definitions: Dictionary = SettingsSchema.built_in_definitions()
var _defaults: Dictionary = {}
var _project_values: Dictionary = {}
var _ordered_keys: Array[String] = []


func _init() -> void:
	_install_schema(_schema)


## Atomically replace the optional project contribution. Runtime calls this
## once during composition, before persistence or observers are installed.
func configure_project_schema(path: String) -> Error:
	var candidate := SettingsSchema.new()
	var error := candidate.load_from_path(path)
	if error != OK:
		_set_error(
			candidate.last_error_source,
			error,
			candidate.last_error_field,
			candidate.last_error_detail,
		)
		return error
	_install_schema(candidate)
	_clear_error()
	return OK


func has_setting(key: String) -> bool:
	return _definitions.has(key)


## Returns a defensive value snapshot. Unknown keys fail closed.
func get_value(key: String) -> Variant:
	if not _definitions.has(key):
		_warn_unknown(key)
		return null
	return _defensive_copy(_current_value_raw(key))


## Returns the data-only schema definition for custom settings UI.
func get_definition(key: String) -> Dictionary:
	if not _definitions.has(key):
		_warn_unknown(key)
		return {}
	return (_definitions[key] as Dictionary).duplicate(true)


func get_registered_keys() -> PackedStringArray:
	return PackedStringArray(_ordered_keys)


## Set one registered value. No coercion or partial mutation is permitted.
func set_value(key: String, value: Variant) -> bool:
	if not _definitions.has(key):
		_warn_unknown(key)
		return false
	var normalized := _normalize_for_write(key, value, false)
	if not normalized["ok"]:
		_warn_invalid(key, normalized["detail"])
		return false
	_assign_value(key, normalized["value"])
	_emit_current_value(key)
	return true


## Canonical complete value snapshot in deterministic registry order.
func to_dict() -> Dictionary:
	var result: Dictionary = {}
	for key: String in _ordered_keys:
		result[key] = _defensive_copy(_current_value_raw(key))
	return result


## Persist the exact current schema version and complete value map.
func save() -> Error:
	var values := to_dict()
	var candidate := _validate_values(values, false)
	if not candidate["ok"]:
		_set_error(
			settings_path,
			ERR_INVALID_DATA,
			"$.values.%s" % candidate["key"],
			candidate["detail"],
		)
		_warn_last_error("cannot save settings")
		return ERR_INVALID_DATA
	var encoded := JSON.stringify({
		"schema_version": _schema.version,
		"values": candidate["values"],
	})
	if encoded.to_utf8_buffer().size() > MAX_PERSISTED_BYTES:
		_set_error(
			settings_path,
			ERR_OUT_OF_MEMORY,
			"$",
			"settings document exceeds the 1048576-byte limit",
		)
		_warn_last_error("cannot save settings")
		return ERR_OUT_OF_MEMORY
	var file := FileAccess.open(settings_path, FileAccess.WRITE)
	if file == null:
		var open_error := FileAccess.get_open_error()
		_set_error(settings_path, open_error, "$", "cannot open settings file for writing")
		_warn_last_error("cannot save settings")
		return open_error
	file.store_string(encoded)
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		_set_error(settings_path, write_error, "$", "cannot write settings file")
		_warn_last_error("cannot save settings")
		return write_error
	_clear_error()
	return OK


## Load, migrate, validate, and commit one complete candidate atomically.
func load_settings() -> Error:
	if not FileAccess.file_exists(settings_path):
		_clear_error()
		return OK
	var document_result := _read_persisted_document()
	if not document_result["ok"]:
		_warn_last_error("cannot load settings")
		return last_error
	var document: Dictionary = document_result["document"]
	var shape_result := _validate_persistence_shape(document)
	if not shape_result["ok"]:
		_set_error(
			settings_path,
			ERR_INVALID_DATA,
			shape_result["field"],
			shape_result["detail"],
		)
		_warn_last_error("cannot load settings")
		return ERR_INVALID_DATA
	var migrated := _schema.migrate_values(
		shape_result["schema_version"], shape_result["values"])
	if not migrated["ok"]:
		_set_error(
			settings_path,
			ERR_INVALID_DATA,
			migrated["field"],
			migrated["detail"],
		)
		_warn_last_error("cannot load settings")
		return ERR_INVALID_DATA
	var validated := _validate_values(migrated["values"], true)
	if not validated["ok"]:
		_set_error(
			settings_path,
			ERR_INVALID_DATA,
			"$.values.%s" % validated["key"],
			validated["detail"],
		)
		_warn_last_error("cannot load settings")
		return ERR_INVALID_DATA

	var previous_values := to_dict()
	var candidate_values := previous_values.duplicate(true)
	for key: String in validated["values"]:
		candidate_values[key] = validated["values"][key]
	for key: String in _ordered_keys:
		if validated["values"].has(key):
			_assign_value(key, candidate_values[key])

	# The whole candidate is visible before the first signal. Read each payload
	# at emit time so synchronous listeners cannot make later notifications stale.
	for key: String in _ordered_keys:
		if previous_values[key] != candidate_values[key]:
			_emit_current_value(key)
	_clear_error()
	return OK


## Restore authored defaults atomically and notify each actual change once in
## deterministic registry order.
func reset_to_default() -> void:
	var previous_values := to_dict()
	for key: String in _ordered_keys:
		_assign_value(key, _defaults[key])
	for key: String in _ordered_keys:
		if previous_values[key] != _defaults[key]:
			_emit_current_value(key)


func set_character_voice_volume(character_id: String, volume: float) -> void:
	var volumes: Dictionary = get_value("character_voice_volume")
	volumes[character_id] = volume
	set_value("character_voice_volume", volumes)


func get_character_voice_volume(character_id: String) -> float:
	var volumes: Dictionary = get_value("character_voice_volume")
	return float(volumes.get(character_id, 1.0))


func set_character_voice_enabled(character_id: String, enabled: bool) -> void:
	var enabled_by_character: Dictionary = get_value("character_voice_enabled")
	enabled_by_character[character_id] = enabled
	set_value("character_voice_enabled", enabled_by_character)


func is_character_voice_enabled(character_id: String) -> bool:
	var enabled_by_character: Dictionary = get_value("character_voice_enabled")
	return bool(enabled_by_character.get(character_id, true))


func _install_schema(schema: SettingsSchema) -> void:
	_schema = schema
	_definitions = SettingsSchema.built_in_definitions()
	var custom_keys: Array = schema.project_definitions.keys()
	custom_keys.sort()
	for key_value: Variant in custom_keys:
		var key := String(key_value)
		_definitions[key] = (
			schema.project_definitions[key] as Dictionary).duplicate(true)
	for key: String in schema.default_overrides:
		var authored_definition := (
			_definitions[key] as Dictionary).duplicate(true)
		authored_definition["default"] = _defensive_copy(
			schema.default_overrides[key])
		_definitions[key] = authored_definition

	_defaults.clear()
	_ordered_keys.clear()
	for built_in_key_value: Variant in SettingsSchema.built_in_definitions().keys():
		var built_in_key := String(built_in_key_value)
		_ordered_keys.append(built_in_key)
		var definition: Dictionary = _definitions[built_in_key]
		_defaults[built_in_key] = _defensive_copy(definition["default"])
	for key_value: Variant in custom_keys:
		var key := String(key_value)
		_ordered_keys.append(key)
		_defaults[key] = _defensive_copy(
			(_definitions[key] as Dictionary)["default"])

	_project_values.clear()
	for key: String in _ordered_keys:
		_assign_value(key, _defaults[key])


func _read_persisted_document() -> Dictionary:
	var file := FileAccess.open(settings_path, FileAccess.READ)
	if file == null:
		var open_error := FileAccess.get_open_error()
		_set_error(settings_path, open_error, "$", "cannot read settings file")
		return {"ok": false}
	var bytes := file.get_buffer(MAX_PERSISTED_BYTES + 1)
	var read_error := file.get_error()
	file.close()
	if bytes.size() > MAX_PERSISTED_BYTES:
		_set_error(
			settings_path,
			ERR_INVALID_DATA,
			"$",
			"settings document exceeds the 1048576-byte limit",
		)
		return {"ok": false}
	if read_error not in [OK, ERR_FILE_EOF]:
		_set_error(settings_path, read_error, "$", "cannot read settings file")
		return {"ok": false}
	if 0 in bytes:
		_set_error(settings_path, ERR_INVALID_DATA, "$", "settings document contains NUL")
		return {"ok": false}
	var source := bytes.get_string_from_utf8()
	if source.to_utf8_buffer() != bytes:
		_set_error(settings_path, ERR_INVALID_DATA, "$", "settings document is not UTF-8")
		return {"ok": false}
	if not source.is_empty() and source.unicode_at(0) == 0xFEFF:
		source = source.substr(1)
	var parser := JSON.new()
	if parser.parse(source) != OK:
		_set_error(
			settings_path,
			ERR_PARSE_ERROR,
			"$",
			"invalid JSON at line %d" % parser.get_error_line(),
		)
		return {"ok": false}
	if not parser.data is Dictionary:
		_set_error(settings_path, ERR_INVALID_DATA, "$", "settings root must be an object")
		return {"ok": false}
	return {"ok": true, "document": parser.data}


func _validate_persistence_shape(document: Dictionary) -> Dictionary:
	for key: Variant in document:
		if typeof(key) != TYPE_STRING or key not in PERSISTENCE_FORMAT_KEYS:
			return _shape_failure("$.%s" % String(key), "unknown persistence field")
	for required_key: String in PERSISTENCE_FORMAT_KEYS:
		if not document.has(required_key):
			return _shape_failure(
				"$.%s" % required_key, "required persistence field is missing")
	var version_result := SettingsSchema.normalize_serialized_integer(
		document["schema_version"])
	if not version_result["ok"] or int(version_result["value"]) <= 0:
		return _shape_failure(
			"$.schema_version", "schema_version must be a positive integer")
	if not document["values"] is Dictionary:
		return _shape_failure("$.values", "values must be an object")
	return {
		"ok": true,
		"schema_version": int(version_result["value"]),
		"values": (document["values"] as Dictionary).duplicate(true),
	}


func _validate_values(raw_values: Dictionary, serialized: bool) -> Dictionary:
	var normalized_values: Dictionary = {}
	var raw_keys: Array = raw_values.keys()
	for key_value: Variant in raw_keys:
		if typeof(key_value) != TYPE_STRING:
			return {
				"ok": false,
				"key": String(key_value),
				"detail": "setting is unknown or unregistered",
			}
	raw_keys.sort()
	for key_value: Variant in raw_keys:
		if not _definitions.has(key_value):
			return {
				"ok": false,
				"key": String(key_value),
				"detail": "setting is unknown or unregistered",
			}
		var key := String(key_value)
		var normalized := _normalize_for_write(
			key, raw_values[key_value], serialized)
		if not normalized["ok"]:
			return {"ok": false, "key": key, "detail": normalized["detail"]}
		normalized_values[key] = normalized["value"]
	return {"ok": true, "values": normalized_values}


func _normalize_for_write(
	key: String,
	value: Variant,
	serialized: bool,
) -> Dictionary:
	var normalized := SettingsSchema.normalize_value(
		_definitions[key], value, serialized)
	# Preserve the established typewriter contract: invalid millisecond values
	# normalize to that field's authored default and still publish the write.
	if not normalized["ok"] and key in _TYPEWRITER_MILLISECOND_KEYS:
		push_warning((
			"SettingsManager: %s must be a non-negative integer in milliseconds; "
			+ "using authored default %d ms"
		) % [key, int(_defaults[key])])
		return {"ok": true, "value": int(_defaults[key]), "detail": ""}
	return normalized


func _assign_value(key: String, value: Variant) -> void:
	var copied := _defensive_copy(value)
	if _schema.project_definitions.has(key):
		_project_values[key] = copied
	else:
		settings[key] = copied


func _current_value_raw(key: String) -> Variant:
	if _schema.project_definitions.has(key):
		return _project_values[key]
	return settings[key]


func _emit_current_value(key: String) -> void:
	settings_changed.emit(key, _defensive_copy(_current_value_raw(key)))


func _warn_unknown(key: String) -> void:
	push_warning("SettingsManager: unknown or unregistered setting '%s'" % key)


func _warn_invalid(key: String, detail: String) -> void:
	if key == "effect_enabled":
		push_warning(
			"SettingsManager: effect_enabled must be a bool; keeping current settings")
		return
	if key in ["movie_volume", "movie_right_click_skip", "movie_skip_on_skip"]:
		push_warning(
			"SettingsManager: %s has an invalid type or range; keeping current settings"
			% key)
		return
	push_warning(
		"SettingsManager: setting '%s' %s; keeping current settings" % [key, detail])


func _warn_last_error(action: String) -> void:
	push_warning(
		"SettingsManager: %s from %s at %s: %s" % [
			action,
			last_error_source,
			last_error_field,
			last_error_detail,
		])


func _set_error(
	source: String,
	code: Error,
	field: String,
	detail: String,
) -> void:
	last_error = code
	last_error_source = source
	last_error_field = field
	last_error_detail = detail


func _clear_error() -> void:
	last_error = OK
	last_error_source = ""
	last_error_field = ""
	last_error_detail = ""


func _shape_failure(field: String, detail: String) -> Dictionary:
	return {"ok": false, "field": field, "detail": detail}


static func _defensive_copy(value: Variant) -> Variant:
	if value is Dictionary or value is Array:
		return value.duplicate(true)
	return value
