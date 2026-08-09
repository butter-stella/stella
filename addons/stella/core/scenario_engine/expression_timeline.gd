## Manages dialogue-avatar expression switch points within a dialogue line.
## Inline avatar markers and typewriter effects share one parser so every
## consumer uses positions in the final visible text.
class_name ExpressionTimeline extends RefCounted

var markers: Array = []  # Array of {expression: String, at_char: int}


func extract_from_text(text: String) -> Dictionary:
	var parsed := parse_inline_annotations(text)
	markers = parsed["markers"].duplicate(true)
	return {
		"clean_text": parsed["clean_text"],
		"markers": markers.duplicate(true),
	}


## Return clean visible text plus zero-based marker/effect positions. Invalid
## brace annotations remain literal text and are reported to the caller.
static func parse_inline_annotations(text: String) -> Dictionary:
	var clean_text: String = ""
	var visible_text: String = ""
	var result_markers: Array = []
	var effects: Array = []
	var warnings: Array[String] = []
	var i: int = 0
	var char_offset: int = 0

	while i < text.length():
		if text[i] == "[":
			var marker_close := text.find("]", i)
			if marker_close != -1:
				var marker_tag := text.substr(i + 1, marker_close - i - 1)
				var avatar_expression := _avatar_marker_expression(marker_tag)
				if not avatar_expression.is_empty():
					result_markers.append({
						"expression": avatar_expression,
						"at_char": char_offset,
					})
					i = marker_close + 1
					continue
				if marker_tag.begins_with("expr:"):
					warnings.append(
						"invalid avatar marker '[%s]'; expected [expr:name]"
						% marker_tag
					)
				# Only the explicit [expr:name] grammar is special. Stella keeps
				# dialogue RichTextLabel in plain-text mode, so every other bracketed
				# span is visible literal text and participates in coordinates.
				var marker_literal := text.substr(i, marker_close - i + 1)
				clean_text += marker_literal
				visible_text += marker_literal
				char_offset += marker_literal.length()
				i = marker_close + 1
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


func get_expression_at_char(char_index: int) -> String:
	var current_expr: String = ""
	for marker in markers:
		if marker["at_char"] <= char_index:
			current_expr = marker["expression"]
		else:
			break
	return current_expr
