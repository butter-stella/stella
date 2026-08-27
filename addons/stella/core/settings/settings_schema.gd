## Declarative, versioned schema for project-defined settings.
##
## The schema is data-only. It cannot install callbacks or replace Stella's
## SettingsManager; it only contributes authored defaults, namespaced setting
## definitions, and deterministic rename/remove migrations.
class_name SettingsSchema extends RefCounted

const MAX_SOURCE_BYTES := 1024 * 1024
const MAX_PROJECT_SETTINGS := 256
const MAX_ENUM_VALUES := 256
const MAX_DICTIONARY_ENTRIES := 1024
const MAX_KEY_LENGTH := 128
const MIN_SAFE_INTEGER := -9007199254740991
const MAX_SAFE_INTEGER := 9007199254740991

var version: int = 1
var default_overrides: Dictionary = {}
var project_definitions: Dictionary = {}
var migrations: Dictionary = {}

var last_error: Error = OK
var last_error_source: String = ""
var last_error_field: String = ""
var last_error_detail: String = ""
var last_error_line: int = 0


## Built-in fields use the same validator as project fields. Project schemas
## may override only their defaults; their type and range remain authoritative.
static func built_in_definitions() -> Dictionary:
	return {
		"character_interval": _integer_definition(50, 0),
		"punctuation_pause": _integer_definition(200, 0),
		"click_to_complete": _boolean_definition(true),
		"text_window_opacity": _number_definition(0.8, 0.0, 1.0),
		"auto_play_delay": _number_definition(1.5, 0.0),
		"auto_play_wait_voice": _boolean_definition(true),
		"auto_play_pause_on_choice": _boolean_definition(true),
		"auto_play_click_interrupt": _boolean_definition(true),
		"skip_interval": _integer_definition(50, 0),
		"skip_only_read": _boolean_definition(true),
		"skip_unread_confirm": _boolean_definition(true),
		"skip_stop_on_choice": _boolean_definition(true),
		"master_volume": _number_definition(1.0, 0.0, 1.0),
		"bgm_volume": _number_definition(0.8, 0.0, 1.0),
		"se_volume": _number_definition(1.0, 0.0, 1.0),
		"system_se_volume": _number_definition(1.0, 0.0, 1.0),
		"voice_volume": _number_definition(1.0, 0.0, 1.0),
		"movie_volume": _number_definition(1.0, 0.0, 1.0),
		# These built-ins historically accept arbitrary per-character entries at the
		# settings boundary. Authoritative audio consumers keep their own typed
		# fail-close preflight, so the unified registry must not pre-empt that contract.
		"character_voice_volume": _dictionary_definition({}, "variant"),
		"character_voice_enabled": _dictionary_definition({}, "variant"),
		"movie_right_click_skip": _boolean_definition(true),
		"movie_skip_on_skip": _boolean_definition(false),
		"voice_continue_on_advance": _boolean_definition(false),
		"voice_replay_on_backlog": _boolean_definition(true),
		"fullscreen": _boolean_definition(false),
		# DisplayHelper has built-in presets, but custom projects historically use
		# additional WIDTHxHEIGHT strings through the same setting.
		"resolution": _string_definition("1920x1080"),
		"effect_enabled": _boolean_definition(true),
	}


## Load and validate a complete schema source before changing this object.
func load_from_path(path: String) -> Error:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _fail(
			path, FileAccess.get_open_error(), "$", "cannot read settings schema")
	var source_bytes := file.get_buffer(MAX_SOURCE_BYTES + 1)
	var read_error := file.get_error()
	file.close()
	if source_bytes.size() > MAX_SOURCE_BYTES:
		return _fail(
			path, ERR_INVALID_DATA, "$",
			"settings schema exceeds the 1048576-byte limit")
	if read_error not in [OK, ERR_FILE_EOF]:
		return _fail(path, read_error, "$", "cannot read settings schema")
	if 0 in source_bytes:
		return _fail(
			path, ERR_INVALID_DATA, "$", "settings schema contains a NUL byte")

	var source := source_bytes.get_string_from_utf8()
	if source.to_utf8_buffer() != source_bytes:
		return _fail(
			path, ERR_INVALID_DATA, "$", "settings schema is not valid UTF-8")
	if not source.is_empty() and source.unicode_at(0) == 0xFEFF:
		source = source.substr(1)

	var parser := JSON.new()
	var parse_error := parser.parse(source)
	if parse_error != OK:
		return _fail(
			path,
			ERR_PARSE_ERROR,
			"$",
			"invalid JSON at line %d" % parser.get_error_line(),
			parser.get_error_line(),
		)
	var document: Variant = parser.data
	var validated := _validate_document(document)
	if not validated["ok"]:
		return _fail(
			path,
			ERR_INVALID_DATA,
			validated["field"],
			validated["detail"],
		)

	version = validated["version"]
	default_overrides = validated["defaults"]
	project_definitions = validated["settings"]
	migrations = validated["migrations"]
	_clear_error()
	return OK


## Validate and normalize a setting using its canonical definition.
## Serialized integer fields accept only lossless integral JSON numbers.
static func normalize_value(
	definition: Dictionary,
	value: Variant,
	serialized: bool,
) -> Dictionary:
	var kind := String(definition.get("type", ""))
	match kind:
		"boolean":
			if typeof(value) != TYPE_BOOL:
				return _invalid_value("must be a boolean")
			return _valid_value(value)
		"integer":
			var integer_result := _normalize_integer(value, serialized)
			if not integer_result["ok"]:
				return integer_result
			var integer_value: int = integer_result["value"]
			if definition.has("minimum") and integer_value < int(definition["minimum"]):
				return _invalid_value("must be within the declared integer range")
			if definition.has("maximum") and integer_value > int(definition["maximum"]):
				return _invalid_value("must be within the declared integer range")
			return _valid_value(integer_value)
		"number":
			if typeof(value) not in [TYPE_INT, TYPE_FLOAT]:
				return _invalid_value("must be a finite number")
			var number := float(value)
			if not is_finite(number):
				return _invalid_value("must be a finite number")
			if definition.has("minimum") and number < float(definition["minimum"]):
				return _invalid_value("must be within the declared numeric range")
			if definition.has("maximum") and number > float(definition["maximum"]):
				return _invalid_value("must be within the declared numeric range")
			return _valid_value(number)
		"string":
			if typeof(value) != TYPE_STRING:
				return _invalid_value("must be a String")
			return _valid_value(String(value))
		"variant":
			return _valid_value(
				value.duplicate(true)
				if value is Dictionary or value is Array
				else value)
		"enum":
			if typeof(value) != TYPE_STRING or value not in definition.get("values", []):
				return _invalid_value("must be one of the declared enum values")
			return _valid_value(String(value))
		"dictionary":
			if not value is Dictionary:
				return _invalid_value("must be a Dictionary")
			var dictionary := value as Dictionary
			if dictionary.size() > MAX_DICTIONARY_ENTRIES:
				return _invalid_value(
					"exceeds the %d-entry Dictionary limit" % MAX_DICTIONARY_ENTRIES)
			var value_definition := _dictionary_value_definition(definition)
			var normalized_dictionary: Dictionary = {}
			var keys: Array = dictionary.keys()
			for raw_key: Variant in keys:
				if typeof(raw_key) != TYPE_STRING or String(raw_key).is_empty():
					return _invalid_value(
						"Dictionary keys must be non-empty Strings")
			keys.sort()
			for raw_key: Variant in keys:
				var child := normalize_value(
					value_definition, dictionary[raw_key], serialized)
				if not child["ok"]:
					return _invalid_value(
						"Dictionary entry '%s' %s" % [raw_key, child["detail"]])
				normalized_dictionary[String(raw_key)] = child["value"]
			return _valid_value(normalized_dictionary)
	return _invalid_value("has an unknown schema type")


## Apply the explicit contiguous migration chain to a detached value map.
func migrate_values(from_version: int, raw_values: Dictionary) -> Dictionary:
	if from_version <= 0:
		return _migration_failure(
			"$.schema_version", "schema_version must be a positive integer")
	if from_version > version:
		return _migration_failure(
			"$.schema_version",
			"persisted schema_version is newer than the project schema")
	var values := raw_values.duplicate(true)
	for current_version: int in range(from_version, version):
		if not migrations.has(current_version):
			return _migration_failure(
				"$.schema_version",
				"missing migration from version %d" % current_version)
		var migration: Dictionary = migrations[current_version]
		var rename: Dictionary = migration["rename"]
		var rename_sources: Array = rename.keys()
		rename_sources.sort()
		for source_value: Variant in rename_sources:
			var source := String(source_value)
			var target := String(rename[source])
			if not values.has(source):
				continue
			if values.has(target):
				return _migration_failure(
					"$.values.%s" % target,
					"migration %d->%d conflicts at target '%s'" % [
						current_version, current_version + 1, target])
			values[target] = values[source]
			values.erase(source)
		for removed_value: Variant in migration["remove"]:
			values.erase(String(removed_value))
	return {"ok": true, "values": values, "detail": ""}


func _validate_document(document: Variant) -> Dictionary:
	if not document is Dictionary:
		return _schema_failure("$", "settings schema root must be an object")
	var root := document as Dictionary
	var root_keys := _require_exact_keys(
		root, ["version"], ["defaults", "settings", "migrations"], "$")
	if not root_keys["ok"]:
		return root_keys
	var version_result := normalize_serialized_integer(root["version"])
	if not version_result["ok"] or int(version_result["value"]) <= 0:
		return _schema_failure("$.version", "version must be a positive integer")
	var parsed_version: int = version_result["value"]

	var built_ins := built_in_definitions()
	var defaults_result := _validate_default_overrides(
		root.get("defaults", {}), built_ins)
	if not defaults_result["ok"]:
		return defaults_result
	var settings_result := _validate_project_definitions(
		root.get("settings", {}), built_ins)
	if not settings_result["ok"]:
		return settings_result
	var migrations_result := _validate_migrations(
		root.get("migrations", []),
		parsed_version,
		settings_result["settings"],
	)
	if not migrations_result["ok"]:
		return migrations_result
	return {
		"ok": true,
		"version": parsed_version,
		"defaults": defaults_result["defaults"],
		"settings": settings_result["settings"],
		"migrations": migrations_result["migrations"],
	}


func _validate_default_overrides(raw: Variant, built_ins: Dictionary) -> Dictionary:
	if not raw is Dictionary:
		return _schema_failure("$.defaults", "defaults must be an object")
	var result: Dictionary = {}
	var keys: Array = (raw as Dictionary).keys()
	for raw_key: Variant in keys:
		if typeof(raw_key) != TYPE_STRING:
			return _schema_failure(
				"$.defaults.%s" % String(raw_key),
				"default override must name an exact built-in setting",
			)
	keys.sort()
	for raw_key: Variant in keys:
		if not built_ins.has(raw_key):
			return _schema_failure(
				"$.defaults.%s" % String(raw_key),
				"default override must name an exact built-in setting",
			)
		var normalized := normalize_value(
			built_ins[raw_key], (raw as Dictionary)[raw_key], true)
		if not normalized["ok"]:
			return _schema_failure(
				"$.defaults.%s" % raw_key, normalized["detail"])
		result[String(raw_key)] = normalized["value"]
	return {"ok": true, "defaults": result}


func _validate_project_definitions(
	raw: Variant,
	built_ins: Dictionary,
) -> Dictionary:
	if not raw is Dictionary:
		return _schema_failure("$.settings", "settings must be an object")
	if (raw as Dictionary).size() > MAX_PROJECT_SETTINGS:
		return _schema_failure(
			"$.settings",
			"settings exceeds the %d-entry project limit" % MAX_PROJECT_SETTINGS,
		)
	var result: Dictionary = {}
	var keys: Array = (raw as Dictionary).keys()
	for raw_key: Variant in keys:
		if typeof(raw_key) != TYPE_STRING:
			return _schema_failure(
				"$.settings.%s" % String(raw_key),
				"project setting keys must be lowercase namespaced identifiers",
			)
	keys.sort()
	for raw_key: Variant in keys:
		if not _is_namespaced_key(String(raw_key)):
			return _schema_failure(
				"$.settings.%s" % String(raw_key),
				"project setting keys must be lowercase namespaced identifiers",
			)
		var key := String(raw_key)
		if built_ins.has(key):
			return _schema_failure(
				"$.settings.%s" % key, "project settings cannot shadow built-ins")
		var definition_result := _validate_definition(
			(raw as Dictionary)[raw_key], "$.settings.%s" % key)
		if not definition_result["ok"]:
			return definition_result
		result[key] = definition_result["definition"]
	return {"ok": true, "settings": result}


func _validate_definition(raw: Variant, field: String) -> Dictionary:
	if not raw is Dictionary:
		return _schema_failure(field, "setting definition must be an object")
	var definition := raw as Dictionary
	if typeof(definition.get("type")) != TYPE_STRING:
		return _schema_failure(field + ".type", "type must be a String")
	var kind := String(definition["type"])
	var required := ["type", "default"]
	var optional: Array[String] = []
	match kind:
		"boolean":
			pass
		"integer", "number":
			optional = ["minimum", "maximum"]
		"enum":
			required.append("values")
		"dictionary":
			required.append("value_type")
			optional = ["minimum", "maximum", "values"]
		_:
			return _schema_failure(
				field + ".type",
				"type must be boolean, integer, number, enum, or dictionary",
			)
	var keys_result := _require_exact_keys(definition, required, optional, field)
	if not keys_result["ok"]:
		return keys_result

	var canonical: Dictionary = {"type": kind}
	if kind == "enum":
		var enum_result := _validate_enum_values(definition["values"], field + ".values")
		if not enum_result["ok"]:
			return enum_result
		canonical["values"] = enum_result["values"]
	elif kind == "dictionary":
		if typeof(definition["value_type"]) != TYPE_STRING:
			return _schema_failure(field + ".value_type", "value_type must be a String")
		var value_type := String(definition["value_type"])
		if value_type not in ["boolean", "integer", "number", "string", "enum"]:
			return _schema_failure(
				field + ".value_type",
				"dictionary value_type must be boolean, integer, number, string, or enum",
			)
		canonical["value_type"] = value_type
		if value_type == "enum":
			if not definition.has("values"):
				return _schema_failure(
					field + ".values", "enum dictionaries require values")
			var enum_result := _validate_enum_values(
				definition["values"], field + ".values")
			if not enum_result["ok"]:
				return enum_result
			canonical["values"] = enum_result["values"]
		elif definition.has("values"):
			return _schema_failure(
				field + ".values", "values is valid only for enum dictionaries")

	if definition.has("minimum") or definition.has("maximum"):
		var range_type := kind
		if kind == "dictionary":
			range_type = String(canonical["value_type"])
		if range_type not in ["integer", "number"]:
			return _schema_failure(
				field, "minimum/maximum require an integer or number type")
		var range_result := _validate_range(
			definition, range_type == "integer", field)
		if not range_result["ok"]:
			return range_result
		if range_result.has("minimum"):
			canonical["minimum"] = range_result["minimum"]
		if range_result.has("maximum"):
			canonical["maximum"] = range_result["maximum"]

	var normalized_default := normalize_value(
		canonical, definition["default"], true)
	if not normalized_default["ok"]:
		return _schema_failure(field + ".default", normalized_default["detail"])
	canonical["default"] = normalized_default["value"]
	return {"ok": true, "definition": canonical}


func _validate_range(
	definition: Dictionary,
	require_integer: bool,
	field: String,
) -> Dictionary:
	var result := {"ok": true}
	for bound: String in ["minimum", "maximum"]:
		if not definition.has(bound):
			continue
		var normalized := (
			normalize_serialized_integer(definition[bound])
			if require_integer
			else _normalize_finite_number(definition[bound])
		)
		if not normalized["ok"]:
			return _schema_failure(
				"%s.%s" % [field, bound],
				"%s must be a %s" % [
					bound, "finite integer" if require_integer else "finite number"],
			)
		result[bound] = normalized["value"]
	if (
		result.has("minimum")
		and result.has("maximum")
		and result["minimum"] > result["maximum"]
	):
		return _schema_failure(field, "minimum cannot exceed maximum")
	return result


func _validate_enum_values(raw: Variant, field: String) -> Dictionary:
	if not raw is Array or raw.is_empty() or raw.size() > MAX_ENUM_VALUES:
		return _schema_failure(
			field, "values must be a non-empty Array within the enum limit")
	var seen: Dictionary = {}
	var values: Array[String] = []
	for index: int in range(raw.size()):
		var value: Variant = raw[index]
		if typeof(value) != TYPE_STRING or String(value).is_empty():
			return _schema_failure(
				"%s[%d]" % [field, index], "enum values must be non-empty Strings")
		if seen.has(value):
			return _schema_failure(
				"%s[%d]" % [field, index], "enum values must be unique")
		seen[value] = true
		values.append(String(value))
	return {"ok": true, "values": values}


func _validate_migrations(
	raw: Variant,
	current_version: int,
	definitions: Dictionary,
) -> Dictionary:
	if not raw is Array:
		return _schema_failure("$.migrations", "migrations must be an Array")
	if raw.size() != current_version - 1:
		return _schema_failure(
			"$.migrations",
			"migrations must contain one contiguous step for every prior version",
		)
	var result: Dictionary = {}
	for index: int in range(raw.size()):
		var field := "$.migrations[%d]" % index
		var migration_value: Variant = raw[index]
		if not migration_value is Dictionary:
			return _schema_failure(field, "migration must be an object")
		var migration := migration_value as Dictionary
		var keys_result := _require_exact_keys(
			migration, ["from", "to"], ["rename", "remove"], field)
		if not keys_result["ok"]:
			return keys_result
		var from_result := normalize_serialized_integer(migration["from"])
		var to_result := normalize_serialized_integer(migration["to"])
		if not from_result["ok"] or not to_result["ok"]:
			return _schema_failure(field, "from/to must be integers")
		var from_version: int = from_result["value"]
		var to_version: int = to_result["value"]
		if from_version != index + 1 or to_version != from_version + 1:
			return _schema_failure(
				field, "migration steps must be ordered and contiguous")

		var rename_result := _validate_rename_map(
			migration.get("rename", {}), field + ".rename", definitions)
		if not rename_result["ok"]:
			return rename_result
		var remove_result := _validate_remove_list(
			migration.get("remove", []), field + ".remove")
		if not remove_result["ok"]:
			return remove_result
		var rename: Dictionary = rename_result["rename"]
		var remove: Array[String] = remove_result["remove"]
		for removed: String in remove:
			if rename.has(removed) or removed in rename.values():
				return _schema_failure(
					field, "rename and remove operations cannot overlap")
		result[from_version] = {
			"to": to_version,
			"rename": rename,
			"remove": remove,
		}
	return {"ok": true, "migrations": result}


func _validate_rename_map(
	raw: Variant,
	field: String,
	definitions: Dictionary,
) -> Dictionary:
	if not raw is Dictionary:
		return _schema_failure(field, "rename must be an object")
	var result: Dictionary = {}
	var targets: Dictionary = {}
	var keys: Array = (raw as Dictionary).keys()
	for raw_source: Variant in keys:
		if typeof(raw_source) != TYPE_STRING:
			return _schema_failure(
				field, "rename keys and targets must be namespaced setting keys")
	keys.sort()
	for raw_source: Variant in keys:
		var raw_target: Variant = (raw as Dictionary)[raw_source]
		if (
			typeof(raw_source) != TYPE_STRING
			or typeof(raw_target) != TYPE_STRING
			or not _is_namespaced_key(String(raw_source))
			or not _is_namespaced_key(String(raw_target))
		):
			return _schema_failure(
				field, "rename keys and targets must be namespaced setting keys")
		var source := String(raw_source)
		var target := String(raw_target)
		if source == target or targets.has(target):
			return _schema_failure(field, "rename targets must be unique and different")
		if (raw as Dictionary).has(target):
			return _schema_failure(field, "rename chains within one step are ambiguous")
		if not definitions.has(target):
			return _schema_failure(
				"%s.%s" % [field, source],
				"rename target must be registered by the current schema",
			)
		targets[target] = true
		result[source] = target
	return {"ok": true, "rename": result}


func _validate_remove_list(raw: Variant, field: String) -> Dictionary:
	if not raw is Array:
		return _schema_failure(field, "remove must be an Array")
	var seen: Dictionary = {}
	var result: Array[String] = []
	for index: int in range(raw.size()):
		var value: Variant = raw[index]
		if typeof(value) != TYPE_STRING or not _is_namespaced_key(String(value)):
			return _schema_failure(
				"%s[%d]" % [field, index],
				"removed keys must be namespaced setting keys",
			)
		var key := String(value)
		if seen.has(key):
			return _schema_failure(
				"%s[%d]" % [field, index], "removed keys must be unique")
		seen[key] = true
		result.append(key)
	result.sort()
	return {"ok": true, "remove": result}


func _require_exact_keys(
	dictionary: Dictionary,
	required: Array,
	optional: Array,
	field: String,
) -> Dictionary:
	for key: Variant in dictionary:
		if typeof(key) != TYPE_STRING or key not in required and key not in optional:
			return _schema_failure(
				"%s.%s" % [field, String(key)], "unknown schema field")
	for required_key: String in required:
		if not dictionary.has(required_key):
			return _schema_failure(
				"%s.%s" % [field, required_key], "required schema field is missing")
	return {"ok": true}


static func _is_namespaced_key(key: String) -> bool:
	if key.length() > MAX_KEY_LENGTH or key.count(".") < 1:
		return false
	# Keep empty pieces: leading, trailing, or repeated separators are invalid
	# authored keys, not aliases for another registered key.
	for segment: String in key.split(".", true):
		if segment.is_empty() or not _is_lower_identifier(segment):
			return false
	return true


static func _is_lower_identifier(value: String) -> bool:
	for index: int in range(value.length()):
		var codepoint := value.unicode_at(index)
		if index == 0:
			if codepoint < 97 or codepoint > 122:
				return false
		elif not (
			(codepoint >= 97 and codepoint <= 122)
			or (codepoint >= 48 and codepoint <= 57)
			or codepoint == 95
		):
			return false
	return not value.is_empty()


static func _dictionary_value_definition(definition: Dictionary) -> Dictionary:
	var child := {"type": definition["value_type"]}
	for key: String in ["minimum", "maximum", "values"]:
		if definition.has(key):
			child[key] = definition[key]
	return child


static func _normalize_integer(value: Variant, serialized: bool) -> Dictionary:
	if typeof(value) == TYPE_INT:
		var integer_value := int(value)
		if integer_value >= MIN_SAFE_INTEGER and integer_value <= MAX_SAFE_INTEGER:
			return _valid_value(integer_value)
	if serialized and typeof(value) == TYPE_FLOAT:
		var number := float(value)
		if (
			is_finite(number)
			and number == floor(number)
			and number >= float(MIN_SAFE_INTEGER)
			and number <= float(MAX_SAFE_INTEGER)
		):
			var integer_value := int(number)
			if float(integer_value) == number:
				return _valid_value(integer_value)
	return _invalid_value(
		"must be a JSON-safe integer between %d and %d" % [
			MIN_SAFE_INTEGER, MAX_SAFE_INTEGER])


## Normalize an integer read through JSON, which represents some integral
## values as floats. Public only for SettingsManager's persistence envelope.
static func normalize_serialized_integer(value: Variant) -> Dictionary:
	return _normalize_integer(value, true)


static func _normalize_finite_number(value: Variant) -> Dictionary:
	if typeof(value) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(value)):
		return _invalid_value("must be a finite number")
	return _valid_value(float(value))


static func _boolean_definition(default_value: bool) -> Dictionary:
	return {"type": "boolean", "default": default_value}


static func _string_definition(default_value: String) -> Dictionary:
	return {"type": "string", "default": default_value}


static func _integer_definition(
	default_value: int,
	minimum: int,
	maximum: Variant = null,
) -> Dictionary:
	var definition := {
		"type": "integer",
		"default": default_value,
		"minimum": minimum,
	}
	if maximum != null:
		definition["maximum"] = maximum
	return definition


static func _number_definition(
	default_value: float,
	minimum: float,
	maximum: Variant = null,
) -> Dictionary:
	var definition := {
		"type": "number",
		"default": default_value,
		"minimum": minimum,
	}
	if maximum != null:
		definition["maximum"] = maximum
	return definition


static func _dictionary_definition(
	default_value: Dictionary,
	value_type: String,
	minimum: Variant = null,
	maximum: Variant = null,
) -> Dictionary:
	var definition := {
		"type": "dictionary",
		"default": default_value,
		"value_type": value_type,
	}
	if minimum != null:
		definition["minimum"] = minimum
	if maximum != null:
		definition["maximum"] = maximum
	return definition


static func _valid_value(value: Variant) -> Dictionary:
	return {"ok": true, "value": value, "detail": ""}


static func _invalid_value(detail: String) -> Dictionary:
	return {"ok": false, "value": null, "detail": detail}


func _schema_failure(field: String, detail: String) -> Dictionary:
	return {"ok": false, "field": field, "detail": detail}


func _migration_failure(field: String, detail: String) -> Dictionary:
	return {"ok": false, "values": {}, "field": field, "detail": detail}


func _fail(
	source: String,
	code: Error,
	field: String,
	detail: String,
	line: int = 0,
) -> Error:
	last_error = code
	last_error_source = source
	last_error_field = field
	last_error_detail = detail
	last_error_line = line
	return code


func _clear_error() -> void:
	last_error = OK
	last_error_source = ""
	last_error_field = ""
	last_error_detail = ""
	last_error_line = 0
