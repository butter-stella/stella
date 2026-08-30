extends GutTest
## Tests for ScenarioEngine — main loop, command dispatch, scene jumping.


var _engine: ScenarioEngine
var _registry: CommandRegistry
var _executed_commands: Array


# --- Test handlers ---
class JumpTestHandler extends CommandHandler:
	func get_command_type() -> String:
		return "jump"
	func execute(data: CommandData, context: ScenarioContext) -> void:
		context.pending_jump = data.get_string("target")


class TrackingHandler extends CommandHandler:
	var _type: String
	var executed: Array = []

	func _init(type: String = "test"):
		_type = type

	func get_command_type() -> String:
		return _type

	func execute(data: CommandData, context: ScenarioContext) -> void:
		executed.append(data)


class ModeTrackingHandler extends CommandHandler:
	var states: Array = []
	var stop_after: int = -1
	var _type: String = "mode_tracking"

	func _init(type: String = "mode_tracking") -> void:
		_type = type

	func get_command_type() -> String:
		return _type

	func execute(_data: CommandData, context: ScenarioContext) -> void:
		states.append({
			"mode": context.current_dialogue_mode,
			"epoch": context.nvl_page_epoch,
		})
		if stop_after > 0 and states.size() >= stop_after:
			context.is_finished = true


class PresentationTrackingHandler extends CommandHandler:
	var states: Array = []

	func get_command_type() -> String:
		return "dialogue"

	func execute(data: CommandData, context: ScenarioContext) -> void:
		states.append({
			"text": data.get_string("text"),
			"mode": context.current_dialogue_mode,
			"profile_name": context.get("current_dialogue_profile_name"),
			"declarative": context.get("current_dialogue_uses_declarative_presentation"),
		})


func _build_cmd(type: String, params: Dictionary = {}) -> CommandData:
	var cmd = CommandData.new()
	cmd.type = type
	cmd.params = params
	return cmd


func _build_scenario(scenes_config: Array) -> ScenarioData:
	var scenario = ScenarioData.new()
	scenario.id = "test"
	for config in scenes_config:
		var scene = SceneData.new()
		scene.id = config["id"]
		for cmd_config in config.get("commands", []):
			scene.commands.append(_build_cmd(cmd_config["type"], cmd_config.get("params", {})))
		scenario.scenes.append(scene)
	return scenario


func before_each():
	_registry = CommandRegistry.new()
	_engine = ScenarioEngine.new()
	_engine.registry = _registry


func test_engine_executes_single_command():
	var handler = TrackingHandler.new("dialogue")
	_registry.register(handler)

	var scenario = _build_scenario([{
		"id": "start",
		"commands": [{"type": "dialogue", "params": {"text": "Hello"}}]
	}])

	_engine.load_scenario(scenario)
	await _engine.run()

	assert_eq(handler.executed.size(), 1)
	assert_eq(handler.executed[0].get_string("text"), "Hello")


func test_engine_executes_multiple_commands_in_order():
	var handler = TrackingHandler.new("dialogue")
	_registry.register(handler)

	var scenario = _build_scenario([{
		"id": "start",
		"commands": [
			{"type": "dialogue", "params": {"text": "First"}},
			{"type": "dialogue", "params": {"text": "Second"}},
			{"type": "dialogue", "params": {"text": "Third"}},
		]
	}])

	_engine.load_scenario(scenario)
	await _engine.run()

	assert_eq(handler.executed.size(), 3)
	assert_eq(handler.executed[0].get_string("text"), "First")
	assert_eq(handler.executed[1].get_string("text"), "Second")
	assert_eq(handler.executed[2].get_string("text"), "Third")


func test_command_position_edge_precedes_handler_and_stale_run_stops() -> void:
	var handler := TrackingHandler.new("dialogue")
	_registry.register(handler)
	var original := _build_scenario([{
		"id": "start",
		"commands": [{"type": "dialogue", "params": {"text": "retired"}}],
	}])
	var replacement := _build_scenario([{
		"id": "replacement",
		"commands": [{"type": "dialogue", "params": {"text": "fresh"}}],
	}])
	var observed: Array[Dictionary] = []
	_engine.command_position_changed.connect(func(
		context: ScenarioContext,
		command: CommandData,
	) -> void:
		observed.append({
			"context": context,
			"command": command,
			"current": context.current_command(),
		})
		if command.get_string("text") == "retired":
			_engine.load_scenario(replacement)
	)

	_engine.load_scenario(original)
	await _engine.run()

	assert_eq(observed.size(), 1)
	assert_same(observed[0]["command"], observed[0]["current"],
		"the non-null cursor is canonical before the edge is emitted")
	assert_eq(handler.executed.size(), 0,
		"a listener-owned replacement invalidates the stale pre-handler tail")
	assert_same(_engine.context.scenario_data, replacement)


func test_parallel_handler_rejects_blocking_dialogue_children_atomically() -> void:
	var read_flags := ReadFlagManager.new()
	var dialogue_handler := DialogueHandler.new(read_flags)
	var parallel_handler := ParallelHandler.new()
	parallel_handler.set_registry(_registry)
	_registry.register(dialogue_handler)
	_registry.register(parallel_handler)
	var first := _build_cmd("dialogue", {"text": "First"})
	var second := _build_cmd("dialogue", {"text": "Second"})
	var parallel := _build_cmd("parallel", {"commands": [first, second]})
	var scenario := _build_scenario([{"id": "start", "commands": []}])
	scenario.scenes[0].commands.append(parallel)
	_engine.load_scenario(scenario)
	await _engine.run()

	assert_push_warning("ParallelHandler: blocking 'dialogue' child is not allowed")
	assert_ne(first.uid, second.uid)
	assert_false(read_flags.is_dialogue_read(
		"id:test", "test", "start", first.uid, 0))
	assert_false(read_flags.is_dialogue_read(
		"id:test", "test", "start", second.uid, 0))


func test_dialogue_request_abort_stops_engine_before_next_command() -> void:
	var read_flags := ReadFlagManager.new()
	_registry.register(DialogueHandler.new(read_flags))
	var scenario := _build_scenario([{
		"id": "start",
		"commands": [
			{"type": "dialogue", "params": {"text": "First"}},
			{"type": "dialogue", "params": {"text": "Must not run"}},
		],
	}])
	var shown: Array[String] = []
	var on_request := func(request: DialogueRequest) -> void:
		shown.append(request.get_segments()[0].get("text", ""))
		request.abort()
	SignalBus.dialogue_requested.connect(on_request)

	_engine.load_scenario(scenario)
	await _engine.run()
	SignalBus.dialogue_requested.disconnect(on_request)

	assert_eq(shown, ["First"])
	assert_eq(_engine.context.current_command_index, 0,
		"abort must not look like successful command completion")
	assert_true(_engine.context.is_finished)


func test_engine_advances_to_next_scene():
	var handler = TrackingHandler.new("dialogue")
	_registry.register(handler)

	var scenario = _build_scenario([
		{"id": "scene1", "commands": [{"type": "dialogue", "params": {"text": "Scene1"}}]},
		{"id": "scene2", "commands": [{"type": "dialogue", "params": {"text": "Scene2"}}]},
	])

	_engine.load_scenario(scenario)
	await _engine.run()

	assert_eq(handler.executed.size(), 2)
	assert_eq(handler.executed[0].get_string("text"), "Scene1")
	assert_eq(handler.executed[1].get_string("text"), "Scene2")


func test_engine_applies_dialogue_mode_sidecars_without_addressable_commands():
	var handler := ModeTrackingHandler.new()
	_registry.register(handler)
	var scenario := _build_scenario([{
		"id": "start",
		"commands": [{"type": "mode_tracking"}],
	}])
	var command: CommandData = scenario.scenes[0].commands[0]
	command.dialogue_mode_events_before.assign(["nvl"])
	command.dialogue_mode_events_after.assign(["adv", "nvl"])
	scenario.scenes[0].dialogue_mode_events_on_exit.assign(["adv"])
	var completed_states: Array = []
	_engine.command_executed.connect(func(_command):
		completed_states.append({
			"mode": _engine.context.current_dialogue_mode,
			"epoch": _engine.context.nvl_page_epoch,
		})
	)

	_engine.load_scenario(scenario)
	await _engine.run()

	assert_eq(scenario.scenes[0].commands.size(), 1,
		"mode sidecars do not consume persisted command indices")
	assert_eq(handler.states, [{"mode": "nvl", "epoch": 1}],
		"before events run before the real handler")
	assert_eq(completed_states, [{"mode": "nvl", "epoch": 2}],
		"after events complete before command_executed")
	assert_eq(_engine.context.current_dialogue_mode, "adv",
		"scene exit events run before natural fallthrough")
	assert_eq(_engine.context.nvl_page_epoch, 2)


func test_engine_applies_mode_only_else_edge_before_the_continuation():
	var scenario := DslParser.parse(DslLexer.tokenize("""@chapter test
@scene start
@if flag
@else
@nvl off
@nvl
@end
@bg marker"""), "mode_only_else")
	assert_eq(scenario.diagnostics, [])
	assert_eq(scenario.scenes.size(), 3,
		"the false mode edge must not require an extra synthetic scene")
	assert_null(scenario.get_scene("__if_start_3_else"))

	var handler := ModeTrackingHandler.new("bg")
	_registry.register(handler)
	_registry.register(ConditionHandler.new())
	_engine.load_scenario(scenario)
	_engine.context.variable_store.set_var("flag", false)
	_engine.context.current_dialogue_mode = "nvl"
	_engine.context.nvl_page_epoch = 1

	await _engine.run()

	assert_eq(handler.states, [{"mode": "nvl", "epoch": 2}],
		"the selected false edge must run before its continuation command")


func test_branch_profile_selection_follows_only_the_executed_path_through_join():
	var scenario := DslParser.parse(DslLexer.tokenize("""@dialogue_profile message line_spacing=1
@dialogue_profile novel line_spacing=2
@dialogue_profile aside line_spacing=3
@chapter test
@scene start
@adv profile=message
@if route == 1
@nvl profile=novel
「then」
@elif route == 2
@overlay profile=aside
「elif」
@else
「else」
@end
「join」"""), "branch_profiles")
	assert_eq(scenario.diagnostics, [])

	for case in [
		{"route": 1, "mode": "nvl", "profile_name": "novel", "branch": "then"},
		{"route": 2, "mode": "overlay", "profile_name": "aside", "branch": "elif"},
		{"route": 3, "mode": "adv", "profile_name": "message", "branch": "else"},
	]:
		var registry := CommandRegistry.new()
		var engine := ScenarioEngine.new()
		var handler := PresentationTrackingHandler.new()
		registry.register(handler)
		registry.register(ConditionHandler.new())
		registry.register(JumpTestHandler.new())
		engine.registry = registry
		engine.load_scenario(scenario)
		engine.context.variable_store.set_var("route", case["route"])

		await engine.run()

		assert_eq(handler.states, [
			{
				"text": case["branch"],
				"mode": case["mode"],
				"profile_name": case["profile_name"],
				"declarative": true,
			},
			{
				"text": "join",
				"mode": case["mode"],
				"profile_name": case["profile_name"],
				"declarative": true,
			},
		], "unexecuted branches must not contaminate dialogue state")


func test_call_restores_adv_profile_after_callee_exit_sidecar():
	var scenario := DslParser.parse(DslLexer.tokenize("""@dialogue_profile message line_spacing=1
@dialogue_profile novel line_spacing=2
@chapter test
@scene main
@adv profile=message
「before」
@call callee
「after」
@jump finish
@scene callee
@nvl profile=novel
「inside」
@nvl off
@scene finish
「finish」"""), "call_profiles")
	assert_eq(scenario.diagnostics, [])
	var registry := CommandRegistry.new()
	var engine := ScenarioEngine.new()
	var handler := PresentationTrackingHandler.new()
	registry.register(handler)
	registry.register(CallHandler.new())
	registry.register(JumpTestHandler.new())
	engine.registry = registry
	engine.load_scenario(scenario)

	await engine.run()

	assert_eq(handler.states, [
		{"text": "before", "mode": "adv", "profile_name": "message", "declarative": true},
		{"text": "inside", "mode": "nvl", "profile_name": "novel", "declarative": true},
		{"text": "after", "mode": "adv", "profile_name": "message", "declarative": true},
		{"text": "finish", "mode": "adv", "profile_name": "message", "declarative": true},
	])


func test_jump_target_replays_its_profile_selection_sidecar():
	var scenario := DslParser.parse(DslLexer.tokenize("""@dialogue_profile message line_spacing=1
@dialogue_profile aside line_spacing=3
@chapter test
@scene start
@adv profile=message
@jump target
@scene target
@overlay profile=aside
「target」"""), "jump_profiles")
	assert_eq(scenario.diagnostics, [])
	var registry := CommandRegistry.new()
	var engine := ScenarioEngine.new()
	var handler := PresentationTrackingHandler.new()
	registry.register(handler)
	registry.register(JumpTestHandler.new())
	engine.registry = registry
	engine.load_scenario(scenario)

	await engine.run()

	assert_eq(handler.states, [{
		"text": "target",
		"mode": "overlay",
		"profile_name": "aside",
		"declarative": true,
	}])


func test_engine_repeated_nvl_event_keeps_the_current_runtime_page():
	var handler := ModeTrackingHandler.new()
	_registry.register(handler)
	var scenario := _build_scenario([{
		"id": "start",
		"commands": [
			{"type": "mode_tracking"},
			{"type": "mode_tracking"},
		],
	}])
	scenario.scenes[0].commands[0].dialogue_mode_events_before.assign(["nvl"])
	scenario.scenes[0].commands[1].dialogue_mode_events_before.assign(["nvl"])

	_engine.load_scenario(scenario)
	await _engine.run()

	assert_eq(handler.states, [
		{"mode": "nvl", "epoch": 1},
		{"mode": "nvl", "epoch": 1},
	], "the parser preserves both events, while runtime ignores the repeated mode")


func test_engine_jump_loop_replays_entry_and_exit_events_on_every_visit():
	var handler := ModeTrackingHandler.new()
	handler.stop_after = 2
	_registry.register(handler)
	_registry.register(JumpTestHandler.new())
	var scenario := _build_scenario([{
		"id": "page",
		"commands": [
			{"type": "mode_tracking"},
			{"type": "jump", "params": {"target": "page"}},
		],
	}])
	scenario.scenes[0].commands[0].dialogue_mode_events_before.assign(["nvl"])
	scenario.scenes[0].commands[1].dialogue_mode_events_before.assign(["adv"])

	_engine.load_scenario(scenario)
	await _engine.run()

	assert_eq(handler.states, [
		{"mode": "nvl", "epoch": 1},
		{"mode": "nvl", "epoch": 2},
	], "jumping back must replay both sidecars and create a fresh NVL page")


func test_engine_nested_if_in_then_executes_only_the_selected_cfg_path():
	var scenario := DslParser.parse(DslLexer.tokenize("""@chapter test
@scene start
@if outer
「outer before」
@if inner
「inner then」
@else
「inner else」
@end
「outer after」
@else
「outer else」
@end
「done」"""), "nested_then")
	assert_eq(scenario.diagnostics, [])

	var cases := [
		{"outer": true, "inner": true,
			"expected": ["outer before", "inner then", "outer after", "done"]},
		{"outer": true, "inner": false,
			"expected": ["outer before", "inner else", "outer after", "done"]},
		{"outer": false, "inner": true,
			"expected": ["outer else", "done"]},
		{"outer": false, "inner": false,
			"expected": ["outer else", "done"]},
	]
	for case in cases:
		var registry := CommandRegistry.new()
		var engine := ScenarioEngine.new()
		var dialogue_handler := TrackingHandler.new("dialogue")
		registry.register(dialogue_handler)
		registry.register(ConditionHandler.new())
		registry.register(JumpTestHandler.new())
		engine.registry = registry
		engine.load_scenario(scenario)
		engine.context.variable_store.set_var("outer", case["outer"])
		engine.context.variable_store.set_var("inner", case["inner"])

		await engine.run()

		var executed_texts: Array[String] = []
		for command in dialogue_handler.executed:
			executed_texts.append(command.get_string("text"))
		assert_eq(executed_texts, case["expected"],
			"nested then CFG mismatch for outer=%s inner=%s"
			% [case["outer"], case["inner"]])


func test_engine_nested_if_in_else_rejoins_before_outer_continuation():
	var scenario := DslParser.parse(DslLexer.tokenize("""@chapter test
@scene start
@if outer
「outer then」
@else
「outer else before」
@if inner
「inner then」
@else
「inner else」
@end
「outer else after」
@end
「done」"""), "nested_else")
	assert_eq(scenario.diagnostics, [])

	var cases := [
		{"outer": true, "inner": true,
			"expected": ["outer then", "done"]},
		{"outer": false, "inner": true,
			"expected": ["outer else before", "inner then", "outer else after", "done"]},
		{"outer": false, "inner": false,
			"expected": ["outer else before", "inner else", "outer else after", "done"]},
	]
	for case in cases:
		var registry := CommandRegistry.new()
		var engine := ScenarioEngine.new()
		var dialogue_handler := TrackingHandler.new("dialogue")
		registry.register(dialogue_handler)
		registry.register(ConditionHandler.new())
		registry.register(JumpTestHandler.new())
		engine.registry = registry
		engine.load_scenario(scenario)
		engine.context.variable_store.set_var("outer", case["outer"])
		engine.context.variable_store.set_var("inner", case["inner"])

		await engine.run()

		var executed_texts: Array[String] = []
		for command in dialogue_handler.executed:
			executed_texts.append(command.get_string("text"))
		assert_eq(executed_texts, case["expected"],
			"nested else CFG mismatch for outer=%s inner=%s"
			% [case["outer"], case["inner"]])


func test_engine_multi_elif_executes_one_branch_then_root_continuation():
	var scenario := DslParser.parse(DslLexer.tokenize("""@chapter test
@scene start
@if route == 1
「one」
@elif route == 2
「two」
@elif route == 3
「three」
@else
「four」
@end
「done」"""), "multi_elif")
	assert_eq(scenario.diagnostics, [])

	for case in [
		{"route": 1, "branch": "one"},
		{"route": 2, "branch": "two"},
		{"route": 3, "branch": "three"},
		{"route": 4, "branch": "four"},
	]:
		var registry := CommandRegistry.new()
		var engine := ScenarioEngine.new()
		var dialogue_handler := TrackingHandler.new("dialogue")
		registry.register(dialogue_handler)
		registry.register(ConditionHandler.new())
		registry.register(JumpTestHandler.new())
		engine.registry = registry
		engine.load_scenario(scenario)
		engine.context.variable_store.set_var("route", case["route"])

		await engine.run()

		var executed_texts: Array[String] = []
		for command in dialogue_handler.executed:
			executed_texts.append(command.get_string("text"))
		assert_eq(executed_texts, [case["branch"], "done"],
			"elif route %d must execute exactly one branch" % case["route"])


func test_engine_nested_if_callee_returns_to_command_after_call():
	var scenario := DslParser.parse(DslLexer.tokenize("""@chapter test
@scene main
「main before」
@call callee
「main after」
@jump finish
@scene callee
「callee before」
@if outer
@if inner
「inner then」
@else
「inner else」
@end
@else
「outer else」
@end
「callee after」
@scene finish
「finish」"""), "nested_callee")
	assert_eq(scenario.diagnostics, [])

	var registry := CommandRegistry.new()
	var engine := ScenarioEngine.new()
	var dialogue_handler := TrackingHandler.new("dialogue")
	registry.register(dialogue_handler)
	registry.register(ConditionHandler.new())
	registry.register(JumpTestHandler.new())
	registry.register(CallHandler.new())
	engine.registry = registry
	engine.load_scenario(scenario)
	engine.context.variable_store.set_var("outer", true)
	engine.context.variable_store.set_var("inner", false)

	await engine.run()

	var executed_texts: Array[String] = []
	for command in dialogue_handler.executed:
		executed_texts.append(command.get_string("text"))
	assert_eq(executed_texts, [
		"main before",
		"callee before",
		"inner else",
		"callee after",
		"main after",
		"finish",
	])
	assert_eq(engine.context.return_stack, [],
		"callee exhaustion must consume exactly one return point")


func test_engine_nested_if_preserves_branch_local_dialogue_mode_sidecars():
	var scenario := DslParser.parse(DslLexer.tokenize("""@chapter test
@scene start
@nvl
@if outer
@nvl off
@if inner
@nvl
@bg inner_true
@else
@overlay
@bg inner_false
@end
@nvl off
@else
@nvl off
@end
@nvl
@bg continuation"""), "nested_modes")
	assert_eq(scenario.diagnostics, [])

	var cases := [
		{"outer": true, "inner": true, "expected": [
			{"mode": "nvl", "epoch": 2},
			{"mode": "nvl", "epoch": 3},
		]},
		{"outer": true, "inner": false, "expected": [
			{"mode": "overlay", "epoch": 1},
			{"mode": "nvl", "epoch": 2},
		]},
		{"outer": false, "inner": true, "expected": [
			{"mode": "nvl", "epoch": 2},
		]},
	]
	for case in cases:
		var registry := CommandRegistry.new()
		var engine := ScenarioEngine.new()
		var mode_handler := ModeTrackingHandler.new("bg")
		registry.register(mode_handler)
		registry.register(ConditionHandler.new())
		registry.register(JumpTestHandler.new())
		engine.registry = registry
		engine.load_scenario(scenario)
		engine.context.variable_store.set_var("outer", case["outer"])
		engine.context.variable_store.set_var("inner", case["inner"])

		await engine.run()

		assert_eq(mode_handler.states, case["expected"],
			"dialogue mode events must stay on the selected nested CFG path")


func test_engine_handles_jump():
	var handler = TrackingHandler.new("dialogue")
	_registry.register(handler)
	_registry.register(JumpTestHandler.new())

	var scenario = _build_scenario([
		{"id": "start", "commands": [
			{"type": "dialogue", "params": {"text": "Before jump"}},
			{"type": "jump", "params": {"target": "ending"}},
			{"type": "dialogue", "params": {"text": "Should be skipped"}},
		]},
		{"id": "middle", "commands": [
			{"type": "dialogue", "params": {"text": "Also skipped"}},
		]},
		{"id": "ending", "commands": [
			{"type": "dialogue", "params": {"text": "After jump"}},
		]},
	])

	_engine.load_scenario(scenario)
	await _engine.run()

	assert_eq(handler.executed.size(), 2)
	assert_eq(handler.executed[0].get_string("text"), "Before jump")
	assert_eq(handler.executed[1].get_string("text"), "After jump")


func test_engine_skips_unknown_command_types():
	var handler = TrackingHandler.new("dialogue")
	_registry.register(handler)

	var scenario = _build_scenario([{
		"id": "start",
		"commands": [
			{"type": "unknown_type"},
			{"type": "dialogue", "params": {"text": "After unknown"}},
		]
	}])

	_engine.load_scenario(scenario)
	await _engine.run()

	assert_eq(handler.executed.size(), 1)
	assert_eq(handler.executed[0].get_string("text"), "After unknown")


func test_engine_empty_scenario():
	var scenario = ScenarioData.new()
	scenario.id = "empty"
	_engine.load_scenario(scenario)
	await _engine.run()
	assert_true(_engine.context.is_finished)


func test_engine_signals_scenario_started():
	var started_ids: Array = []
	_engine.scenario_started.connect(func(id): started_ids.append(id))

	var scenario = _build_scenario([{
		"id": "start", "commands": []
	}])

	_engine.load_scenario(scenario)
	await _engine.run()

	assert_eq(started_ids, ["test"])


func test_engine_signals_scenario_ended():
	var ended_ids: Array = []
	_engine.scenario_ended.connect(func(id): ended_ids.append(id))

	var scenario = _build_scenario([{
		"id": "start", "commands": []
	}])

	_engine.load_scenario(scenario)
	await _engine.run()

	assert_eq(ended_ids, ["test"])


func test_engine_signals_scene_changed():
	var changed_ids: Array = []
	_engine.scene_changed.connect(func(id): changed_ids.append(id))

	var handler = TrackingHandler.new("dialogue")
	_registry.register(handler)

	var scenario = _build_scenario([
		{"id": "scene1", "commands": [{"type": "dialogue", "params": {"text": "1"}}]},
		{"id": "scene2", "commands": [{"type": "dialogue", "params": {"text": "2"}}]},
	])

	_engine.load_scenario(scenario)
	await _engine.run()

	assert_eq(changed_ids, ["scene1", "scene2"])


func test_scenario_started_reentrancy_cannot_resume_or_end_replaced_run():
	var handler := TrackingHandler.new("dialogue")
	_registry.register(handler)
	var old_scenario := _build_scenario([{
		"id": "old",
		"commands": [{"type": "dialogue", "params": {"text": "stale"}}],
	}])
	old_scenario.id = "old"
	var replacement := _build_scenario([{"id": "replacement", "commands": []}])
	replacement.id = "replacement"
	var changed_ids: Array[String] = []
	var ended_ids: Array[String] = []
	_engine.scene_changed.connect(func(id: String) -> void: changed_ids.append(id))
	_engine.scenario_ended.connect(func(id: String) -> void: ended_ids.append(id))
	_engine.scenario_started.connect(func(id: String) -> void:
		if id == "old":
			_engine.load_scenario(replacement)
			_engine.run()
	)

	_engine.load_scenario(old_scenario)
	await _engine.run()

	assert_eq(handler.executed, [])
	assert_eq(changed_ids, ["replacement"])
	assert_eq(ended_ids, ["replacement"])
	assert_eq(_engine.context.scenario_data.id, "replacement")


func test_scene_changed_reentrancy_cannot_resume_or_end_replaced_run():
	var handler := TrackingHandler.new("dialogue")
	_registry.register(handler)
	var old_scenario := _build_scenario([{
		"id": "old_scene",
		"commands": [{"type": "dialogue", "params": {"text": "stale"}}],
	}])
	old_scenario.id = "old"
	var replacement := _build_scenario([{"id": "replacement", "commands": []}])
	replacement.id = "replacement"
	var ended_ids: Array[String] = []
	_engine.scenario_ended.connect(func(id: String) -> void: ended_ids.append(id))
	_engine.scene_changed.connect(func(id: String) -> void:
		if id == "old_scene":
			_engine.load_scenario(replacement)
			_engine.run()
	)

	_engine.load_scenario(old_scenario)
	await _engine.run()

	assert_eq(handler.executed, [])
	assert_eq(ended_ids, ["replacement"])
	assert_eq(_engine.context.scenario_data.id, "replacement")


func test_command_executed_reentrancy_cannot_run_remaining_old_commands():
	var handler := TrackingHandler.new("dialogue")
	_registry.register(handler)
	var old_scenario := _build_scenario([{
		"id": "old_scene",
		"commands": [
			{"type": "dialogue", "params": {"text": "first"}},
			{"type": "dialogue", "params": {"text": "stale second"}},
		],
	}])
	old_scenario.id = "old"
	var replacement := _build_scenario([{"id": "replacement", "commands": []}])
	replacement.id = "replacement"
	var ended_ids: Array[String] = []
	_engine.scenario_ended.connect(func(id: String) -> void: ended_ids.append(id))
	_engine.command_executed.connect(func(_command: CommandData) -> void:
		if _engine.context.scenario_data.id == "old":
			_engine.load_scenario(replacement)
			_engine.run()
	)

	_engine.load_scenario(old_scenario)
	await _engine.run()

	assert_eq(handler.executed.size(), 1)
	assert_eq(handler.executed[0].get_string("text"), "first")
	assert_eq(ended_ids, ["replacement"])
	assert_eq(_engine.context.scenario_data.id, "replacement")


func test_context_tracks_current_position():
	var handler = TrackingHandler.new("dialogue")
	_registry.register(handler)

	var scenario = _build_scenario([{
		"id": "start",
		"commands": [
			{"type": "dialogue", "params": {"text": "Hello"}},
		]
	}])

	_engine.load_scenario(scenario)
	assert_eq(_engine.context.current_scene_index, 0)
	assert_eq(_engine.context.current_command_index, 0)


func test_engine_auto_creates_variable_store():
	var scenario = _build_scenario([{
		"id": "start", "commands": []
	}])
	_engine.load_scenario(scenario)
	assert_not_null(_engine.context.variable_store)
