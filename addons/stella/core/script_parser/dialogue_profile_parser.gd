## Parses STLA-native dialogue presentation profile declarations.
##
## Declarations are compile-time data and do not become runtime commands:
##   @dialogue_profile novel panel_anchors=0,0,1,1
##   @dialogue_profile novel text_anchors=0.15,0.1,0.85,0.7
##   @dialogue_profile novel show=quick_menu hide=adv_chrome
##   @dialogue_profile novel entry_prefix="・" entry_separator=""
class_name DialogueProfileParser
extends RefCounted

const VECTOR_KEYS := [
	"panel_anchors",
	"panel_offsets",
	"text_anchors",
	"text_offsets",
	"text_margins",
]
const COLOR_KEYS := ["panel_modulate", "background_modulate"]
const BOOL_KEYS := [
	"fit_content",
	"scroll_active",
	"scroll_following",
	"clip_contents",
	"background_visible",
]
const STRING_KEYS := ["entry_prefix", "entry_separator"]
const HORIZONTAL_ALIGNMENTS := {
	"left": HORIZONTAL_ALIGNMENT_LEFT,
	"center": HORIZONTAL_ALIGNMENT_CENTER,
	"right": HORIZONTAL_ALIGNMENT_RIGHT,
	"fill": HORIZONTAL_ALIGNMENT_FILL,
}
const VERTICAL_ALIGNMENTS := {
	"top": VERTICAL_ALIGNMENT_TOP,
	"center": VERTICAL_ALIGNMENT_CENTER,
	"bottom": VERTICAL_ALIGNMENT_BOTTOM,
	"fill": VERTICAL_ALIGNMENT_FILL,
}
const AUTOWRAP_MODES := {
	"off": TextServer.AUTOWRAP_OFF,
	"arbitrary": TextServer.AUTOWRAP_ARBITRARY,
	"word": TextServer.AUTOWRAP_WORD,
	"word_smart": TextServer.AUTOWRAP_WORD_SMART,
}


static func collect(tokens: Array) -> Dictionary:
	var profiles: Dictionary = {}
	var diagnostics: Array = []
	for token_value in tokens:
		var token: DslToken = token_value
		if token.type != DslToken.Type.AT_COMMAND:
			continue
		if _command_name(token.raw_text) != "dialogue_profile":
			continue
		_parse_declaration(token, profiles, diagnostics)
	return {"profiles": profiles, "diagnostics": diagnostics}


static func parse_mode_directive(
	raw_text: String,
	command_name: String,
	profiles: Dictionary,
	line: int,
) -> Dictionary:
	var diagnostics: Array = []
	var args := _strip_inline_comment(
		raw_text.substr(command_name.length() + 1).strip_edges())
	var parts := _split_args(args)
	if parts.is_empty():
		return {
			"mode": command_name,
			"profile_name": "",
			"profile": {},
			"diagnostics": diagnostics,
		}
	if parts[0] == "off":
		if command_name == "adv":
			_diagnostic(diagnostics, "error",
				"DslParser: @adv off is invalid; use @adv or @adv profile=name (line %d)"
				% line, line)
		if parts.size() > 1:
			_diagnostic(diagnostics, "error",
				"DslParser: @%s off does not accept other parameters (line %d)"
				% [command_name, line], line)
		return {
			"mode": "adv",
			"profile_name": "",
			"profile": {},
			"diagnostics": diagnostics,
		}

	var profile_name := ""
	for part_value in parts:
		var part := String(part_value)
		var equals := part.find("=")
		if equals == -1:
			_diagnostic(diagnostics, "error",
				"DslParser: @%s expects named parameters such as profile=novel, got '%s' (line %d)"
				% [command_name, part, line], line)
			continue
		var key := part.substr(0, equals).strip_edges()
		var value := _unquote(part.substr(equals + 1).strip_edges())
		if key != "profile":
			_diagnostic(diagnostics, "error",
				"DslParser: @%s has unknown parameter '%s' (line %d)"
				% [command_name, key, line], line)
			continue
		if value.is_empty():
			_diagnostic(diagnostics, "error",
				"DslParser: @%s profile cannot be empty (line %d)"
				% [command_name, line], line)
			continue
		profile_name = value

	var profile: Dictionary = {}
	if not profile_name.is_empty():
		if profiles.has(profile_name):
			profile = (profiles[profile_name] as Dictionary).duplicate(true)
		else:
			_diagnostic(diagnostics, "error",
				"DslParser: @%s references unknown dialogue profile '%s' (line %d)"
				% [command_name, profile_name, line], line)
	return {
		"mode": command_name,
		"profile_name": profile_name,
		"profile": profile,
		"diagnostics": diagnostics,
	}


static func _parse_declaration(
	token: DslToken,
	profiles: Dictionary,
	diagnostics: Array,
) -> void:
	var args := _strip_inline_comment(
		token.raw_text.substr("@dialogue_profile".length()).strip_edges())
	var parts := _split_args(args)
	if parts.is_empty():
		_diagnostic(diagnostics, "error",
			"DslParser: @dialogue_profile is missing a profile name (line %d)"
			% token.line, token.line)
		return
	var profile_name := _unquote(String(parts[0]))
	if not _valid_profile_name(profile_name):
		_diagnostic(diagnostics, "error",
			"DslParser: invalid dialogue profile name '%s' (line %d)"
			% [profile_name, token.line], token.line)
		return
	if not profiles.has(profile_name):
		profiles[profile_name] = {}
	var profile: Dictionary = profiles[profile_name]
	if parts.size() == 1:
		_diagnostic(diagnostics, "warning",
			"DslParser: dialogue profile '%s' declaration has no properties (line %d)"
			% [profile_name, token.line], token.line)
		return

	for index in range(1, parts.size()):
		var assignment := String(parts[index])
		var equals := assignment.find("=")
		if equals == -1:
			_diagnostic(diagnostics, "error",
				"DslParser: dialogue profile property '%s' must use key=value (line %d)"
				% [assignment, token.line], token.line)
			continue
		var key := assignment.substr(0, equals).strip_edges()
		var assignment_value := assignment.substr(equals + 1).strip_edges()
		var parsed: Dictionary
		if key in STRING_KEYS:
			parsed = _parse_string_property(
				key, assignment_value, token.line, diagnostics)
		else:
			parsed = _parse_property(
				key, _unquote(assignment_value), token.line, diagnostics, profile)
		if parsed["valid"] and parsed.get("store", true):
			profile[key] = parsed["value"]
	profiles[profile_name] = profile


static func _parse_property(
	key: String,
	raw_value: String,
	line: int,
	diagnostics: Array,
	profile: Dictionary,
) -> Dictionary:
	if key in VECTOR_KEYS:
		return _parse_vector4(key, raw_value, line, diagnostics)
	if key in COLOR_KEYS:
		if not Color.html_is_valid(raw_value):
			return _invalid(diagnostics,
				"DslParser: dialogue profile %s must be an HTML color such as #ffffff00 (line %d)"
				% [key, line], line)
		return _valid(Color.from_string(raw_value, Color.WHITE))
	if key in BOOL_KEYS:
		if raw_value != "true" and raw_value != "false":
			return _invalid(diagnostics,
				"DslParser: dialogue profile %s must be true or false (line %d)"
				% [key, line], line)
		return _valid(raw_value == "true")
	match key:
		"horizontal_alignment":
			return _parse_enum(key, raw_value, HORIZONTAL_ALIGNMENTS, line, diagnostics)
		"vertical_alignment":
			return _parse_enum(key, raw_value, VERTICAL_ALIGNMENTS, line, diagnostics)
		"autowrap_mode":
			return _parse_enum(key, raw_value, AUTOWRAP_MODES, line, diagnostics)
		"line_spacing":
			if not raw_value.is_valid_int():
				return _invalid(diagnostics,
					"DslParser: dialogue profile line_spacing must be an integer (line %d)"
					% line, line)
			return _valid(raw_value.to_int())
		"show", "hide":
			var visibility: Dictionary = profile.get("visibility_groups", {}).duplicate()
			var visible := key == "show"
			if raw_value.is_empty():
				return _invalid(diagnostics,
					"DslParser: dialogue profile %s requires at least one group name (line %d)"
					% [key, line], line)
			for group_value in raw_value.split(","):
				var group_name := String(group_value).strip_edges()
				if group_name.is_empty() or group_name.contains("="):
					return _invalid(diagnostics,
						"DslParser: dialogue profile %s contains an invalid group name (line %d)"
						% [key, line], line)
				visibility[group_name] = visible
			profile["visibility_groups"] = visibility
			# show/hide are authoring aliases; only the merged visibility map is runtime data.
			return {"valid": true, "store": false, "value": null}
		_:
			return _invalid(diagnostics,
				"DslParser: unknown dialogue profile property '%s' (line %d)"
				% [key, line], line)


static func _parse_vector4(
	key: String,
	raw_value: String,
	line: int,
	diagnostics: Array,
) -> Dictionary:
	var components := raw_value.split(",")
	if components.size() != 4:
		return _invalid(diagnostics,
			"DslParser: dialogue profile %s requires four comma-separated numbers (line %d)"
			% [key, line], line)
	var values: Array[float] = []
	for component_value in components:
		var component := String(component_value).strip_edges()
		if not component.is_valid_float() or not is_finite(component.to_float()):
			return _invalid(diagnostics,
				"DslParser: dialogue profile %s must contain only finite numbers (line %d)"
				% [key, line], line)
		values.append(component.to_float())
	var vector := Vector4(values[0], values[1], values[2], values[3])
	if key.ends_with("_anchors"):
		if minf(minf(vector.x, vector.y), minf(vector.z, vector.w)) < 0.0 \
			or maxf(maxf(vector.x, vector.y), maxf(vector.z, vector.w)) > 1.0:
			return _invalid(diagnostics,
				"DslParser: dialogue profile %s must stay inside the 0..1 range (line %d)"
				% [key, line], line)
		if vector.x > vector.z or vector.y > vector.w:
			return _invalid(diagnostics,
				"DslParser: dialogue profile %s must be ordered left <= right and top <= bottom (line %d)"
				% [key, line], line)
	if key == "text_margins" \
		and minf(minf(vector.x, vector.y), minf(vector.z, vector.w)) < 0.0:
		return _invalid(diagnostics,
			"DslParser: dialogue profile text_margins cannot be negative (line %d)"
			% line, line)
	return _valid(vector)


static func _parse_enum(
	key: String,
	raw_value: String,
	values: Dictionary,
	line: int,
	diagnostics: Array,
) -> Dictionary:
	if not values.has(raw_value):
		return _invalid(diagnostics,
			"DslParser: dialogue profile %s has unsupported value '%s' (line %d)"
			% [key, raw_value, line], line)
	return _valid(values[raw_value])


static func _parse_string_property(
	key: String,
	raw_value: String,
	line: int,
	diagnostics: Array,
) -> Dictionary:
	var closing_quote := ""
	if raw_value.begins_with("\""):
		closing_quote = "\""
	elif raw_value.begins_with("'"):
		closing_quote = "'"
	elif raw_value.begins_with("“"):
		closing_quote = "”"
	else:
		return _invalid(diagnostics,
			"DslParser: dialogue profile %s must be a quoted string (line %d)"
			% [key, line], line)

	var decoded := ""
	var escaped := false
	for index in range(1, raw_value.length()):
		var character := raw_value.substr(index, 1)
		if escaped:
			match character:
				"\\":
					decoded += "\\"
				"\"":
					decoded += "\""
				"'":
					decoded += "'"
				"n":
					decoded += "\n"
				"r":
					decoded += "\r"
				"t":
					decoded += "\t"
				_:
					return _invalid(diagnostics,
						"DslParser: dialogue profile %s has invalid escape sequence '\\%s' (line %d)"
						% [key, character, line], line)
			escaped = false
			continue
		if character == "\\":
			escaped = true
			continue
		if character == closing_quote:
			if index != raw_value.length() - 1:
				return _invalid(diagnostics,
					"DslParser: dialogue profile %s must contain exactly one quoted string (line %d)"
					% [key, line], line)
			if decoded.contains("[") or decoded.contains("]"):
				return _invalid(diagnostics,
					"DslParser: dialogue profile %s is plain text and cannot contain BBCode brackets (line %d)"
					% [key, line], line)
			return _valid(decoded)
		decoded += character

	return _invalid(diagnostics,
		"DslParser: dialogue profile %s has an unterminated quoted string (line %d)"
		% [key, line], line)


static func _valid(value: Variant) -> Dictionary:
	return {"valid": true, "value": value}


static func _invalid(diagnostics: Array, message: String, line: int) -> Dictionary:
	_diagnostic(diagnostics, "error", message, line)
	return {"valid": false, "value": null}


static func _diagnostic(
	diagnostics: Array,
	level: String,
	message: String,
	line: int,
) -> void:
	diagnostics.append({"level": level, "message": message, "line": line})


static func _valid_profile_name(profile_name: String) -> bool:
	return (
		not profile_name.is_empty()
		and not profile_name.contains("=")
		and not profile_name.contains(",")
		and not profile_name.contains("/")
	)


static func _command_name(raw: String) -> String:
	var after_at := raw.substr(1).strip_edges()
	for index in range(after_at.length()):
		if _is_inline_whitespace(after_at.substr(index, 1)):
			return after_at.substr(0, index)
	return after_at


static func _split_args(text: String) -> Array[String]:
	var result: Array[String] = []
	var current := ""
	var closing_quote := ""
	var escaped := false
	for index in range(text.length()):
		var character := text.substr(index, 1)
		if not closing_quote.is_empty():
			current += character
			if escaped:
				escaped = false
			elif character == "\\":
				escaped = true
			elif character == closing_quote:
				closing_quote = ""
			continue
		match character:
			"\"", "'":
				closing_quote = character
				current += character
			"“":
				closing_quote = "”"
				current += character
			_:
				if _is_inline_whitespace(character):
					if not current.is_empty():
						result.append(current)
						current = ""
				else:
					current += character
	if not current.is_empty():
		result.append(current)
	return result


static func _strip_inline_comment(text: String) -> String:
	if text.length() < 2:
		return text
	var closing_quote := ""
	var escaped := false
	for index in range(text.length() - 1):
		var character := text.substr(index, 1)
		if not closing_quote.is_empty():
			if escaped:
				escaped = false
			elif character == "\\":
				escaped = true
			elif character == closing_quote:
				closing_quote = ""
			continue
		match character:
			"\"", "'":
				closing_quote = character
			"“":
				closing_quote = "”"
			"/":
				if text.substr(index + 1, 1) == "/" \
					and (index == 0 or _is_inline_whitespace(text.substr(index - 1, 1))):
					return text.substr(0, index).strip_edges()
	return text


static func _unquote(value: String) -> String:
	if value.length() < 2:
		return value
	var first := value.substr(0, 1)
	var last := value.substr(value.length() - 1, 1)
	if (first == "\"" and last == "\"") \
		or (first == "'" and last == "'") \
		or (first == "“" and last == "”"):
		return value.substr(1, value.length() - 2)
	return value


static func _is_inline_whitespace(character: String) -> bool:
	return not character.is_empty() and character.strip_edges().is_empty()
