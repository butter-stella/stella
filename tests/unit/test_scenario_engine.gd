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
