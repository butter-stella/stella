extends GutTest
## Tests for ScenarioData, SceneData, and ChoiceData.
## These classes are globally registered via class_name, no preload needed.


# --- ScenarioData ---

func test_scenario_data_has_id_and_title():
	var s = ScenarioData.new()
	s.id = "chapter_01"
	s.title = "First Chapter"
	assert_eq(s.id, "chapter_01")
	assert_eq(s.title, "First Chapter")


func test_scenario_data_holds_scenes():
	var s = ScenarioData.new()
	var scene = SceneData.new()
	scene.id = "start"
	s.scenes.append(scene)
	assert_eq(s.scenes.size(), 1)
	assert_eq(s.scenes[0].id, "start")


func test_scenario_get_scene_by_id():
	var s = ScenarioData.new()
	var scene1 = SceneData.new()
	scene1.id = "start"
	var scene2 = SceneData.new()
	scene2.id = "ending"
	s.scenes.append(scene1)
	s.scenes.append(scene2)
	assert_eq(s.get_scene("ending").id, "ending")
	assert_eq(s.get_scene("start").id, "start")


func test_scenario_get_scene_returns_null_for_missing():
	var s = ScenarioData.new()
	assert_null(s.get_scene("nonexistent"))


func test_scenario_get_scene_index():
	var s = ScenarioData.new()
	var scene1 = SceneData.new()
	scene1.id = "start"
	var scene2 = SceneData.new()
	scene2.id = "ending"
	s.scenes.append(scene1)
	s.scenes.append(scene2)
	assert_eq(s.get_scene_index("start"), 0)
	assert_eq(s.get_scene_index("ending"), 1)
	assert_eq(s.get_scene_index("missing"), -1)


# --- SceneData ---

func test_scene_data_holds_commands():
	var scene = SceneData.new()
	scene.id = "test_scene"
	var cmd = CommandData.new()
	cmd.type = "dialogue"
	cmd.params = {"text": "Hello"}
	scene.commands.append(cmd)
	assert_eq(scene.commands.size(), 1)
	assert_eq(scene.commands[0].type, "dialogue")


func test_scene_data_empty_commands():
	var scene = SceneData.new()
	scene.id = "empty"
	assert_eq(scene.commands.size(), 0)


# --- ChoiceData ---

func test_choice_data_has_prompt_and_options():
	var choice = ChoiceData.new()
	choice.prompt = "What do you do?"
	var opt = ChoiceData.ChoiceOption.new()
	opt.id = "go"
	opt.label = "Go"
	opt.jump = "scene_go"
	choice.options.append(opt)
	assert_eq(choice.prompt, "What do you do?")
	assert_eq(choice.options.size(), 1)
	assert_eq(choice.options[0].id, "go")
	assert_eq(choice.options[0].label, "Go")
	assert_eq(choice.options[0].jump, "scene_go")


func test_choice_option_set_field():
	var opt = ChoiceData.ChoiceOption.new()
	opt.set_vars = {"affection": "+5"}
	assert_eq(opt.set_vars["affection"], "+5")


func test_choice_option_condition():
	var opt = ChoiceData.ChoiceOption.new()
	opt.condition = "affection >= 5"
	assert_eq(opt.condition, "affection >= 5")


func test_choice_option_defaults():
	var opt = ChoiceData.ChoiceOption.new()
	assert_eq(opt.id, "")
	assert_eq(opt.label, "")
	assert_eq(opt.jump, "")
	assert_eq(opt.condition, "")
	assert_eq(opt.set_vars.size(), 0)


# ─── assign_command_uids (issue #88) ───

func test_assign_command_uids_monotonic_across_scenes():
	var data = ScenarioData.new()
	var s0 = SceneData.new()
	s0.id = "a"
	for i in range(3):
		s0.commands.append(CommandData.new())
	var s1 = SceneData.new()
	s1.id = "b"
	for i in range(2):
		s1.commands.append(CommandData.new())
	data.scenes = [s0, s1]

	data.assign_command_uids()

	assert_eq(s0.commands[0].uid, 0)
	assert_eq(s0.commands[1].uid, 1)
	assert_eq(s0.commands[2].uid, 2)
	assert_eq(s1.commands[0].uid, 3)
	assert_eq(s1.commands[1].uid, 4)


func test_assign_command_uids_skips_already_assigned():
	# Idempotent: pre-assigned uids are left alone.
	var data = ScenarioData.new()
	var s = SceneData.new()
	var c0 = CommandData.new()
	c0.uid = 100  # pre-assigned
	var c1 = CommandData.new()  # uid=-1 by default
	var c2 = CommandData.new()
	c2.uid = 50
	s.commands = [c0, c1, c2]
	data.scenes = [s]

	data.assign_command_uids()

	assert_eq(c0.uid, 100, "pre-assigned uid preserved")
	assert_eq(c1.uid, 101, "auto-assigned advances past max(prev, 100)")
	assert_eq(c2.uid, 50, "pre-assigned uid preserved")


func test_assign_command_uids_includes_nested_parallel_commands() -> void:
	var data := ScenarioData.new()
	var scene := SceneData.new()
	var parallel := CommandData.new()
	parallel.type = "parallel"
	var first := CommandData.new()
	first.type = "dialogue"
	var second := CommandData.new()
	second.type = "dialogue"
	parallel.params = {"commands": [first, second]}
	scene.commands = [parallel]
	data.scenes = [scene]

	data.assign_command_uids()

	assert_eq(parallel.uid, 0)
	assert_eq(first.uid, 1)
	assert_eq(second.uid, 2)


func test_read_identity_uses_simplified_full_source_path() -> void:
	var data := ScenarioData.new()
	data.id = "main"
	data.source_path = "res://routes/../route_a/main.stla"

	assert_eq(data.get_read_identity(), "path:res://route_a/main.stla")


func test_content_change_invalidates_position_based_read_identity() -> void:
	var original := DslParser.parse(
		DslLexer.tokenize("@scene start\n「B」"),
		"main",
		"res://story/main.stla",
	)
	var updated := DslParser.parse(
		DslLexer.tokenize("@scene start\n「A」\n「B」"),
		"main",
		"res://story/main.stla",
	)
	original.assign_command_uids()
	updated.assign_command_uids()
	var flags := ReadFlagManager.new()
	flags.mark_dialogue_read(
		original.get_read_identity(), "start", original.scenes[0].commands[0].uid)

	assert_ne(original.get_read_identity(), updated.get_read_identity())
	assert_false(flags.is_dialogue_read(
		updated.get_read_identity(),
		"main",
		"start",
		updated.scenes[0].commands[0].uid,
		0,
	), "an inserted command must fail closed instead of inheriting B's old flag")


func test_semantic_fingerprint_ignores_comment_whitespace_and_spelling() -> void:
	var original := DslParser.parse(DslLexer.tokenize("""@chapter route \"Route\"
@scene start
@if flag
@bg room cut 0 # first note
@end"""), "main", "res://story/main.stla")
	var equivalent := DslParser.parse(DslLexer.tokenize("""// shifted comment

@chapter   route “Route”
@scene   start
@if flag
@bg   room   cut   0.0   # revised note
@end"""), "main", "res://story/main.stla")

	assert_eq(original.diagnostics, [])
	assert_eq(equivalent.diagnostics, [])
	assert_eq(original.get_read_identity(), equivalent.get_read_identity(),
		"non-semantic edits must retain read history even when @if lines move")


func test_semantic_fingerprint_ignores_documented_inline_comments() -> void:
	var original := DslParser.parse(DslLexer.tokenize("""@chapter route
@scene start
@bg room cut 0 // first note"""), "main", "res://story/main.stla")
	var equivalent := DslParser.parse(DslLexer.tokenize("""@chapter route
@scene start
@bg room cut 0 // revised note"""), "main", "res://story/main.stla")

	assert_eq(original.get_read_identity(), equivalent.get_read_identity())


func test_stage_batch_fingerprint_excludes_only_operation_line_metadata() -> void:
	var original := DslParser.parse(DslLexer.tokenize("""@chapter route
@scene start
@stage_batch policy=join
  @stage hero show asset=stage:redraw_source transition=fade duration=0.3
@end"""), "main", "res://story/main.stla")
	var format_shifted := DslParser.parse(DslLexer.tokenize("""// lead note

@chapter route
@scene start
@stage_batch policy=join

// child note
  @stage hero show asset=stage:redraw_source transition=fade duration=0.3
@end"""), "main", "res://story/main.stla")
	var changed_policy := DslParser.parse(DslLexer.tokenize("""@chapter route
@scene start
@stage_batch policy=fire_and_forget
  @stage hero show asset=stage:redraw_source transition=fade duration=0.3
@end"""), "main", "res://story/main.stla")
	var changed_operation := DslParser.parse(DslLexer.tokenize("""@chapter route
@scene start
@stage_batch policy=join
  @stage hero show asset=stage:redraw_blur_source transition=fade duration=0.3
@end"""), "main", "res://story/main.stla")
	var scenarios := [
		original, format_shifted, changed_policy, changed_operation,
	]
	var batches: Array[CommandData] = []
	for scenario: ScenarioData in scenarios:
		assert_eq(scenario.diagnostics, [])
		assert_eq(scenario.scenes.size(), 1)
		assert_eq(scenario.scenes[0].commands.size(), 1)
		var batch: CommandData = scenario.scenes[0].commands[0]
		var keys := batch.params.keys()
		keys.sort()
		assert_eq(keys, ["operation_lines", "operations", "policy"])
		batches.append(batch)

	assert_ne(batches[0].declared_line, batches[1].declared_line,
		"formatting must move the retained opening-line diagnostic metadata")
	assert_ne(batches[0].params["operation_lines"],
		batches[1].params["operation_lines"],
		"formatting must move the retained child-line diagnostic metadata")
	assert_eq(batches[0].params["policy"], batches[1].params["policy"])
	assert_eq(batches[0].params["operations"], batches[1].params["operations"])
	assert_eq(original.content_fingerprint, format_shifted.content_fingerprint,
		"diagnostic-only Stage child lines cannot change semantic identity")
	assert_eq(original.get_read_identity(), format_shifted.get_read_identity())
	assert_ne(original.content_fingerprint, changed_policy.content_fingerprint,
		"batch policy remains semantic")
	assert_ne(original.get_read_identity(), changed_policy.get_read_identity())
	assert_ne(original.content_fingerprint,
		changed_operation.content_fingerprint,
		"canonical Stage operation behavior remains semantic")
	assert_ne(original.get_read_identity(), changed_operation.get_read_identity())


func test_semantic_fingerprint_uses_normalized_condition_ir() -> void:
	var original := DslParser.parse(DslLexer.tokenize("""@chapter route
@scene start
@if score==1 && !flag || ratio >= 01.500
「Same branch」
@end"""), "main", "res://story/main.stla")
	var equivalent := DslParser.parse(DslLexer.tokenize("""@chapter route
@scene start
@if score  ==  1.0  &&  ! flag  ||  ratio>=1.5
「Same branch」
@end"""), "main", "res://story/main.stla")
	var changed := DslParser.parse(DslLexer.tokenize("""@chapter route
@scene start
@if score != 1 && !flag || ratio >= 1.5
「Same branch」
@end"""), "main", "res://story/main.stla")

	assert_eq(original.diagnostics, [])
	assert_eq(equivalent.diagnostics, [])
	assert_eq(original.get_read_identity(), equivalent.get_read_identity(),
		"condition spacing and equivalent numeric spelling retain read history")
	assert_ne(original.get_read_identity(), changed.get_read_identity(),
		"a condition behavior change must still invalidate the fingerprint")


func test_semantic_fingerprint_preserves_tiny_condition_numbers() -> void:
	var decimal := DslParser.parse(DslLexer.tokenize("""@chapter route
@scene start
@if ratio == 0.000000000000000001
「Tiny branch」
@end"""), "main", "res://story/main.stla")
	var scientific := DslParser.parse(DslLexer.tokenize("""@chapter route
@scene start
@if ratio == 1e-18
「Tiny branch」
@end"""), "main", "res://story/main.stla")
	var zero := DslParser.parse(DslLexer.tokenize("""@chapter route
@scene start
@if ratio == 0
「Tiny branch」
@end"""), "main", "res://story/main.stla")

	assert_eq(decimal.diagnostics, [])
	assert_eq(scientific.diagnostics, [])
	assert_eq(zero.diagnostics, [])
	assert_eq(decimal.get_read_identity(), scientific.get_read_identity(),
		"equivalent decimal and scientific Float values retain read history")
	assert_ne(decimal.get_read_identity(), zero.get_read_identity(),
		"zero and a tiny nonzero condition must not share read history")


func test_semantic_fingerprint_changes_for_authored_behavior() -> void:
	var original := DslParser.parse(DslLexer.tokenize("""@chapter route
@scene start
@bg room cut 0"""), "main", "res://story/main.stla")
	var changed := DslParser.parse(DslLexer.tokenize("""@chapter route
@scene start
@bg hallway cut 0"""), "main", "res://story/main.stla")

	assert_ne(original.get_read_identity(), changed.get_read_identity())


# ─── ChapterData (issue #97) ───

func test_chapter_data_default_fields():
	var ch = ChapterData.new()
	assert_eq(ch.id, "")
	assert_eq(ch.display_name, "")
	assert_eq(ch.scene_ids.size(), 0)


func test_chapter_data_holds_scene_ids():
	var ch = ChapterData.new()
	ch.id = "prologue"
	ch.display_name = "序章"
	ch.scene_ids.append("scene_a")
	ch.scene_ids.append("scene_b")
	assert_eq(ch.id, "prologue")
	assert_eq(ch.display_name, "序章")
	assert_eq(ch.scene_ids.size(), 2)
	assert_eq(ch.scene_ids[0], "scene_a")


func test_chapter_data_declared_line_default_zero():
	# Default for manually-constructed ChapterData (parser sets real value).
	var ch = ChapterData.new()
	assert_eq(ch.declared_line, 0)


# ─── SceneData.chapter_id back-reference ───

func test_scene_data_chapter_id_default_empty():
	var s = SceneData.new()
	assert_eq(s.chapter_id, "")


func test_scene_data_declared_line_default_zero():
	# Default for manually-constructed SceneData (parser sets real value).
	var s = SceneData.new()
	assert_eq(s.declared_line, 0)


# ─── ScenarioData.chapters API ───

func test_scenario_data_chapters_field_default_empty():
	var data = ScenarioData.new()
	assert_eq(data.chapters.size(), 0)


func test_scenario_data_diagnostics_field_default_empty():
	# Parser populates this with {level, message, line} entries.
	var data = ScenarioData.new()
	assert_eq(data.diagnostics.size(), 0)


func test_scenario_get_chapter_by_id():
	var data = ScenarioData.new()
	var ch = ChapterData.new()
	ch.id = "prologue"
	data.chapters.append(ch)
	assert_eq(data.get_chapter("prologue").id, "prologue")


func test_scenario_get_chapter_returns_null_for_missing():
	var data = ScenarioData.new()
	assert_null(data.get_chapter("nonexistent"))


func test_scenario_get_chapter_index():
	var data = ScenarioData.new()
	var c0 = ChapterData.new()
	c0.id = "prologue"
	var c1 = ChapterData.new()
	c1.id = "ch1"
	data.chapters.append(c0)
	data.chapters.append(c1)
	assert_eq(data.get_chapter_index("prologue"), 0)
	assert_eq(data.get_chapter_index("ch1"), 1)
	assert_eq(data.get_chapter_index("missing"), -1)


func test_scenario_get_chapter_for_scene():
	# Walk via scene.chapter_id back-reference.
	var data = ScenarioData.new()
	var ch = ChapterData.new()
	ch.id = "prologue"
	ch.scene_ids.append("start")
	data.chapters.append(ch)
	var s = SceneData.new()
	s.id = "start"
	s.chapter_id = "prologue"
	data.scenes.append(s)
	var found = data.get_chapter_for_scene("start")
	assert_not_null(found)
	assert_eq(found.id, "prologue")


func test_scenario_get_chapter_for_scene_returns_null_for_orphan():
	var data = ScenarioData.new()
	var s = SceneData.new()
	s.id = "orphan"
	s.chapter_id = ""
	data.scenes.append(s)
	assert_null(data.get_chapter_for_scene("orphan"))
