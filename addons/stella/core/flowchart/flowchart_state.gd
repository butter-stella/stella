## Per-save flowchart state — tracks the player's current play-through
## trajectory at chapter granularity (issue #97).
##
## Consumers:
##   - StellaRuntime.jump_from_flowchart: uses jump_to() + get_snapshot()
##   - StellaRuntime scene_changed handler: calls enter_chapter() on transitions
##   - PR-D flowchart UI: reads current_path for "current path" highlighting
##
## SaveManager provider: serialized into each save slot alongside the other
## per-save state (scenario_context, variable_store, presentation_state).
class_name FlowchartState extends RefCounted


## Ordered list of chapter_ids representing the player's trajectory in this
## play-through. Tail = current chapter.
var current_path: Array = []  # Array[String]

## Per-chapter rollback snapshots captured at chapter entry time. Keyed by
## chapter_id; value = rollback snapshot (same format as _capture_rollback_snapshot).
## Overwrites on revisit (most recent entry wins).
var chapter_snapshots: Dictionary = {}  # chapter_id → Dictionary

## Captured once at _prepare_scenario time. Used as fallback for
## jump_to_chapter when the target chapter was never visited (author mode).
var initial_snapshot: Dictionary = {}


## Called when the player enters a new chapter (detected by StellaRuntime
## when scene_changed fires and the new scene's chapter differs from current).
func enter_chapter(chapter_id: String, snapshot: Dictionary) -> void:
	current_path.append(chapter_id)
	chapter_snapshots[chapter_id] = snapshot


## The chapter the player is currently in, or "" if no chapter entered yet.
func get_current_chapter_id() -> String:
	if current_path.size() == 0:
		return ""
	return current_path[-1]


## Get the snapshot to apply when jumping to the given chapter.
## Returns chapter_snapshots[id] if visited, else initial_snapshot.
## Warns if initial_snapshot is empty (indicates _prepare_scenario was
## not called before a jump, which would silently restore empty state).
func get_snapshot_for_chapter(chapter_id: String) -> Dictionary:
	if chapter_snapshots.has(chapter_id):
		return chapter_snapshots[chapter_id]
	if initial_snapshot.is_empty():
		push_warning("FlowchartState: initial_snapshot is empty when jumping to unvisited chapter '%s' — was _prepare_scenario called?" % chapter_id)
	return initial_snapshot


## Update current_path for a flowchart jump. Does NOT apply the snapshot
## (that's StellaRuntime's job, since it involves engine context swap).
##
## Truncates if target is on current_path (last occurrence); otherwise
## resets to [target].
func jump_to(chapter_id: String) -> void:
	# Find last occurrence of chapter_id in current_path.
	var last_idx := -1
	for i in range(current_path.size() - 1, -1, -1):
		if current_path[i] == chapter_id:
			last_idx = i
			break

	if last_idx >= 0:
		# Truncate to the last occurrence (inclusive).
		current_path = current_path.slice(0, last_idx + 1)
	else:
		# Off-path: reset line to just this chapter.
		current_path = [chapter_id]


## Reset all state. Called by StellaRuntime._prepare_scenario on fresh start.
func clear() -> void:
	current_path.clear()
	chapter_snapshots.clear()
	initial_snapshot = {}


# ─── SaveManager Provider interface ───

func get_provider_id() -> String:
	return "flowchart_state"


func capture_snapshot() -> Dictionary:
	return {
		"current_path": current_path.duplicate(),
		"chapter_snapshots": chapter_snapshots.duplicate(true),
	}


func restore_snapshot(snapshot: Dictionary) -> void:
	current_path = snapshot.get("current_path", []).duplicate()
	chapter_snapshots = snapshot.get("chapter_snapshots", {}).duplicate(true)
