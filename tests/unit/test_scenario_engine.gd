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
