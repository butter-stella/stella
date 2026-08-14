## Manages save/load using snapshot providers.
## Each subsystem registers as a provider; SaveManager collects and restores snapshots.
class_name SaveManager extends RefCounted

const MAX_JSON_SAFE_INTEGER := 9007199254740991
const FIRST_UNSAFE_JSON_INTEGER_FLOAT := 9007199254740992.0

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


func load_save(slot_id: int, scenario_data: ScenarioData = null) -> bool:
	var data: Variant = read_save_data(slot_id, scenario_data)
	if data == null:
		return false
	restore_data(data)
	return true


## Parse a manual save without mutating registered providers. Runtime scene
## navigation uses this to validate the complete transaction before replacing
## a live game or title scene.
func read_save_data(
	slot_id: int,
	scenario_data: ScenarioData = null,
) -> Variant:
	return _read_data(save_dir + "save_%d.json" % slot_id, scenario_data)


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


func quick_load(scenario_data: ScenarioData = null) -> bool:
	var data: Variant = read_quick_save_data(scenario_data)
	if data == null:
		return false
	restore_data(data)
	return true


func read_quick_save_data(scenario_data: ScenarioData = null) -> Variant:
	return _read_data(save_dir + "quicksave.json", scenario_data)


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


func auto_load(scenario_data: ScenarioData = null) -> bool:
	var data: Variant = read_auto_save_data(scenario_data)
	if data == null:
		return false
	restore_data(data)
	return true


func read_auto_save_data(scenario_data: ScenarioData = null) -> Variant:
	return _read_data(save_dir + "autosave.json", scenario_data)


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


## Apply an already parsed save snapshot. The caller owns validation and may
## keep this data across an asynchronous scene transition without reopening a
## file whose contents could change mid-transaction.
func restore_data(data: Dictionary) -> void:
	for provider in _providers:
		var id = provider.get_provider_id()
		if data.has(id):
			provider.restore_snapshot(data[id])


func _read_data(path: String, scenario_data: ScenarioData = null) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var text := file.get_as_text()
	var read_error := file.get_error()
	file.close()
	if read_error not in [OK, ERR_FILE_EOF]:
		return null
	var data: Variant = JSON.parse_string(text)
	if data == null or not data is Dictionary:
		return null
	# Every registered snapshot provider has a Dictionary restore boundary.
	# Reject a structurally invalid save before Runtime replaces the current
	# scene/context instead of discovering the type mismatch during commit.
	for key: Variant in data:
		if key != "timestamp" and not data[key] is Dictionary:
			return null
	if scenario_data != null and not validate_data_for_scenario(data, scenario_data):
		return null
	return data


## Validate every built-in provider snapshot against the scenario that will
## receive it. This is deliberately side-effect free: Runtime calls the read
## API with a parsed ScenarioData before acquiring navigation ownership or
## replacing the current scene/context.
func validate_data_for_scenario(
	raw_data: Variant,
	scenario_data: ScenarioData,
) -> bool:
	if not raw_data is Dictionary or scenario_data == null:
		return false
	var data: Dictionary = raw_data
	if not data.has("scenario_context"):
		return false
	if not _scenario_snapshot_is_valid(data["scenario_context"], scenario_data):
		return false
	if data.has("timestamp") and not _non_negative_number_is_valid(data["timestamp"]):
		return false
	if (
		data.has("variable_store")
		and not _variable_store_snapshot_is_valid(data["variable_store"])
	):
		return false
	if (
		data.has("presentation_state")
		and not _presentation_snapshot_is_valid(data["presentation_state"])
	):
		return false
	if (
		data.has("read_flags")
		and not _read_flags_snapshot_is_valid(data["read_flags"])
	):
		return false
	if data.has("unlocks") and not _unlocks_snapshot_is_valid(data["unlocks"]):
		return false
	if (
		data.has("flowchart_visited")
		and not _flowchart_visited_snapshot_is_valid(data["flowchart_visited"])
	):
		return false
	if (
		data.has("flowchart_state")
		and not _flowchart_snapshot_is_valid(data["flowchart_state"], scenario_data)
	):
		return false
	return true


func _scenario_snapshot_is_valid(
	raw_snapshot: Variant,
	scenario_data: ScenarioData,
) -> bool:
	if not raw_snapshot is Dictionary or scenario_data.scenes.is_empty():
		return false
	var snapshot: Dictionary = raw_snapshot
	if not snapshot.has("scene_index") or not snapshot.has("command_index"):
		return false
	# Runtime saves from before source identity v1 cannot be safely mapped to a
	# target when two authored files share a basename. Fail closed instead of
	# guessing; generic SaveManager reads without ScenarioData remain available
	# to migration tooling that wants to inspect legacy JSON explicitly.
	if (
		not snapshot.has("scenario_id")
		or not snapshot["scenario_id"] is String
		or String(snapshot["scenario_id"]).is_empty()
		or snapshot["scenario_id"] != scenario_data.id
		or not snapshot.has("scenario_source_identity")
		or not snapshot["scenario_source_identity"] is String
		or String(snapshot["scenario_source_identity"]).is_empty()
		or scenario_data.source_identity.is_empty()
		or snapshot["scenario_source_identity"] != scenario_data.source_identity
	):
		return false
	if not _scenario_position_is_valid(snapshot, scenario_data):
		return false
	if snapshot.has("is_finished") and not snapshot["is_finished"] is bool:
		return false
	if snapshot.has("return_stack"):
		if not snapshot["return_stack"] is Array:
			return false
		for raw_entry: Variant in snapshot["return_stack"]:
			if (
				not raw_entry is Dictionary
				or not _scenario_position_is_valid(raw_entry, scenario_data)
			):
				return false
	if snapshot.has("dialogue_mode"):
		if (
			not snapshot["dialogue_mode"] is String
			or snapshot["dialogue_mode"] not in ["adv", "nvl", "overlay"]
		):
			return false
	if (
		snapshot.has("nvl_page_epoch")
		and (
			not _integer_is_valid(snapshot["nvl_page_epoch"])
			or int(snapshot["nvl_page_epoch"]) < 0
		)
	):
		return false
	if snapshot.has("nvl_page_entries"):
		if not snapshot["nvl_page_entries"] is Array:
			return false
		for raw_entry: Variant in snapshot["nvl_page_entries"]:
			if not _nvl_entry_is_valid(raw_entry, scenario_data):
				return false
	for key: String in ["dialogue_profile_name", "adv_dialogue_profile_name"]:
		if snapshot.has(key) and not snapshot[key] is String:
			return false
	for key: String in [
		"dialogue_declarative_presentation",
		"adv_dialogue_declarative_presentation",
	]:
		if snapshot.has(key) and not snapshot[key] is bool:
			return false
	return true


func _scenario_position_is_valid(
	raw_position: Variant,
	scenario_data: ScenarioData,
) -> bool:
	if not raw_position is Dictionary:
		return false
	var position: Dictionary = raw_position
	if (
		not position.has("scene_index")
		or not position.has("command_index")
		or not _integer_is_valid(position["scene_index"])
		or not _integer_is_valid(position["command_index"])
	):
		return false
	var scene_index := int(position["scene_index"])
	var command_index := int(position["command_index"])
	if scene_index < 0 or scene_index >= scenario_data.scenes.size():
		return false
	var scene: SceneData = scenario_data.scenes[scene_index]
	return command_index >= 0 and command_index <= scene.commands.size()


func _nvl_entry_is_valid(
	raw_entry: Variant,
	scenario_data: ScenarioData,
) -> bool:
	if not raw_entry is Dictionary:
		return false
	var entry: Dictionary = raw_entry
	for key: String in ["command_uid", "scene_index", "command_index"]:
		if not entry.has(key) or not _integer_is_valid(entry[key]):
			return false
	if not _scenario_position_is_valid(entry, scenario_data):
		return false
	for key: String in ["profile_name", "character"]:
		if entry.has(key) and not entry[key] is String:
			return false
	if not entry.has("segments") or not entry["segments"] is Array:
		return false
	for raw_segment: Variant in entry["segments"]:
		if not raw_segment is Dictionary:
			return false
		for key: String in ["text", "voice"]:
			if raw_segment.has(key) and not raw_segment[key] is String:
				return false
	return true


func _variable_store_snapshot_is_valid(raw_snapshot: Variant) -> bool:
	if not raw_snapshot is Dictionary:
		return false
	var snapshot: Dictionary = raw_snapshot
	for key: String in ["scenario", "global"]:
		if snapshot.has(key) and not snapshot[key] is Dictionary:
			return false
	return true


func _presentation_snapshot_is_valid(raw_snapshot: Variant) -> bool:
	if not raw_snapshot is Dictionary:
		return false
	var snapshot: Dictionary = raw_snapshot
	for key: String in ["bg", "bgm"]:
		if snapshot.has(key) and not snapshot[key] is String:
			return false
	if snapshot.has("stage_layers"):
		if not snapshot["stage_layers"] is Dictionary:
			return false
		for raw_layer_id: Variant in snapshot["stage_layers"]:
			if (
				not raw_layer_id is String
				or String(raw_layer_id).strip_edges().is_empty()
				or not StageLayerState.validate_snapshot_state(
					snapshot["stage_layers"][raw_layer_id],
					false,
				)
			):
				return false
	return true


func _bool_map_is_valid(raw_map: Variant) -> bool:
	if not raw_map is Dictionary:
		return false
	for key: Variant in raw_map:
		if not key is String or not raw_map[key] is bool:
			return false
	return true


## ReadFlagManager v2 stores collision-safe structured records while saves
## created by earlier Stella versions remain a flat String -> bool map. Accept
## both restore contracts, but validate the complete selected schema before a
## navigation transaction can replace the active scene/context.
func _read_flags_snapshot_is_valid(raw_snapshot: Variant) -> bool:
	if not raw_snapshot is Dictionary:
		return false
	var snapshot: Dictionary = raw_snapshot
	if not snapshot.has("version"):
		return _bool_map_is_valid(snapshot)
	var version: Variant = snapshot["version"]
	if not _integer_is_valid(version) or int(version) != 2:
		return false
	var records: Variant = snapshot.get("flags", null)
	var legacy_records: Variant = snapshot.get("legacy_flags", [])
	if not records is Array or not legacy_records is Array:
		return false
	for raw_record: Variant in records:
		if not raw_record is Dictionary:
			return false
		var record: Dictionary = raw_record
		if (
			not record.get("scenario", null) is String
			or not record.get("scene", null) is String
			or not _json_safe_non_negative_integer_is_valid(
				record.get("command_uid", null),
			)
			or (record.has("legacy") and not record["legacy"] is bool)
		):
			return false
	for legacy_key: Variant in legacy_records:
		if not legacy_key is String:
			return false
	return true


func _json_safe_non_negative_integer_is_valid(value: Variant) -> bool:
	if value is int:
		return value >= 0 and value <= MAX_JSON_SAFE_INTEGER
	if not value is float:
		return false
	var numeric: float = value
	if (
		not is_finite(numeric)
		or numeric < 0.0
		or numeric >= FIRST_UNSAFE_JSON_INTEGER_FLOAT
		or numeric != floor(numeric)
	):
		return false
	return float(int(numeric)) == numeric


func _unlocks_snapshot_is_valid(raw_snapshot: Variant) -> bool:
	if not raw_snapshot is Dictionary:
		return false
	for category: Variant in raw_snapshot:
		if (
			not category is String
			or not _string_array_is_valid(raw_snapshot[category])
		):
			return false
	return true


func _flowchart_visited_snapshot_is_valid(raw_snapshot: Variant) -> bool:
	if not raw_snapshot is Dictionary:
		return false
	var snapshot: Dictionary = raw_snapshot
	for key: String in ["visited_chapters", "visited_chapter_edges"]:
		if snapshot.has(key) and not _bool_map_is_valid(snapshot[key]):
			return false
	return true


func _flowchart_snapshot_is_valid(
	raw_snapshot: Variant,
	scenario_data: ScenarioData,
) -> bool:
	if not raw_snapshot is Dictionary:
		return false
	var snapshot: Dictionary = raw_snapshot
	if snapshot.has("current_path"):
		if not _string_array_is_valid(snapshot["current_path"]):
			return false
		for chapter_id: String in snapshot["current_path"]:
			if (
				not scenario_data.chapters.is_empty()
				and scenario_data.get_chapter(chapter_id) == null
			):
				return false
	if snapshot.has("chapter_snapshots"):
		if not snapshot["chapter_snapshots"] is Dictionary:
			return false
		for raw_chapter_id: Variant in snapshot["chapter_snapshots"]:
			if not raw_chapter_id is String:
				return false
			var chapter_id: String = raw_chapter_id
			if (
				(not scenario_data.chapters.is_empty()
				and scenario_data.get_chapter(chapter_id) == null)
				or not _rollback_snapshot_is_valid(
					snapshot["chapter_snapshots"][raw_chapter_id],
					scenario_data,
				)
			):
				return false
	return true


func _rollback_snapshot_is_valid(
	raw_snapshot: Variant,
	scenario_data: ScenarioData,
) -> bool:
	if not raw_snapshot is Dictionary:
		return false
	var snapshot: Dictionary = raw_snapshot
	if (
		snapshot.has("scenario_context")
		and not _scenario_snapshot_is_valid(
			snapshot["scenario_context"],
			scenario_data,
		)
	):
		return false
	if snapshot.has("variable_store") and not snapshot["variable_store"] is Dictionary:
		return false
	if (
		snapshot.has("presentation_state")
		and not _presentation_snapshot_is_valid(snapshot["presentation_state"])
	):
		return false
	if snapshot.has("chapter_id"):
		if not snapshot["chapter_id"] is String:
			return false
		var chapter_id: String = snapshot["chapter_id"]
		if (
			not chapter_id.is_empty()
			and not scenario_data.chapters.is_empty()
			and scenario_data.get_chapter(chapter_id) == null
		):
			return false
	return true


func _string_array_is_valid(raw_array: Variant) -> bool:
	if not raw_array is Array:
		return false
	for value: Variant in raw_array:
		if not value is String:
			return false
	return true


func _integer_is_valid(value: Variant) -> bool:
	return (
		value is int
		or (
			value is float
			and is_finite(value)
			and value == floor(value)
		)
	)


func _non_negative_number_is_valid(value: Variant) -> bool:
	return (
		(value is int or value is float)
		and is_finite(float(value))
		and float(value) >= 0.0
	)


func _ensure_dir() -> void:
	if not DirAccess.dir_exists_absolute(save_dir):
		DirAccess.make_dir_recursive_absolute(save_dir)
