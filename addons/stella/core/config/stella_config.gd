## Loads and provides access to stella.cfg project configuration.
## All fields have sensible defaults — a missing config file is valid.
class_name StellaConfig
extends RefCounted

const _CONFIG_SCHEMA := {
	"game": {
		"title": {"property": "game_title", "type": TYPE_STRING},
		"scenario": {"property": "scenario_path", "type": TYPE_STRING},
		"title_bgm": {"property": "title_bgm", "type": TYPE_STRING},
	},
	"paths": {
		"backgrounds": {"property": "backgrounds_path", "type": TYPE_STRING},
		"characters": {"property": "characters_path", "type": TYPE_STRING},
		"stage": {"property": "stage_path", "type": TYPE_STRING},
		"bgm": {"property": "bgm_path", "type": TYPE_STRING},
		"se": {"property": "se_path", "type": TYPE_STRING},
		"voice": {"property": "voice_path", "type": TYPE_STRING},
	},
	"features": {
		"cg_gallery": {"property": "cg_gallery", "type": TYPE_BOOL},
		"backlog": {"property": "backlog", "type": TYPE_BOOL},
		"save_slots": {
			"property": "save_slots",
			"type": TYPE_INT,
			"minimum": 1,
			"maximum": 100,
		},
	},
	"system_se": {
		"select": {"property": "se_select", "type": TYPE_STRING},
		"cancel": {"property": "se_cancel", "type": TYPE_STRING},
	},
	"overrides": {
		"title_scene": {"property": "title_scene", "type": TYPE_STRING},
		"game_scene": {"property": "game_scene", "type": TYPE_STRING},
		"settings_scene": {"property": "settings_scene", "type": TYPE_STRING},
		"save_load_scene": {"property": "save_load_scene", "type": TYPE_STRING},
		"backlog_scene": {"property": "backlog_scene", "type": TYPE_STRING},
		"flowchart_scene": {"property": "flowchart_scene", "type": TYPE_STRING},
	},
}


## Minimal cursor for Stella's deliberately small config grammar. Raw control
## characters are preserved because ConfigFile.save() writes String newlines,
## tabs, and carriage returns literally inside quotes. Diagnostics still count
## CRLF as one physical line ending.
class _ConfigCursor:
	extends RefCounted

	var text: String
	var offset: int = 0
	var line: int = 1
	var column: int = 1
	var _previous_was_carriage_return: bool = false


	func _init(raw_text: String) -> void:
		text = raw_text
		if not text.is_empty() and text.unicode_at(0) == 0xFEFF:
			text = text.substr(1)


	func is_at_end() -> bool:
		return offset >= text.length()


	func peek(ahead: int = 0) -> String:
		var position := offset + ahead
		if position >= text.length():
			return ""
		return text.substr(position, 1)


	func advance() -> String:
		if is_at_end():
			return ""
		var character := text.substr(offset, 1)
		offset += 1
		if character == "\r":
			line += 1
			column = 1
			_previous_was_carriage_return = true
		elif character == "\n":
			if not _previous_was_carriage_return:
				line += 1
			column = 1
			_previous_was_carriage_return = false
		else:
			column += 1
			_previous_was_carriage_return = false
		return character


	func skip_horizontal_whitespace() -> void:
		while peek() in [" ", "\t", "\v", "\f"]:
			advance()

## Whether a config file was actually found and loaded.
var has_config_file: bool = false

## Most recent source-load failure. Successful loads clear these fields.
## Details contain only source/schema metadata, never configuration values.
var last_error: Error = OK
var last_error_source: String = ""
var last_error_detail: String = ""
var last_error_line: int = 0
var last_error_column: int = 0

# [game]
var game_title: String = "Stella"
var scenario_path: String = "res://scenarios/main.stla"
var title_bgm: String = ""  # BGM asset name for title screen

# [paths]
var backgrounds_path: String = "res://art/backgrounds/"
var characters_path: String = "res://art/characters/"
var stage_path: String = "res://art/stage/"
var bgm_path: String = "res://audio/bgm/"
var se_path: String = "res://audio/se/"
var voice_path: String = "res://audio/voice/"

# [features]
var cg_gallery: bool = false
var backlog: bool = true
var save_slots: int = 8

# [system_se] — file names (without extension) for UI sound effects
var se_select: String = ""      # choice / menu selection
var se_cancel: String = ""      # cancel / close overlay

# [overrides]
var title_scene: String = ""
var game_scene: String = ""
var settings_scene: String = ""
var save_load_scene: String = ""
var backlog_scene: String = ""
var flowchart_scene: String = ""

var _applied_sources := PackedStringArray()


## Apply one configuration source atomically.
##
## Syntax and the complete Stella schema are validated before any field is
## changed. An invalid source therefore leaves both resolved values and the
## applied-source list untouched.
func load_from_path(path: String) -> Error:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		var open_error: Error = FileAccess.get_open_error()
		_set_error(path, open_error, error_string(open_error))
		return open_error

	var source := file.get_as_text()
	var read_error: Error = file.get_error()
	file.close()
	if read_error not in [OK, ERR_FILE_EOF]:
		_set_error(path, read_error, error_string(read_error))
		return read_error

	var parsed := _parse_config(source)
	var parse_error: Error = parsed["error"]
	if parse_error != OK:
		var error_line: int = parsed["line"]
		var error_column: int = parsed["column"]
		_set_error(
			path,
			parse_error,
			"line %d, column %d: %s" % [
				error_line,
				error_column,
				parsed["detail"],
			],
			error_line,
			error_column,
		)
		return parse_error

	var updates: Dictionary = parsed["updates"]

	for property_name: String in updates:
		set(property_name, updates[property_name])

	_applied_sources.append(path)
	has_config_file = true
	_clear_error()
	return OK


## Restore built-in defaults and clear all source/error metadata.
func reset() -> void:
	has_config_file = false
	game_title = "Stella"
	scenario_path = "res://scenarios/main.stla"
	title_bgm = ""
	backgrounds_path = "res://art/backgrounds/"
	characters_path = "res://art/characters/"
	stage_path = "res://art/stage/"
	bgm_path = "res://audio/bgm/"
	se_path = "res://audio/se/"
	voice_path = "res://audio/voice/"
	cg_gallery = false
	backlog = true
	save_slots = 8
	se_select = ""
	se_cancel = ""
	title_scene = ""
	game_scene = ""
	settings_scene = ""
	save_load_scene = ""
	backlog_scene = ""
	flowchart_scene = ""
	_applied_sources.clear()
	_clear_error()


## Ordered paths successfully applied to this resolved configuration.
func get_applied_sources() -> PackedStringArray:
	return _applied_sources.duplicate()


## Parse exactly the subset used by Stella: named sections with String, bool,
## and int assignments. Nothing is committed until this whole source succeeds.
func _parse_config(source: String) -> Dictionary:
	var cursor := _ConfigCursor.new(source)
	var updates: Dictionary = {}
	var current_section := ""

	_skip_config_trivia(cursor)
	while not cursor.is_at_end():
		if cursor.peek() == "[":
			var section_result := _parse_section_header(cursor)
			if section_result["error"] != OK:
				return section_result
			current_section = section_result["section"]
		else:
			var assignment_result := _parse_assignment(cursor, current_section)
			if assignment_result["error"] != OK:
				return assignment_result
			updates[assignment_result["property"]] = assignment_result["value"]
		_skip_config_trivia(cursor)

	return _parse_success(updates)


func _parse_section_header(cursor: _ConfigCursor) -> Dictionary:
	var header_line := cursor.line
	var header_column := cursor.column
	cursor.advance()
	cursor.skip_horizontal_whitespace()

	var name_line := cursor.line
	var name_column := cursor.column
	var section := _parse_identifier(cursor)
	if section == "":
		return _parse_failure(
			ERR_PARSE_ERROR,
			"expected a section name",
			name_line,
			name_column,
		)

	cursor.skip_horizontal_whitespace()
	if cursor.peek() != "]":
		return _parse_failure(
			ERR_PARSE_ERROR,
			"expected ']' after section name",
			cursor.line,
			cursor.column,
		)
	cursor.advance()

	var line_result := _finish_config_line(cursor, "section header")
	if line_result["error"] != OK:
		return line_result
	if not _CONFIG_SCHEMA.has(section):
		return _parse_failure(
			ERR_INVALID_DATA,
			"unknown section [%s]" % section,
			name_line,
			name_column,
		)

	return {
		"error": OK,
		"section": section,
		"line": header_line,
		"column": header_column,
	}


func _parse_assignment(cursor: _ConfigCursor, section: String) -> Dictionary:
	var key_line := cursor.line
	var key_column := cursor.column
	var key := _parse_identifier(cursor)
	if key == "":
		return _parse_failure(
			ERR_PARSE_ERROR,
			"expected a key assignment",
			key_line,
			key_column,
		)
	if section == "":
		return _parse_failure(
			ERR_PARSE_ERROR,
			"key assignment appears before a section header",
			key_line,
			key_column,
		)

	var section_schema: Dictionary = _CONFIG_SCHEMA[section]
	if not section_schema.has(key):
		return _parse_failure(
			ERR_INVALID_DATA,
			"unknown key [%s] %s" % [section, key],
			key_line,
			key_column,
		)

	cursor.skip_horizontal_whitespace()
	if cursor.peek() != "=":
		return _parse_failure(
			ERR_PARSE_ERROR,
			"expected '=' after [%s] %s" % [section, key],
			cursor.line,
			cursor.column,
		)
	cursor.advance()
	cursor.skip_horizontal_whitespace()

	var value_line := cursor.line
	var value_column := cursor.column
	var value_result := _parse_config_value(cursor)
	if value_result["error"] != OK:
		return _parse_failure(
			value_result["error"],
			"invalid value for [%s] %s: %s" % [
				section,
				key,
				value_result["detail"],
			],
			value_result.get("line", value_line),
			value_result.get("column", value_column),
		)

	var entry: Dictionary = section_schema[key]
	var expected_type: int = entry["type"]
	var value: Variant = value_result["value"]
	if typeof(value) != expected_type:
		return _parse_failure(
			ERR_INVALID_DATA,
			"invalid type for [%s] %s: expected %s, got %s" % [
				section,
				key,
				type_string(expected_type),
				type_string(typeof(value)),
			],
			value_line,
			value_column,
		)
	if expected_type == TYPE_INT and entry.has("minimum"):
		var integer_value: int = value
		var minimum: int = entry["minimum"]
		var maximum: int = entry["maximum"]
		if integer_value < minimum or integer_value > maximum:
			return _parse_failure(
				ERR_INVALID_DATA,
				"value for [%s] %s must be between %d and %d" % [
					section,
					key,
					minimum,
					maximum,
				],
				value_line,
				value_column,
			)

	var line_result := _finish_config_line(cursor, "value")
	if line_result["error"] != OK:
		return line_result

	return {
		"error": OK,
		"property": entry["property"],
		"value": value,
		"line": key_line,
		"column": key_column,
	}


func _parse_config_value(cursor: _ConfigCursor) -> Dictionary:
	var character := cursor.peek()
	if character == "\"":
		return _parse_quoted_string(cursor)
	if character == "+" or character == "-" or _is_ascii_digit(character):
		return _parse_integer(cursor)
	if _is_identifier_start(character):
		var value_line := cursor.line
		var value_column := cursor.column
		var literal := _parse_identifier(cursor)
		if literal == "true":
			return {"error": OK, "value": true}
		if literal == "false":
			return {"error": OK, "value": false}
		return _parse_failure(
			ERR_INVALID_DATA,
			"expected a quoted String, bool, or int",
			value_line,
			value_column,
		)
	return _parse_failure(
		ERR_INVALID_DATA,
		"expected a quoted String, bool, or int",
		cursor.line,
		cursor.column,
	)


func _parse_quoted_string(cursor: _ConfigCursor) -> Dictionary:
	var start_line := cursor.line
	var start_column := cursor.column
	var value := ""
	cursor.advance()

	while not cursor.is_at_end():
		var character := cursor.advance()
		if character == "\"":
			return {"error": OK, "value": value}
		if character == "\\":
			var escape_result := _parse_string_escape(cursor)
			if escape_result["error"] != OK:
				return escape_result
			value += escape_result["value"]
			continue
		value += character

	return _parse_failure(
		ERR_PARSE_ERROR,
		"unterminated quoted String",
		start_line,
		start_column,
	)


func _parse_string_escape(cursor: _ConfigCursor) -> Dictionary:
	var escape_line := cursor.line
	var escape_column := cursor.column
	if cursor.is_at_end():
		return _parse_failure(
			ERR_PARSE_ERROR,
			"unterminated String escape",
			escape_line,
			escape_column,
		)

	var escaped := cursor.advance()
	match escaped:
		"\"":
			return {"error": OK, "value": "\""}
		"\\":
			return {"error": OK, "value": "\\"}
		"/":
			return {"error": OK, "value": "/"}
		"a":
			return {"error": OK, "value": String.chr(7)}
		"b":
			return {"error": OK, "value": String.chr(8)}
		"f":
			return {"error": OK, "value": String.chr(12)}
		"n":
			return {"error": OK, "value": "\n"}
		"r":
			return {"error": OK, "value": "\r"}
		"t":
			return {"error": OK, "value": "\t"}
		"v":
			return {"error": OK, "value": String.chr(11)}
		"u":
			return _parse_unicode_escape(cursor, escape_line, escape_column)

	# VariantParser/ConfigFile accepts unknown escapes and keeps the character
	# after dropping the backslash (for example, `\q` becomes `q`). Preserve
	# that established String compatibility without ever reflecting the value in
	# diagnostics.
	return {"error": OK, "value": escaped}


func _parse_unicode_escape(
	cursor: _ConfigCursor,
	escape_line: int,
	escape_column: int,
) -> Dictionary:
	var codepoint := 0
	for _digit_index in range(4):
		var character := cursor.peek()
		var digit := _hex_digit_value(character)
		if digit < 0:
			return _parse_failure(
				ERR_PARSE_ERROR,
				"invalid Unicode escape",
				cursor.line,
				cursor.column,
			)
		codepoint = codepoint * 16 + digit
		cursor.advance()

	if codepoint >= 0xD800 and codepoint <= 0xDFFF:
		return _parse_failure(
			ERR_PARSE_ERROR,
			"unsupported Unicode surrogate escape",
			escape_line,
			escape_column,
		)
	return {"error": OK, "value": String.chr(codepoint)}


func _parse_integer(cursor: _ConfigCursor) -> Dictionary:
	var value_line := cursor.line
	var value_column := cursor.column
	var encoded := ""
	if cursor.peek() in ["+", "-"]:
		encoded += cursor.advance()
	if not _is_ascii_digit(cursor.peek()):
		return _parse_failure(
			ERR_PARSE_ERROR,
			"malformed int",
			value_line,
			value_column,
		)
	while _is_ascii_digit(cursor.peek()):
		encoded += cursor.advance()

	var digits := encoded
	var negative := encoded.begins_with("-")
	if negative or encoded.begins_with("+"):
		digits = encoded.substr(1)
	var limit := "9223372036854775808" if negative else "9223372036854775807"
	if _decimal_digits_exceed_limit(digits, limit):
		return _parse_failure(
			ERR_INVALID_DATA,
			"int is outside the supported range",
			value_line,
			value_column,
		)
	return {"error": OK, "value": encoded.to_int()}


func _decimal_digits_exceed_limit(digits: String, limit: String) -> bool:
	var first_significant := 0
	while first_significant < digits.length() and digits[first_significant] == "0":
		first_significant += 1
	var significant := digits.substr(first_significant)
	if significant.length() != limit.length():
		return significant.length() > limit.length()
	for index in range(significant.length()):
		var digit := significant.unicode_at(index)
		var limit_digit := limit.unicode_at(index)
		if digit != limit_digit:
			return digit > limit_digit
	return false


func _parse_identifier(cursor: _ConfigCursor) -> String:
	if not _is_identifier_start(cursor.peek()):
		return ""
	var identifier := cursor.advance()
	while _is_identifier_continue(cursor.peek()):
		identifier += cursor.advance()
	return identifier


func _skip_config_trivia(cursor: _ConfigCursor) -> void:
	while true:
		cursor.skip_horizontal_whitespace()
		if cursor.peek() == ";":
			_skip_config_comment(cursor)
		if _is_line_break(cursor.peek()):
			_consume_line_break(cursor)
			continue
		return


func _finish_config_line(cursor: _ConfigCursor, context: String) -> Dictionary:
	cursor.skip_horizontal_whitespace()
	if cursor.peek() == ";":
		_skip_config_comment(cursor)
	if cursor.is_at_end():
		return {"error": OK}
	if _is_line_break(cursor.peek()):
		_consume_line_break(cursor)
		return {"error": OK}
	return _parse_failure(
		ERR_PARSE_ERROR,
		"unexpected trailing content after %s" % context,
		cursor.line,
		cursor.column,
	)


func _skip_config_comment(cursor: _ConfigCursor) -> void:
	while not cursor.is_at_end() and not _is_line_break(cursor.peek()):
		cursor.advance()


func _is_line_break(character: String) -> bool:
	return character == "\n" or character == "\r"


func _consume_line_break(cursor: _ConfigCursor) -> void:
	var first := cursor.advance()
	if first == "\r" and cursor.peek() == "\n":
		cursor.advance()


func _is_identifier_start(character: String) -> bool:
	if character == "_":
		return true
	if character == "":
		return false
	var codepoint := character.unicode_at(0)
	return (
		(codepoint >= 65 and codepoint <= 90)
		or (codepoint >= 97 and codepoint <= 122)
	)


func _is_identifier_continue(character: String) -> bool:
	return _is_identifier_start(character) or _is_ascii_digit(character)


func _is_ascii_digit(character: String) -> bool:
	if character == "":
		return false
	var codepoint := character.unicode_at(0)
	return codepoint >= 48 and codepoint <= 57


func _hex_digit_value(character: String) -> int:
	if character == "":
		return -1
	var codepoint := character.unicode_at(0)
	if codepoint >= 48 and codepoint <= 57:
		return codepoint - 48
	if codepoint >= 65 and codepoint <= 70:
		return codepoint - 65 + 10
	if codepoint >= 97 and codepoint <= 102:
		return codepoint - 97 + 10
	return -1


func _parse_success(updates: Dictionary) -> Dictionary:
	return {
		"error": OK,
		"updates": updates,
		"line": 0,
		"column": 0,
		"detail": "",
	}


func _parse_failure(
	code: Error,
	detail: String,
	line: int,
	column: int,
) -> Dictionary:
	return {
		"error": code,
		"updates": {},
		"line": line,
		"column": column,
		"detail": detail,
	}


func _set_error(
	path: String,
	code: Error,
	detail: String,
	line: int = 0,
	column: int = 0,
) -> void:
	last_error = code
	last_error_source = path
	last_error_detail = detail
	last_error_line = line
	last_error_column = column


func _clear_error() -> void:
	last_error = OK
	last_error_source = ""
	last_error_detail = ""
	last_error_line = 0
	last_error_column = 0
