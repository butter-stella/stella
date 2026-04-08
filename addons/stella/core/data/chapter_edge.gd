## A directed edge in the scenario graph (issue #97 PR-B).
## Represents a possible transition from one chapter to another, discovered
## by ScenarioGraphBuilder via static analysis of the scenario script.
##
## Edge IDs are stable strings derived from (source, target, kind, label),
## suitable for persistence in PR-C's visited_chapter_edges set.
class_name ChapterEdge extends RefCounted

## Edge kind constants — matches the design table in issue #97.
const KIND_JUMP = "jump"               # explicit @jump that crosses chapter boundary
const KIND_CHOICE = "choice"           # @choice option that crosses chapter boundary
const KIND_SEQUENTIAL = "sequential"   # fall-through from last scene of chapter A to first scene of next chapter B
const KIND_CALL = "call"               # @call into another chapter
const KIND_TERMINAL = "terminal"       # execution terminates inside this chapter (no outgoing transition)

## Edge ID component separator. Unit Separator (U+001F) — chosen instead of
## a printable character (e.g. "|") so it cannot collide with characters that
## a chapter id or label might legitimately contain.
const _ID_SEP = "\u001f"

var source_chapter_id: String = ""
## Empty for KIND_TERMINAL edges (no target).
var target_chapter_id: String = ""
var kind: String = ""
## For KIND_CHOICE: the option's label text. Empty otherwise.
var label: String = ""
## Source line of the command that produced this edge (1-based, 0 if unknown).
## Used for click-to-source in the author flowchart UI.
var source_line: int = 0


## Stable identifier suitable for persistence (PR-C's visited_chapter_edges).
## Two edges with the same id are considered the "same edge" for visited
## tracking purposes — duplicates are deduplicated by the builder.
##
## label is included so multiple choice options to the same target are
## distinct (e.g. "选项 A" → ch_x and "选项 B" → ch_x are 2 edges).
func get_edge_id() -> String:
	return source_chapter_id + _ID_SEP + target_chapter_id + _ID_SEP + kind + _ID_SEP + label
