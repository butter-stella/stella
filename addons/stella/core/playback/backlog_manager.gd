## Stores dialogue history for the backlog/history screen.
##
## Implements a "browser history" model with a cursor:
## - add_entry on a known path (matches existing entry at cursor+1) only
##   advances the cursor — no duplication.
## - add_entry on a divergent path truncates entries after the cursor.
## - jump_to(index) moves the cursor without truncating, so the user can
##   navigate freely until they actually take a different branch.
##
## Sparse anchor snapshots: every Nth entry (anchor_interval) plus any entry
## flagged via force_next_anchor() carries a full snapshot dict. Other
## entries store only their (scene_index, command_index) position. The
## consumer can replay forward from the nearest preceding anchor to reach
## any target entry.
##
## When trimming from the front for max_entries, an evicted entry that
## carried a snapshot becomes the _head_anchor, ensuring jump_to from any
## remaining index can still find a usable replay starting point.
class_name BacklogManager extends RefCounted

var max_entries: int = 100
var anchor_interval: int = 10

var _entries: Array = []
var _cursor: int = -1
var _force_next_anchor: bool = false
## {scene_index, command_index, snapshot} for entries that fell out of the
## window. Null if none.
var _head_anchor: Variant = null
## Monotonic counter — increments only on actual append (not on cursor
## advance over a known path), used to space out interval anchors.
var _append_count: int = 0


func add_entry(character: String, segments: Array, scene_index: int = 0, command_index: int = 0, snapshot_func: Callable = Callable()) -> void:
	# Browser-history: walking known path → just advance the cursor.
	var next_idx = _cursor + 1
	if next_idx < _entries.size():
		var existing = _entries[next_idx]
		if existing["scene_index"] == scene_index and existing["command_index"] == command_index:
			_cursor = next_idx
			return
		# Divergence: drop everything after the cursor.
		_entries.resize(_cursor + 1)

	var full_text := ""
	var voices: Array = []
	for seg in segments:
		full_text += String(seg.get("text", ""))
		var v := String(seg.get("voice", ""))
		if v != "":
			voices.append(v)

	var entry: Dictionary = {
		"character": character,
		"text": full_text,
		"voices": voices,
		"scene_index": scene_index,
		"command_index": command_index,
		"snapshot": null,
	}

	var should_anchor := _force_next_anchor or (_append_count % anchor_interval == 0)
	if should_anchor and snapshot_func.is_valid():
		entry["snapshot"] = snapshot_func.call()
	_force_next_anchor = false
	_append_count += 1

	_entries.append(entry)
	_cursor = _entries.size() - 1

	while _entries.size() > max_entries:
		var dropped = _entries.pop_front()
		if dropped.get("snapshot") != null:
			_head_anchor = {
				"scene_index": dropped["scene_index"],
				"command_index": dropped["command_index"],
				"snapshot": dropped["snapshot"],
			}
		_cursor -= 1


func get_entries() -> Array:
	return _entries


func get_entry(index: int) -> Dictionary:
	if index >= 0 and index < _entries.size():
		return _entries[index]
	return {}


func get_cursor() -> int:
	return _cursor


func get_head_anchor() -> Variant:
	return _head_anchor


## Mark the next add_entry to carry a snapshot regardless of interval. Used
## by the runtime after engine scene_changed events so each branch boundary
## has an anchor — replay between consecutive anchors is always linear.
func force_next_anchor() -> void:
	_force_next_anchor = true


## Move the cursor to `index` and return the replay info needed to restore
## state at that entry. Does NOT truncate. Returns {} if index invalid.
##
## Result: {snapshot, anchor_scene_index, anchor_command_index,
## target_scene_index, target_command_index}
func jump_to(index: int) -> Dictionary:
	if index < 0 or index >= _entries.size():
		return {}
	var target = _entries[index]
	# Search backwards from index for an anchor entry.
	var i = index
	while i >= 0:
		var e = _entries[i]
		if e.get("snapshot") != null:
			# Cursor sits one BEFORE the target so when the target dialogue
			# re-fires (after replay reaches it) the position match path
			# advances cursor to `index` instead of treating it as a new
			# divergent entry.
			_cursor = index - 1
			return {
				"snapshot": e["snapshot"],
				"anchor_scene_index": e["scene_index"],
				"anchor_command_index": e["command_index"],
				"target_scene_index": target["scene_index"],
				"target_command_index": target["command_index"],
			}
		i -= 1
	# Fall back to head_anchor (anchor that fell out of the window).
	if _head_anchor != null:
		_cursor = index - 1
		return {
			"snapshot": _head_anchor["snapshot"],
			"anchor_scene_index": _head_anchor["scene_index"],
			"anchor_command_index": _head_anchor["command_index"],
			"target_scene_index": target["scene_index"],
			"target_command_index": target["command_index"],
		}
	return {}


func clear() -> void:
	_entries.clear()
	_cursor = -1
	_force_next_anchor = false
	_head_anchor = null
	_append_count = 0
