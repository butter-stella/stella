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
) -> void:
	var registered_effect_registry: Dictionary = {}
	for raw_name in registered_effect_names:
		var effect_name := String(raw_name).strip_edges()
		if not effect_name.is_empty():
			registered_effect_registry[effect_name] = true
	# Presentation enrichment follows the canonical request synchronously. Update
	# that same entry in place; it is not another history traversal.
	if not registered_effect_names.is_empty() \
		and _cursor >= 0 and _cursor < _entries.size() \
		and int(_entries[_cursor].get("command_uid", -2)) == command_uid:
		var current: Dictionary = _entries[_cursor]
		_update_entry_text(current, segments, registered_effect_registry)
		_entries[_cursor] = current
		return
	# Browser-history: walking known path → just advance the cursor.
	var next_idx = _cursor + 1
	if next_idx < _entries.size():
		var existing = _entries[next_idx]
		if existing["command_uid"] == command_uid:
			_cursor = next_idx
			return
		# Divergence: drop everything after the cursor.
		_entries.resize(_cursor + 1)

	var entry: Dictionary = {
		"character": character,
		"text": "",
		"voices": [],
		"command_uid": command_uid,
		"snapshot": snapshot_func.call() if snapshot_func.is_valid() else null,
	}
	_update_entry_text(entry, segments, registered_effect_registry)

	_entries.append(entry)
	_cursor = _entries.size() - 1

	while _entries.size() > max_entries:
		_entries.pop_front()
		_cursor -= 1


func _update_entry_text(
	entry: Dictionary,
	segments: Array,
	registered_effect_registry: Dictionary,
) -> void:
	var full_text := ""
	var voices: Array = []
	for seg in segments:
		full_text += DialogueTextNormalizer.to_plain_text(
			String(seg.get("text", "")), registered_effect_registry)
		var voice := String(seg.get("voice", ""))
		if not voice.is_empty():
			voices.append(voice)
	entry["text"] = full_text
	entry["voices"] = voices


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
