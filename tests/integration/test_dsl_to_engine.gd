extends GutTest
## Integration test: DSL → Lexer → Parser → Engine end-to-end.

var _original_presentation_snapshot: Dictionary
var _original_stage_assets_path := ""
var _stage_presenter: StagePresenter


func before_each() -> void:
	_original_presentation_snapshot = (
		StellaRuntime.presentation_state.capture_snapshot()
	)
	_original_stage_assets_path = StellaRuntime.stage_assets_path
	StellaRuntime.stage_assets_path = "res://tests/fixtures/stage/"
	StellaRuntime.presentation_state.clear()
	_stage_presenter = StagePresenter.new()
	add_child_autoqfree(_stage_presenter)


func after_each() -> void:
	if _stage_presenter != null and _stage_presenter.get_parent() != null:
		_stage_presenter.get_parent().remove_child(_stage_presenter)
	StellaRuntime.presentation_state.restore_snapshot(
		_original_presentation_snapshot
	)
	StellaRuntime.stage_assets_path = _original_stage_assets_path


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
	assert_true(
		scenario.diagnostics.is_empty(),
		"integration fixture must parse without diagnostics: %s" % [scenario.diagnostics],
	)

	var registry = CommandRegistry.new()
	var store = VariableStore.new()

	registry.register(BgHandler.new())
	registry.register(StageLayerHandler.new(StellaRuntime.presentation_director))
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
	var source = """@chapter test
@scene start
@bg bg_school_gate fade 0.8
@stage sakura show kind=character asset=stage:redraw_source position=960,80
sakura「你好！」
@choice
  - "你好" -> friendly {affection += 5}
  - "……" -> cold

@scene friendly
@stage sakura update asset=stage:redraw_blur_source
sakura「太好了！」
@jump ending

@scene cold
@stage sakura update asset=stage:redraw_blur_order
sakura「这样啊...」
@jump ending

@scene ending
「（第一天结束了。）」
@stage sakura remove"""

	var engine = _setup_engine(source)

	var scenes_visited: Array = []
	engine.scene_changed.connect(func(id): scenes_visited.append(id))

	await engine.run()

	assert_true(engine.context.is_finished)
	assert_eq(scenes_visited[0], "start")
	assert_eq(scenes_visited[-1], "ending")
	assert_true(scenes_visited.has("friendly"))


func test_headless_dialogue_marks_only_commands_advanced_normally() -> void:
	var source := """@chapter test
@scene start
「First」
「Second」"""
	var scenario := DslParser.parse(DslLexer.tokenize(source), "headless_read_flags")
	assert_eq(scenario.diagnostics, [])
	var read_flags := ReadFlagManager.new()
	var registry := CommandRegistry.new()
	registry.register(DialogueHandler.new(read_flags))
	var engine := ScenarioEngine.new()
	engine.registry = registry
	engine.load_scenario(scenario)
	var context := engine.context
	var scenario_identity := scenario.get_read_identity()
	var shown_texts: Array[String] = []
	var requests: Array[DialogueRequest] = []
	var on_dialogue := func(request: DialogueRequest) -> void:
		shown_texts.append(String(request.get_segments()[0].get("text", "")))
		requests.append(request)
	SignalBus.dialogue_requested.connect(on_dialogue)

	engine.run()
	await get_tree().process_frame
	assert_eq(shown_texts, ["First"])
	assert_eq(context.current_command_index, 0)
	assert_false(read_flags.is_dialogue_read(
		scenario_identity, "headless_read_flags", "start", 0, 0))

	assert_true(requests[0].advance())
	await get_tree().process_frame
	assert_eq(shown_texts, ["First", "Second"])
	assert_eq(context.current_command_index, 1,
		"the engine advances to the next command before dispatching it")
	assert_true(read_flags.is_dialogue_read(
		scenario_identity, "headless_read_flags", "start", 0, 0))
	assert_false(read_flags.is_dialogue_read(
		scenario_identity, "headless_read_flags", "start", 1, 1),
		"the currently waiting command is not read yet")

	# Runtime cancellation replaces the active context before waking the handler.
	engine.context = null
	SignalBus.engine_abort_requested.emit()
	await get_tree().process_frame
	assert_false(read_flags.is_dialogue_read(
		scenario_identity, "headless_read_flags", "start", 1, 1),
		"aborting the second command must leave it unread")
	SignalBus.dialogue_requested.disconnect(on_dialogue)


func test_named_stage_runs_from_dsl_through_scenario_engine():
	var source = """@chapter test
@scene start
@stage base show kind=background asset=stage:redraw_source z=-10
@stage hero show kind=character body=stage:redraw_blur_source face=stage:redraw_mask position=320,480
@stage hero update face=stage:redraw_blur_order"""
	var emitted_batches: Array = []
	var callback = func(operations, force_cut):
		emitted_batches.append([operations.duplicate(true), force_cut])
	SignalBus.stage_operations_requested.connect(callback)
	var engine := _setup_engine(source, "named_stage_e2e")

	await engine.run()

	assert_true(engine.context.is_finished)
	assert_eq(emitted_batches.size(), 3)
	assert_eq(emitted_batches[0][0][0]["id"], "base")
	assert_eq(emitted_batches[1][0][0]["id"], "hero")
	assert_eq(emitted_batches[2][0][0]["action"], "update")
	assert_false(emitted_batches[2][1])
	var stage_layers: Dictionary = (
		StellaRuntime.presentation_state.capture_snapshot()["stage_layers"]
	)
	assert_eq(stage_layers["hero"]["position"], [320.0, 480.0])
	assert_eq(stage_layers["hero"]["body"], "stage:redraw_blur_source")
	assert_eq(stage_layers["hero"]["face"], "stage:redraw_blur_order")
	SignalBus.stage_operations_requested.disconnect(callback)


func test_invalid_stage_update_cannot_partially_mutate_runtime_state():
	var source = """@chapter test
@scene start
@stage hero show face=stage:redraw_source opacity=0.8
@stage hero update face=stage:redraw_blur_order opacity=2"""
	var scenario := DslParser.parse(
		DslLexer.tokenize(source),
		"invalid_named_stage_e2e",
	)
	assert_eq(
		scenario.scenes[0].commands.size(),
		1,
		"the invalid update must not produce a runtime command",
	)
	var has_source_diagnostic := false
	for diagnostic in scenario.diagnostics:
		if (
			int(diagnostic.get("line", -1)) == 4
			and "opacity" in String(diagnostic.get("message", ""))
		):
			has_source_diagnostic = true
	assert_true(has_source_diagnostic)

	var emitted_batches: Array = []
	var callback = func(operations, force_cut):
		emitted_batches.append([operations.duplicate(true), force_cut])
	SignalBus.stage_operations_requested.connect(callback)
	var registry := CommandRegistry.new()
	registry.register(StageLayerHandler.new(StellaRuntime.presentation_director))
	var engine := ScenarioEngine.new()
	engine.registry = registry
	engine.load_scenario(scenario)

	await engine.run()

	assert_true(engine.context.is_finished)
	assert_eq(emitted_batches.size(), 1)
	var stage_layers: Dictionary = (
		StellaRuntime.presentation_state.capture_snapshot()["stage_layers"]
	)
	assert_eq(stage_layers["hero"]["face"], "stage:redraw_source")
	assert_almost_eq(stage_layers["hero"]["opacity"], 0.8, 0.001)
	SignalBus.stage_operations_requested.disconnect(callback)
