## Manages save/load using snapshot providers.
## Each subsystem registers as a provider; SaveManager collects and restores snapshots.
class_name SaveManager extends RefCounted

var save_dir: String = "user://saves/"
var _providers: Array = []


func register_provider(provider) -> void:
	var id = provider.get_provider_id()
	for i in range(_providers.size()):
		if _providers[i].get_provider_id() == id:
			_providers[i] = provider
			return
	_providers.append(provider)


func get_provider_count() -> int:
	return _providers.size()


func save(slot_id: int) -> void:
	_ensure_dir()

	var data: Dictionary = {}
	for provider in _providers:
		data[provider.get_provider_id()] = provider.capture_snapshot()
	data["timestamp"] = Time.get_unix_time_from_system()

	var path = save_dir + "save_%d.json" % slot_id
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data))


func load_save(slot_id: int) -> bool:
	var path = save_dir + "save_%d.json" % slot_id
	if not FileAccess.file_exists(path):
		return false

	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false

	var text = file.get_as_text()
	var data = JSON.parse_string(text)
	if data == null or not data is Dictionary:
		return false

	for provider in _providers:
		var id = provider.get_provider_id()
		if data.has(id):
			provider.restore_snapshot(data[id])

	return true


func has_save(slot_id: int) -> bool:
	return FileAccess.file_exists(save_dir + "save_%d.json" % slot_id)


func delete_save(slot_id: int) -> void:
	var path = save_dir + "save_%d.json" % slot_id
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func get_save_list() -> Array:
	_ensure_dir()
	var result: Array = []
	var dir = DirAccess.open(save_dir)
	if dir == null:
		return result

	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.begins_with("save_") and file_name.ends_with(".json"):
			var slot_str = file_name.replace("save_", "").replace(".json", "")
			if slot_str.is_valid_int():
				result.append(slot_str.to_int())
		file_name = dir.get_next()

	result.sort()
	return result


## --- Quick Save (separate from manual slots) ---

func quick_save() -> void:
	_ensure_dir()
	var data: Dictionary = {}
	for provider in _providers:
		data[provider.get_provider_id()] = provider.capture_snapshot()
	data["timestamp"] = Time.get_unix_time_from_system()

	var path = save_dir + "quicksave.json"
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data))


func quick_load() -> bool:
	var path = save_dir + "quicksave.json"
	if not FileAccess.file_exists(path):
		return false
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	var text = file.get_as_text()
	var data = JSON.parse_string(text)
	if data == null or not data is Dictionary:
		return false
	for provider in _providers:
		var id = provider.get_provider_id()
		if data.has(id):
			provider.restore_snapshot(data[id])
	return true


func has_quick_save() -> bool:
	return FileAccess.file_exists(save_dir + "quicksave.json")


func delete_quick_save() -> void:
	var path = save_dir + "quicksave.json"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func get_quick_save_metadata() -> Dictionary:
	var path = save_dir + "quicksave.json"
	return _read_metadata(path)


## --- Auto Save (triggered on game interruption) ---

func auto_save() -> void:
	_ensure_dir()
	var data: Dictionary = {}
	for provider in _providers:
		data[provider.get_provider_id()] = provider.capture_snapshot()
	data["timestamp"] = Time.get_unix_time_from_system()

	var path = save_dir + "autosave.json"
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data))


func auto_load() -> bool:
	var path = save_dir + "autosave.json"
	if not FileAccess.file_exists(path):
		return false
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	var text = file.get_as_text()
	var data = JSON.parse_string(text)
	if data == null or not data is Dictionary:
		return false
	for provider in _providers:
		var id = provider.get_provider_id()
		if data.has(id):
			provider.restore_snapshot(data[id])
	return true


func has_auto_save() -> bool:
	return FileAccess.file_exists(save_dir + "autosave.json")


func delete_auto_save() -> void:
	var path = save_dir + "autosave.json"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func get_auto_save_metadata() -> Dictionary:
	var path = save_dir + "autosave.json"
	return _read_metadata(path)


## Return "quick", "auto", or "" based on which continue save is newest.
func get_latest_continue_type() -> String:
	var has_quick = has_quick_save()
	var has_auto = has_auto_save()
	if not has_quick and not has_auto:
		return ""
	if has_quick and not has_auto:
		return "quick"
	if has_auto and not has_quick:
		return "auto"
	# Both exist — compare timestamps
	var quick_meta = get_quick_save_metadata()
	var auto_meta = get_auto_save_metadata()
	var quick_ts: float = quick_meta.get("timestamp", 0.0)
	var auto_ts: float = auto_meta.get("timestamp", 0.0)
	if quick_ts >= auto_ts:
		return "quick"
	return "auto"


## --- Metadata ---

func get_save_metadata(slot_id: int) -> Dictionary:
	return _read_metadata(save_dir + "save_%d.json" % slot_id)


func _read_metadata(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var data = JSON.parse_string(file.get_as_text())
	if data == null or not data is Dictionary:
		return {}
	var result := {}
	var ts = data.get("timestamp", 0)
	if ts != 0:
		var dt = Time.get_datetime_dict_from_unix_time(int(ts))
		result["timestamp"] = ts
		result["timestamp_str"] = "%04d/%02d/%02d %02d:%02d" % [dt["year"], dt["month"], dt["day"], dt["hour"], dt["minute"]]
	return result


func _ensure_dir() -> void:
	if not DirAccess.dir_exists_absolute(save_dir):
		DirAccess.make_dir_recursive_absolute(save_dir)
