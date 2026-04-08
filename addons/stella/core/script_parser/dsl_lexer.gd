## Tokenizes .stla source text into a list of DslTokens.
class_name DslLexer extends RefCounted


static func tokenize(source: String) -> Array:
	var tokens: Array = []
	var lines = source.split("\n")

	for i in range(lines.size()):
		var raw = lines[i]
		var stripped = raw.strip_edges()

		# Skip empty lines and comments
		if stripped == "" or stripped.begins_with("//"):
			continue

		var token = DslToken.new()
		token.raw_text = stripped
		token.line = i + 1
		token.indent = raw.length() - raw.strip_edges(true, false).length()

		# Classify token type
		if stripped.begins_with("@scene ") or stripped == "@scene":
			token.type = DslToken.Type.SCENE_DIRECTIVE
		elif stripped.begins_with("@chapter ") or stripped == "@chapter":
			token.type = DslToken.Type.CHAPTER_DIRECTIVE
		elif stripped.begins_with("@"):
			token.type = DslToken.Type.AT_COMMAND
		elif _is_choice_option(stripped):
			token.type = DslToken.Type.CHOICE_OPTION
		elif _is_narration(stripped):
			token.type = DslToken.Type.NARRATION
		elif _is_dialogue(stripped):
			token.type = DslToken.Type.DIALOGUE
		elif _is_monologue(stripped):
			token.type = DslToken.Type.MONOLOGUE
		else:
			continue  # Skip unrecognized lines

		tokens.append(token)

	return tokens


static func _is_choice_option(line: String) -> bool:
	var trimmed = line.strip_edges()
	return trimmed.begins_with("- \"") or trimmed.begins_with("- \u201c")


static func _is_narration(line: String) -> bool:
	return line.begins_with("\u300c")  # 「


static func _is_dialogue(line: String) -> bool:
	return line.find("\u300c") != -1 and line.find("\u300d") != -1  # 「...」


static func _is_monologue(line: String) -> bool:
	return line.find("\uff08") != -1 and line.find("\uff09") != -1  # （...）
