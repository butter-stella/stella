extends GutTest
## Tests for @elif and @call DSL directives.


# --- @elif ---

func test_elif_basic():
	var source = """@scene start
@set score = 10
@if score >= 20
  sakura「优秀！」
@elif score >= 10
  sakura「不错。」
@else
  sakura「加油。」
@end"""
	var tokens = DslLexer.tokenize(source)
	var data = DslParser.parse(tokens, "test")

	# Should have condition commands that chain elif
	var found_condition = false
	for scene in data.scenes:
		for cmd in scene.commands:
			if cmd.type == "condition":
				found_condition = true
	assert_true(found_condition, "Should generate condition commands for @if/@elif/@else")


func test_elif_generates_correct_chain():
	var source = """@scene start
@if a >= 3
  sakura「A」
@elif a >= 2
  sakura「B」
@elif a >= 1
  sakura「C」
@else
  sakura「D」
@end"""
	var tokens = DslLexer.tokenize(source)
	var data = DslParser.parse(tokens, "test")

	# The start scene should have a condition command
	var start_cmds = data.scenes[0].commands
	var condition_found = false
	for cmd in start_cmds:
		if cmd.type == "condition":
			condition_found = true
			assert_eq(cmd.get_string("if"), "a >= 3")
			# The else_jump should point to a synthetic scene that has the next elif
			assert_true(cmd.has_param("else_jump"))
	assert_true(condition_found)


func test_elif_without_else():
	var source = """@scene start
@if flag
  sakura「是。」
@elif other_flag
  sakura「也是。」
@end"""
	var tokens = DslLexer.tokenize(source)
	var data = DslParser.parse(tokens, "test")
	# Should not crash, should generate valid structure
	assert_true(data.scenes.size() >= 1)


func test_elif_only_executes_matching_branch():
	# Critical bug: elif then_scene was missing continuation jump,
	# causing fall-through to subsequent branches
	var source = """@scene start
@set score = 15
@if score >= 20
  @set result = "A"
@elif score >= 10
  @set result = "B"
@else
  @set result = "C"
@end
@set done = true"""

	var tokens = DslLexer.tokenize(source)
	var scenario = DslParser.parse(tokens, "test")

	# Verify that all synthetic then_scenes have jump to continuation
	for scene in scenario.scenes:
		if scene.id.find("_then") != -1:
			var last_cmd = scene.commands[-1] if scene.commands.size() > 0 else null
			assert_not_null(last_cmd, "then scene '%s' should have commands" % scene.id)
			if last_cmd:
				assert_eq(last_cmd.type, "jump", "then scene '%s' should end with jump" % scene.id)


func test_call_empty_target_no_crash():
	var scenario = ScenarioData.new()
	scenario.id = "test"
	var scene = SceneData.new()
	scene.id = "main"
	scenario.scenes = [scene]

	var ctx = ScenarioContext.new(scenario)
	var handler = CallHandler.new()
	var cmd = CommandData.new()
	cmd.type = "call"
	cmd.params = {"target": ""}

	# Should not push to return stack with empty target
	await handler.execute(cmd, ctx)
	assert_eq(ctx.return_stack.size(), 0, "Empty target should not push return stack")


# --- @call ---

func test_call_handler_type():
	var handler = CallHandler.new()
	assert_eq(handler.get_command_type(), "call")


func test_call_sets_pending_jump_and_return():
	var scenario = ScenarioData.new()
	scenario.id = "test"
	var scene1 = SceneData.new()
	scene1.id = "main"
	var scene2 = SceneData.new()
	scene2.id = "sub"
	scenario.scenes = [scene1, scene2]

	var ctx = ScenarioContext.new(scenario)
	ctx.current_scene_index = 0
	ctx.current_command_index = 2  # pretend we're at command 2

	var handler = CallHandler.new()
	var cmd = CommandData.new()
	cmd.type = "call"
	cmd.params = {"target": "sub"}

	await handler.execute(cmd, ctx)

	assert_eq(ctx.pending_jump, "sub")
	assert_eq(ctx.return_stack.size(), 1)
	assert_eq(ctx.return_stack[0]["scene_index"], 0)
	assert_eq(ctx.return_stack[0]["command_index"], 3)  # next command after call


func test_dsl_parser_call():
	var tokens = DslLexer.tokenize("@scene s\n@call flashback_001")
	var data = DslParser.parse(tokens, "t")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.type, "call")
	assert_eq(cmd.get_string("target"), "flashback_001")


class TrackDialogueHandler extends CommandHandler:
	var executed: Array = []
	func get_command_type() -> String:
		return "dialogue"
	func execute(data: CommandData, _context: ScenarioContext) -> void:
		executed.append(data.get_string("text", ""))


func test_engine_return_from_call():
	var registry = CommandRegistry.new()

	var dialogue_handler = TrackDialogueHandler.new()
	registry.register(dialogue_handler)
	registry.register(CallHandler.new())
	registry.register(JumpHandler.new())

	var scenario = ScenarioData.new()
	scenario.id = "test"

	# main scene: dialogue A → call sub → dialogue C
	var main_scene = SceneData.new()
	main_scene.id = "main"
	var cmd_a = CommandData.new()
	cmd_a.type = "dialogue"
	cmd_a.params = {"text": "A"}
	var cmd_call = CommandData.new()
	cmd_call.type = "call"
	cmd_call.params = {"target": "sub"}
	var cmd_c = CommandData.new()
	cmd_c.type = "dialogue"
	cmd_c.params = {"text": "C"}
	main_scene.commands = [cmd_a, cmd_call, cmd_c]

	# sub scene: dialogue B (then engine should return to main)
	# Put sub scene BEFORE main so auto-advance doesn't reach it
	var sub_scene = SceneData.new()
	sub_scene.id = "sub"
	var cmd_b = CommandData.new()
	cmd_b.type = "dialogue"
	cmd_b.params = {"text": "B"}
	sub_scene.commands = [cmd_b]

	# Sub scene first, main second — engine starts at scene 0 (sub won't auto-play)
	# Actually, put main first and sub last, but add a jump to end after C
	var end_scene = SceneData.new()
	end_scene.id = "end"
	var cmd_end_jump = CommandData.new()
	cmd_end_jump.type = "jump"
	cmd_end_jump.params = {"target": "__done"}  # nonexistent = engine stops
	main_scene.commands = [cmd_a, cmd_call, cmd_c, cmd_end_jump]

	scenario.scenes = [main_scene, sub_scene, end_scene]

	var engine = ScenarioEngine.new()
	engine.registry = registry
	engine.load_scenario(scenario)

	await engine.run()

	# Should execute A, B, C in order
	assert_eq(dialogue_handler.executed, ["A", "B", "C"])
