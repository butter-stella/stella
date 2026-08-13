## Tracks which authored dialogue commands have been read.
## Used by SkipController to implement "skip only read" behavior.
class_name ReadFlagManager extends RefCounted

const SNAPSHOT_VERSION := 2

## JSON-encoded [scenario_identity, scene_id, command_uid] -> structured record.
## Encoding the tuple avoids the delimiter collisions in the legacy
## "scenario:scene:index" format.
var _flags: Dictionary = {}


## Compatibility API for programmatic callers whose scenario identifier is
## already canonical. Runtime dialogue should use mark_dialogue_read().
func mark_read(scenario_id: String, scene_id: String, command_index: int) -> void:
	_store(scenario_id, scene_id, command_index, false)


func is_read(scenario_id: String, scene_id: String, command_index: int) -> bool:
	return _flags.has(_key(scenario_id, scene_id, command_index))


func mark_dialogue_read(
	scenario_identity: String,
	scene_id: String,
	command_uid: int,
) -> void:
	_store(scenario_identity, scene_id, command_uid, false)


## New snapshots query the canonical authored identity. The legacy alias is
## consulted only for records actually migrated from a v1 save, so newly read
## equal-basename scenarios cannot collide through the compatibility path.
func is_dialogue_read(
	scenario_identity: String,
	legacy_scenario_id: String,
	scene_id: String,
	command_uid: int,
	legacy_command_index: int,
) -> bool:
	if is_read(scenario_identity, scene_id, command_uid):
		return true
	if legacy_scenario_id.is_empty() or legacy_command_index < 0:
		return false
	var legacy: Dictionary = _flags.get(
		_key(legacy_scenario_id, scene_id, legacy_command_index), {})
	return bool(legacy.get("legacy", false))


func get_provider_id() -> String:
	return "read_flags"


func capture_snapshot() -> Dictionary:
	var keys := _flags.keys()
	keys.sort()
	var records: Array = []
	for key in keys:
		records.append((_flags[key] as Dictionary).duplicate(true))
	return {
		"version": SNAPSHOT_VERSION,
		"flags": records,
	}


## Read history is monotonic within the loaded progress set. Loading an older
## save adds the flags it knew about without erasing later lines. Durable
## cross-session storage still requires loading a save/global progress file.
func restore_snapshot(snapshot: Dictionary) -> void:
	if (
		int(snapshot.get("version", 0)) == SNAPSHOT_VERSION
		and snapshot.get("flags", null) is Array
	):
		_restore_v2(snapshot.get("flags", []))
		return
	_restore_legacy(snapshot)


func _restore_v2(records: Array) -> void:
	for value in records:
		if not value is Dictionary:
			continue
		var record: Dictionary = value
		if (
			not record.has("scenario")
			or not record.has("scene")
			or not record.has("command_uid")
		):
			continue
		_store(
			String(record["scenario"]),
			String(record["scene"]),
			int(record["command_uid"]),
			bool(record.get("legacy", false)),
		)


func _restore_legacy(snapshot: Dictionary) -> void:
	for value in snapshot:
		if not bool(snapshot[value]):
			continue
		var legacy_key := String(value)
		var final_separator := legacy_key.rfind(":")
		if final_separator <= 0:
			continue
		var command_text := legacy_key.substr(final_separator + 1)
		if not command_text.is_valid_int():
			continue
		var prefix := legacy_key.substr(0, final_separator)
		var first_separator := prefix.find(":")
		if first_separator <= 0 or first_separator >= prefix.length() - 1:
			continue
		_store(
			prefix.substr(0, first_separator),
			prefix.substr(first_separator + 1),
			int(command_text),
			true,
		)


func _store(
	scenario_identity: String,
	scene_id: String,
	command_uid: int,
	legacy: bool,
) -> void:
	var key := _key(scenario_identity, scene_id, command_uid)
	var existing: Dictionary = _flags.get(key, {})
	var is_legacy_record := (
		legacy
		if existing.is_empty()
		else legacy and bool(existing.get("legacy", false))
	)
	_flags[key] = {
		"scenario": scenario_identity,
		"scene": scene_id,
		"command_uid": command_uid,
		# Once a canonical record exists it must not become a basename fallback
		# merely because an old save containing the same tuple is loaded later.
		"legacy": is_legacy_record,
	}


func _key(scenario_identity: String, scene_id: String, command_uid: int) -> String:
	return JSON.stringify([scenario_identity, scene_id, command_uid])
