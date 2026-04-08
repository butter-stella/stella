extends GutTest
## Tests for DslParser — converting tokens into ScenarioData.


func _parse(source: String, id: String = "test") -> ScenarioData:
	var tokens = DslLexer.tokenize(source)
	return DslParser.parse(tokens, id)


func test_empty_tokens():
	var data = _parse("")
	assert_eq(data.id, "test")
	assert_eq(data.scenes.size(), 0)


func test_single_scene():
	var data = _parse('@scene start "序章"')
	assert_eq(data.scenes.size(), 1)
	assert_eq(data.scenes[0].id, "start")


func test_multiple_scenes():
	var data = _parse("""@scene start
@scene middle
@scene ending""")
	assert_eq(data.scenes.size(), 3)
	assert_eq(data.scenes[0].id, "start")
	assert_eq(data.scenes[1].id, "middle")
	assert_eq(data.scenes[2].id, "ending")


func test_dialogue_basic():
	var data = _parse("""@scene start
sakura「你好。」""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.type, "dialogue")
	assert_eq(cmd.get_string("character"), "sakura")
	assert_eq(cmd.get_string("text"), "你好。")
	assert_eq(cmd.get_string("mode"), "adv")


func test_dialogue_with_voice():
	var data = _parse("""@scene start
sakura「你好。」 #voice:sakura_001""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.get_string("voice"), "sakura_001")


func test_narration():
	var data = _parse("""@scene start
「窗外下起了雨。」""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.type, "dialogue")
	assert_eq(cmd.get_string("character"), "")
	assert_eq(cmd.get_string("text"), "窗外下起了雨。")


func test_monologue():
	var data = _parse("""@scene start
sakura（这个人...好奇怪。）""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.type, "dialogue")
	assert_eq(cmd.get_string("character"), "sakura")
	assert_eq(cmd.get_string("text"), "这个人...好奇怪。")
	assert_eq(cmd.get_string("mode"), "monologue")


func test_bg_full_params():
	var data = _parse("""@scene start
@bg bg_school fade 0.8""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.type, "bg")
	assert_eq(cmd.get_string("asset"), "bg_school")
	assert_eq(cmd.get_string("transition"), "fade")
	assert_almost_eq(cmd.get_float("duration"), 0.8, 0.001)


func test_bg_defaults():
	var data = _parse("""@scene start
@bg bg_school""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.get_string("transition"), "fade")
	assert_almost_eq(cmd.get_float("duration"), 0.5, 0.001)


func test_show_full_params():
	var data = _parse("""@scene start
@show sakura smile left""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.type, "char_show")
	assert_eq(cmd.get_string("character"), "sakura")
	assert_eq(cmd.get_string("expression"), "smile")
	assert_eq(cmd.get_string("position"), "left")


func test_show_defaults():
	var data = _parse("""@scene start
@show sakura""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.get_string("expression"), "default")
	assert_eq(cmd.get_string("position"), "center")


func test_hide():
	var data = _parse("""@scene start
@hide sakura""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.type, "char_hide")
	assert_eq(cmd.get_string("character"), "sakura")


func test_hide_all():
	var data = _parse("""@scene start
@hide all""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.get_string("character"), "all")


func test_expr():
	var data = _parse("""@scene start
@expr sakura sad""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.type, "char_expr")
	assert_eq(cmd.get_string("character"), "sakura")
	assert_eq(cmd.get_string("expression"), "sad")


func test_jump():
	var data = _parse("""@scene start
@jump ending""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.type, "jump")
	assert_eq(cmd.get_string("target"), "ending")


func test_set_assign():
	var data = _parse("""@scene start
@set talked = true""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.type, "set")
	assert_eq(cmd.get_string("var"), "talked")
	assert_eq(cmd.get_string("value"), "true")
	assert_eq(cmd.get_string("op"), "=")


func test_set_increment():
	var data = _parse("""@scene start
@set score += 5""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.get_string("var"), "score")
	assert_eq(cmd.get_string("op"), "+=")


func test_choice_basic():
	var data = _parse("""@scene start
@choice
  - "你好" -> scene_a
  - "再见" -> scene_b""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.type, "choice")
	var options = cmd.params.get("options", [])
	assert_eq(options.size(), 2)
	assert_eq(options[0]["label"], "你好")
	assert_eq(options[0]["jump"], "scene_a")
	assert_eq(options[1]["label"], "再见")
	assert_eq(options[1]["jump"], "scene_b")


func test_choice_with_prompt():
	var data = _parse("""@scene start
@choice "你该怎么回应？"
  - "你好" -> scene_a""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.get_string("prompt"), "你该怎么回应？")


func test_choice_with_set():
	var data = _parse("""@scene start
@choice
  - "走吧" -> scene_go {affection += 5}""")
	var cmd = data.scenes[0].commands[0]
	var options = cmd.params.get("options", [])
	assert_true(options[0].has("set"))


func test_if_else_end():
	var data = _parse("""@scene start
@if has_key
  sakura「你有钥匙！」
@else
  sakura「没有钥匙...」
@end""")
	# Should generate a condition command + synthetic scenes
	var found_condition = false
	for scene in data.scenes:
		for cmd in scene.commands:
			if cmd.type == "condition":
				found_condition = true
				assert_eq(cmd.get_string("if"), "has_key")
				assert_true(cmd.has_param("then_jump"))
				assert_true(cmd.has_param("else_jump"))
	assert_true(found_condition, "Should have a condition command")


func test_if_without_else():
	var data = _parse("""@scene start
@if has_key
  sakura「你有钥匙！」
@end
sakura「继续...」""")
	var found_condition = false
	for scene in data.scenes:
		for cmd in scene.commands:
			if cmd.type == "condition":
				found_condition = true
	assert_true(found_condition)


func test_end_command():
	var data = _parse("""@scene start
@end""")
	# @end at scene level is just a marker, no command generated
	assert_eq(data.scenes[0].commands.size(), 0)


func test_full_poc_scenario():
	var source = """@scene start "初次相遇"
@bg bg_school_gate fade 0.8
@show sakura smile center
sakura「你好，初次见面！」
@choice "你该怎么回应？"
  - "你好！" -> friendly {affection += 5}
  - "……嗯。" -> cold

@scene friendly
@expr sakura happy
sakura「太好了！」
@jump ending

@scene cold
@expr sakura sad
sakura「这样啊...」
@jump ending

@scene ending
「（第一天就这样结束了。）」
@hide sakura
@bg bg_black fade 1.0
@end"""
	var data = _parse(source, "poc_demo")
	assert_eq(data.id, "poc_demo")
	assert_eq(data.scenes.size(), 4)
	assert_eq(data.scenes[0].id, "start")
	assert_eq(data.scenes[1].id, "friendly")
	assert_eq(data.scenes[2].id, "cold")
	assert_eq(data.scenes[3].id, "ending")
	# Start scene should have: bg, char_show, dialogue, choice
	assert_true(data.scenes[0].commands.size() >= 4)


func test_voice_command():
	var data = _parse("""@scene start
@voice sakura_001""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.type, "voice")
	assert_eq(cmd.get_string("asset"), "sakura_001")


# --- @combine / @end block ---

func test_combine_basic_single_segment():
	var data = _parse("""@scene start
@combine
@expr sakura sad
sakura「第一句。」 #voice:v1
@end""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.type, "dialogue")
	assert_eq(cmd.get_string("character"), "sakura")
	var segments = cmd.params.get("segments", [])
	assert_eq(segments.size(), 1)
	assert_eq(segments[0]["text"], "第一句。")
	assert_eq(segments[0]["voice"], "v1")
	assert_eq(segments[0]["expression"], "sad")


func test_combine_multiple_segments():
	var data = _parse("""@scene start
@combine
@expr sakura sad
sakura「第一句。」 #voice:v1
@expr sakura surprised
sakura「第二句。」 #voice:v2
@expr sakura happy
sakura「第三句。」 #voice:v3
@end""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.type, "dialogue")
	assert_eq(cmd.get_string("character"), "sakura")
	var segments = cmd.params.get("segments", [])
	assert_eq(segments.size(), 3)
	assert_eq(segments[0]["text"], "第一句。")
	assert_eq(segments[0]["voice"], "v1")
	assert_eq(segments[0]["expression"], "sad")
	assert_eq(segments[1]["text"], "第二句。")
	assert_eq(segments[1]["voice"], "v2")
	assert_eq(segments[1]["expression"], "surprised")
	assert_eq(segments[2]["text"], "第三句。")
	assert_eq(segments[2]["voice"], "v3")
	assert_eq(segments[2]["expression"], "happy")


func test_combine_concatenated_text_for_backlog():
	# Parser should also expose concatenated text for backlog/typewriter
	var data = _parse("""@scene start
@combine
@expr sakura sad
sakura「我本来很开心的...」 #voice:v1
@expr sakura surprised
sakura「但是听说下周要期中考...」 #voice:v2
@end""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.get_string("text"),
		"我本来很开心的...但是听说下周要期中考...",
		"combined text should be concatenation of all segments")


func test_combine_segment_without_expr_has_empty_expression():
	# If no @expr precedes a segment, expression field should be empty (means "keep current")
	var data = _parse("""@scene start
@combine
sakura「第一句。」 #voice:v1
sakura「第二句。」 #voice:v2
@end""")
	var cmd = data.scenes[0].commands[0]
	var segments = cmd.params.get("segments", [])
	assert_eq(segments.size(), 2)
	assert_eq(segments[0]["expression"], "")
	assert_eq(segments[1]["expression"], "")


func test_combine_only_produces_one_command():
	var data = _parse("""@scene start
@combine
@expr sakura sad
sakura「一。」 #voice:v1
@expr sakura happy
sakura「二。」 #voice:v2
@end
sakura「之后的话。」 #voice:v3""")
	# Should have: 1 combine dialogue + 1 normal dialogue = 2 commands
	assert_eq(data.scenes[0].commands.size(), 2)
	assert_eq(data.scenes[0].commands[0].type, "dialogue")
	assert_eq(data.scenes[0].commands[0].params.get("segments", []).size(), 2)
	assert_eq(data.scenes[0].commands[1].type, "dialogue")
	assert_false(data.scenes[0].commands[1].params.has("segments"),
		"normal dialogue should not have segments field")


func test_combine_narration_segments():
	# Narration (no character) should also work
	var data = _parse("""@scene start
@combine
「第一段旁白。」 #voice:n1
「第二段旁白。」 #voice:n2
@end""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.get_string("character"), "")
	var segments = cmd.params.get("segments", [])
	assert_eq(segments.size(), 2)
	assert_eq(segments[0]["text"], "第一段旁白。")
	assert_eq(segments[1]["text"], "第二段旁白。")


func test_combine_inside_existing_scenario():
	# Should work alongside other commands
	var data = _parse("""@scene start
@bg bg_school
@show sakura smile
sakura「开始。」 #voice:v0
@combine
@expr sakura sad
sakura「一。」 #voice:v1
@expr sakura happy
sakura「二。」 #voice:v2
@end
sakura「结束。」 #voice:v3""")
	assert_eq(data.scenes[0].commands.size(), 5)
	assert_eq(data.scenes[0].commands[0].type, "bg")
	assert_eq(data.scenes[0].commands[1].type, "char_show")
	assert_eq(data.scenes[0].commands[2].type, "dialogue")
	assert_eq(data.scenes[0].commands[3].type, "dialogue")
	assert_eq(data.scenes[0].commands[3].params.get("segments", []).size(), 2)
	assert_eq(data.scenes[0].commands[4].type, "dialogue")


# ─── @chapter directive (issue #97) ───

func _has_diagnostic(data: ScenarioData, level: String, substring: String) -> bool:
	for d in data.diagnostics:
		if d.get("level") == level and substring in str(d.get("message", "")):
			return true
	return false


func test_chapter_creates_chapter_data():
	var data = _parse('@chapter prologue "序章"\n@scene start')
	assert_eq(data.chapters.size(), 1)
	assert_eq(data.chapters[0].id, "prologue")
	assert_eq(data.chapters[0].display_name, "序章")


func test_chapter_without_display_name_falls_back_to_id():
	var data = _parse("@chapter ch1\n@scene start")
	assert_eq(data.chapters.size(), 1)
	assert_eq(data.chapters[0].id, "ch1")
	# Fallback: display name == id when no quoted title
	assert_eq(data.chapters[0].display_name, "ch1")


func test_chapter_groups_following_scenes():
	var data = _parse("""@chapter prologue
@scene a
@scene b
@scene c""")
	assert_eq(data.chapters.size(), 1)
	assert_eq(data.chapters[0].scene_ids.size(), 3)
	assert_eq(data.chapters[0].scene_ids[0], "a")
	assert_eq(data.chapters[0].scene_ids[1], "b")
	assert_eq(data.chapters[0].scene_ids[2], "c")


func test_multiple_chapters_each_get_their_scenes():
	var data = _parse("""@chapter prologue
@scene a
@scene b
@chapter ch1
@scene c
@scene d""")
	assert_eq(data.chapters.size(), 2)
	assert_eq(data.chapters[0].id, "prologue")
	assert_eq(data.chapters[0].scene_ids, ["a", "b"])
	assert_eq(data.chapters[1].id, "ch1")
	assert_eq(data.chapters[1].scene_ids, ["c", "d"])


func test_scene_carries_chapter_id_back_reference():
	var data = _parse("""@chapter prologue
@scene a
@chapter ch1
@scene b""")
	assert_eq(data.scenes.size(), 2)
	assert_eq(data.scenes[0].chapter_id, "prologue")
	assert_eq(data.scenes[1].chapter_id, "ch1")


func test_scene_before_any_chapter_emits_error_diagnostic():
	# Issue #97: 强制规范化 — scene declared before any @chapter is an error
	var data = _parse('@scene orphan\n@chapter ch1\n@scene legit')
	assert_true(_has_diagnostic(data, "error", "before any @chapter"),
		"orphan scene should produce an error diagnostic")
	# Orphan scene is still recorded with empty chapter_id (forgiving parser)
	assert_eq(data.scenes[0].id, "orphan")
	assert_eq(data.scenes[0].chapter_id, "")


func test_empty_chapter_emits_error_diagnostic():
	# Issue #97: 每个 chapter 必须至少包含一个 @scene
	var data = _parse("@chapter empty_ch\n@chapter ch_with_scene\n@scene s")
	assert_true(_has_diagnostic(data, "error", "empty_ch"),
		"empty chapter should produce an error diagnostic naming it")


func test_chapter_inside_if_block_emits_error_diagnostic():
	var data = _parse("""@chapter prologue
@scene start
@if some_flag
@chapter inner
@end""")
	assert_true(_has_diagnostic(data, "error", "@chapter cannot be used inside @if"),
		"chapter inside @if block should produce an error diagnostic")


func test_chapter_at_end_of_file_with_no_scenes_is_empty_chapter_error():
	var data = _parse("@chapter ch1\n@scene s\n@chapter trailing")
	assert_true(_has_diagnostic(data, "error", "trailing"),
		"trailing chapter with no scenes should error")


func test_no_diagnostic_when_well_formed():
	var data = _parse("""@chapter prologue
@scene a
@scene b
@chapter ch1
@scene c""")
	assert_eq(data.diagnostics.size(), 0,
		"well-formed scenario should produce no diagnostics")
