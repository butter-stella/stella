extends GutTest
## Integration test: DSL → Lexer → Parser → Engine end-to-end.


# Auto-advancing handlers for testing (no player input needed)
class AutoDialogueHandler extends CommandHandler:
	func get_command_type() -> String:
		return "dialogue"
	func execute(_data: CommandData, _context: ScenarioContext) -> void:
		pass


class AutoChoiceHandler extends CommandHandler:
	func get_command_type() -> String:
		return "choice"
	func execute(data: CommandData, context: ScenarioContext) -> void:
		var options = data.params.get("options", [])
		if options.size() > 0:
			var opt = options[0]
			if opt.has("jump"):
				context.pending_jump = opt["jump"]
			if opt.has("set") and context.variable_store:
				var set_data = opt["set"]
				for var_name in set_data:
					var parts = set_data[var_name].split(" ")
					if parts.size() == 2:
						context.variable_store.set_var(
							var_name,
							int(parts[1]),
							VariableStore.Scope.SCENARIO,
							parts[0]
						)


func _setup_engine(source: String, scenario_id: String = "demo") -> ScenarioEngine:
	var tokens = DslLexer.tokenize(source)
	var scenario = DslParser.parse(tokens, scenario_id)

	var registry = CommandRegistry.new()
	var store = VariableStore.new()

	registry.register(BgHandler.new())
	registry.register(CharShowHandler.new())
	registry.register(CharHideHandler.new())
	registry.register(CharExprHandler.new())
	registry.register(JumpHandler.new())
	registry.register(SetHandler.new())
	registry.register(ConditionHandler.new())
	registry.register(AutoDialogueHandler.new())
	registry.register(AutoChoiceHandler.new())

	var engine = ScenarioEngine.new()
	engine.registry = registry
	engine.load_scenario(scenario)
	engine.context.variable_store = store
	return engine


func test_poc_demo_runs_to_completion():
	var source = """@scene start
@bg bg_school_gate fade 0.8
@show sakura smile center
sakura「你好！」
@choice
  - "你好" -> friendly {affection += 5}
  - "……" -> cold

@scene friendly
@expr sakura happy
sakura「太好了！」
@jump ending

@scene cold
@expr sakura sad
sakura「这样啊...」
@jump ending

@scene ending
「（第一天结束了。）」
@hide sakura
@end"""

	var engine = _setup_engine(source)

	var scenes_visited: Array = []
	engine.scene_changed.connect(func(id): scenes_visited.append(id))

	await engine.run()

	assert_true(engine.context.is_finished)
	assert_eq(scenes_visited[0], "start")
	assert_eq(scenes_visited[-1], "ending")
	assert_true(scenes_visited.has("friendly"))
