## Manages expression switch points within a dialogue line.
## Extracts [expression] markers from text and provides lookup by character position.
class_name ExpressionTimeline extends RefCounted

var markers: Array = []  # Array of {expression: String, at_char: int}


func extract_from_text(text: String) -> Dictionary:
	var clean_text: String = ""
	var result_markers: Array = []
	var i: int = 0
	var char_offset: int = 0

	while i < text.length():
		if text[i] == "[":
			var close = text.find("]", i)
			if close != -1:
				var tag = text.substr(i + 1, close - i - 1)
				# Only treat as expression if it's a simple word (no colon = not inline effect)
				if tag.find(":") == -1 and tag.find(" ") == -1:
					result_markers.append({
						"expression": tag,
						"at_char": char_offset,
					})
					i = close + 1
					continue
		clean_text += text[i]
		char_offset += 1
		i += 1

	return {
		"clean_text": clean_text,
		"markers": result_markers,
	}


func get_expression_at_char(char_index: int) -> String:
	var current_expr: String = ""
	for marker in markers:
		if marker["at_char"] <= char_index:
			current_expr = marker["expression"]
		else:
			break
	return current_expr
