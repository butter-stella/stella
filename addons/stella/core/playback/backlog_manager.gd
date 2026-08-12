## Stores dialogue history for the backlog/history screen.
##
## Implements a "browser history" model with a cursor:
## - add_entry on a known path (matches existing entry at cursor+1) only
##   advances the cursor — no duplication.
## - add_entry on a divergent path truncates entries after the cursor.
## - jump_to(index) moves the cursor without truncating, so the user can
##   navigate freely until they actually take a different branch.
##
## Each entry stores a full game-state snapshot captured by the runtime
## (scenario_context + variable_store + presentation_state). Backlog jump
## restores that snapshot directly — no fast-forward replay needed. The
## max_entries cap (default 200) bounds total memory; older entries are
## evicted from the front when exceeded.
##
## NOT a SaveManager provider. The snapshots reference the currently-
## running engine.context and become meaningless across scenario reload.
## Persisting them into save files would balloon save size and risk
## restoring stale rollback points that point at commands which no longer
## exist. Session-only memory state, cleared on every fresh scenario
## entry (see StellaRuntime._prepare_scenario + the other two clear sites).
class_name BacklogManager extends RefCounted

var max_entries: int = 200

var _entries: Array = []
var _cursor: int = -1
var _registered_bbcode_effect_names: Dictionary = {}
var _registered_bbcode_effect_names_provider: Callable = Callable()
var _has_registered_bbcode_effect_names_provider: bool = false


## Register scene-provided RichTextEffect tag names without coupling Core to a
## RichTextLabel or a concrete dialogue scene. Unknown tags stay literal unless
## the active Presentation layer explicitly registers them here.
func set_registered_bbcode_effect_names(effect_names: Array) -> void:
	_registered_bbcode_effect_names.clear()
	for value in effect_names:
		var effect_name := String(value).strip_edges()
		if effect_name.is_empty() \
			or effect_name.contains("/") \
			or effect_name.contains(" ") \
			or effect_name.contains("="):
			continue
		_registered_bbcode_effect_names[effect_name] = true


## Presentation can provide the active RichTextLabel effect names lazily so
## Runtime's earlier show_dialogue listener strips the exact registry used by
## the scene on that same synchronous SHOW. Passing an invalid provider clears
## any registry left by a retired Presenter.
func set_registered_bbcode_effect_names_provider(provider: Callable) -> void:
	_registered_bbcode_effect_names_provider = provider
	_has_registered_bbcode_effect_names_provider = true
	_refresh_registered_bbcode_effect_names_from_provider()


func _refresh_registered_bbcode_effect_names_from_provider() -> void:
	if not _has_registered_bbcode_effect_names_provider:
		return
	if not _registered_bbcode_effect_names_provider.is_valid():
		set_registered_bbcode_effect_names([])
		return
	var provided_names: Variant = (
		_registered_bbcode_effect_names_provider.call())
	if provided_names is Array:
		set_registered_bbcode_effect_names(provided_names)
	else:
		set_registered_bbcode_effect_names([])


## Add a backlog entry for a dialogue that just fired.
##
## `command_uid` is the stable per-scenario id assigned by
## ScenarioData.assign_command_uids() — used as the divergence-detection
## key. Two entries from the same execution have the same uid; an entry
## that diverges (different choice, different branch) has a different uid.
## Earlier the manager used (scene_index, command_index) which collided
## under @call reuse and dynamic command insertion (issue #88).
func add_entry(character: String, segments: Array, command_uid: int = -1, snapshot_func: Callable = Callable()) -> void:
	_refresh_registered_bbcode_effect_names_from_provider()
	# Browser-history: walking known path → just advance the cursor.
	var next_idx = _cursor + 1
	if next_idx < _entries.size():
		var existing = _entries[next_idx]
		if existing["command_uid"] == command_uid:
			_cursor = next_idx
			return
		# Divergence: drop everything after the cursor.
		_entries.resize(_cursor + 1)

	var full_text := ""
	var voices: Array = []
	for seg in segments:
		full_text += _strip_inline_markers(
			String(seg.get("text", "")), _registered_bbcode_effect_names)
		var v := String(seg.get("voice", ""))
		if v != "":
			voices.append(v)

	var entry: Dictionary = {
		"character": character,
		"text": full_text,
		"voices": voices,
		"command_uid": command_uid,
		"snapshot": snapshot_func.call() if snapshot_func.is_valid() else null,
	}

	_entries.append(entry)
	_cursor = _entries.size() - 1

	while _entries.size() > max_entries:
		_entries.pop_front()
		_cursor -= 1


func get_entries() -> Array:
	return _entries


func get_entry(index: int) -> Dictionary:
	if index >= 0 and index < _entries.size():
		return _entries[index]
	return {}


func get_cursor() -> int:
	return _cursor


## Move the cursor to one before `index` and return that entry's snapshot.
## Does NOT truncate — history is preserved so the player can navigate
## back and forth. The cursor lands at `index - 1` so that when the engine
## re-dispatches the dialogue at `index`, the position match advances the
## cursor cleanly without inserting a duplicate.
##
## Returns {} if index is invalid or the entry has no snapshot.
func jump_to(index: int) -> Dictionary:
	if index < 0 or index >= _entries.size():
		return {}
	var entry = _entries[index]
	if entry.get("snapshot") == null:
		return {}
	_cursor = index - 1
	return {
		"snapshot": entry["snapshot"],
		"command_uid": entry["command_uid"],
	}


func clear() -> void:
	_entries.clear()
	_cursor = -1


## Convert authored dialogue markup to the plain text shown by BacklogScreen's
## ordinary Button. Formatting BBCode disappears, block/list tags become useful
## whitespace or list prefixes, and literal-bracket tags keep their visible
## meaning. Stella's explicit avatar and valid typewriter-effect markers are
## removed too; malformed annotations remain visible for diagnosis.
## Kept in Core so stored history never contains UI-specific markup.
static func _strip_inline_markers(
	text: String,
	registered_effect_names: Dictionary = {},
) -> String:
	var plain := ""
	var tag_stack: Array[String] = []
	var list_stack: Array[Dictionary] = []
	# Godot reads only the raw source between [img] and the next BBCode token as
	# the image path. Once another token starts, following text is ordinary
	# visible content even if [/img] has not appeared yet.
	var image_source_pending := false
	var suppress_next_source_newline := false
	var i := 0
	while i < text.length():
		if suppress_next_source_newline and text[i] != "\n":
			suppress_next_source_newline = false
		if text[i] == "[":
			# The first bracket in [[ is literal, but the second one can still
			# begin a real BBCode tag. An unknown second tag remains fully literal
			# and must not become a Stella expression marker.
			if i + 1 < text.length() and text[i + 1] == "[":
				image_source_pending = false
				var escaped_close := ExpressionTimeline.find_unquoted_closing_bracket(
					text, i + 2)
				if escaped_close != -1:
					var escaped_tag := text.substr(
						i + 2, escaped_close - i - 2)
					if _is_registered_bbcode_tag(
						escaped_tag, registered_effect_names):
						plain = _append_plain_content(plain, "[", list_stack)
						i += 1
						continue
				# No formatting tag starts at the second bracket, so Godot's `[[`
				# escape contributes one literal opening bracket.
				plain = _append_plain_content(plain, "[", list_stack)
				i += 2
				continue
			var close := ExpressionTimeline.find_unquoted_closing_bracket(text, i + 1)
			if close != -1:
				var raw_tag := text.substr(i + 1, close - i - 1)
				if _is_registered_bbcode_tag(raw_tag, registered_effect_names):
					image_source_pending = false
					var tag_name := _bbcode_tag_name(raw_tag)
					var stack_name := _bbcode_stack_name(raw_tag)
					var is_closing := raw_tag.begins_with("/")
					if is_closing:
						var matches_open := (
							not tag_stack.is_empty()
							and tag_stack[-1] == stack_name
						)
						if matches_open:
							tag_stack.pop_back()
							if tag_name in [
								"p", "center", "left", "right", "fill",
								"indent", "table", "ul", "ol",
							]:
								plain = _append_plain_line_break(plain)
								suppress_next_source_newline = true
							if tag_name in ["ul", "ol"] \
								and not list_stack.is_empty():
								list_stack.pop_back()
						else:
							# Godot renders a closing tag literally when it does not
							# match the current stack item; mirror that visible fallback.
							plain = _append_plain_content(
								plain, text.substr(i, close - i + 1), list_stack)
					else:
						var self_closing := _is_self_closing_bbcode(raw_tag, tag_name)
						if tag_name == "img":
							# Object-replacement character is the conventional plain-text
							# stand-in for an inline image.
							plain = _append_plain_content(plain, "\ufffc", list_stack)
							image_source_pending = true
							tag_stack.append(stack_name)
						else:
							match tag_name:
								"br":
									plain = _append_plain_line_break(plain)
								"lb":
									plain = _append_plain_content(plain, "[", list_stack)
								"rb":
									plain = _append_plain_content(plain, "]", list_stack)
								"char":
									plain = _append_plain_content(
										plain, _bbcode_char_to_text(raw_tag), list_stack)
								"hr":
									plain = _append_plain_line_break(plain)
								"ul", "ol":
									plain = _append_plain_line_break(plain)
									suppress_next_source_newline = true
									list_stack.append({
										"tag": tag_name,
										"style": _bbcode_list_style(raw_tag, tag_name),
										"next_index": 1,
									})
								"p", "center", "left", "right", "fill", "indent", "table":
									plain = _append_plain_line_break(plain)
									suppress_next_source_newline = true
								"cell":
									if not plain.is_empty() \
										and not plain.ends_with("\n") \
										and not plain.ends_with("\t"):
										plain = _append_plain_content(
											plain, "\t", list_stack)
								_:
									plain = _append_plain_content(
										plain, _bbcode_control_character(tag_name), list_stack)
						if not self_closing \
							and tag_name != "img":
							tag_stack.append(stack_name)
					i = close + 1
					continue
				if ExpressionTimeline.is_registered_effect_main_value_literal(
					raw_tag, registered_effect_names):
					image_source_pending = false
					plain = _append_plain_content(
						plain, text.substr(i, close - i + 1), list_stack)
					i = close + 1
					continue
				if _is_explicit_avatar_marker(raw_tag):
					i = close + 1
					continue
			# Literal/unknown bracket text survives Stella's marker pass and ends
			# Godot's image-path token. A removed [expr:name] above does not.
			image_source_pending = false
		if text[i] == "{":
			var close := text.find("}", i)
			if close != -1:
				var tag := text.substr(i + 1, close - i - 1)
				if _is_valid_inline_effect(tag):
					i = close + 1
					continue
		if not image_source_pending:
			if text[i] == "\n":
				if suppress_next_source_newline:
					suppress_next_source_newline = false
				else:
					plain += "\n"
			else:
				plain = _append_plain_content(plain, text[i], list_stack)
		i += 1
	while plain.begins_with("\n"):
		plain = plain.substr(1)
	while plain.ends_with("\n"):
		plain = plain.substr(0, plain.length() - 1)
	return plain


static func _is_registered_bbcode_tag(
	raw_tag: String,
	registered_effect_names: Dictionary,
) -> bool:
	return ExpressionTimeline.is_godot_bbcode_tag(
		raw_tag, registered_effect_names)


static func _is_explicit_avatar_marker(raw_tag: String) -> bool:
	if not raw_tag.begins_with("expr:"):
		return false
	var expression := raw_tag.substr(5)
	if expression.is_empty() or ":" in expression:
		return false
	for index in range(expression.length()):
		if expression.substr(index, 1) in [" ", "\t", "\n", "\r"]:
			return false
	return true


static func _is_valid_inline_effect(raw_tag: String) -> bool:
	var parts := raw_tag.split(":", false, 1)
	if parts.size() != 2:
		return false
	var effect_type := String(parts[0]).strip_edges().to_lower()
	var raw_value := String(parts[1]).strip_edges()
	return (
		effect_type in ["wait", "speed"]
		and raw_value.is_valid_float()
		and is_finite(float(raw_value))
		and float(raw_value) >= 0.0
	)


static func _bbcode_tag_name(raw_tag: String) -> String:
	var body := raw_tag.substr(1) if raw_tag.begins_with("/") else raw_tag
	var name_end := body.length()
	for delimiter in [" ", "="]:
		var position := body.find(delimiter)
		if position != -1:
			name_end = mini(name_end, position)
	if body.begins_with("hr"):
		return "hr"
	if body.begins_with("img"):
		return "img"
	if body.begins_with("dropcap"):
		return "dropcap"
	return body.substr(0, name_end)


static func _bbcode_stack_name(raw_tag: String) -> String:
	var body := raw_tag.substr(1) if raw_tag.begins_with("/") else raw_tag
	var name_end := body.length()
	for delimiter in [" ", "="]:
		var position := body.find(delimiter)
		if position != -1:
			name_end = mini(name_end, position)
	return body.substr(0, name_end)


static func _is_self_closing_bbcode(raw_tag: String, tag_name: String) -> bool:
	return tag_name in [
		"alm", "br", "char", "fsi", "hr", "lb", "lre", "lri", "lrm",
		"lro", "pdf", "pdi", "rb", "rle", "rli", "rlm", "rlo", "shy",
		"wj", "zwj", "zwnj",
	] or raw_tag.begins_with("hr")


static func _bbcode_list_style(raw_tag: String, tag_name: String) -> String:
	if tag_name == "ol":
		var type_prefix := "ol type="
		if raw_tag.begins_with(type_prefix):
			return raw_tag.substr(type_prefix.length())
		return "1"
	var bullet_prefix := "ul bullet="
	if not raw_tag.begins_with(bullet_prefix):
		return "•"
	var bullet := raw_tag.substr(bullet_prefix.length())
	if bullet.length() >= 2 \
		and ((bullet.begins_with("\"") and bullet.ends_with("\"")) \
		or (bullet.begins_with("'") and bullet.ends_with("'"))):
		bullet = bullet.substr(1, bullet.length() - 2)
	return bullet if not bullet.is_empty() else "•"


static func _append_plain_content(
	value: String,
	content: String,
	list_stack: Array[Dictionary],
) -> String:
	if content.is_empty():
		return value
	if not list_stack.is_empty() \
		and (value.is_empty() or value.ends_with("\n")):
		value += _next_list_prefix(list_stack)
	return value + content


static func _next_list_prefix(list_stack: Array[Dictionary]) -> String:
	var frame: Dictionary = list_stack[-1]
	var item_index := int(frame.get("next_index", 1))
	frame["next_index"] = item_index + 1
	list_stack[-1] = frame
	var marker := String(frame.get("style", "•"))
	if String(frame.get("tag", "ul")) == "ol":
		marker = _ordered_list_marker(item_index, marker)
	return "  ".repeat(list_stack.size() - 1) + marker + " "


static func _ordered_list_marker(item_index: int, style: String) -> String:
	match style:
		"a":
			return _alphabetic_list_marker(item_index, false) + "."
		"A":
			return _alphabetic_list_marker(item_index, true) + "."
		"i":
			return _roman_list_marker(item_index).to_lower() + "."
		"I":
			return _roman_list_marker(item_index) + "."
		_:
			return str(item_index) + "."


static func _alphabetic_list_marker(item_index: int, uppercase: bool) -> String:
	var result := ""
	var remaining := maxi(1, item_index)
	var alphabet_start := 65 if uppercase else 97
	while remaining > 0:
		remaining -= 1
		result = String.chr(alphabet_start + (remaining % 26)) + result
		remaining = int(remaining / 26)
	return result


static func _roman_list_marker(item_index: int) -> String:
	var values := [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1]
	var symbols := [
		"M", "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I",
	]
	var result := ""
	var remaining := maxi(1, item_index)
	for index in range(values.size()):
		while remaining >= int(values[index]):
			result += String(symbols[index])
			remaining -= int(values[index])
	return result


static func _append_plain_line_break(value: String) -> String:
	if value.is_empty() or value.ends_with("\n"):
		return value
	return value + "\n"


static func _bbcode_char_to_text(raw_tag: String) -> String:
	var equals := raw_tag.find("=")
	if equals == -1:
		return ""
	var value := raw_tag.substr(equals + 1)
	var digit_start := 0
	if value.begins_with("0x") or value.begins_with("0X"):
		digit_start = 2
	if digit_start >= value.length():
		return "\ufffd"
	var codepoint := 0
	for index in range(digit_start, value.length()):
		var character := value[index]
		var digit := -1
		if character >= "0" and character <= "9":
			digit = character.unicode_at(0) - 48
		elif character >= "a" and character <= "f":
			digit = character.unicode_at(0) - 87
		elif character >= "A" and character <= "F":
			digit = character.unicode_at(0) - 55
		if digit == -1:
			return "\ufffd"
		codepoint = codepoint * 16 + digit
		if codepoint > 0x10ffff:
			return "\ufffd"
	if codepoint <= 0 or (codepoint >= 0xd800 and codepoint <= 0xdfff):
		return "\ufffd"
	return String.chr(codepoint)


static func _bbcode_control_character(tag_name: String) -> String:
	var controls := {
		"alm": "\u061c",
		"fsi": "\u2068",
		"lre": "\u202a",
		"lri": "\u2066",
		"lrm": "\u200e",
		"lro": "\u202d",
		"pdf": "\u202c",
		"pdi": "\u2069",
		"rle": "\u202b",
		# Godot 4.6/4.7 currently emit U+2027 for [rli] (rather than the
		# nominal U+2067); mirror the actual player-visible parser result.
		"rli": "\u2027",
		"rlm": "\u200f",
		"rlo": "\u202e",
		"shy": "\u00ad",
		"wj": "\u2060",
		"zwj": "\u200d",
		"zwnj": "\u200c",
	}
	return str(controls.get(tag_name, ""))
