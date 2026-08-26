## Stores a stack of rollback snapshots captured at each @choice command,
## powering the "回到上一选项" (rewind to previous choice) toolbar action.
##
## A snapshot is pushed every time ChoiceHandler emits `choice_show`, and
## `pop_previous()` returns the snapshot for the most-recent choice that
## the player ISN'T currently parked on — so pressing the button while
## awaiting choice N lands on choice N-1, and pressing after picking choice
## N and walking forward lands back on N.
##
## Divergence handling: after pop_previous returns a snapshot, that entry
## (and everything above it) is dropped. When the engine re-dispatches the
## choice, its choice_show listener pushes a fresh entry in its place. This
## keeps the stack accurate regardless of which option is picked on the
## rewind.
##
## The max_entries cap (default 50) bounds memory; older entries are
## evicted from the front when exceeded — matching BacklogManager's policy.
##
## NOT a SaveManager provider. The snapshots here reference the currently-
## running engine.context and become meaningless across scenario reload.
## Persisting them into save files would balloon save size and risk
## restoring stale rollback points that point at commands which no longer
## exist. Session-only memory state, cleared on every fresh scenario entry
## alongside backlog_manager (see StellaRuntime._prepare_scenario / the
## other two clear sites).
class_name ChoiceHistoryManager extends RefCounted

var max_entries: int = 50

var _entries: Array = []


## Record a choice that was just surfaced to the player. `command_uid` is
## the stable per-scenario id of the choice command; `snapshot_func` is
## called synchronously to capture the rollback state at the moment of
## the choice_show emission.
func record(command_uid: int, snapshot_func: Callable) -> void:
	var snapshot = snapshot_func.call() if snapshot_func.is_valid() else null
	_entries.append({
		"command_uid": command_uid,
		"snapshot": snapshot,
	})
	while _entries.size() > max_entries:
		_entries.pop_front()


## True if there's a snapshot the player can rewind to — i.e. some entry
## exists that ISN'T the choice they're currently parked on.
func has_previous(current_cmd_uid: int) -> bool:
	for i in range(_entries.size() - 1, -1, -1):
		if _entries[i]["command_uid"] != current_cmd_uid:
			return true
	return false


## Return the most recent snapshot whose command_uid != current_cmd_uid,
## and truncate the stack to drop that entry (and anything above it —
## including the currently-parked-on entry if we skipped it). Returns
## {} when no such snapshot exists.
##
## Why skip the top when it matches: if the player is awaiting choice N
## (current_cmd_uid == top entry's uid), "回到上一选项" semantically means
## "the choice BEFORE this one", not "this same choice". Skipping the top
## makes the button feel non-trivial in that state.
##
## Why truncate including the skipped top: the skipped entry is also being
## navigated away from — keeping it would leave a stale snapshot that a
## subsequent pop could return. On rewind, the engine re-runs the target
## choice, its choice_show listener re-records it, and the stack is
## correct again.
##
## TODO(@call re-entrance): if the same @choice command is reached via a
## @call and the return stack, its uid will appear twice in _entries. The
## skip-top rule would skip the inner reentrance and return the outer
## frame — probably not what the player expects. Rare in practice; refine
## once @call is used with choices inside called scenes.
func pop_previous(current_cmd_uid: int) -> Dictionary:
	var info := peek_previous(current_cmd_uid)
	if info.is_empty() or not commit_previous(current_cmd_uid):
		return {}
	info.erase("target_index")
	return info


func peek_previous(current_cmd_uid: int) -> Dictionary:
	var target_idx := -1
	for i in range(_entries.size() - 1, -1, -1):
		if _entries[i]["command_uid"] != current_cmd_uid:
			target_idx = i
			break
	if target_idx == -1:
		return {}
	var snap = _entries[target_idx]["snapshot"]
	if snap == null:
		# Defensive: don't truncate on a malformed entry — that would lose
		# valid history below. Callers pass a live Callable in practice so
		# this branch shouldn't fire, but the earlier `is_valid()` guard in
		# record() implies we should handle the null case without side
		# effects.
		return {}
	return {"snapshot": snap, "target_index": target_idx}


func commit_previous(current_cmd_uid: int) -> bool:
	var info := peek_previous(current_cmd_uid)
	if info.is_empty():
		return false
	_entries.resize(int(info["target_index"]))
	return true


func clear() -> void:
	_entries.clear()


func size() -> int:
	return _entries.size()
