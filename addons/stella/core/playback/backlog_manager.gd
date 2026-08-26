## Stores dialogue history for the backlog/history screen.
##
## Implements a "browser history" model with a cursor:
## - add_entry on a known path (matches existing entry at cursor+1) only
##   advances the cursor — no duplication.
## - add_entry on a divergent path truncates entries after the cursor.
## - jump_to(index) moves the cursor without truncating, so the user can
##   navigate freely until they actually take a different branch.
##
## Each entry stores a full game-state snapshot captured by the runtime
## (scenario_context + variable_store + presentation_state). Backlog jump
## restores that snapshot directly — no fast-forward replay needed. The
## max_entries cap (default 200) bounds total memory; older entries are
## evicted from the front when exceeded.
##
## NOT a SaveManager provider. The snapshots reference the currently-
## running engine.context and become meaningless across scenario reload.
## Persisting them into save files would balloon save size and risk
## restoring stale rollback points that point at commands which no longer
## exist. Session-only memory state, cleared on every fresh scenario
## entry (see StellaRuntime._prepare_scenario + the other two clear sites).
class_name BacklogManager extends RefCounted

var max_entries: int = 200

var _entries: Array = []
var _cursor: int = -1
var _pending_enrichment: Dictionary = {}


## Add a backlog entry for a dialogue that just fired.
##
## `command_uid` is the stable per-scenario id assigned by
## ScenarioData.assign_command_uids() — used as the divergence-detection
## key. Two entries from the same execution have the same uid; an entry
## that diverges (different choice, different branch) has a different uid.
## Earlier the manager used (scene_index, command_index) which collided
## under @call reuse and dynamic command insertion (issue #88).
func add_entry(
	character: String,
	segments: Array,
	command_uid: int = -1,
	snapshot_func: Callable = Callable(),
	registered_effect_names: Array = [],
	entry_id: String = "",
) -> void:
	var stable_entry_id := (
		entry_id if not entry_id.is_empty() else "command:%d" % command_uid)
	var registered_effect_registry: Dictionary = {}
	for raw_name in registered_effect_names:
		var effect_name := String(raw_name).strip_edges()
		if not effect_name.is_empty():
			registered_effect_registry[effect_name] = true
	# Browser-history: walking known path → just advance the cursor.
	var next_idx = _cursor + 1
	if next_idx < _entries.size():
		var existing: Dictionary = _entries[next_idx]
		var same_execution := (
			int(existing["command_uid"]) == command_uid
			if command_uid >= 0
			else String(existing.get("entry_id", "")) == stable_entry_id
		)
		if same_execution:
			existing["entry_id"] = stable_entry_id
			if _pending_enrichment.has(stable_entry_id):
				var pending: Dictionary = _pending_enrichment[stable_entry_id]
				_update_entry_text(
					existing,
					pending.get("segments", []),
					pending.get("registry", {}),
				)
				_pending_enrichment.erase(stable_entry_id)
			_entries[next_idx] = existing
			_cursor = next_idx
			return
		# Divergence: drop everything after the cursor.
		_entries.resize(_cursor + 1)

	var entry: Dictionary = {
		"character": character,
		"text": "",
		"voices": [],
		"voice_segments": [],
		"command_uid": command_uid,
		"entry_id": stable_entry_id,
		"snapshot": snapshot_func.call() if snapshot_func.is_valid() else null,
	}
	_update_entry_text(entry, segments, registered_effect_registry)
	if _pending_enrichment.has(stable_entry_id):
		var pending: Dictionary = _pending_enrichment[stable_entry_id]
		_update_entry_text(
			entry,
			pending.get("segments", []),
			pending.get("registry", {}),
		)
		_pending_enrichment.erase(stable_entry_id)

	_entries.append(entry)
	_cursor = _entries.size() - 1

	while _entries.size() > max_entries:
		_entries.pop_front()
		_cursor -= 1


## Enrich the already captured entry identified by the canonical request. This
## never consults the mutable browser cursor or current ScenarioContext.
func enrich_entry(
	entry_id: String,
	segments: Array,
	registered_effect_names: Array,
) -> bool:
	if entry_id.is_empty():
		return false
	var registry: Dictionary = {}
	for raw_name in registered_effect_names:
		var effect_name := String(raw_name).strip_edges()
		if not effect_name.is_empty():
			registry[effect_name] = true
	for index in range(_entries.size() - 1, -1, -1):
		var entry: Dictionary = _entries[index]
		if String(entry.get("entry_id", "")) != entry_id:
			continue
		_update_entry_text(entry, segments, registry)
		_entries[index] = entry
		return true
	_pending_enrichment[entry_id] = {
		"segments": segments.duplicate(true),
		"registry": registry.duplicate(true),
	}
	return false


func _update_entry_text(
	entry: Dictionary,
	segments: Array,
	registered_effect_registry: Dictionary,
) -> void:
	var full_text := ""
	var voices: Array = []
	var voice_segments: Array = []
	for seg in segments:
		full_text += DialogueTextNormalizer.to_plain_text(
			String(seg.get("text", "")), registered_effect_registry)
		var layers_value: Variant = seg.get("voice_layers", [])
		if layers_value is Array and not (layers_value as Array).is_empty():
			var layers: Array = (layers_value as Array).duplicate(true)
			for layer_value: Variant in layers:
				if layer_value is Dictionary:
					voices.append(String((layer_value as Dictionary).get("asset", "")))
			voice_segments.append({"voice_layers": layers})
	entry["text"] = full_text
	entry["voices"] = voices
	entry["voice_segments"] = voice_segments


func get_entries() -> Array:
	return _entries


func get_entry(index: int) -> Dictionary:
	if index >= 0 and index < _entries.size():
		return _entries[index]
	return {}


func get_cursor() -> int:
	return _cursor


## Move the cursor to one before `index` and return that entry's snapshot.
## Does NOT truncate — history is preserved so the player can navigate
## back and forth. The cursor lands at `index - 1` so that when the engine
## re-dispatches the dialogue at `index`, the position match advances the
## cursor cleanly without inserting a duplicate.
##
## Returns {} if index is invalid or the entry has no snapshot.
func jump_to(index: int) -> Dictionary:
	if index < 0 or index >= _entries.size():
		return {}
	var entry = _entries[index]
	if entry.get("snapshot") == null:
		return {}
	_cursor = index - 1
	return {
		"snapshot": entry["snapshot"],
		"command_uid": entry["command_uid"],
	}


func clear() -> void:
	_entries.clear()
	_cursor = -1
	_pending_enrichment.clear()
