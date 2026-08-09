## Builds a chapter-level ScenarioGraph from a parsed ScenarioData (issue #97).
##
## Algorithm:
##   For each chapter, walk execution starting from its entry scene
##   (chapter.scene_ids[0]). Walk transparently through internal jumps,
##   choices, calls, and synthetic if/elif scenes. When the walker reaches
##   a transition that crosses into a different chapter, emit an edge.
##   When the walker exhausts paths without crossing out, emit a terminal
##   edge.
##
## The walker is per-chapter scoped — it tracks visited scenes within the
## current walk to avoid infinite loops on internal cycles. Edge dedup is
## by edge_id, so convergent internal paths into the same external target
## produce only one edge.
class_name ScenarioGraphBuilder extends RefCounted


## Build a graph from parsed ScenarioData. Returns an empty graph if data is
## null. Graph references the same ChapterData instances as the input.
static func build(data: ScenarioData) -> ScenarioGraph:
	var graph = ScenarioGraph.new()
	if data == null:
		return graph
	graph.scenario_id = data.id
	graph.chapters = data.chapters

	for chapter in data.chapters:
		_build_for_chapter(chapter, data, graph)

	return graph


## Walk all scenes reachable from the chapter entry, emitting cross-chapter
## edges as boundaries are crossed. Falls through to a terminal edge if no
## non-internal path leads out.
static func _build_for_chapter(chapter: ChapterData, data: ScenarioData, graph: ScenarioGraph) -> void:
	if chapter.scene_ids.size() == 0:
		return  # Parser already errored on empty chapters; nothing to walk.

	var entry_scene_id = chapter.get_entry_scene_id()
	var visited_scenes: Dictionary = {}  # scene_id -> true
	var emitted_edge_ids: Dictionary = {}  # edge_id -> true (dedup)
	var has_terminal_path := false  # tracks whether walker reached an end-of-execution path

	# Walk starting from the entry scene. The walker is iterative-style via
	# a worklist so we don't recurse arbitrarily deep on long internal chains.
	# LIFO is fine: edge dedup makes the discovery order irrelevant for the
	# final graph; only intermediate ordering changes.
	var worklist: Array = [entry_scene_id]
	while worklist.size() > 0:
		var scene_id: String = worklist.pop_back()
		if visited_scenes.has(scene_id):
			continue
		visited_scenes[scene_id] = true

		var scene = data.get_scene(scene_id)
		if scene == null:
			continue  # Bad jump target — _handle_transition records its own diagnostic.

		# Walk commands looking for transitions that exit this scene.
		# Returns whether the scene "ended naturally" (fell through past the
		# last command without an explicit jump/end).
		var fell_through = _walk_scene_commands(
			scene, chapter, data, graph,
			visited_scenes, emitted_edge_ids, worklist)

		if fell_through:
			# The scene's commands ran out → engine would advance to the
			# next scene in declaration order.
			var next_scene_id = _next_scene_in_declaration_order(scene, data)
			if next_scene_id == "":
				has_terminal_path = true  # End of file
			else:
				var next_chapter_id = _chapter_id_of(next_scene_id, data)
				if next_chapter_id == chapter.id:
					# Internal fall-through; queue the next scene.
					worklist.append(next_scene_id)
				else:
					# Cross-chapter fall-through → sequential edge.
					_emit_edge(graph, chapter.id, next_chapter_id,
						ChapterEdge.KIND_SEQUENTIAL, "", scene.declared_line,
						emitted_edge_ids)

	# Three exit topologies:
	#   1. Found a terminal path → emit TERMINAL edge.
	#   2. Found no terminal path AND no cross-chapter outgoing edges →
	#      chapter is internally cyclic with no escape (deadlock). Emit a
	#      diagnostic; do NOT emit TERMINAL because the chapter doesn't
	#      actually terminate. PR-C / PR-D treat zero-edge nodes as stuck.
	#   3. Found cross-chapter edges but no terminal path → no TERMINAL
	#      needed; the chapter exits via the cross edges.
	if has_terminal_path:
		_emit_edge(graph, chapter.id, "",
			ChapterEdge.KIND_TERMINAL, "", 0, emitted_edge_ids)
	elif graph.get_outgoing_edges(chapter.id).size() == 0:
		_record_warning(graph,
			"ScenarioGraphBuilder: chapter '%s' has no outgoing transitions (internal loop with no exit — player would be stuck)"
			% chapter.id, chapter.declared_line)


## Walk commands of a single scene. Returns true if execution falls through
## the last command (no jump / end / etc terminated the scene early).
static func _walk_scene_commands(scene: SceneData, chapter: ChapterData,
		data: ScenarioData, graph: ScenarioGraph,
		visited_scenes: Dictionary, emitted_edge_ids: Dictionary,
		worklist: Array) -> bool:
	for cmd in scene.commands:
		match cmd.type:
			"jump":
				var target = cmd.params.get("target", "")
				_handle_transition(target, ChapterEdge.KIND_JUMP, "",
					cmd, chapter, data, graph, emitted_edge_ids, worklist)
				# @jump exits the scene — no fall-through.
				return false

			"call":
				var target = cmd.params.get("target", "")
				_handle_transition(target, ChapterEdge.KIND_CALL, "",
					cmd, chapter, data, graph, emitted_edge_ids, worklist)
				# @call returns afterwards — execution continues with the
				# next command. Don't return; keep walking.

			"choice":
				# Pathological case (not currently produced by typical
				# scripts but possible in DSL): if EVERY option has no jump
				# target, execution would fall through past the @choice to
				# subsequent commands. We currently treat the choice as a
				# scene exit regardless — any post-choice commands in such
				# scenes are unreachable from the graph's perspective. Document
				# behavior; do not silently confuse the walker.
				var options = cmd.params.get("options", [])
				for opt in options:
					var opt_target = opt.get("jump", "")
					var opt_label = opt.get("label", "")
					if opt_target == "":
						continue  # Internal-flow option (rare); see comment above.
					_handle_transition(opt_target, ChapterEdge.KIND_CHOICE,
						opt_label, cmd, chapter, data, graph,
						emitted_edge_ids, worklist)
				# @choice blocks execution until selection — for graph
				# purposes the scene exits via the chosen option, no
				# fall-through.
				return false

			"condition":
				# Synthetic command from @if expansion. Has then_jump and
				# else_jump pointing at synthetic scenes within the same
				# chapter (chapter_id was inherited at parse time).
				var then_jump = cmd.params.get("then_jump", "")
				var else_jump = cmd.params.get("else_jump", "")
				if then_jump != "":
					_handle_transition(then_jump, ChapterEdge.KIND_JUMP, "",
						cmd, chapter, data, graph, emitted_edge_ids, worklist)
				if else_jump != "":
					_handle_transition(else_jump, ChapterEdge.KIND_JUMP, "",
						cmd, chapter, data, graph, emitted_edge_ids, worklist)
				# Both branches exit the current scene; the merge point is
				# the cont scene that the synthetic branches jump back to.
				return false

	return true


## Resolve a transition target. If the target is in the same chapter, queue
## it on the worklist for internal walking. If it's in a different chapter,
## emit a graph edge (and a lint warning if non-entry).
static func _handle_transition(target_scene_id: String, kind: String,
		label: String, cmd: CommandData, source_chapter: ChapterData,
		data: ScenarioData, graph: ScenarioGraph,
		emitted_edge_ids: Dictionary, worklist: Array) -> void:
	if target_scene_id == "":
		return
	var line = _command_source_line(cmd)

	# Validate target exists. Author typo'd jump → emit diagnostic so the
	# graph drift is visible (parser doesn't see this — it only validates
	# at AST level, not at scene-id resolution).
	var target_scene = data.get_scene(target_scene_id)
	if target_scene == null:
		_record_warning(graph,
			"ScenarioGraphBuilder: %s in chapter '%s' targets unknown scene '%s' (line %d)"
			% [kind, source_chapter.id, target_scene_id, line], line)
		return

	var target_chapter_id = target_scene.chapter_id
	if target_chapter_id == "":
		# Orphan target scene — parser already flagged the orphan with its
		# own diagnostic; nothing more to add here.
		return

	if target_chapter_id == source_chapter.id:
		# Internal transition — keep walking.
		worklist.append(target_scene_id)
	else:
		# Cross-chapter — emit edge.
		_emit_edge(graph, source_chapter.id, target_chapter_id,
			kind, label, line, emitted_edge_ids)
		# Lint: warn if jump targets a non-entry scene of the destination chapter.
		var target_chapter = data.get_chapter(target_chapter_id)
		if target_chapter != null:
			var entry_id = target_chapter.get_entry_scene_id()
			if entry_id != "" and entry_id != target_scene_id:
				_record_warning(graph,
					"ScenarioGraphBuilder: cross-chapter %s from '%s' to non-entry scene '%s' of chapter '%s' (line %d)"
					% [kind, source_chapter.id, target_scene_id, target_chapter_id, line],
					line)


## Get the chapter_id of a scene by id, or "" if not found / orphan.
static func _chapter_id_of(scene_id: String, data: ScenarioData) -> String:
	var scene = data.get_scene(scene_id)
	if scene == null:
		return ""
	return scene.chapter_id


## Find the next scene in declaration order after the given scene.
## Skips synthetic __if_*/__elif_* scenes — those are reached via condition
## commands, not declaration-order fallthrough, so they would otherwise
## produce phantom sequential edges.
##
## Note: scene ids beginning with `__if_` or `__elif_` are reserved by the
## parser for synthetic scenes (DslParser._close_if_block /
## _compile_condition_node). Author scenes with those prefixes would be
## silently skipped here — DslParser does not currently validate against
## reserved prefixes; that would be a future PR-A hardening.
static func _next_scene_in_declaration_order(scene: SceneData, data: ScenarioData) -> String:
	var idx = data.get_scene_index(scene.id)
	if idx == -1:
		return ""
	var i = idx + 1
	while i < data.scenes.size():
		var next = data.scenes[i]
		if not next.id.begins_with("__if_") and not next.id.begins_with("__elif_"):
			return next.id
		i += 1
	return ""


static func _command_source_line(cmd: CommandData) -> int:
	# 0 sentinel = synthesized command (e.g. condition from @if expansion).
	return cmd.declared_line


static func _emit_edge(graph: ScenarioGraph, source_id: String,
		target_id: String, kind: String, label: String, line: int,
		emitted_edge_ids: Dictionary) -> void:
	var edge = ChapterEdge.new()
	edge.source_chapter_id = source_id
	edge.target_chapter_id = target_id
	edge.kind = kind
	edge.label = label
	edge.source_line = line
	var eid = edge.get_edge_id()
	if emitted_edge_ids.has(eid):
		return  # Dedup convergent paths.
	emitted_edge_ids[eid] = true
	graph.edges.append(edge)


static func _record_warning(graph: ScenarioGraph, message: String, line: int) -> void:
	graph.diagnostics.append({"level": "warning", "message": message, "line": line})
