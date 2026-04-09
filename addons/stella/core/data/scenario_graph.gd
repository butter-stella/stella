## Static analysis result of a scenario's chapter-level structure (issue #97).
##
## Built by ScenarioGraphBuilder from a parsed ScenarioData. Each ChapterData
## is a node; each cross-chapter transition (jump / choice / sequential / call /
## terminal) is a ChapterEdge.
##
## Consumers:
##   - PR-C: jump_to_chapter API uses get_chapter / get_outgoing_edges
##   - PR-D: flowchart UI renders nodes + edges, click-to-source uses
##           ChapterData.declared_line and ChapterEdge.source_line
##
## The graph is a pure data class (no signals, no engine reference). It is
## constructed once after parse and is immutable thereafter.
class_name ScenarioGraph extends RefCounted

var scenario_id: String = ""
## Reference to the chapters this graph indexes. Same instances as
## ScenarioData.chapters — not duplicated. Order matches declaration order.
var chapters: Array = []  # Array[ChapterData]
var edges: Array = []     # Array[ChapterEdge]
## Lint-level diagnostics from the graph builder (e.g. cross-chapter jump
## to non-entry scene). Same shape as ScenarioData.diagnostics:
## {level: "warning"|"error", message: String, line: int}.
var diagnostics: Array = []


func get_chapter(chapter_id: String) -> ChapterData:
	for ch in chapters:
		if ch.id == chapter_id:
			return ch
	return null


## All edges originating from the given chapter (in declaration / discovery order).
func get_outgoing_edges(chapter_id: String) -> Array:
	var result: Array = []
	for edge in edges:
		if edge.source_chapter_id == chapter_id:
			result.append(edge)
	return result


## All edges leading into the given chapter.
func get_incoming_edges(chapter_id: String) -> Array:
	var result: Array = []
	for edge in edges:
		if edge.target_chapter_id == chapter_id:
			result.append(edge)
	return result


## Returns true if the chapter has scenes but no outgoing edges — i.e., the
## player would be stuck if execution reached this chapter and didn't
## terminate naturally. Builder marks this with a "no outgoing transitions"
## diagnostic (see issue #103).
##
## Returns false for: empty chapters (parser error, not deadlock), non-existent
## chapters, and chapters that have at least one outgoing edge (including
## KIND_TERMINAL, which is a natural end).
func is_deadlocked(chapter_id: String) -> bool:
	if get_outgoing_edges(chapter_id).size() > 0:
		return false
	var ch = get_chapter(chapter_id)
	if ch == null or ch.scene_ids.size() == 0:
		return false
	return true
