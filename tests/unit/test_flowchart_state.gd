extends GutTest
## Tests for FlowchartState + FlowchartVisitedState (issue #97 PR-C).


# ─── FlowchartState ───

func test_flowchart_state_default_empty():
	var fs = FlowchartState.new()
	assert_eq(fs.current_path.size(), 0)
	assert_eq(fs.chapter_snapshots.size(), 0)
	assert_eq(fs.get_current_chapter_id(), "")


func test_enter_chapter_appends_to_path():
	var fs = FlowchartState.new()
	fs.enter_chapter("prologue", {"hp": 100})
	fs.enter_chapter("ch1", {"hp": 80})
	assert_eq(fs.current_path, ["prologue", "ch1"])
	assert_eq(fs.get_current_chapter_id(), "ch1")


func test_enter_chapter_stores_snapshot():
	var fs = FlowchartState.new()
	fs.enter_chapter("prologue", {"hp": 100})
	assert_eq(fs.chapter_snapshots["prologue"]["hp"], 100)


func test_enter_chapter_overwrites_snapshot_on_revisit():
	var fs = FlowchartState.new()
	fs.enter_chapter("prologue", {"hp": 100})
	fs.enter_chapter("ch1", {"hp": 80})
	fs.enter_chapter("prologue", {"hp": 60})
	assert_eq(fs.chapter_snapshots["prologue"]["hp"], 60,
		"revisit should overwrite the snapshot with the new entry state")
	# Path includes both visits
	assert_eq(fs.current_path, ["prologue", "ch1", "prologue"])


func test_get_snapshot_for_visited_chapter():
	var fs = FlowchartState.new()
	fs.enter_chapter("prologue", {"hp": 100})
	var snap = fs.get_snapshot_for_chapter("prologue")
	assert_eq(snap["hp"], 100)


func test_get_snapshot_for_unvisited_chapter_returns_initial():
	var fs = FlowchartState.new()
	fs.initial_snapshot = {"hp": 0, "starting": true}
	var snap = fs.get_snapshot_for_chapter("never_visited")
	assert_eq(snap["hp"], 0)
	assert_eq(snap["starting"], true)


func test_jump_to_chapter_in_path_truncates_to_last_occurrence():
	var fs = FlowchartState.new()
	fs.enter_chapter("a", {})
	fs.enter_chapter("b", {})
	fs.enter_chapter("c", {})
	fs.enter_chapter("a", {})
	fs.enter_chapter("d", {})
	# Path: [a, b, c, a, d]. Jump to "a" → truncate to last occurrence.
	fs.jump_to("a")
	assert_eq(fs.current_path, ["a", "b", "c", "a"],
		"truncate to last occurrence of 'a'")


func test_jump_to_chapter_off_path_resets():
	var fs = FlowchartState.new()
	fs.enter_chapter("a", {})
	fs.enter_chapter("b", {})
	# Jump to "x" which is not in path.
	fs.jump_to("x")
	assert_eq(fs.current_path, ["x"],
		"off-path jump should reset to just the target")


func test_clear_resets_everything():
	var fs = FlowchartState.new()
	fs.enter_chapter("a", {"hp": 100})
	fs.initial_snapshot = {"init": true}
	fs.clear()
	assert_eq(fs.current_path.size(), 0)
	assert_eq(fs.chapter_snapshots.size(), 0)
	assert_eq(fs.initial_snapshot.size(), 0)


func test_capture_restore_roundtrip():
	var fs = FlowchartState.new()
	fs.enter_chapter("prologue", {"hp": 100})
	fs.enter_chapter("ch1", {"hp": 80})
	var snap = fs.capture_snapshot()

	var fs2 = FlowchartState.new()
	fs2.restore_snapshot(snap)
	assert_eq(fs2.current_path, ["prologue", "ch1"])
	assert_eq(fs2.chapter_snapshots["prologue"]["hp"], 100)
	assert_eq(fs2.chapter_snapshots["ch1"]["hp"], 80)


func test_capture_snapshot_is_independent_copy():
	var fs = FlowchartState.new()
	fs.enter_chapter("a", {"hp": 100})
	var snap = fs.capture_snapshot()
	fs.enter_chapter("b", {"hp": 50})
	# Original snapshot should not be affected by later mutations.
	assert_eq(snap["current_path"].size(), 1)
	assert_false(snap["chapter_snapshots"].has("b"))


func test_provider_id():
	var fs = FlowchartState.new()
	assert_eq(fs.get_provider_id(), "flowchart_state")


# ─── FlowchartVisitedState ───

func test_visited_state_default_empty():
	var vs = FlowchartVisitedState.new()
	assert_false(vs.is_chapter_visited("any"))
	assert_false(vs.is_edge_visited("any"))


func test_mark_chapter_visited():
	var vs = FlowchartVisitedState.new()
	vs.mark_chapter_visited("prologue")
	assert_true(vs.is_chapter_visited("prologue"))
	assert_false(vs.is_chapter_visited("ch1"))


func test_mark_edge_visited():
	var vs = FlowchartVisitedState.new()
	vs.mark_edge_visited("a|b|jump|")
	assert_true(vs.is_edge_visited("a|b|jump|"))
	assert_false(vs.is_edge_visited("a|c|jump|"))


func test_visited_state_capture_restore_roundtrip():
	var vs = FlowchartVisitedState.new()
	vs.mark_chapter_visited("prologue")
	vs.mark_chapter_visited("ch1")
	vs.mark_edge_visited("prologue|ch1|jump|")
	var snap = vs.capture_snapshot()

	var vs2 = FlowchartVisitedState.new()
	vs2.restore_snapshot(snap)
	assert_true(vs2.is_chapter_visited("prologue"))
	assert_true(vs2.is_chapter_visited("ch1"))
	assert_true(vs2.is_edge_visited("prologue|ch1|jump|"))


func test_visited_state_provider_id():
	var vs = FlowchartVisitedState.new()
	assert_eq(vs.get_provider_id(), "flowchart_visited")


# ─── ScenarioGraph.is_deadlocked (#103) ───

func test_is_deadlocked_returns_true_for_zero_edge_chapter():
	var graph = ScenarioGraph.new()
	var ch = ChapterData.new()
	ch.id = "stuck"
	ch.scene_ids.append("s1")
	graph.chapters.append(ch)
	# No edges → deadlock
	assert_true(graph.is_deadlocked("stuck"))


func test_is_deadlocked_returns_false_when_terminal_edge_exists():
	var graph = ScenarioGraph.new()
	var ch = ChapterData.new()
	ch.id = "ending"
	ch.scene_ids.append("s1")
	graph.chapters.append(ch)
	var edge = ChapterEdge.new()
	edge.source_chapter_id = "ending"
	edge.target_chapter_id = ""
	edge.kind = ChapterEdge.KIND_TERMINAL
	graph.edges.append(edge)
	assert_false(graph.is_deadlocked("ending"))


func test_is_deadlocked_returns_false_for_empty_chapter():
	var graph = ScenarioGraph.new()
	var ch = ChapterData.new()
	ch.id = "empty"
	# No scene_ids → parser would have errored; not a deadlock
	graph.chapters.append(ch)
	assert_false(graph.is_deadlocked("empty"))


func test_is_deadlocked_returns_false_for_unknown_chapter():
	var graph = ScenarioGraph.new()
	assert_false(graph.is_deadlocked("nonexistent"))


func test_is_deadlocked_returns_false_when_cross_chapter_edge_exists():
	var graph = ScenarioGraph.new()
	var ch = ChapterData.new()
	ch.id = "has_exit"
	ch.scene_ids.append("s1")
	graph.chapters.append(ch)
	var edge = ChapterEdge.new()
	edge.source_chapter_id = "has_exit"
	edge.target_chapter_id = "other"
	edge.kind = ChapterEdge.KIND_JUMP
	graph.edges.append(edge)
	assert_false(graph.is_deadlocked("has_exit"))
