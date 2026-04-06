## Stores dialogue history for the backlog/history screen.
class_name BacklogManager extends RefCounted

var max_entries: int = 100
var _entries: Array = []


func add_entry(character: String, segments: Array) -> void:
	# `segments` is the unified dialogue payload — a list of
	# {text, voice, expression} dicts. A normal single-line dialogue has
	# segments.size() == 1; a @combine block has multiple. Backlog replay
	# plays every segment's voice in order.
	var full_text := ""
	var voices: Array = []
	for seg in segments:
		full_text += String(seg.get("text", ""))
		var v := String(seg.get("voice", ""))
		if v != "":
			voices.append(v)
	_entries.append({
		"character": character,
		"text": full_text,
		"voices": voices,
	})
	while _entries.size() > max_entries:
		_entries.pop_front()


func get_entries() -> Array:
	return _entries


func get_entry(index: int) -> Dictionary:
	if index >= 0 and index < _entries.size():
		return _entries[index]
	return {}


func clear() -> void:
	_entries.clear()
