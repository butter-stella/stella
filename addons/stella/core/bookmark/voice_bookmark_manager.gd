## Manages voice line bookmarks — collect, list, filter, persist.
class_name VoiceBookmarkManager extends RefCounted

var _bookmarks: Array = []


func add_bookmark(character: String, text: String, voice_asset: String,
		scenario_id: String, scene_id: String, command_index: int) -> void:
	_bookmarks.append({
		"character": character,
		"text": text,
		"voice_asset": voice_asset,
		"scenario_id": scenario_id,
		"scene_id": scene_id,
		"command_index": command_index,
		"timestamp": Time.get_unix_time_from_system(),
	})


func remove_bookmark(index: int) -> void:
	if index >= 0 and index < _bookmarks.size():
		_bookmarks.remove_at(index)


func get_bookmarks() -> Array:
	return _bookmarks


func get_bookmarks_by_character(character: String) -> Array:
	var result: Array = []
	for bm in _bookmarks:
		if bm["character"] == character:
			result.append(bm)
	return result


func get_provider_id() -> String:
	return "voice_bookmarks"


func capture_snapshot() -> Dictionary:
	return {"bookmarks": _bookmarks.duplicate(true)}


func restore_snapshot(snapshot: Dictionary) -> void:
	_bookmarks = snapshot.get("bookmarks", []).duplicate(true)
