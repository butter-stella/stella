## Syntax highlighter for .nat DSL files in CodeEdit.
@tool
class_name NatSyntaxHighlighter extends SyntaxHighlighter

# Colors
const COLOR_COMMENT := Color(0.5, 0.5, 0.5)        # gray
const COLOR_SCENE := Color(0.9, 0.4, 0.4)           # red-ish
const COLOR_COMMAND := Color(0.4, 0.7, 1.0)         # blue
const COLOR_CHARACTER := Color(0.4, 0.9, 0.5)       # green
const COLOR_DIALOGUE := Color(1.0, 0.9, 0.6)        # warm yellow
const COLOR_NARRATION := Color(0.8, 0.8, 0.9)       # light lavender
const COLOR_CHOICE_MARKER := Color(1.0, 0.6, 0.2)   # orange
const COLOR_TAG := Color(0.7, 0.5, 0.9)             # purple — #voice, #tag
const COLOR_ARROW := Color(1.0, 0.6, 0.2)           # orange — ->
const COLOR_BRACE := Color(0.7, 0.5, 0.9)           # purple — { }
const COLOR_STRING := Color(0.8, 0.6, 0.4)          # brown — quoted strings
const COLOR_DEFAULT := Color(0.85, 0.85, 0.85)


func _get_line_syntax_highlighting(line: int) -> Dictionary:
	var text_edit := get_text_edit()
	if text_edit == null:
		return {}
	var text := text_edit.get_line(line)
	var result := {}

	if text.strip_edges() == "":
		return result

	var stripped := text.strip_edges()

	# Comment line
	if stripped.begins_with("//"):
		result[0] = {"color": COLOR_COMMENT}
		return result

	# @scene directive
	if stripped.begins_with("@scene"):
		result[0] = {"color": COLOR_SCENE}
		_highlight_quoted_strings(text, result, COLOR_SCENE)
		return result

	# @ commands
	if stripped.begins_with("@"):
		result[0] = {"color": COLOR_COMMAND}
		_highlight_quoted_strings(text, result, COLOR_COMMAND)
		return result

	# Choice option: - "text" -> target
	if stripped.begins_with("- "):
		var offset := text.find("- ")
		result[offset] = {"color": COLOR_CHOICE_MARKER}
		_highlight_quoted_strings(text, result, COLOR_CHOICE_MARKER)
		_highlight_arrow(text, result)
		_highlight_braces(text, result)
		return result

	# Dialogue: character「text」
	var bracket_open := text.find("\u300c")
	if bracket_open >= 0:
		var line_start := _find_first_non_space(text)
		if line_start < bracket_open:
			result[line_start] = {"color": COLOR_CHARACTER}
		result[bracket_open] = {"color": COLOR_DIALOGUE}
		_highlight_tags(text, result)
		_highlight_inline_effects(text, result)
		return result

	# Narration: 「text」 (starts with bracket)
	if stripped.begins_with("\u300c"):
		result[0] = {"color": COLOR_NARRATION}
		_highlight_inline_effects(text, result)
		return result

	# Monologue: character（text）
	var paren_open := text.find("\uff08")
	if paren_open >= 0:
		var line_start := _find_first_non_space(text)
		if line_start < paren_open:
			result[line_start] = {"color": COLOR_CHARACTER}
		result[paren_open] = {"color": COLOR_NARRATION}
		return result

	result[0] = {"color": COLOR_DEFAULT}
	return result


func _highlight_quoted_strings(text: String, result: Dictionary, base_color: Color = COLOR_DEFAULT) -> void:
	var i := 0
	while i < text.length():
		if text[i] == '"':
			result[i] = {"color": COLOR_STRING}
			var end := text.find('"', i + 1)
			if end >= 0:
				result[end + 1] = {"color": base_color}
				i = end + 1
			else:
				break
		else:
			i += 1


func _highlight_tags(text: String, result: Dictionary) -> void:
	var i := text.find("#")
	while i >= 0:
		var end := i + 1
		while end < text.length() and text[end] != ' ' and text[end] != '\t':
			end += 1
		result[i] = {"color": COLOR_TAG}
		if end < text.length():
			result[end] = {"color": COLOR_DIALOGUE}
		i = text.find("#", end)


func _highlight_inline_effects(text: String, result: Dictionary) -> void:
	# Highlight [effect] and {effect} within dialogue
	var i := 0
	while i < text.length():
		if text[i] == '[':
			result[i] = {"color": COLOR_TAG}
			var end := text.find(']', i + 1)
			if end >= 0:
				result[end + 1] = {"color": COLOR_DIALOGUE}
				i = end + 1
			else:
				i += 1
		elif text[i] == '{':
			result[i] = {"color": COLOR_BRACE}
			var end := text.find('}', i + 1)
			if end >= 0:
				result[end + 1] = {"color": COLOR_DIALOGUE}
				i = end + 1
			else:
				i += 1
		else:
			i += 1


func _highlight_arrow(text: String, result: Dictionary) -> void:
	var pos := text.find("->")
	if pos >= 0:
		result[pos] = {"color": COLOR_ARROW}
		result[pos + 2] = {"color": COLOR_CHOICE_MARKER}


func _highlight_braces(text: String, result: Dictionary) -> void:
	var open := text.find("{")
	if open >= 0:
		result[open] = {"color": COLOR_BRACE}
		var close := text.find("}", open)
		if close >= 0:
			result[close + 1] = {"color": COLOR_CHOICE_MARKER}


func _find_first_non_space(text: String) -> int:
	for i in range(text.length()):
		if text[i] != ' ' and text[i] != '\t':
			return i
	return 0
