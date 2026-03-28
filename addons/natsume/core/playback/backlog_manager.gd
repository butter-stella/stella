## Stores dialogue history for the backlog/history screen.
class_name BacklogManager extends RefCounted

var max_entries: int = 100
var _entries: Array = []


func add_entry(character: String, text: String, voice: String) -> void:
	_entries.append({
		"character": character,
		"text": text,
		"voice": voice,
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
