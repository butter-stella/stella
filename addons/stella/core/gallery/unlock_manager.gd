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


## Gallery unlocks are global, cross-playthrough progress. Loading an older
## save unions its items into the current state instead of rolling progress back.
## Durable cross-session storage still requires a separate global progress file.
func restore_snapshot(snapshot: Dictionary) -> void:
	for category in snapshot:
		var loaded_items: Array = snapshot[category]
		for item_id in loaded_items:
			unlock(category, item_id)
