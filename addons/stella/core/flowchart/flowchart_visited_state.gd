## Global (cross-playthrough) flowchart visited state (issue #97).
##
## Tracks which chapters and edges the player has ever reached across all
## play-throughs. Used by PR-D's flowchart UI to distinguish visited vs
## unvisited nodes/edges.
##
## SaveManager provider: persisted independently of per-save data. Registered
## alongside other monotonic providers (read_flags, unlock_manager).
class_name FlowchartVisitedState extends RefCounted


## chapter_id → true (Set emulation via Dictionary).
var visited_chapters: Dictionary = {}

## edge_id (from ChapterEdge.get_edge_id()) → true.
var visited_chapter_edges: Dictionary = {}


func mark_chapter_visited(chapter_id: String) -> void:
	visited_chapters[chapter_id] = true


func is_chapter_visited(chapter_id: String) -> bool:
	return visited_chapters.has(chapter_id)


func mark_edge_visited(edge_id: String) -> void:
	visited_chapter_edges[edge_id] = true


func is_edge_visited(edge_id: String) -> bool:
	return visited_chapter_edges.has(edge_id)


# ─── SaveManager Provider interface ───

func get_provider_id() -> String:
	return "flowchart_visited"


func capture_snapshot() -> Dictionary:
	return {
		"visited_chapters": visited_chapters.duplicate(),
		"visited_chapter_edges": visited_chapter_edges.duplicate(),
	}


## Merge (union), NOT overwrite. Visited state is monotonic — loading an old
## save must never erase progress accumulated in other playthroughs.
##
## SaveManager calls restore_snapshot on every load_save. Without merge,
## loading save slot 1 (visited={A,B}) after visiting C in a new game
## would wipe C. With merge, the result is {A,B,C}.
##
## Note: this means the in-memory visited set is the union of all saves
## ever loaded in this session. For a fully correct cross-session global,
## a separate persistence file would be needed (see follow-up issue).
func restore_snapshot(snapshot: Dictionary) -> void:
	var loaded_chapters = snapshot.get("visited_chapters", {})
	for key in loaded_chapters:
		visited_chapters[key] = true
	var loaded_edges = snapshot.get("visited_chapter_edges", {})
	for key in loaded_edges:
		visited_chapter_edges[key] = true
