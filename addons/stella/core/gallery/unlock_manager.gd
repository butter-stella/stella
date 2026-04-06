## Tracks unlocked gallery items (CG, BGM, scenes).
## Persisted via global variables / snapshot.
class_name UnlockManager extends RefCounted

var _unlocked: Dictionary = {}  # category -> Array[String]


func unlock(category: String, item_id: String) -> void:
	if not _unlocked.has(category):
		_unlocked[category] = []
	if not _unlocked[category].has(item_id):
		_unlocked[category].append(item_id)


func is_unlocked(category: String, item_id: String) -> bool:
	if not _unlocked.has(category):
		return false
	return _unlocked[category].has(item_id)


func get_unlocked(category: String) -> Array:
	return _unlocked.get(category, [])


func get_provider_id() -> String:
	return "unlocks"


func capture_snapshot() -> Dictionary:
	return _unlocked.duplicate(true)


func restore_snapshot(snapshot: Dictionary) -> void:
	_unlocked = snapshot.duplicate(true)
