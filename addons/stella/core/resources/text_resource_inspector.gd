## Side-effect-free inspector for Godot text resources used by Stella scenes.
## Malformed or semantically degraded text is rejected before ResourceLoader can
## echo authored paths, types, or values to engine diagnostics.
class_name TextResourceInspector
extends RefCounted

const MAX_TEXT_RESOURCE_BYTES = 8 * 1024 * 1024
const MAX_RESOURCE_TAG_BYTES = 512 * 1024
const MAX_QUOTED_ATTRIBUTE_BYTES = 256 * 1024


class InspectionResult extends RefCounted:
	var ok: bool = false
	var dependencies: Array[Dictionary] = []
	var format: String = ""
	var header: Dictionary = {}
	var node_paths: Dictionary = {}
	## Compact effective-tree model. Only nodes authored or queried by an
	## override are materialized; nested instance descendants resolve lazily.
	var scene_model: Dictionary = {}
	var matches_expected_type: bool = true
	## Unique canonical path + expected-type inspections performed by the most
	## recent top-level transaction. Cached repeated instances do not increment it.
	var visited_resource_count: int = 0


	func to_dictionary() -> Dictionary:
		return {
			"ok": ok,
			"dependencies": dependencies.duplicate(true),
			"format": format,
			"header": header.duplicate(true),
			"node_paths": node_paths.duplicate(true),
			"scene_model": scene_model.duplicate(true),
			"matches_expected_type": matches_expected_type,
			"visited_resource_count": visited_resource_count,
		}


var _active_paths: Dictionary = {}
var _completed_results: Dictionary = {}
var _inspection_depth: int = 0
var _transaction_visit_count: int = 0
var _last_inspection_visit_count: int = 0


## Decode the String grammar shared by Godot 4.6 text-resource tags and
## serialized Variant values. The returned `end` points just after the closing
## quote. Raw source is never included in errors or metadata on failure.
static func _decode_resource_string(
	text: String,
	quote_index: int,
	max_raw_bytes: int = -1,
) -> Dictionary:
	if (
		quote_index < 0
		or quote_index >= text.length()
		or text[quote_index] != "\""
	):
		return {"ok": false}
	var index := quote_index + 1
	var raw_start := index
	var segment_start := index
	var parts := PackedStringArray()
	while index < text.length():
		var character := text[index]
		if character == "\"":
			if (
				max_raw_bytes >= 0
				and text.substr(raw_start, index - raw_start).to_utf8_buffer().size()
				> max_raw_bytes
			):
				return {"ok": false}
			if segment_start < index:
				parts.append(text.substr(segment_start, index - segment_start))
			return {
				"ok": true,
				"value": "".join(parts),
				"end": index + 1,
			}
		if character != "\\":
			index += 1
			continue

		if segment_start < index:
			parts.append(text.substr(segment_start, index - segment_start))
		index += 1
		if index >= text.length():
			return {"ok": false}
		var escaped := text[index]
		index += 1
		match escaped:
			"\"":
				parts.append("\"")
			"\\":
				parts.append("\\")
			"/":
				parts.append("/")
			"b":
				parts.append(String.chr(8))
			"f":
				parts.append(String.chr(12))
			"n":
				parts.append("\n")
			"r":
				parts.append("\r")
			"t":
				parts.append("\t")
			"u", "U":
				var digit_count := 4 if escaped == "u" else 6
				var decoded := _decode_resource_unicode_digits(
					text,
					index,
					digit_count,
				)
				if not decoded.get("ok", false):
					return {"ok": false}
				index = decoded["end"]
				var codepoint: int = decoded["codepoint"]
				if codepoint >= 0xD800 and codepoint <= 0xDBFF:
					if (
						index + 1 >= text.length()
						or text[index] != "\\"
						or text[index + 1] not in ["u", "U"]
					):
						return {"ok": false}
					var low_kind := text[index + 1]
					var low_count := 4 if low_kind == "u" else 6
					var decoded_low := _decode_resource_unicode_digits(
						text,
						index + 2,
						low_count,
					)
					if not decoded_low.get("ok", false):
						return {"ok": false}
					var low_codepoint: int = decoded_low["codepoint"]
					if low_codepoint < 0xDC00 or low_codepoint > 0xDFFF:
						return {"ok": false}
					index = decoded_low["end"]
					codepoint = (
						0x10000
						+ ((codepoint - 0xD800) << 10)
						+ low_codepoint - 0xDC00
					)
				elif codepoint >= 0xDC00 and codepoint <= 0xDFFF:
					return {"ok": false}
				if codepoint > 0x10FFFF:
					codepoint = 0xFFFD
				parts.append(String.chr(codepoint))
			_:
				# VariantParser drops the slash for unknown escapes.
				parts.append(escaped)
		segment_start = index
	return {"ok": false}


static func _decode_resource_unicode_digits(
	text: String,
	start: int,
	digit_count: int,
) -> Dictionary:
	if start < 0 or start + digit_count > text.length():
		return {"ok": false}
	var codepoint := 0
	for index in range(start, start + digit_count):
		var digit := _resource_hex_digit_value(text[index])
		if digit < 0:
			return {"ok": false}
		codepoint = codepoint * 16 + digit
	return {
		"ok": true,
		"codepoint": codepoint,
		"end": start + digit_count,
	}


static func _resource_hex_digit_value(character: String) -> int:
	if character >= "0" and character <= "9":
		return character.unicode_at(0) - "0".unicode_at(0)
	var lower := character.to_lower()
	if lower >= "a" and lower <= "f":
		return 10 + lower.unicode_at(0) - "a".unicode_at(0)
	return -1


static func _safe_decimal_integer_literal(literal: String) -> bool:
	if literal.is_empty():
		return false
	var digit_start := 0
	if literal[0] in ["+", "-"]:
		digit_start = 1
	if digit_start == literal.length():
		return false
	for index in range(digit_start, literal.length()):
		if literal[index] < "0" or literal[index] > "9":
			return false
	while digit_start < literal.length() - 1 and literal[digit_start] == "0":
		digit_start += 1
	var digits := literal.substr(digit_start)
	var limit := "9223372036854775808" if literal.begins_with("-") else (
		"9223372036854775807"
	)
	if digits.length() != limit.length():
		return digits.length() < limit.length()
	for index in digits.length():
		if digits[index] == limit[index]:
			continue
		return digits[index] < limit[index]
	return true


static func _normalized_resource_id_value(value: String, quoted: bool) -> String:
	if value.is_empty():
		return ""
	var digit_start := 0
	if value[0] in ["+", "-"]:
		digit_start = 1
	var signed_decimal := digit_start < value.length()
	for index in range(digit_start, value.length()):
		if value[index] < "0" or value[index] > "9":
			signed_decimal = false
			break
	if not signed_decimal:
		return "s:" + value if quoted else ""
	var magnitude_start := digit_start
	while (
		magnitude_start < value.length() - 1
		and value[magnitude_start] == "0"
	):
		magnitude_start += 1
	var has_quoted_spelling_difference := (
		quoted
		and (
			value.begins_with("+")
			or magnitude_start > digit_start
			or not _safe_decimal_integer_literal(value)
		)
	)
	if has_quoted_spelling_difference:
		return "s:" + value
	if not _safe_decimal_integer_literal(value):
		return ""
	var magnitude := value.substr(magnitude_start)
	if magnitude == "0":
		return "n:0"
	return "n:" + ("-" if value.begins_with("-") else "") + magnitude


func inspect(path: String, expected_type: String = "") -> InspectionResult:
	var is_top_level := _inspection_depth == 0
	if is_top_level:
		_active_paths.clear()
		_completed_results.clear()
		_transaction_visit_count = 0
	_inspection_depth += 1
	var result := _inspect_cached(path, expected_type)
	_inspection_depth -= 1
	if is_top_level:
		_last_inspection_visit_count = _transaction_visit_count
		result.visited_resource_count = _transaction_visit_count
		_active_paths.clear()
		_completed_results.clear()
	return result


func get_last_inspection_visit_count() -> int:
	return _last_inspection_visit_count


func _inspect_cached(path: String, expected_type: String) -> InspectionResult:
	var canonical_path := path.simplify_path()
	var cache_key := canonical_path + "\n" + expected_type
	if _completed_results.has(cache_key):
		return _inspection_result_from_dictionary(_completed_results[cache_key])
	if _active_paths.has(canonical_path):
		return InspectionResult.new()
	_active_paths[canonical_path] = true
	_transaction_visit_count += 1
	var raw := _inspect_dictionary(canonical_path)
	var result := _inspection_result_from_dictionary(raw)
	if result.ok and not expected_type.is_empty():
		result.matches_expected_type = _text_resource_declares_type(
			canonical_path,
			expected_type,
			result,
		)
	_active_paths.erase(canonical_path)
	_completed_results[cache_key] = result.to_dictionary()
	return _inspection_result_from_dictionary(_completed_results[cache_key])


func _inspection_result_from_dictionary(raw: Dictionary) -> InspectionResult:
	var result := InspectionResult.new()
	result.ok = raw.get("ok", false)
	result.dependencies.assign(raw.get("dependencies", []))
	result.format = raw.get("format", "")
	result.header = raw.get("header", {}).duplicate(true)
	result.node_paths = raw.get("node_paths", {}).duplicate(true)
	result.scene_model = raw.get("scene_model", {}).duplicate(true)
	result.matches_expected_type = raw.get("matches_expected_type", true)
	result.visited_resource_count = raw.get("visited_resource_count", 0)
	return result


## Parse serialized Variant values without evaluating them or handing malformed
## private source to Godot's resource parser. The grammar intentionally covers
## the canonical primitives/containers/constructors emitted by Godot 4.x text
## resources; an unsupported token makes the complete source fail preflight.
class _ResourceValueParser:
	var _text: String
	var _index: int = 0
	var _references: Array[Dictionary] = []


	func _init(text: String) -> void:
		_text = text


	func parse() -> Dictionary:
		_skip_ignored()
		var value := _parse_value()
		if not value.get("ok", false):
			return {"ok": false, "references": []}
		_skip_ignored()
		if _index != _text.length():
			return {"ok": false, "references": []}
		return {
			"ok": true,
			"references": _references,
		}


	func _parse_value() -> Dictionary:
		_skip_ignored()
		if _index >= _text.length():
			return {"ok": false}
		var character := _text[_index]
		if character == "\"":
			return _parse_string(false)
		if (
			character in ["&", "^"]
			and _index + 1 < _text.length()
			and _text[_index + 1] == "\""
		):
			return _parse_string(true)
		if character == "[":
			return _parse_array()
		if character == "{":
			return _parse_dictionary()
		if character == "+" or character == "-" or _is_digit(character):
			return _parse_number()
		if _is_identifier_start(character):
			return _parse_identifier_or_constructor()
		return {"ok": false}


	func _parse_string(has_prefix: bool) -> Dictionary:
		if has_prefix:
			_index += 1
		if _index >= _text.length() or _text[_index] != "\"":
			return {"ok": false}
		var decoded := TextResourceInspector._decode_resource_string(
			_text,
			_index,
		)
		if not decoded.get("ok", false):
			return {"ok": false}
		_index = decoded["end"]
		return {
			"ok": true,
			"kind": "string",
			"value": decoded["value"],
		}


	func _parse_array() -> Dictionary:
		_index += 1
		var values: Array[Dictionary] = []
		_skip_ignored()
		if _consume("]"):
			return {"ok": true, "kind": "array", "values": values}
		while true:
			var value := _parse_value()
			if not value.get("ok", false):
				return {"ok": false}
			values.append(value)
			_skip_ignored()
			if _consume("]"):
				return {"ok": true, "kind": "array", "values": values}
			if not _consume(","):
				return {"ok": false}
			_skip_ignored()
			if _consume("]"):
				return {"ok": true, "kind": "array", "values": values}
		return {"ok": false}


	func _parse_dictionary() -> Dictionary:
		_index += 1
		var entries: Array[Dictionary] = []
		_skip_ignored()
		if _consume("}"):
			return {"ok": true, "kind": "dictionary", "entries": entries}
		while true:
			var key := _parse_value()
			if not key.get("ok", false):
				return {"ok": false}
			_skip_ignored()
			if not _consume(":"):
				return {"ok": false}
			var value := _parse_value()
			if not value.get("ok", false):
				return {"ok": false}
			entries.append({"key": key, "value": value})
			_skip_ignored()
			if _consume("}"):
				return {"ok": true, "kind": "dictionary", "entries": entries}
			if not _consume(","):
				return {"ok": false}
			_skip_ignored()
			if _consume("}"):
				return {"ok": true, "kind": "dictionary", "entries": entries}
		return {"ok": false}


	func _parse_number() -> Dictionary:
		var start := _index
		if _text[_index] in ["+", "-"]:
			_index += 1
		if _consume_word("inf") or _consume_word("nan"):
			return {
				"ok": true,
				"kind": "number",
				"value": _text.substr(start, _index - start),
			}
		var saw_digit := false
		if (
			_index + 1 < _text.length()
			and _text[_index] == "0"
			and _text[_index + 1].to_lower() == "x"
		):
			_index += 2
			var hex_start := _index
			while _index < _text.length() and _is_hex_digit(_text[_index]):
				_index += 1
			if _index == hex_start:
				return {"ok": false}
			return {
				"ok": true,
				"kind": "number",
				"value": _text.substr(start, _index - start),
			}
		while _index < _text.length() and _is_digit(_text[_index]):
			saw_digit = true
			_index += 1
		if _index < _text.length() and _text[_index] == ".":
			_index += 1
			while _index < _text.length() and _is_digit(_text[_index]):
				saw_digit = true
				_index += 1
		if not saw_digit:
			_index = start
			return {"ok": false}
		if _index < _text.length() and _text[_index].to_lower() == "e":
			_index += 1
			if _index < _text.length() and _text[_index] in ["+", "-"]:
				_index += 1
			var exponent_start := _index
			while _index < _text.length() and _is_digit(_text[_index]):
				_index += 1
			if _index == exponent_start:
				return {"ok": false}
		if (
			_index < _text.length()
			and _is_identifier_continue(_text[_index])
		):
			return {"ok": false}
		return {
			"ok": true,
			"kind": "number",
			"value": _text.substr(start, _index - start),
		}


	func _parse_identifier_or_constructor() -> Dictionary:
		var name := _parse_identifier()
		if name in ["true", "false"]:
			return {"ok": true, "kind": "bool"}
		if name == "null":
			return {"ok": true, "kind": "null"}
		if name in ["inf", "nan"]:
			return {"ok": true, "kind": "number"}

		_skip_horizontal_space()
		var generic := ""
		if _index < _text.length() and _text[_index] == "[":
			generic = _parse_generic_type_list()
			if generic.is_empty():
				return {"ok": false}
			_skip_horizontal_space()
		if not _consume("("):
			return {"ok": false}
		var arguments: Array[Dictionary] = []
		_skip_ignored()
		if not _consume(")"):
			while true:
				var argument := _parse_value()
				if not argument.get("ok", false):
					return {"ok": false}
				arguments.append(argument)
				_skip_ignored()
				if _consume(")"):
					break
				if not _consume(","):
					return {"ok": false}
				_skip_ignored()
				if _consume(")"):
					break
		if not _constructor_arguments_are_valid(name, generic, arguments):
			return {"ok": false}
		if name in ["ExtResource", "SubResource"]:
			_references.append({
				"kind": name,
				"id": _reference_id(arguments[0]),
			})
		return {
			"ok": true,
			"kind": "constructor",
			"name": name,
			"arguments": arguments,
		}


	func _parse_generic_type_list() -> String:
		var start := _index
		var depth := 0
		while _index < _text.length():
			var character := _text[_index]
			if character == "[":
				depth += 1
			elif character == "]":
				depth -= 1
				if depth == 0:
					_index += 1
					return _text.substr(start, _index - start)
			elif not (
				character in [" ", "\t", "\r", "\n", ",", ".", "_"]
				or _is_digit(character)
				or character >= "A" and character <= "Z"
				or character >= "a" and character <= "z"
			):
				return ""
			_index += 1
		return ""


	func _constructor_arguments_are_valid(
		name: String,
		generic: String,
		arguments: Array[Dictionary],
	) -> bool:
		if not _constructor_is_known(name):
			return false
		if not generic.is_empty() and name not in ["Array", "Dictionary"]:
			return false
		if name in ["ExtResource", "SubResource"]:
			return (
				arguments.size() == 1
				and not _reference_id(arguments[0]).is_empty()
			)
		if name in ["NodePath", "String", "StringName"]:
			return (
				arguments.size() == 1
				and arguments[0].get("kind", "") == "string"
			)
		if name in ["Callable", "Signal"]:
			return arguments.is_empty()
		if name == "RID":
			return (
				arguments.is_empty()
				or _arguments_are_numbers(arguments, 1)
			)
		var exact_numeric_arity := {
			"Vector2": 2, "Vector2i": 2,
			"Vector3": 3, "Vector3i": 3,
			"Vector4": 4, "Vector4i": 4,
			"Rect2": 4, "Rect2i": 4,
			"Transform2D": 6,
			"Plane": 4,
			"Quaternion": 4,
			"AABB": 6,
			"Basis": 9,
			"Transform3D": 12,
			"Projection": 16,
		}
		if exact_numeric_arity.has(name):
			return _arguments_are_numbers(arguments, exact_numeric_arity[name])
		if name == "Color":
			return (
				_arguments_are_numbers(arguments, 4)
				or (
					arguments.size() == 1
					and arguments[0].get("kind", "") == "string"
				)
			)
		if name == "Array":
			return (
				arguments.is_empty()
				or (
					arguments.size() == 1
					and arguments[0].get("kind", "") == "array"
				)
			)
		if name == "Dictionary":
			return (
				arguments.is_empty()
				or (
					arguments.size() == 1
					and arguments[0].get("kind", "") == "dictionary"
				)
			)
		if name in [
			"PackedByteArray", "PackedInt32Array", "PackedInt64Array",
			"PackedFloat32Array", "PackedFloat64Array",
		]:
			return _arguments_are_numbers(arguments, arguments.size())
		if name == "PackedStringArray":
			return _arguments_have_kind(arguments, "string")
		var packed_numeric_width := {
			"PackedVector2Array": 2,
			"PackedVector3Array": 3,
			"PackedVector4Array": 4,
			"PackedColorArray": 4,
		}
		if packed_numeric_width.has(name):
			var width: int = packed_numeric_width[name]
			return (
				arguments.size() % width == 0
				and _arguments_are_numbers(arguments, arguments.size())
			)
		# Object()/EncodedObjectAsID() are not emitted for resource properties in
		# supported Stella scenes, and safely validating their class/property
		# semantics would require executing constructors. Reject them before the
		# Godot parser can echo malformed private tokens.
		return false


	func _reference_id(argument: Dictionary) -> String:
		var kind: String = argument.get("kind", "")
		var value: String = argument.get("value", "")
		if kind == "string":
			return _normalized_resource_id(value, true)
		if kind == "number":
			return _normalized_resource_id(value, false)
		return ""


	func _normalized_resource_id(value: String, quoted: bool) -> String:
		return TextResourceInspector._normalized_resource_id_value(value, quoted)


	func _arguments_are_numbers(
		arguments: Array[Dictionary],
		expected_count: int,
	) -> bool:
		if arguments.size() != expected_count:
			return false
		for argument: Dictionary in arguments:
			if argument.get("kind", "") != "number":
				return false
		return true


	func _arguments_have_kind(
		arguments: Array[Dictionary],
		expected_kind: String,
	) -> bool:
		for argument: Dictionary in arguments:
			if argument.get("kind", "") != expected_kind:
				return false
		return true


	func _constructor_is_known(name: String) -> bool:
		return name in [
			"AABB", "Array", "Basis", "Callable", "Color", "Dictionary",
			"EncodedObjectAsID", "ExtResource", "NodePath", "Object", "Plane",
			"Projection", "Quaternion", "Rect2", "Rect2i", "RID", "Signal",
			"String", "StringName", "SubResource", "Transform2D", "Transform3D",
			"Vector2", "Vector2i", "Vector3", "Vector3i", "Vector4", "Vector4i",
			"PackedByteArray", "PackedInt32Array", "PackedInt64Array",
			"PackedFloat32Array", "PackedFloat64Array", "PackedStringArray",
			"PackedVector2Array", "PackedVector3Array", "PackedVector4Array",
			"PackedColorArray",
		]


	func _parse_identifier() -> String:
		var start := _index
		_index += 1
		while (
			_index < _text.length()
			and _is_identifier_continue(_text[_index])
		):
			_index += 1
		return _text.substr(start, _index - start)


	func _skip_ignored() -> void:
		while _index < _text.length():
			var character := _text[_index]
			if character in [" ", "\t", "\r", "\n"]:
				_index += 1
				continue
			if character == ";":
				while _index < _text.length() and _text[_index] != "\n":
					_index += 1
				continue
			break


	func _skip_horizontal_space() -> void:
		while _index < _text.length() and _text[_index] in [" ", "\t"]:
			_index += 1


	func _consume(expected: String) -> bool:
		if _index >= _text.length() or _text[_index] != expected:
			return false
		_index += 1
		return true


	func _consume_word(word: String) -> bool:
		if _text.substr(_index, word.length()).to_lower() != word:
			return false
		var end := _index + word.length()
		if end < _text.length() and _is_identifier_continue(_text[end]):
			return false
		_index = end
		return true


	func _is_digit(character: String) -> bool:
		return character >= "0" and character <= "9"


	func _is_hex_digit(character: String) -> bool:
		var lower := character.to_lower()
		return _is_digit(character) or lower >= "a" and lower <= "f"


	func _is_identifier_start(character: String) -> bool:
		return (
			character == "_"
			or character >= "A" and character <= "Z"
			or character >= "a" and character <= "z"
		)


	func _is_identifier_continue(character: String) -> bool:
		return _is_identifier_start(character) or _is_digit(character)

func _inspect_dictionary(path: String) -> Dictionary:
	if not FileAccess.file_exists(path) and not ResourceLoader.exists(path):
		return {"ok": false, "dependencies": []}
	var extension := path.get_extension().to_lower()
	if extension not in ["tscn", "tres"]:
		return _structured_resource_dependencies(path)
	var file := FileAccess.open(path, FileAccess.READ)
	# Export remaps source-looking paths to binary resources that are loadable
	# through ResourceLoader but intentionally unavailable through FileAccess.
	if file == null:
		return _structured_resource_dependencies(path)
	if file.get_length() > MAX_TEXT_RESOURCE_BYTES:
		return {"ok": false, "dependencies": []}
	var bytes := file.get_buffer(file.get_length())
	var read_error := file.get_error()
	file.close()
	if read_error not in [OK, ERR_FILE_EOF]:
		return {"ok": false, "dependencies": []}
	if bytes.is_empty():
		return {"ok": false, "dependencies": []}
	# Only explicit Godot binary resource magic may enter the structured loader
	# path. A malformed text file that starts with whitespace/comment data must
	# stay in the side-effect-free parser below; otherwise ResourceLoader can
	# echo its private source tokens and paths while reporting parse failures.
	if _resource_bytes_have_binary_magic(bytes):
		return _structured_resource_dependencies(path)
	if bytes.has(0):
		return {"ok": false, "dependencies": []}
	if (
		bytes.size() >= 3
		and bytes[0] == 0xEF
		and bytes[1] == 0xBB
		and bytes[2] == 0xBF
	):
		# Godot 4.6's text resource loader does not accept a UTF-8 BOM. Reject
		# it here so the later real load cannot echo the private resource path.
		return {"ok": false, "dependencies": []}
	var text := bytes.get_string_from_utf8()
	if text.to_utf8_buffer() != bytes:
		return {"ok": false, "dependencies": []}
	var lines := text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
	if lines.is_empty():
		return {"ok": false, "dependencies": []}
	var expected_header := "gd_scene" if extension == "tscn" else "gd_resource"
	var header_line_index := -1
	var header_text := ""
	for line_index in lines.size():
		var candidate := _strip_resource_comment(lines[line_index]).strip_edges()
		if candidate.is_empty():
			continue
		header_line_index = line_index
		header_text = candidate
		break
	if header_line_index < 0:
		return {"ok": false, "dependencies": []}
	var header := _parse_resource_tag(header_text)
	if (
		not header.get("ok", false)
		or header.get("name", "") != expected_header
		or not _resource_header_tag_is_valid(header, extension)
	):
		return {"ok": false, "dependencies": []}

	var dependencies: Array[Dictionary] = []
	var ext_resource_ids: Dictionary = {}
	var ext_resources: Dictionary = {}
	var sub_resource_ids: Dictionary = {}
	var scene_structure_tags: Array[Dictionary] = []
	var resource_references: Array[Dictionary] = []
	if not _append_resource_tag_references(header, resource_references):
		return {"ok": false, "dependencies": []}
	var format_state := {
		"stage": 0,
		"node_count": 0,
		"main_resource_count": 0,
		"allows_assignments": false,
	}
	var assignment_state: Dictionary = {}
	for line_index in range(header_line_index + 1, lines.size()):
		var raw_line: String = lines[line_index]
		if not assignment_state.is_empty():
			assignment_state["value_parts"].append(raw_line)
			if not _scan_resource_value_fragment(raw_line, assignment_state):
				return {"ok": false, "dependencies": []}
			if assignment_state.get("complete", false):
				if not _append_resource_value_references(
					"\n".join(assignment_state["value_parts"]),
					resource_references,
				):
					return {"ok": false, "dependencies": []}
				assignment_state = {}
			continue

		var stripped := _strip_resource_comment(raw_line).strip_edges()
		if stripped.is_empty():
			continue
		if stripped.begins_with("["):
			var tag := _parse_resource_tag(stripped)
			if (
				not tag.get("ok", false)
				or not _resource_body_tag_is_valid(
					tag,
					extension,
					format_state,
				)
			):
				return {"ok": false, "dependencies": []}
			if not _append_resource_tag_references(tag, resource_references):
				return {"ok": false, "dependencies": []}
			if tag["name"] in ["node", "connection", "editable"]:
				scene_structure_tags.append(tag.duplicate(true))
			if tag["name"] == "ext_resource":
				var attributes: Dictionary = tag["attributes"]
				var declared_type: String = attributes.get("type", "")
				var resource_id := _resource_id_key(tag, "id")
				var dependency_path := _resource_dependency_path_from_attributes(
					attributes,
				)
				if (
					declared_type.is_empty()
					or resource_id.is_empty()
					or ext_resource_ids.has(resource_id)
					or dependency_path.is_empty()
				):
					return {"ok": false, "dependencies": []}
				ext_resource_ids[resource_id] = true
				ext_resources[resource_id] = {
					"path": dependency_path,
					"type": declared_type,
				}
				dependencies.append({
					"path": dependency_path,
					"type": declared_type,
				})
			elif tag["name"] == "sub_resource":
				var sub_id := _resource_id_key(tag, "id")
				if sub_id.is_empty() or sub_resource_ids.has(sub_id):
					return {"ok": false, "dependencies": []}
				sub_resource_ids[sub_id] = true
			continue
		if not format_state.get("allows_assignments", false):
			return {"ok": false, "dependencies": []}
		assignment_state = _begin_resource_assignment(stripped)
		if not assignment_state.get("ok", false):
			return {"ok": false, "dependencies": []}
		if assignment_state.get("complete", false):
			if not _append_resource_value_references(
				"\n".join(assignment_state["value_parts"]),
				resource_references,
			):
				return {"ok": false, "dependencies": []}
			assignment_state = {}
	if not _resource_references_are_declared(
		resource_references,
		ext_resource_ids,
		sub_resource_ids,
	):
		return {"ok": false, "dependencies": []}
	if (
		not assignment_state.is_empty()
		or not _resource_format_state_is_complete(extension, format_state)
	):
		return {"ok": false, "dependencies": []}
	var node_paths: Dictionary = {}
	var scene_model: Dictionary = {}
	if extension == "tscn":
		var scene_structure := _inspect_scene_structure(
			scene_structure_tags,
			ext_resources,
		)
		if not scene_structure.get("ok", false):
			return {"ok": false, "dependencies": []}
		node_paths = scene_structure.get("node_paths", {})
		scene_model = scene_structure.get("scene_model", {})
	return {
		"ok": true,
		"dependencies": dependencies,
		"format": "text",
		"header": header,
		"node_paths": node_paths,
		"scene_model": scene_model,
	}


func _inspect_scene_structure(
	tags: Array[Dictionary],
	ext_resources: Dictionary,
) -> Dictionary:
	var scene_model := {
		"nodes": {},
		"instances": {},
	}
	var node_paths: Dictionary = scene_model["nodes"]
	var instance_paths: Dictionary = scene_model["instances"]
	var node_tags: Array[Dictionary] = []
	var trailing_tags: Array[Dictionary] = []
	for tag: Dictionary in tags:
		if tag.get("name", "") == "node":
			node_tags.append(tag)
		else:
			trailing_tags.append(tag)
	if node_tags.is_empty():
		return {"ok": false}

	for node_index in node_tags.size():
		var tag: Dictionary = node_tags[node_index]
		var attributes: Dictionary = tag.get("attributes", {})
		var name: String = attributes.get("name", "")
		if not _scene_node_name_is_valid(name):
			return {"ok": false}
		var has_type := attributes.has("type")
		var has_instance := attributes.has("instance")
		if has_type and has_instance:
			return {"ok": false}

		if node_index == 0:
			if attributes.has("owner") or not has_type and not has_instance:
				return {"ok": false}
			if has_type:
				node_paths["."] = String(attributes["type"])
			else:
				var inherited := _scene_instance_dependency(
					String(attributes["instance"]),
					ext_resources,
				)
				if not inherited.get("ok", false):
					return {"ok": false}
				instance_paths["."] = inherited["path"]
				var inherited_type := _scene_model_node_type(
					scene_model,
					".",
					{},
				)
				if inherited_type.is_empty():
					return {"ok": false}
				node_paths["."] = inherited_type
			continue

		var parent_path := _normalized_scene_path(
			String(attributes.get("parent", "")),
		)
		if (
			parent_path.is_empty()
			or _scene_model_node_type(scene_model, parent_path, {}).is_empty()
		):
			return {"ok": false}
		var node_path := name if parent_path == "." else parent_path + "/" + name
		if has_type or has_instance:
			if not _scene_model_node_type(scene_model, node_path, {}).is_empty():
				return {"ok": false}
			if has_type:
				node_paths[node_path] = String(attributes["type"])
			else:
				var nested := _scene_instance_dependency(
					String(attributes["instance"]),
					ext_resources,
				)
				if not nested.get("ok", false):
					return {"ok": false}
				instance_paths[node_path] = nested["path"]
				var nested_type := _scene_model_node_type(
					scene_model,
					node_path,
					{},
				)
				if nested_type.is_empty():
					return {"ok": false}
				node_paths[node_path] = nested_type
		else:
			# Property-only entries are valid only when an inherited or nested
			# effective node already exists at the complete NodePath. Resolve only
			# this path instead of materializing every descendant of every instance.
			var inherited_type := _scene_model_node_type(
				scene_model,
				node_path,
				{},
			)
			if inherited_type.is_empty():
				return {"ok": false}
			node_paths[node_path] = inherited_type

		if attributes.has("owner"):
			var owner_path := _normalized_scene_path(String(attributes["owner"]))
			if (
				owner_path.is_empty()
				or _scene_model_node_type(scene_model, owner_path, {}).is_empty()
				or not _scene_path_is_ancestor(owner_path, node_path)
			):
				return {"ok": false}

	for tag: Dictionary in trailing_tags:
		var attributes: Dictionary = tag.get("attributes", {})
		match tag.get("name", ""):
			"connection":
				for key: String in ["from", "to"]:
					var endpoint := _normalized_scene_path(
						String(attributes.get(key, "")),
					)
					if (
						endpoint.is_empty()
						or _scene_model_node_type(scene_model, endpoint, {}).is_empty()
					):
						return {"ok": false}
			"editable":
				var editable_path := _normalized_scene_path(
					String(attributes.get("path", "")),
				)
				if (
					editable_path.is_empty()
					or _scene_model_node_type(
						scene_model,
						editable_path,
						{},
					).is_empty()
				):
					return {"ok": false}
			_:
				return {"ok": false}
	return {
		"ok": true,
		"node_paths": node_paths.duplicate(true),
		"scene_model": scene_model,
	}


func _scene_instance_dependency(
	serialized_value: String,
	ext_resources: Dictionary,
) -> Dictionary:
	var parsed := _ResourceValueParser.new(serialized_value).parse()
	if not parsed.get("ok", false):
		return {"ok": false}
	var references: Array = parsed.get("references", [])
	if (
		references.size() != 1
		or references[0].get("kind", "") != "ExtResource"
	):
		return {"ok": false}
	var resource_id: String = references[0].get("id", "")
	if not ext_resources.has(resource_id):
		return {"ok": false}
	var dependency: Dictionary = ext_resources[resource_id]
	if not _resource_declared_class_inherits(
		dependency.get("type", ""),
		"PackedScene",
	):
		return {"ok": false}
	var nested := inspect(dependency.get("path", ""), "PackedScene")
	if not nested.ok or not nested.matches_expected_type:
		return {"ok": false}
	if nested.scene_model.is_empty():
		return {"ok": false}
	var root_type := _scene_model_node_type(nested.scene_model, ".", {})
	if root_type.is_empty():
		return {"ok": false}
	return {
		"ok": true,
		"path": String(dependency.get("path", "")).simplify_path(),
		"root_type": root_type,
	}


func _scene_model_node_type(
	scene_model: Dictionary,
	target_path: String,
	visited: Dictionary,
) -> String:
	var normalized_target := _normalized_scene_path(target_path)
	if normalized_target.is_empty():
		return ""
	var nodes: Dictionary = scene_model.get("nodes", {})
	if nodes.has(normalized_target):
		return String(nodes[normalized_target])
	var instances: Dictionary = scene_model.get("instances", {})
	var owning_path := ""
	for candidate_path: String in instances:
		var owns_target := (
			candidate_path == "."
			or normalized_target == candidate_path
			or normalized_target.begins_with(candidate_path + "/")
		)
		if owns_target and candidate_path.length() > owning_path.length():
			owning_path = candidate_path
	if owning_path.is_empty():
		return ""
	var relative_path := normalized_target
	if owning_path != ".":
		relative_path = "." if normalized_target == owning_path else (
			normalized_target.substr(owning_path.length() + 1)
		)
	var dependency_path := String(instances[owning_path]).simplify_path()
	var identity := dependency_path + "\n" + relative_path
	if dependency_path.is_empty() or visited.has(identity):
		return ""
	visited[identity] = true
	var nested := inspect(dependency_path, "PackedScene")
	if (
		not nested.ok
		or not nested.matches_expected_type
		or nested.scene_model.is_empty()
	):
		return ""
	return _scene_model_node_type(nested.scene_model, relative_path, visited)


func _scene_node_name_is_valid(name: String) -> bool:
	return (
		not name.is_empty()
		and name not in [".", ".."]
		and not name.contains("/")
		and not name.contains(":")
	)


func _normalized_scene_path(path: String) -> String:
	if path == ".":
		return "."
	var normalized := path
	if normalized.begins_with("./"):
		normalized = normalized.substr(2)
	if normalized.is_empty() or normalized.begins_with("/"):
		return ""
	for segment in normalized.split("/", true):
		if segment.is_empty() or segment in [".", ".."] or segment.contains(":"):
			return ""
	return normalized


func _scene_path_is_ancestor(owner_path: String, node_path: String) -> bool:
	return (
		owner_path == "."
		or node_path.begins_with(owner_path + "/")
	)


func _resource_header_tag_is_valid(tag: Dictionary, extension: String) -> bool:
	var expected_name := "gd_scene" if extension == "tscn" else "gd_resource"
	if tag.get("name", "") != expected_name:
		return false
	var attributes: Dictionary = tag.get("attributes", {})
	if (
		not _resource_tag_has_safe_integer(tag, "format", true, false)
		or String(attributes["format"]) not in ["1", "2", "3"]
		or not _resource_tag_optional_quoted_string(tag, "uid")
		or not _resource_tag_has_safe_integer(tag, "load_steps", false, false)
	):
		return false
	if extension == "tscn":
		return true
	return (
		_resource_tag_has_quoted_string(tag, "type")
		and _resource_native_class_inherits(
			attributes["type"],
			"Resource",
			true,
		)
		and _resource_tag_optional_quoted_string(tag, "script_class", true)
	)


## Mirror Godot 4.6's format-specific tag state before ResourceLoader sees the
## source. This intentionally validates only loader-significant fields while
## allowing forward-compatible extra attributes whose Variant syntax is safe.
func _resource_body_tag_is_valid(
	tag: Dictionary,
	extension: String,
	state: Dictionary,
) -> bool:
	var tag_name: String = tag.get("name", "")
	var stage: int = state.get("stage", 0)
	state["allows_assignments"] = false
	if tag_name == "ext_resource":
		if stage != 0 or not _resource_ext_tag_is_valid(tag):
			return false
		return true
	if tag_name == "sub_resource":
		if stage > 1 or not _resource_sub_tag_is_valid(tag):
			return false
		state["stage"] = 1
		state["allows_assignments"] = true
		return true
	if extension == "tres":
		if tag_name != "resource" or stage > 2:
			return false
		if state.get("main_resource_count", 0) != 0:
			return false
		state["stage"] = 2
		state["main_resource_count"] = 1
		state["allows_assignments"] = true
		return true

	match tag_name:
		"node":
			if stage > 2 or not _resource_scene_node_tag_is_valid(tag, state):
				return false
			state["stage"] = 2
			state["node_count"] = state.get("node_count", 0) + 1
			state["allows_assignments"] = true
			return true
		"connection":
			if (
				state.get("node_count", 0) == 0
				or not _resource_connection_tag_is_valid(tag)
			):
				return false
			state["stage"] = 3
			return true
		"editable":
			if (
				state.get("node_count", 0) == 0
				or not _resource_tag_has_quoted_string(tag, "path")
			):
				return false
			state["stage"] = 3
			return true
		_:
			return false


func _resource_format_state_is_complete(
	extension: String,
	state: Dictionary,
) -> bool:
	if extension == "tscn":
		return state.get("node_count", 0) > 0
	return state.get("main_resource_count", 0) == 1


func _resource_ext_tag_is_valid(tag: Dictionary) -> bool:
	var attributes: Dictionary = tag.get("attributes", {})
	return (
		_resource_tag_has_quoted_string(tag, "type")
		and _resource_declared_class_inherits(
			attributes.get("type", ""),
			"Resource",
		)
		and _resource_tag_has_quoted_string(tag, "path")
		and not _resource_id_key(tag, "id").is_empty()
		and _resource_tag_optional_quoted_string(tag, "uid")
	)


func _resource_sub_tag_is_valid(tag: Dictionary) -> bool:
	var attributes: Dictionary = tag.get("attributes", {})
	return (
		_resource_tag_has_quoted_string(tag, "type")
		and _resource_native_class_inherits(
			attributes.get("type", ""),
			"Resource",
			true,
		)
		and not _resource_id_key(tag, "id").is_empty()
	)


func _resource_scene_node_tag_is_valid(
	tag: Dictionary,
	state: Dictionary,
) -> bool:
	if not _resource_tag_has_quoted_string(tag, "name"):
		return false
	for key: String in ["type", "parent", "owner", "instance_placeholder"]:
		if not _resource_tag_optional_quoted_string(tag, key):
			return false
	for key: String in ["instance", "groups", "node_paths", "parent_id_path", "owner_uid_path"]:
		if not _resource_tag_optional_unquoted_value(tag, key):
			return false
	for key: String in ["index", "unique_id"]:
		if not _resource_tag_has_safe_integer(tag, key, false, true):
			return false
	var attributes: Dictionary = tag.get("attributes", {})
	if (
		attributes.has("type")
		and not _resource_native_class_inherits(
			attributes["type"],
			"Node",
			true,
		)
	):
		return false
	var node_count: int = state.get("node_count", 0)
	if node_count == 0:
		return (
			not attributes.has("parent")
			and (
				_resource_tag_has_quoted_string(tag, "type")
				or attributes.has("instance")
			)
		)
	return attributes.has("parent")


func _resource_connection_tag_is_valid(tag: Dictionary) -> bool:
	for key: String in ["from", "to", "signal", "method"]:
		if not _resource_tag_has_quoted_string(tag, key):
			return false
	for key: String in ["flags", "unbinds"]:
		if not _resource_tag_has_safe_integer(tag, key, false, true):
			return false
	for key: String in ["binds", "from_uid_path", "to_uid_path"]:
		if not _resource_tag_optional_unquoted_value(tag, key):
			return false
	return true


func _resource_tag_has_quoted_string(
	tag: Dictionary,
	key: String,
	allow_empty: bool = false,
) -> bool:
	var attributes: Dictionary = tag.get("attributes", {})
	var quoted: Dictionary = tag.get("quoted_attributes", {})
	return (
		attributes.has(key)
		and quoted.get(key, false)
		and (allow_empty or not String(attributes[key]).is_empty())
	)


func _resource_tag_optional_quoted_string(
	tag: Dictionary,
	key: String,
	allow_empty: bool = false,
) -> bool:
	var attributes: Dictionary = tag.get("attributes", {})
	return (
		not attributes.has(key)
		or _resource_tag_has_quoted_string(tag, key, allow_empty)
	)


func _resource_tag_optional_unquoted_value(
	tag: Dictionary,
	key: String,
) -> bool:
	var attributes: Dictionary = tag.get("attributes", {})
	var quoted: Dictionary = tag.get("quoted_attributes", {})
	return not attributes.has(key) or not quoted.get(key, false)


func _resource_tag_has_safe_integer(
	tag: Dictionary,
	key: String,
	required: bool,
	allow_quoted: bool,
) -> bool:
	var attributes: Dictionary = tag.get("attributes", {})
	var quoted: Dictionary = tag.get("quoted_attributes", {})
	if not attributes.has(key):
		return not required
	if quoted.get(key, false) and not allow_quoted:
		return false
	var literal := String(attributes[key])
	return _safe_decimal_integer_literal(literal)


func _resource_id_key(tag: Dictionary, key: String) -> String:
	var attributes: Dictionary = tag.get("attributes", {})
	var quoted: Dictionary = tag.get("quoted_attributes", {})
	if not attributes.has(key):
		return ""
	var value: String = attributes[key]
	return _normalized_resource_id_value(value, quoted.get(key, false))


func _resource_declared_class_inherits(
	actual_class: String,
	base_class: String,
) -> bool:
	if actual_class.is_empty() or base_class.is_empty():
		return false
	if ClassDB.class_exists(actual_class):
		return ClassDB.is_parent_class(actual_class, base_class)
	return _script_class_inherits(actual_class, base_class)


func _resource_native_class_inherits(
	actual_class: String,
	base_class: String,
	require_instantiable: bool,
) -> bool:
	return (
		ClassDB.class_exists(actual_class)
		and ClassDB.is_parent_class(actual_class, base_class)
		and (
			not require_instantiable
			or ClassDB.can_instantiate(actual_class)
		)
	)


func _resource_bytes_have_binary_magic(bytes: PackedByteArray) -> bool:
	if bytes.size() < 4:
		return false
	# Godot binary resources begin with RSCC (compressed) or RSRC. Do not infer
	# binary format from an arbitrary non-'[' first byte.
	return (
		bytes[0] == 0x52 # R
		and bytes[1] == 0x53 # S
		and bytes[2] in [0x43, 0x52] # C/R
		and bytes[3] == 0x43 # C
	)


func _append_resource_tag_references(
	tag: Dictionary,
	references: Array[Dictionary],
) -> bool:
	var attributes: Dictionary = tag.get("attributes", {})
	var quoted_attributes: Dictionary = tag.get("quoted_attributes", {})
	for key: String in attributes:
		if quoted_attributes.get(key, false):
			continue
		if not _append_resource_value_references(
			String(attributes[key]),
			references,
		):
			return false
	return true


func _append_resource_value_references(
	value: String,
	references: Array[Dictionary],
) -> bool:
	var parsed := _ResourceValueParser.new(value).parse()
	if not parsed.get("ok", false):
		return false
	for reference: Dictionary in parsed.get("references", []):
		references.append(reference)
	return true


func _resource_references_are_declared(
	references: Array[Dictionary],
	ext_resource_ids: Dictionary,
	sub_resource_ids: Dictionary,
) -> bool:
	for reference: Dictionary in references:
		var resource_id: String = reference.get("id", "")
		match reference.get("kind", ""):
			"ExtResource":
				if not ext_resource_ids.has(resource_id):
					return false
			"SubResource":
				if not sub_resource_ids.has(resource_id):
					return false
			_:
				return false
	return true


func _structured_resource_dependencies(path: String) -> Dictionary:
	var dependencies: Array[Dictionary] = []
	for raw_dependency: String in ResourceLoader.get_dependencies(path):
		var dependency_path := _resource_dependency_path(raw_dependency)
		var declared_type := _resource_dependency_type(raw_dependency)
		if dependency_path.is_empty():
			return {"ok": false, "dependencies": []}
		dependencies.append({
			"path": dependency_path,
			"type": declared_type,
		})
	var result := {
		"ok": true,
		"dependencies": dependencies,
		"format": "structured",
	}
	# Godot 4.6 treats `ResourceLoader.exists(..., type_hint)` as an existence
	# query even when the cached resource has another type. Inspect the loaded
	# structured value itself so scripts/textures are not misclassified as
	# PackedScenes while binary `.scn` files still expose their SceneState.
	var structured_resource := ResourceLoader.load(path)
	if structured_resource is PackedScene:
		var packed := structured_resource as PackedScene
		var scene_model := _structured_scene_model(packed)
		if not scene_model.get("ok", false):
			return {"ok": false, "dependencies": []}
		result["scene_model"] = scene_model["scene_model"]
		result["node_paths"] = scene_model["node_paths"]
	return result


## Convert a binary/remapped PackedScene's own serialized SceneState into the
## same compact model used by text scenes. Nested descendants remain lazy; only
## property-only entries actually present in this state are resolved.
func _structured_scene_model(scene: PackedScene) -> Dictionary:
	if scene == null or not scene.can_instantiate():
		return {"ok": false}
	var state := scene.get_state()
	if state == null or state.get_node_count() == 0:
		return {"ok": false}
	var model := {
		"nodes": {},
		"instances": {},
	}
	var nodes: Dictionary = model["nodes"]
	var instances: Dictionary = model["instances"]
	var unresolved := PackedStringArray()
	for node_index in state.get_node_count():
		var node_path := _normalized_scene_path(
			String(state.get_node_path(node_index)),
		)
		if node_path.is_empty():
			return {"ok": false}
		var nested_scene := state.get_node_instance(node_index)
		if nested_scene != null:
			var nested_path := nested_scene.resource_path.simplify_path()
			if nested_path.is_empty():
				return {"ok": false}
			instances[node_path] = nested_path
		var native_type := String(state.get_node_type(node_index))
		if native_type.is_empty():
			unresolved.append(node_path)
		else:
			nodes[node_path] = native_type
	for node_path: String in unresolved:
		var native_type := _scene_model_node_type(model, node_path, {})
		if native_type.is_empty():
			return {"ok": false}
		nodes[node_path] = native_type
	if not nodes.has("."):
		return {"ok": false}
	return {
		"ok": true,
		"scene_model": model,
		"node_paths": nodes.duplicate(true),
	}


func _parse_resource_tag(line: String) -> Dictionary:
	if (
		not line.begins_with("[")
		or not line.ends_with("]")
		or line.to_utf8_buffer().size() > MAX_RESOURCE_TAG_BYTES
	):
		return {"ok": false}
	var content := line.substr(1, line.length() - 2)
	var index := 0
	while index < content.length() and content[index] not in [" ", "\t"]:
		index += 1
	var tag_name := content.substr(0, index)
	if not _resource_token_is_identifier(tag_name):
		return {"ok": false}
	var attributes := {}
	var quoted_attributes := {}
	while index < content.length():
		while index < content.length() and content[index] in [" ", "\t"]:
			index += 1
		if index >= content.length():
			break
		var key_start := index
		while (
			index < content.length()
			and content[index] not in [" ", "\t", "="]
		):
			index += 1
		var key := content.substr(key_start, index - key_start)
		while index < content.length() and content[index] in [" ", "\t"]:
			index += 1
		if (
			not _resource_token_is_identifier(key)
			or attributes.has(key)
			or index >= content.length()
			or content[index] != "="
		):
			return {"ok": false}
		index += 1
		while index < content.length() and content[index] in [" ", "\t"]:
			index += 1
		if index >= content.length():
			return {"ok": false}
		if content[index] == "\"":
			quoted_attributes[key] = true
			var decoded := _decode_resource_string(
				content,
				index,
				MAX_QUOTED_ATTRIBUTE_BYTES,
			)
			if not decoded.get("ok", false):
				return {"ok": false}
			attributes[key] = decoded["value"]
			index = decoded["end"]
		else:
			quoted_attributes[key] = false
			var value_start := index
			index = _resource_tag_value_end(content, index)
			if index < 0:
				return {"ok": false}
			var raw_value := content.substr(value_start, index - value_start)
			if raw_value.is_empty():
				return {"ok": false}
			attributes[key] = raw_value
	return {
		"ok": true,
		"name": tag_name,
		"attributes": attributes,
		"quoted_attributes": quoted_attributes,
	}


func _resource_token_is_identifier(token: String) -> bool:
	if token.is_empty():
		return false
	for index in token.length():
		var character := token[index]
		if (
			character == "_"
			or character >= "A" and character <= "Z"
			or character >= "a" and character <= "z"
			or index > 0 and character >= "0" and character <= "9"
		):
			continue
		return false
	return true


func _resource_tag_value_end(content: String, start: int) -> int:
	var stack: Array[String] = []
	var in_string := false
	var escaped := false
	var index := start
	while index < content.length():
		var character := content[index]
		if in_string:
			if escaped:
				escaped = false
			elif character == "\\":
				escaped = true
			elif character == "\"":
				in_string = false
			index += 1
			continue
		if character == "\"":
			in_string = true
		elif character in ["(", "[", "{"]:
			stack.append(character)
		elif character in [")", "]", "}"]:
			if stack.is_empty() or not _resource_delimiters_match(
				stack.back(),
				character,
			):
				return -1
			stack.pop_back()
		elif character in [" ", "\t"] and stack.is_empty():
			break
		index += 1
	if in_string or not stack.is_empty():
		return -1
	return index


func _strip_resource_comment(line: String) -> String:
	var in_string := false
	var escaped := false
	for index in line.length():
		var character := line[index]
		if in_string:
			if escaped:
				escaped = false
			elif character == "\\":
				escaped = true
			elif character == "\"":
				in_string = false
			continue
		if character == "\"":
			in_string = true
		elif character == ";":
			return line.substr(0, index)
	return line


## Validate serialized Variant structure without evaluating it or passing raw
## private source to Godot's parser. Values may span lines (typed arrays,
## dictionaries, and literal strings), so keep a small delimiter/string state
## until the complete assignment has closed.
func _begin_resource_assignment(line: String) -> Dictionary:
	var equals_index := line.find("=")
	if equals_index <= 0 or line.substr(0, equals_index).strip_edges().is_empty():
		return {"ok": false}
	var value := line.substr(equals_index + 1).strip_edges()
	if value.is_empty():
		return {"ok": false}

	var state := {
		"ok": true,
		"complete": false,
		"kind": "",
		"value_parts": PackedStringArray([value]),
		"stack": [],
		"in_string": false,
		"escaped": false,
	}
	if value.begins_with("\""):
		state["kind"] = "string"
		state["in_string"] = true
		if not _scan_resource_value_fragment(value.substr(1), state):
			return {"ok": false}
		return state
	if value.begins_with("&\"") or value.begins_with("^\""):
		state["kind"] = "string"
		state["in_string"] = true
		if not _scan_resource_value_fragment(value.substr(2), state):
			return {"ok": false}
		return state

	var container_start := _resource_container_start(value)
	if container_start >= 0:
		state["kind"] = "container"
		if not _scan_resource_value_fragment(
			value.substr(container_start),
			state,
		):
			return {"ok": false}
		return state

	if _resource_scalar_is_valid(value):
		state["kind"] = "scalar"
		state["complete"] = true
		return state
	# A bare unknown identifier is a common malformed-resource failure, and
	# Godot includes that identifier verbatim in its parser error. Reject it here.
	return {"ok": false}


func _resource_container_start(value: String) -> int:
	if value[0] in ["[", "{", "("]:
		return 0
	var open_index := value.find("(")
	if open_index <= 0:
		return -1
	var prefix := value.substr(0, open_index).strip_edges()
	var base_name := prefix.get_slice("[", 0).strip_edges()
	if not _resource_constructor_is_known(base_name):
		return -1
	var generic_depth := 0
	for character in prefix:
		if character == "[":
			generic_depth += 1
		elif character == "]":
			generic_depth -= 1
			if generic_depth < 0:
				return -1
		elif not (
			character == "_"
			or character == ","
			or character == "."
			or character == " "
			or character == "\t"
			or character >= "0" and character <= "9"
			or character >= "A" and character <= "Z"
			or character >= "a" and character <= "z"
		):
			return -1
	if generic_depth != 0:
		return -1
	return open_index


func _resource_constructor_is_known(name: String) -> bool:
	return (
		name in [
			"AABB", "Array", "Basis", "Callable", "Color", "Dictionary",
			"EncodedObjectAsID", "ExtResource", "NodePath", "Object", "Plane",
			"Projection", "Quaternion", "Rect2", "Rect2i", "RID", "Signal",
			"String", "StringName", "SubResource", "Transform2D", "Transform3D",
		]
		or name.begins_with("Packed")
		or name.begins_with("Vector")
	)


func _resource_scalar_is_valid(value: String) -> bool:
	if value in ["true", "false", "null", "inf", "+inf", "-inf", "nan"]:
		return true
	return value.is_valid_int() or value.is_valid_float()


func _scan_resource_value_fragment(
	fragment: String,
	state: Dictionary,
) -> bool:
	var kind: String = state["kind"]
	var stack: Array = state["stack"]
	var in_string: bool = state["in_string"]
	var escaped: bool = state["escaped"]
	for index in fragment.length():
		var character := fragment[index]
		if in_string:
			if escaped:
				escaped = false
				continue
			if character == "\\":
				escaped = true
				continue
			if character != "\"":
				continue
			in_string = false
			if kind == "string":
				if not _resource_value_tail_is_empty(fragment, index + 1):
					return false
				state["complete"] = true
				state["in_string"] = false
				state["escaped"] = false
				return true
			continue

		if character == ";":
			break
		if character == "\"":
			in_string = true
			continue
		if character in ["(", "[", "{"]:
			stack.append(character)
			continue
		if character in [")", "]", "}"]:
			if stack.is_empty() or not _resource_delimiters_match(
				stack.back(),
				character,
			):
				return false
			stack.pop_back()
			if stack.is_empty():
				if not _resource_value_tail_is_empty(fragment, index + 1):
					return false
				state["complete"] = true
				state["stack"] = stack
				state["in_string"] = false
				state["escaped"] = false
				return true

	# A physical newline consumes a trailing escape inside a literal multiline
	# string; the first character on the next line is not escaped by that slash.
	if in_string and escaped:
		escaped = false
	state["stack"] = stack
	state["in_string"] = in_string
	state["escaped"] = escaped
	return true


func _resource_value_tail_is_empty(fragment: String, start: int) -> bool:
	for index in range(start, fragment.length()):
		var character := fragment[index]
		if character in [" ", "\t"]:
			continue
		return character == ";"
	return true


func _resource_delimiters_match(opening: String, closing: String) -> bool:
	return (
		opening == "(" and closing == ")"
		or opening == "[" and closing == "]"
		or opening == "{" and closing == "}"
	)


func _resource_dependency_path_from_attributes(attributes: Dictionary) -> String:
	var uid_text: String = attributes.get("uid", "")
	if uid_text.begins_with("uid://"):
		var dependency_uid := ResourceUID.text_to_id(uid_text)
		if dependency_uid != ResourceUID.INVALID_ID and ResourceUID.has_id(dependency_uid):
			return ResourceUID.get_id_path(dependency_uid).simplify_path()
	return String(attributes.get("path", "")).simplify_path()


func _resource_dependency_type(raw_dependency: String) -> String:
	var fields := raw_dependency.split("::", true)
	if fields.size() >= 2:
		return fields[1]
	return ""


func _text_resource_declares_type(
	path: String,
	declared_type: String,
	inspection: InspectionResult,
) -> bool:
	if declared_type.is_empty():
		return false
	var extension := path.get_extension().to_lower()
	if extension == "tscn":
		return ClassDB.is_parent_class("PackedScene", declared_type)
	if extension == "tres":
		# Reuse the same byte/header gate as dependency discovery. In
		# particular, never classify a BOM or arbitrary non-'[' preamble as
		# binary and pass it to ResourceLoader, whose parse error includes the
		# authored path.
		var metadata := inspection.to_dictionary()
		if metadata.get("format", "") == "structured":
			var binary_resource := ResourceLoader.load(path, declared_type)
			return (
				binary_resource != null
					and binary_resource.is_class(declared_type)
			)
		if metadata.get("format", "") != "text":
			return false
		var header: Dictionary = metadata.get("header", {})
		var actual_type: String = header["attributes"].get("type", "")
		if (
			not actual_type.is_empty()
			and ClassDB.is_parent_class(actual_type, declared_type)
		):
			return true
		var script_class: String = header["attributes"].get(
			"script_class",
			"",
		)
		return _script_class_inherits(script_class, declared_type)
	var loaded_resource := ResourceLoader.load(path, declared_type)
	return loaded_resource != null and loaded_resource.is_class(declared_type)


func _script_class_inherits(
	actual_class: String,
	declared_class: String,
) -> bool:
	if actual_class.is_empty() or declared_class.is_empty():
		return false
	var base_by_class: Dictionary = {}
	for entry: Dictionary in ProjectSettings.get_global_class_list():
		var global_name: String = entry.get("class", "")
		if not global_name.is_empty():
			base_by_class[global_name] = String(entry.get("base", ""))

	var current := actual_class
	var visited: Dictionary = {}
	while not current.is_empty() and not visited.has(current):
		if current == declared_class:
			return true
		visited[current] = true
		if base_by_class.has(current):
			current = base_by_class[current]
			continue
		if ClassDB.class_exists(current):
			return ClassDB.is_parent_class(current, declared_class)
		break
	return false


func _resource_dependency_path(raw_dependency: String) -> String:
	var fields := raw_dependency.split("::", true)
	# Imported/exported resources may report UID::type::fallback-path. A valid
	# UID follows resource relocation, while the serialized fallback can be
	# stale. Prefer the registry's canonical path and use the fallback only when
	# that UID is unavailable (including stripped/older PCK metadata).
	if not fields.is_empty() and fields[0].begins_with("uid://"):
		var dependency_uid := ResourceUID.text_to_id(fields[0])
		if dependency_uid != ResourceUID.INVALID_ID and ResourceUID.has_id(dependency_uid):
			var canonical_path := ResourceUID.get_id_path(dependency_uid)
			if (
				not canonical_path.is_empty()
				and ResourceLoader.exists(canonical_path)
			):
				return canonical_path.simplify_path()
	if fields.size() >= 3 and not fields[2].is_empty():
		return fields[2].simplify_path()
	if fields.is_empty():
		return ""
	return fields[0].simplify_path()
