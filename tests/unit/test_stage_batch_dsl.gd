extends GutTest
## Frozen parser contract for issue #164's authored stage composition block.
##
## Sources are deliberately synthetic. Valid blocks compile to one addressable
## command while every invalid block fails closed without leaking child stage
## commands. The existing @stage, @parallel, and @combine surfaces remain intact.


const SOURCE_PATH := "res://tests/fixtures/scenarios/stage_batch/parser_probe.stla"


func _parse(source: String, source_path: String = SOURCE_PATH) -> ScenarioData:
	return DslParser.parse(
		DslLexer.tokenize(source),
		"stage_batch_parser_contract",
		source_path,
	)


func _all_commands(data: ScenarioData) -> Array[CommandData]:
	var commands: Array[CommandData] = []
	for scene_value: Variant in data.scenes:
		var scene: SceneData = scene_value
		for command_value: Variant in scene.commands:
			commands.append(command_value as CommandData)
	return commands


func _batch_commands(data: ScenarioData) -> Array[CommandData]:
	return _all_commands(data).filter(
		func(command: CommandData) -> bool:
			return command.type == "stage_batch"
	)


func _error_diagnostics(data: ScenarioData) -> Array:
	return data.diagnostics.filter(
		func(diagnostic: Dictionary) -> bool:
			return String(diagnostic.get("level", "")) == "error"
	)


func _has_error_at(
	data: ScenarioData,
	message_part: String,
	line: int,
) -> bool:
	return _has_diagnostic_at(data, "error", message_part, line)


func _has_diagnostic_at(
	data: ScenarioData,
	level: String,
	message_part: String,
	line: int,
) -> bool:
	for diagnostic_value: Variant in data.diagnostics:
		var diagnostic: Dictionary = diagnostic_value
		if (
			String(diagnostic.get("level", "")) == level
			and int(diagnostic.get("line", -1)) == line
			and message_part in String(diagnostic.get("message", ""))
		):
			var diagnostic_path := String(
				diagnostic.get("source_path", data.source_path))
			return diagnostic_path == SOURCE_PATH
	return false


func _sorted_keys(value: Dictionary) -> Array:
	var keys := value.keys()
	keys.sort()
	return keys


func test_join_block_compiles_one_exact_ordered_command() -> void:
	var data := _parse("""@chapter synthetic
@scene start
@stage_batch policy=join
  @stage a show kind=background asset=stage:redraw_source transition=fade duration=2
  @stage b update position=42,24 transition=move duration=1
  @stage c hide transition=fade duration=0.5
@end""")
	assert_eq(data.source_path, SOURCE_PATH)
	assert_eq(_error_diagnostics(data), [], str(data.diagnostics))
	var batches := _batch_commands(data)
	assert_eq(batches.size(), 1,
		"one authored block is one addressable scenario command")
	if batches.size() != 1:
		return
	var command: CommandData = batches[0]
	assert_eq(command.declared_line, 3)
	assert_eq(_sorted_keys(command.params), [
		"operation_lines", "operations", "policy",
	])
	assert_eq(command.get_string("policy"), "join")
	assert_eq(command.params["operation_lines"], [4, 5, 6])
	var operations: Array = command.params["operations"]
	assert_eq(operations.size(), 3)
	assert_eq(operations.map(
		func(operation: Dictionary) -> String:
			return String(operation.get("id", ""))
	), ["a", "b", "c"], "child source order is preserved")
	for operation_value: Variant in operations:
		assert_eq(_sorted_keys(operation_value as Dictionary), [
			"action", "duration", "id", "properties", "transition", "transition_params",
		])
	assert_eq(operations[0]["action"], "show")
	assert_eq(operations[1]["properties"]["position"], [42.0, 24.0])
	assert_eq(operations[2]["action"], "hide")


func test_fire_and_forget_is_the_only_other_policy() -> void:
	var data := _parse("""@chapter synthetic
@scene start
@stage_batch policy=fire_and_forget
  @stage overlay show asset=stage:redraw_source transition=fade duration=3
@end""")
	assert_eq(_error_diagnostics(data), [], str(data.diagnostics))
	var batches := _batch_commands(data)
	assert_eq(batches.size(), 1)
	if batches.size() == 1:
		assert_eq(batches[0].get_string("policy"), "fire_and_forget")
		assert_eq(batches[0].params["operation_lines"], [4])


func test_stage_batch_is_valid_inside_an_active_if_branch() -> void:
	var data := _parse("""@chapter synthetic
@scene start
@if route == 1
  @stage_batch policy=join
    @stage conditional show asset=stage:redraw_source
  @end
@end""")
	assert_eq(_error_diagnostics(data), [], str(data.diagnostics))
	var batches := _batch_commands(data)
	assert_eq(batches.size(), 1,
		"conditional CFG expansion retains one typed stage_batch command")
	if batches.size() == 1:
		assert_eq(batches[0].declared_line, 4)
		assert_eq(batches[0].params["operation_lines"], [5])


func test_header_is_closed_strict_and_source_located() -> void:
	var cases := [
		{
			"label": "missing policy",
			"header": "@stage_batch",
			"message": "policy",
		},
		{
			"label": "unknown key",
			"header": "@stage_batch mode=join",
			"message": "mode",
		},
		{
			"label": "duplicate policy",
			"header": "@stage_batch policy=join policy=join",
			"message": "duplicate",
		},
		{
			"label": "empty policy still owns the unique slot",
			"header": "@stage_batch policy= policy=join",
			"message": "duplicate",
		},
		{
			"label": "invalid value",
			"header": "@stage_batch policy=wait_all",
			"message": "wait_all",
		},
		{
			"label": "uppercase join is not canonical",
			"header": "@stage_batch policy=JOIN",
			"message": "JOIN",
		},
		{
			"label": "mixed-case fire-and-forget is not canonical",
			"header": "@stage_batch policy=Fire_And_Forget",
			"message": "Fire_And_Forget",
		},
		{
			"label": "bare argument",
			"header": "@stage_batch join",
			"message": "join",
		},
	]
	for case_value: Variant in cases:
		var case: Dictionary = case_value
		var data := _parse("""@chapter synthetic
@scene start
%s
  @stage leaked show asset=stage:redraw_source
@end""" % String(case["header"]))
		assert_eq(_batch_commands(data).size(), 0, String(case["label"]))
		assert_eq(_all_commands(data).size(), 0,
			"an invalid header cannot leak its child: %s" % case["label"])
		assert_true(_has_error_at(data, String(case["message"]), 3),
			"header diagnostic owns the opening line: %s" % case["label"])


func test_empty_duplicate_and_clear_mixed_blocks_fail_atomically() -> void:
	var cases := [
		{
			"label": "empty",
			"source": """@chapter synthetic
@scene start
@stage_batch policy=join
@end""",
			"line": 3,
			"message": "empty",
		},
		{
			"label": "duplicate non-clear layer",
			"source": """@chapter synthetic
@scene start
@stage_batch policy=join
  @stage same show asset=stage:redraw_source
  @stage same update opacity=0.5
@end""",
			"line": 5,
			"message": "same",
		},
		{
			"label": "clear with sibling",
			"source": """@chapter synthetic
@scene start
@stage_batch policy=join
  @stage kept show asset=stage:redraw_source
  @stage clear
@end""",
			"line": 5,
			"message": "clear",
		},
	]
	for case_value: Variant in cases:
		var case: Dictionary = case_value
		var data := _parse(String(case["source"]))
		assert_eq(_all_commands(data).size(), 0, String(case["label"]))
		assert_true(_has_error_at(
			data, String(case["message"]), int(case["line"])),
			String(case["label"]),
		)


func test_illegal_children_and_nested_blocks_fail_at_the_offender() -> void:
	var cases := [
		{
			"label": "dialogue child",
			"child": "  「not a stage operation」",
			"line": 4,
			"message": "stage",
		},
		{
			"label": "nested batch",
			"child": "  @stage_batch policy=join\n"
				+ "    @stage nested show asset=stage:redraw_source\n"
				+ "  @end",
			"line": 4,
			"message": "stage_batch",
		},
		{
			"label": "parallel child",
			"child": "  @parallel\n"
				+ "    @bg off\n"
				+ "  @end",
			"line": 4,
			"message": "parallel",
		},
		{
			"label": "combine child",
			"child": "  @combine\n"
				+ "    「not allowed」\n"
				+ "  @end",
			"line": 4,
			"message": "combine",
		},
	]
	for case_value: Variant in cases:
		var case: Dictionary = case_value
		var data := _parse("""@chapter synthetic
@scene start
@stage_batch policy=join
%s
@end""" % String(case["child"]))
		assert_eq(_batch_commands(data).size(), 0, String(case["label"]))
		assert_true(_has_error_at(
			data, String(case["message"]), int(case["line"])),
			String(case["label"]),
		)


func test_canonical_child_error_rejects_the_complete_block() -> void:
	var data := _parse("""@chapter synthetic
@scene start
@stage_batch policy=join
  @stage valid show asset=stage:redraw_source
  @stage broken update opacity=2 face=stage:must_not_apply
@end""")
	assert_eq(_all_commands(data).size(), 0,
		"one invalid canonical child rejects every sibling")
	assert_eq(_error_diagnostics(data).size(), 1, str(data.diagnostics))
	assert_true(_has_error_at(data, "opacity", 5))
	assert_false(_has_error_at(data, "invalid @stage child", 5),
		"the specific child diagnostic replaces the generic fallback")

	var standalone := _parse("""@chapter synthetic
@scene start
@stage broken update opacity=2 face=stage:must_not_apply""")
	assert_eq(_all_commands(standalone).size(), 0)
	assert_true(_has_diagnostic_at(standalone, "warning", "opacity", 3),
		"standalone @stage keeps its legacy warning severity")
	assert_false(_has_error_at(standalone, "opacity", 3),
		"batch strictness must not change standalone diagnostics")


func test_missing_end_owns_the_open_line_and_cannot_consume_next_scene() -> void:
	var data := _parse("""@chapter synthetic
@scene first
@stage_batch policy=join
  @stage stale show asset=stage:redraw_source
@scene second
「kept」""")
	assert_eq(_batch_commands(data).size(), 0)
	assert_true(_has_error_at(data, "@end", 3),
		"unclosed block reports its opening line")
	var dialogues := _all_commands(data).filter(
		func(command: CommandData) -> bool:
			return command.type == "dialogue"
	)
	assert_eq(dialogues.size(), 1,
		"the next scene remains independently parseable")
	if dialogues.size() == 1:
		assert_eq(dialogues[0].get_string("text"), "kept")

	var across_chapter := _parse("""@chapter first
@scene first_scene
@stage_batch policy=join
  @stage stale show asset=stage:redraw_source
@chapter second
@scene second_scene
「new chapter kept」""")
	assert_true(_has_error_at(across_chapter, "@end", 3))
	assert_eq(across_chapter.chapters.map(
		func(chapter: ChapterData) -> String: return chapter.id
	), ["first", "second"])
	assert_eq(across_chapter.scenes.map(
		func(scene: SceneData) -> Array:
			return [scene.id, scene.chapter_id]
	), [["first_scene", "first"], ["second_scene", "second"]],
		"an unterminated batch cannot consume the following chapter structure")
	var chapter_dialogues := _all_commands(across_chapter).filter(
		func(command: CommandData) -> bool:
			return command.type == "dialogue"
	)
	assert_eq(chapter_dialogues.size(), 1)
	if chapter_dialogues.size() == 1:
		assert_eq(
			chapter_dialogues[0].get_string("text"), "new chapter kept")


func test_batch_requires_an_active_scene() -> void:
	var before_chapter := _parse("""@stage_batch policy=join
  @stage orphan show asset=stage:redraw_source
@end
@chapter synthetic
@scene start""")
	assert_eq(_batch_commands(before_chapter).size(), 0)
	assert_true(_has_error_at(before_chapter, "scene", 1))

	var chapter_gap := _parse("""@chapter synthetic
@stage_batch policy=join
  @stage gap show asset=stage:redraw_source
@end
@scene start""")
	assert_eq(_batch_commands(chapter_gap).size(), 0)
	assert_true(_has_error_at(chapter_gap, "scene", 2))


func test_existing_stage_parallel_and_combine_are_not_reinterpreted() -> void:
	var data := _parse("""@chapter synthetic
@scene start
@stage standalone show asset=stage:redraw_source
@parallel
@bg off
@end
@combine
@stage cue update face=stage:redraw_source
「existing cue」
@end""")
	assert_eq(_error_diagnostics(data), [], str(data.diagnostics))
	var commands := _all_commands(data)
	assert_eq(commands.map(
		func(command: CommandData) -> String: return command.type
	), ["stage_layer", "parallel", "dialogue"])
	assert_eq(_batch_commands(data), [],
		"#164 does not reinterpret any existing composition spelling")
	assert_eq(commands[2].params["segments"][0]["stage_ops"].size(), 1,
		"@combine keeps its private segment cue semantics")
	assert_eq(
		commands[2].params["segments"][0]["stage_operation_lines"].size(),
		1,
		"@combine preserves one exact authored line per private Stage cue",
	)
