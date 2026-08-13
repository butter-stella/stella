## Tracks which authored dialogue commands have been read.
## Used by SkipController to implement "skip only read" behavior.
class_name ReadFlagManager extends RefCounted

const SNAPSHOT_VERSION := 2
## JSON numbers above 2^53 - 1 cannot round-trip every adjacent integer through
## the float representation used by Godot's save parser. Command UIDs are
## non-negative ordinals, so persisted values outside this exact domain are
## corrupt even when float(value) happens to have no fractional component.
const MAX_JSON_SAFE_INTEGER := 9007199254740991
const FIRST_UNSAFE_JSON_INTEGER_FLOAT := 9007199254740992.0

## JSON-encoded [scenario_identity, scene_id, command_uid] -> structured record.
## Encoding the tuple avoids the delimiter collisions in the legacy
## "scenario:scene:index" format.
var _flags: Dictionary = {}
## V1 keys are inherently ambiguous when either authored id contains ':'. Keep
## their raw encoding so compatibility queries preserve the exact old lookup
## semantics instead of inventing a potentially wrong structured tuple.
var _legacy_flags: Dictionary = {}


## Compatibility API for programmatic callers whose scenario identifier is
## already canonical. Runtime dialogue should use mark_dialogue_read().
func mark_read(scenario_id: String, scene_id: String, command_index: int) -> void:
	_store(scenario_id, scene_id, command_index)


func is_read(scenario_id: String, scene_id: String, command_index: int) -> bool:
	return (
		_flags.has(_key(scenario_id, scene_id, command_index))
		or _legacy_flags.has(_legacy_key(
			scenario_id, scene_id, command_index))
	)


func mark_dialogue_read(
	scenario_identity: String,
	scene_id: String,
	command_uid: int,
) -> void:
	_store(scenario_identity, scene_id, command_uid)


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
	return _legacy_flags.has(_legacy_key(
		legacy_scenario_id, scene_id, legacy_command_index))


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
		"legacy_flags": _sorted_legacy_keys(),
	}


## Read history is monotonic within the loaded progress set. Loading an older
## save adds the flags it knew about without erasing later lines. Durable
## cross-session storage still requires loading a save/global progress file.
func restore_snapshot(snapshot: Dictionary) -> void:
	if not snapshot.has("version"):
		_restore_legacy(snapshot)
		return
	var version_value: Variant = snapshot.get("version")
	if not (version_value is int or version_value is float):
		push_error("ReadFlagManager: snapshot version must be numeric")
		return
	var numeric_version := float(version_value)
	if not is_finite(numeric_version) or numeric_version != SNAPSHOT_VERSION:
		push_error(
			"ReadFlagManager: unsupported snapshot version %s"
			% String.num(numeric_version))
		return
	var records: Variant = snapshot.get("flags", null)
	var legacy_records: Variant = snapshot.get("legacy_flags", [])
	if not records is Array or not legacy_records is Array:
		push_error("ReadFlagManager: malformed v2 snapshot")
		return
	if not _validate_v2(records, legacy_records):
		push_error("ReadFlagManager: malformed v2 snapshot record")
		return
	_restore_v2(records, legacy_records)


func _restore_v2(records: Array, legacy_records: Array) -> void:
	for value in records:
		var record: Dictionary = value
		var scenario := String(record["scenario"])
		var scene := String(record["scene"])
		var command_uid := int(record["command_uid"])
		# Interim v2 snapshots may contain a structured legacy marker. Joining
		# the fields reconstructs the original ambiguous v1 string exactly.
		if bool(record.get("legacy", false)):
			_legacy_flags[_legacy_key(scenario, scene, command_uid)] = true
		else:
			_store(scenario, scene, command_uid)
	for legacy_key in legacy_records:
		_legacy_flags[String(legacy_key)] = true


func _validate_v2(records: Array, legacy_records: Array) -> bool:
	for value in records:
		if not value is Dictionary:
			return false
		var record: Dictionary = value
		var command_uid: Variant = record.get("command_uid", null)
		if (
			not record.get("scenario", null) is String
			or not record.get("scene", null) is String
			or not _is_json_integer(command_uid)
			or (
				record.has("legacy")
				and not record.get("legacy") is bool
			)
		):
			return false
	for value in legacy_records:
		if not value is String:
			return false
	return true


func _is_json_integer(value: Variant) -> bool:
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
	var narrowed := int(numeric)
	return float(narrowed) == numeric


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
		if legacy_key.substr(0, final_separator).find(":") <= 0:
			continue
		_legacy_flags[legacy_key] = true


func _store(
	scenario_identity: String,
	scene_id: String,
	command_uid: int,
) -> void:
	var key := _key(scenario_identity, scene_id, command_uid)
	_flags[key] = {
		"scenario": scenario_identity,
		"scene": scene_id,
		"command_uid": command_uid,
	}


func _key(scenario_identity: String, scene_id: String, command_uid: int) -> String:
	return JSON.stringify([scenario_identity, scene_id, command_uid])


func _legacy_key(scenario_id: String, scene_id: String, command_index: int) -> String:
	return "%s:%s:%d" % [scenario_id, scene_id, command_index]


func _sorted_legacy_keys() -> Array:
	var keys := _legacy_flags.keys()
	keys.sort()
	return keys
