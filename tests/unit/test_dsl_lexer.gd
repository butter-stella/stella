extends GutTest
## Tests for DslLexer — tokenizing .stl source text.


func test_empty_source():
	var tokens = DslLexer.tokenize("")
	assert_eq(tokens.size(), 0)


func test_comments_only():
	var tokens = DslLexer.tokenize("// this is a comment\n// another one")
	assert_eq(tokens.size(), 0)


func test_blank_lines_skipped():
	var tokens = DslLexer.tokenize("\n\n\n")
	assert_eq(tokens.size(), 0)


func test_scene_directive():
	var tokens = DslLexer.tokenize('@scene start "初次相遇"')
	assert_eq(tokens.size(), 1)
	assert_eq(tokens[0].type, DslToken.Type.SCENE_DIRECTIVE)
	assert_eq(tokens[0].line, 1)


func test_scene_directive_no_title():
	var tokens = DslLexer.tokenize("@scene start")
	assert_eq(tokens.size(), 1)
	assert_eq(tokens[0].type, DslToken.Type.SCENE_DIRECTIVE)


func test_at_command():
	var tokens = DslLexer.tokenize("@bg bg_school fade 0.8")
	assert_eq(tokens.size(), 1)
	assert_eq(tokens[0].type, DslToken.Type.AT_COMMAND)


func test_at_commands_various():
	for cmd in ["@show sakura smile left", "@hide sakura", "@expr sakura sad",
				 "@set talked = true", "@jump ending", "@if affection >= 10",
				 "@else", "@end"]:
		var tokens = DslLexer.tokenize(cmd)
		assert_eq(tokens.size(), 1, "Should tokenize: %s" % cmd)
		assert_eq(tokens[0].type, DslToken.Type.AT_COMMAND)


func test_dialogue():
	var tokens = DslLexer.tokenize('sakura「你好，初次见面。」')
	assert_eq(tokens.size(), 1)
	assert_eq(tokens[0].type, DslToken.Type.DIALOGUE)


func test_dialogue_with_voice():
	var tokens = DslLexer.tokenize('sakura「你好。」 #voice:sakura_001')
	assert_eq(tokens.size(), 1)
	assert_eq(tokens[0].type, DslToken.Type.DIALOGUE)


func test_narration():
	var tokens = DslLexer.tokenize('「窗外下起了雨。」')
	assert_eq(tokens.size(), 1)
	assert_eq(tokens[0].type, DslToken.Type.NARRATION)


func test_monologue():
	var tokens = DslLexer.tokenize('sakura（这个人...好奇怪。）')
	assert_eq(tokens.size(), 1)
	assert_eq(tokens[0].type, DslToken.Type.MONOLOGUE)


func test_choice_option():
	var tokens = DslLexer.tokenize('  - "一起走吧" -> scene_go')
	assert_eq(tokens.size(), 1)
	assert_eq(tokens[0].type, DslToken.Type.CHOICE_OPTION)


func test_choice_option_with_set():
	var tokens = DslLexer.tokenize('  - "一起走吧" -> scene_go {affection += 5}')
	assert_eq(tokens.size(), 1)
	assert_eq(tokens[0].type, DslToken.Type.CHOICE_OPTION)


func test_choice_option_with_condition():
	var tokens = DslLexer.tokenize('  - "走吧" -> scene_go ?if affection >= 5')
	assert_eq(tokens.size(), 1)
	assert_eq(tokens[0].type, DslToken.Type.CHOICE_OPTION)


func test_line_numbers():
	var source = """// comment
@scene start

sakura「你好。」
@bg bg_school"""
	var tokens = DslLexer.tokenize(source)
	assert_eq(tokens.size(), 3)
	assert_eq(tokens[0].line, 2)  # @scene
	assert_eq(tokens[1].line, 4)  # dialogue
	assert_eq(tokens[2].line, 5)  # @bg


func test_mixed_scene():
	var source = """@scene start "序章"
@bg bg_school_gate
@show sakura smile center
sakura「你好！」 #voice:sakura_001
@choice
  - "你好" -> friendly {affection += 5}
  - "……" -> cold"""
	var tokens = DslLexer.tokenize(source)
	assert_eq(tokens.size(), 7)
	assert_eq(tokens[0].type, DslToken.Type.SCENE_DIRECTIVE)
	assert_eq(tokens[1].type, DslToken.Type.AT_COMMAND)  # @bg
	assert_eq(tokens[2].type, DslToken.Type.AT_COMMAND)  # @show
	assert_eq(tokens[3].type, DslToken.Type.DIALOGUE)
	assert_eq(tokens[4].type, DslToken.Type.AT_COMMAND)  # @choice
	assert_eq(tokens[5].type, DslToken.Type.CHOICE_OPTION)
	assert_eq(tokens[6].type, DslToken.Type.CHOICE_OPTION)


func test_indent_preserved():
	var tokens = DslLexer.tokenize('  - "option" -> target')
	assert_eq(tokens[0].indent, 2)
