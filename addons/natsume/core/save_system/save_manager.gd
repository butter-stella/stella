## Manages save/load using snapshot providers.
## Each subsystem registers as a provider; SaveManager collects and restores snapshots.
class_name SaveManager extends RefCounted

var save_dir: String = "user://saves/"
var _providers: Array = []


func register_provider(provider) -> void:
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


func get_save_metadata(slot_id: int) -> Dictionary:
	var path = save_dir + "save_%d.json" % slot_id
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
