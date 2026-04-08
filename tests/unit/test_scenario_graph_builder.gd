extends GutTest
## Tests for ScenarioGraphBuilder — static analysis of chapter-level structure
## (issue #97 PR-B).
##
## Each test parses a small DSL fragment, builds the graph, and asserts on
## the resulting nodes/edges. Edge assertions use a helper that finds an edge
## by (source, target, kind) tuple.


func _build(source: String) -> ScenarioGraph:
	var tokens = DslLexer.tokenize(source)
	var data = DslParser.parse(tokens, "test")
	return ScenarioGraphBuilder.build(data)


func _has_edge(graph: ScenarioGraph, source: String, target: String, kind: String, label: String = "") -> bool:
	for e in graph.edges:
		if e.source_chapter_id == source and e.target_chapter_id == target and e.kind == kind:
			if label == "" or e.label == label:
				return true
	return false


func _count_edges_from(graph: ScenarioGraph, source: String) -> int:
	return graph.get_outgoing_edges(source).size()


# ─── ScenarioGraph data class ───

func test_graph_default_empty():
	var g = ScenarioGraph.new()
	assert_eq(g.chapters.size(), 0)
	assert_eq(g.edges.size(), 0)
	assert_eq(g.diagnostics.size(), 0)


func test_graph_chapters_reference_scenario_data():
	# Built graph holds the same ChapterData instances as the source ScenarioData.
	var graph = _build("@chapter ch\n@scene s\nsakura「a」")
	assert_eq(graph.chapters.size(), 1)
	assert_eq(graph.chapters[0].id, "ch")


# ─── Node enumeration ───

func test_single_chapter_zero_edges():
	# A scenario with one chapter and one terminal scene → no outgoing edges
	# except a TERMINAL marker.
	var graph = _build("@chapter only\n@scene s\nsakura「end」")
	assert_eq(graph.chapters.size(), 1)
	assert_true(_has_edge(graph, "only", "", ChapterEdge.KIND_TERMINAL),
		"single chapter with no jumps should produce a terminal edge")


func test_two_chapters_sequential_fallthrough():
	# Chapter A's last scene falls through to chapter B's first scene → sequential edge.
	var graph = _build("""@chapter a
@scene s_a
sakura「a」
@chapter b
@scene s_b
sakura「b」""")
	assert_true(_has_edge(graph, "a", "b", ChapterEdge.KIND_SEQUENTIAL),
		"fallthrough A → B should be a sequential edge")
	# B has no further chapters, so it terminates.
	assert_true(_has_edge(graph, "b", "", ChapterEdge.KIND_TERMINAL))


# ─── @jump edges ───

func test_explicit_jump_cross_chapter():
	var graph = _build("""@chapter a
@scene s_a
sakura「a」
@jump s_b
@chapter b
@scene s_b
sakura「b」""")
	assert_true(_has_edge(graph, "a", "b", ChapterEdge.KIND_JUMP),
		"@jump s_b should create a JUMP edge a → b")
	# fallthrough fall-through is replaced by the jump; no sequential edge
	assert_false(_has_edge(graph, "a", "b", ChapterEdge.KIND_SEQUENTIAL))


func test_internal_jump_does_not_create_edge():
	# @jump within the same chapter is internal flow, not a graph edge.
	var graph = _build("""@chapter a
@scene s1
@jump s2
@scene s2
sakura「end」""")
	# Internal jump has no edge; the chapter still terminates.
	assert_eq(_count_edges_from(graph, "a"), 1,
		"single internal jump should produce only the terminal edge")
	assert_true(_has_edge(graph, "a", "", ChapterEdge.KIND_TERMINAL))


# ─── @choice edges ───

func test_choice_cross_chapter_options():
	var graph = _build("""@chapter a
@scene s_a
@choice
  - "go to b" -> s_b
  - "go to c" -> s_c
@chapter b
@scene s_b
sakura「b」
@chapter c
@scene s_c
sakura「c」""")
	assert_true(_has_edge(graph, "a", "b", ChapterEdge.KIND_CHOICE, "go to b"))
	assert_true(_has_edge(graph, "a", "c", ChapterEdge.KIND_CHOICE, "go to c"))


func test_choice_internal_branch_does_not_create_edge():
	# A choice option that jumps to another scene WITHIN the same chapter
	# is just internal flow, not a flowchart edge.
	var graph = _build("""@chapter a
@scene s1
@choice
  - "branch" -> s2
@scene s2
sakura「end」""")
	# No cross-chapter edge. Just a terminal.
	assert_eq(_count_edges_from(graph, "a"), 1)
	assert_true(_has_edge(graph, "a", "", ChapterEdge.KIND_TERMINAL))


# ─── @call edges ───

func test_call_cross_chapter():
	var graph = _build("""@chapter a
@scene s_a
@call s_b
sakura「back」
@chapter b
@scene s_b
sakura「sub」""")
	assert_true(_has_edge(graph, "a", "b", ChapterEdge.KIND_CALL),
		"@call to a scene in another chapter should create a CALL edge")


# ─── @if branches ───

func test_if_else_branches_recurse_into_synthetic_scenes():
	# @if expansion creates synthetic scenes. The walker must follow both
	# branches but treat the synthetic scenes as internal (no extra edges).
	var graph = _build("""@chapter a
@scene s_a
@if some_flag
sakura「then」
@else
sakura「else」
@end
@jump s_b
@chapter b
@scene s_b
sakura「b」""")
	# Only one cross-chapter edge: a → b via @jump
	assert_true(_has_edge(graph, "a", "b", ChapterEdge.KIND_JUMP))
	assert_eq(_count_edges_from(graph, "a"), 1,
		"if/else branches should be transparent — only the post-if @jump produces an edge")


# ─── Loop / cycle handling ───

func test_internal_cycle_does_not_infinite_loop():
	# A scene that jumps back to itself (or to an earlier scene in the same
	# chapter) must not crash the walker. Cycle detection per-walk is required.
	var graph = _build("""@chapter a
@scene s1
@jump s1""")
	# Just don't crash; the chapter has no cross-chapter edges.
	assert_eq(_count_edges_from(graph, "a"), 0,
		"infinite-loop chapter has no terminal and no cross-chapter edges")


# ─── Lint warnings ───

func test_cross_chapter_jump_to_non_entry_scene_emits_warning():
	# Issue #97: @jump that targets a scene which is NOT its chapter's first
	# (entry) scene should emit a lint warning. Author can still do this; the
	# warning just says "you probably meant the chapter's entry scene".
	var graph = _build("""@chapter a
@scene s_a
@jump s_b_internal
@chapter b
@scene s_b_entry
sakura「entry」
@scene s_b_internal
sakura「internal」""")
	var saw_warning := false
	for d in graph.diagnostics:
		if d.get("level") == "warning" and "non-entry" in str(d.get("message", "")):
			saw_warning = true
	assert_true(saw_warning,
		"cross-chapter jump to non-entry scene should produce a lint warning")


func test_cross_chapter_jump_to_entry_scene_no_warning():
	var graph = _build("""@chapter a
@scene s_a
@jump s_b
@chapter b
@scene s_b
sakura「b」""")
	# Both: the JUMP edge exists (proves the cross-chapter path works)
	# AND no non-entry warning is emitted.
	assert_true(_has_edge(graph, "a", "b", ChapterEdge.KIND_JUMP),
		"jump to entry scene should still produce a JUMP edge")
	for d in graph.diagnostics:
		assert_false("non-entry" in str(d.get("message", "")),
			"jump to entry scene should not warn; got: %s" % d.get("message"))


# ─── Edge ID stability ───

func test_edge_id_includes_label_for_choice_disambiguation():
	# Two choice options to the same target chapter must have distinct edge
	# IDs (otherwise visited tracking in PR-C can't distinguish them).
	var graph = _build("""@chapter a
@scene s_a
@choice
  - "选项 A" -> s_b
  - "选项 B" -> s_b
@chapter b
@scene s_b
sakura「b」""")
	var ids := {}
	for e in graph.get_outgoing_edges("a"):
		if e.kind == ChapterEdge.KIND_CHOICE:
			ids[e.get_edge_id()] = true
	assert_eq(ids.size(), 2,
		"two choice options to the same chapter must have distinct edge IDs")


func test_edge_id_stable_format():
	var e = ChapterEdge.new()
	e.source_chapter_id = "src"
	e.target_chapter_id = "dst"
	e.kind = ChapterEdge.KIND_JUMP
	assert_eq(e.get_edge_id(), "src|dst|jump|")


# ─── Source line propagation ───

func test_jump_edge_carries_source_line():
	# The line number of the @jump command is captured for click-to-source.
	var graph = _build("""@chapter a
@scene s_a
@jump s_b
@chapter b
@scene s_b
sakura「b」""")
	for e in graph.edges:
		if e.kind == ChapterEdge.KIND_JUMP:
			assert_gt(e.source_line, 0,
				"@jump edge should carry a non-zero source line")


# ─── Deduplication ───

func test_duplicate_edges_collapsed():
	# If multiple internal paths converge into the same cross-chapter @jump
	# (e.g. both @if branches jump to the same external scene), the edge
	# should appear only once.
	var graph = _build("""@chapter a
@scene s_a
@if x
@jump s_b
@else
@jump s_b
@end
@chapter b
@scene s_b
sakura「b」""")
	var jump_edges := 0
	for e in graph.edges:
		if e.kind == ChapterEdge.KIND_JUMP and e.source_chapter_id == "a" and e.target_chapter_id == "b":
			jump_edges += 1
	assert_eq(jump_edges, 1,
		"convergent jumps from both if branches should produce only one edge")
