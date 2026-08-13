## Manages dialogue-avatar expression switch points within a dialogue line.
## Inline avatar markers and typewriter effects share one parser so every
## consumer uses positions in the final visible text.
class_name ExpressionTimeline extends RefCounted

const _BBCODE_EXACT_TAGS := [
	"alm", "b", "br", "cell", "center", "code", "fill", "fsi", "i",
	"indent", "lb", "left", "lre", "lri", "lrm", "lro", "ol", "p", "pdf",
	"pdi", "rb", "right", "rle", "rli", "rlm", "rlo", "s", "shy", "u",
	"ul", "url", "wj", "zwj", "zwnj",
]
const _BBCODE_OPTION_PREFIXES := [
	"bgcolor=", "cell=", "cell ", "char=", "color=", "fgcolor=", "font=",
	"font ", "font_size=", "hint=", "lang=", "opentype_features=", "otf=",
	"outline_color=", "outline_size=", "p ", "s ", "table=", "u ",
	"ul bullet=", "url=", "url ",
]
const _BBCODE_EFFECT_TAGS := [
	"fade", "pulse", "rainbow", "shake", "tornado", "wave",
]
const _BBCODE_ORDERED_LIST_TAGS := [
	"ol type=1", "ol type=a", "ol type=A", "ol type=i", "ol type=I",
]

var markers: Array = []  # Array of {expression: String, at_char: int}


func extract_from_text(
	text: String,
	registered_effect_names: Dictionary = {},
) -> Dictionary:
	var parsed := parse_inline_annotations(text, registered_effect_names)
	markers = parsed["markers"].duplicate(true)
	var result := parsed.duplicate(true)
	result["markers"] = markers.duplicate(true)
	return result


## Removes Stella's explicit avatar/typewriter annotations while retaining the
## authored BBCode source. Marker/effect `at_char`/`pos` fields use Godot's
## parsed-character domain; `source_offset` fields use the retained BBCode
## source domain. Unknown bracket spans, including legacy bare `[happy]`
## markers, remain literal text.
static func parse_inline_annotations(
	text: String,
	registered_effect_names: Dictionary = {},
) -> Dictionary:
	var clean_text: String = ""
	var visible_text: String = ""
	var result_markers: Array = []
	var effects: Array = []
	var warnings: Array[String] = []
	var i: int = 0
	var char_offset: int = 0

	while i < text.length():
		if text[i] == "[":
			# RichTextLabel treats [[ as one literal opening bracket.
			if i + 1 < text.length() and text[i + 1] == "[":
				clean_text += "[["
				visible_text += "[["
				char_offset += 1
				i += 2
				continue
			var close := find_unquoted_closing_bracket(text, i + 1)
			if close != -1:
				var tag := text.substr(i + 1, close - i - 1)
				var avatar_expression := _avatar_marker_expression(tag)
				if not avatar_expression.is_empty():
					result_markers.append({
						"expression": avatar_expression,
						"at_char": char_offset,
						"source_offset": clean_text.length(),
					})
					i = close + 1
					continue
				if tag.begins_with("expr:"):
					warnings.append(
						"invalid avatar marker '[%s]'; expected [expr:name]"
						% tag
					)
				if is_godot_bbcode_tag(tag, registered_effect_names):
					var bbcode_source := text.substr(i, close - i + 1)
					clean_text += bbcode_source
					visible_text += bbcode_source
					char_offset += godot_bbcode_visible_character_count(tag)
					i = close + 1
					continue
				# Godot renders a main-value form such as [custom=2]
				# literally for scene-provided RichTextEffects (custom options use
				# `[custom key=2]`). Preserve that visible source and keep it out
				# of Stella's expression-marker channel.
				if is_registered_effect_main_value_literal(
					tag, registered_effect_names):
					var literal_tag := text.substr(i, close - i + 1)
					clean_text += literal_tag
					visible_text += literal_tag
					char_offset += literal_tag.length()
					i = close + 1
					continue
				# Only explicit [expr:name] is Stella syntax. Unknown/bare tags are
				# rendered literally and participate in parsed-character coordinates.
				var marker_literal := text.substr(i, close - i + 1)
				clean_text += marker_literal
				visible_text += marker_literal
				char_offset += marker_literal.length()
				i = close + 1
				continue
		if text[i] == "{":
			var effect_close := text.find("}", i)
			if effect_close != -1:
				var effect_tag := text.substr(i + 1, effect_close - i - 1)
				var parts := effect_tag.split(":", false, 1)
				var effect_type := String(parts[0]).strip_edges().to_lower() \
					if parts.size() > 0 else ""
				var raw_value := String(parts[1]).strip_edges() \
					if parts.size() == 2 else ""
				if (
					parts.size() == 2
					and effect_type in ["wait", "speed"]
					and raw_value.is_valid_float()
					and is_finite(float(raw_value))
					and float(raw_value) >= 0.0
				):
					effects.append({
						"type": effect_type,
						"value": float(raw_value),
						"pos": char_offset,
						"source_offset": clean_text.length(),
					})
					i = effect_close + 1
					continue
				warnings.append(
					(
						"invalid inline effect '{%s}'; expected wait/speed with a "
						+ "non-negative millisecond value"
					) % effect_tag
				)
				var effect_literal := text.substr(i, effect_close - i + 1)
				clean_text += effect_literal
				visible_text += effect_literal
				char_offset += effect_literal.length()
				i = effect_close + 1
				continue
		clean_text += text[i]
		visible_text += text[i]
		char_offset += 1
		i += 1

	return {
		"clean_text": clean_text,
		"visible_text": visible_text,
		"markers": result_markers,
		"effects": effects,
		"warnings": warnings,
		"visible_length": char_offset,
		"character_count": char_offset,
	}


static func _avatar_marker_expression(tag: String) -> String:
	if not tag.begins_with("expr:"):
		return ""
	var expression := tag.substr(5)
	if expression.is_empty() or ":" in expression:
		return ""
	for index in range(expression.length()):
		if expression.substr(index, 1) in [" ", "\t", "\n", "\r"]:
			return ""
	return expression


## Finds the same syntactic tag boundary needed by Godot BBCode: a `]` inside
## a quoted option value is data, not the end of the tag.
static func find_unquoted_closing_bracket(text: String, from: int) -> int:
	var quote := ""
	for index in range(from, text.length()):
		var character := text[index]
		if character == "\"" or character == "'":
			if quote.is_empty():
				quote = character
			elif character == quote:
				quote = ""
			continue
		if character == "]" and quote.is_empty():
			return index
	return -1


## Case-sensitive Godot 4.6 BBCode recognition used to keep built-in and
## scene-registered RichTextEffect tags out of Stella's separate `[expr:name]`
## marker channel. The optional registry maps exact effect names to any value;
## omitting it preserves the original built-in-only API behavior.
static func is_godot_bbcode_tag(
	raw_tag: String,
	registered_effect_names: Dictionary = {},
) -> bool:
	if raw_tag.is_empty():
		return false
	# A closing tag is either consumed when it exactly matches Godot's current
	# top-of-stack item, or rendered literally when it does not. In both cases it
	# must survive Stella's opening-only expression-marker pass.
	if raw_tag.begins_with("/"):
		return true
	if raw_tag in _BBCODE_EXACT_TAGS:
		return true
	if raw_tag in _BBCODE_ORDERED_LIST_TAGS:
		return true
	# These branches intentionally mirror Godot 4.6's broad
	# `begins_with()` checks, including their unusual acceptance of suffixes.
	if raw_tag.begins_with("dropcap") \
		or raw_tag.begins_with("hr") \
		or raw_tag.begins_with("img"):
		return true
	for prefix in _BBCODE_OPTION_PREFIXES:
		if raw_tag.begins_with(prefix):
			return true
	# Built-in animated effects compare the parsed first token (`bbcode_name`),
	# so a main value and/or an option block are both accepted.
	for effect_name in _BBCODE_EFFECT_TAGS:
		if raw_tag == effect_name \
			or raw_tag.begins_with(effect_name + "=") \
			or raw_tag.begins_with(effect_name + " "):
			return true
	var custom_effect_name := _bbcode_opening_tag_name(raw_tag)
	if registered_effect_names.has(custom_effect_name):
		return raw_tag == custom_effect_name \
			or raw_tag.begins_with(custom_effect_name + " ")
	return false


## A registered custom effect with a main value is neither BBCode nor a Stella
## expression. RichTextLabel displays the complete bracket source literally.
static func is_registered_effect_main_value_literal(
	raw_tag: String,
	registered_effect_names: Dictionary,
) -> bool:
	if raw_tag.begins_with("/"):
		return false
	var equals_position := raw_tag.find("=")
	if equals_position <= 0:
		return false
	var effect_name := raw_tag.left(equals_position)
	return registered_effect_names.has(effect_name)


static func _bbcode_opening_tag_name(raw_tag: String) -> String:
	var name_end := raw_tag.length()
	for delimiter in [" ", "="]:
		var position := raw_tag.find(delimiter)
		if position != -1:
			name_end = mini(name_end, position)
	return raw_tag.substr(0, name_end)


static func godot_bbcode_visible_character_count(raw_tag: String) -> int:
	if raw_tag.begins_with("/"):
		return 0
	var tag := raw_tag
	if tag in [
		"alm", "br", "fsi", "lb", "lre", "lri", "lrm", "lro", "pdf",
		"pdi", "rb", "rle", "rli", "rlm", "rlo", "shy", "wj", "zwj", "zwnj",
	] or tag.begins_with("char=") or tag.begins_with("img"):
		return 1
	return 0


func get_expression_at_char(char_index: int) -> String:
	var current_expr: String = ""
	for marker in markers:
		if marker["at_char"] <= char_index:
			current_expr = marker["expression"]
		else:
			break
	return current_expr
