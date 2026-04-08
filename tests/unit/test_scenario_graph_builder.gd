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

func test_internal_cycle_emits_deadlock_diagnostic():
	# A scene that jumps back to itself with no escape: walker must not loop
	# forever, and the chapter MUST be flagged as deadlock so PR-D can show
	# the author / PR-C can refuse to leave.
	var graph = _build("""@chapter a
@scene s1
@jump s1""")
	# Chapter still exists in the graph (regression guard against the chapter
	# being silently dropped).
	assert_not_null(graph.get_chapter("a"), "deadlock chapter must remain in graph")
	# No outgoing edges (player is stuck — not "terminal", which means natural end).
	assert_eq(_count_edges_from(graph, "a"), 0,
		"deadlock chapter has 0 outgoing edges")
	# Deadlock diagnostic surfaced.
	var saw_deadlock := false
	for d in graph.diagnostics:
		if d.get("level") == "warning" and "no outgoing transitions" in str(d.get("message", "")):
			saw_deadlock = true
	assert_true(saw_deadlock, "deadlock chapter should produce a 'no outgoing transitions' warning")


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
	# Fields joined by U+001F (Unit Separator). 4 fields → 3 separators.
	var sep = "\u001f"
	assert_eq(e.get_edge_id(), "src" + sep + "dst" + sep + "jump" + sep + "")


# ─── Source line propagation ───

func test_jump_edge_carries_source_line():
	# The line number of the @jump command is captured for click-to-source.
	# @jump is on line 3 of the fixture below.
	var graph = _build("""@chapter a
@scene s_a
@jump s_b
@chapter b
@scene s_b
sakura「b」""")
	var found_jump := false
	for e in graph.edges:
		if e.kind == ChapterEdge.KIND_JUMP:
			found_jump = true
			assert_eq(e.source_line, 3,
				"@jump edge should carry the exact source line of the @jump command")
	assert_true(found_jump, "fixture should produce at least one JUMP edge")


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
	# Regression guard: ensure walker actually emitted the edge (otherwise
	# the equality check below would trivially pass on a "drops everything" bug).
	assert_gt(jump_edges, 0, "convergent jump fixture must produce at least one edge")
	assert_eq(jump_edges, 1,
		"convergent jumps from both if branches should produce only one edge")


# ─── Round 2 fixes (CR feedback) ───

func test_cross_chapter_cycle_terminates_and_emits_edges():
	# CR sonnet C11: A → B → C → A. Walker must terminate (per-chapter
	# visited_scenes scope means each walk is bounded), and the resulting
	# graph contains all 3 cross-chapter edges.
	var graph = _build("""@chapter a
@scene s_a
@jump s_b
@chapter b
@scene s_b
@jump s_c
@chapter c
@scene s_c
@jump s_a""")
	assert_true(_has_edge(graph, "a", "b", ChapterEdge.KIND_JUMP))
	assert_true(_has_edge(graph, "b", "c", ChapterEdge.KIND_JUMP))
	assert_true(_has_edge(graph, "c", "a", ChapterEdge.KIND_JUMP))


func test_cross_chapter_jump_to_unknown_scene_emits_diagnostic():
	# CR sonnet C9: a typo'd @jump target previously was a silent skip.
	# Now the builder records a diagnostic so PR-D can show the typo.
	var graph = _build("""@chapter a
@scene s_a
@jump s_typo
@chapter b
@scene s_b
sakura「b」""")
	var saw_diag := false
	for d in graph.diagnostics:
		if "unknown scene" in str(d.get("message", "")) and "s_typo" in str(d.get("message", "")):
			saw_diag = true
	assert_true(saw_diag, "typo'd jump target should produce 'unknown scene' diagnostic")


func test_get_incoming_edges_returns_inbound():
	# CR sonnet C12: get_incoming_edges API was untested. A typo in the
	# target_chapter_id check would have gone unnoticed.
	var graph = _build("""@chapter a
@scene s_a
@jump s_b
@chapter b
@scene s_b
sakura「b」""")
	var incoming = graph.get_incoming_edges("b")
	assert_eq(incoming.size(), 1, "chapter b should have exactly 1 incoming edge")
	assert_eq(incoming[0].source_chapter_id, "a")
	assert_eq(incoming[0].target_chapter_id, "b")
	# Chapter a has no inbound (cycle test covers the inbound-from-itself case)
	assert_eq(graph.get_incoming_edges("a").size(), 0)


func test_cross_chapter_sequential_dedup():
	# CR opus: A has multiple internal scenes that all fall through into B.
	# All paths produce the same edge_id (a, b, sequential, "") and dedup
	# keeps just one. Without dedup, the graph would double-count.
	var graph = _build("""@chapter a
@scene s_a1
sakura「one」
@scene s_a2
sakura「two」
@chapter b
@scene s_b
sakura「b」""")
	var seq_edges := 0
	for e in graph.edges:
		if e.kind == ChapterEdge.KIND_SEQUENTIAL and e.source_chapter_id == "a":
			seq_edges += 1
	assert_eq(seq_edges, 1,
		"multiple internal-fallthrough paths must collapse to a single sequential edge")


func test_chapter_data_get_entry_scene_id():
	# CR opus: ChapterData.get_entry_scene_id() helper.
	var ch = ChapterData.new()
	assert_eq(ch.get_entry_scene_id(), "", "empty chapter returns empty string")
	ch.scene_ids.append("first")
	ch.scene_ids.append("second")
	assert_eq(ch.get_entry_scene_id(), "first")


func test_edge_id_uses_unit_separator_not_pipe():
	# CR sonnet B7: edge ID separator changed from `|` to U+001F so chapter
	# ids and labels containing `|` cannot collide.
	var e = ChapterEdge.new()
	e.source_chapter_id = "src|with|pipe"
	e.target_chapter_id = "dst"
	e.kind = ChapterEdge.KIND_JUMP
	# The id should NOT use `|` as a separator — verify by checking that the
	# substring "src|with|pipe" appears intact (not split by the separator).
	var eid = e.get_edge_id()
	assert_true("src|with|pipe" in eid,
		"chapter id with `|` should appear unsplit in the edge id")
	assert_true("\u001f" in eid,
		"edge id should use Unit Separator U+001F as the field separator")


func test_empty_chapter_skipped_silently_by_builder():
	# Defensive: parser would normally error on empty chapter, but the
	# builder must not crash if given a manually-constructed empty chapter.
	var data = ScenarioData.new()
	data.id = "test"
	var ch = ChapterData.new()
	ch.id = "empty"
	data.chapters.append(ch)
	var graph = ScenarioGraphBuilder.build(data)
	# Builder should produce a graph with the empty chapter as a node and
	# no outgoing edges (and no crash).
	assert_eq(graph.chapters.size(), 1)
	assert_eq(graph.get_outgoing_edges("empty").size(), 0)
