extends GutTest
## Unit contract for native story/recollection playback ownership (issue #171).

const SOURCE_PATH := "res://synthetic/recollection_playback.stla"


class TrackingHandler extends CommandHandler:
	var calls: Array[String] = []

	func get_command_type() -> String:
		return "tracking"

	func execute(data: CommandData, _context: ScenarioContext) -> void:
		calls.append(data.get_string("value"))


class ReturnTarget extends Node:
	var calls: Array[String]

	func _init(call_sink: Array[String]) -> void:
		calls = call_sink

	func return_to_gallery() -> void:
		calls.append("returned")


func _command(type: String, line: int, params: Dictionary = {}) -> CommandData:
	var command := CommandData.new()
	command.type = type
	command.params = params
	command.declared_line = line
	return command


func _scenario(commands: Array[CommandData]) -> ScenarioData:
	var data := ScenarioData.new()
	data.id = "recollection_playback"
	data.source_path = SOURCE_PATH
	data.source_identity = ScenarioData.make_source_identity(SOURCE_PATH)
	var scene := SceneData.new()
	scene.id = "start"
	scene.commands.assign(commands)
	data.scenes = [scene]
	return data


func _parse(source: String) -> ScenarioData:
	return DslParser.parse(
		DslLexer.tokenize(source),
		"recollection_playback",
		SOURCE_PATH,
	)


func _has_error(data: ScenarioData, fragment: String) -> bool:
	for diagnostic: Dictionary in data.diagnostics:
		if (
			String(diagnostic.get("level", "")) == "error"
			and String(diagnostic.get("message", "")).contains(fragment)
		):
			return true
	return false


func test_playback_context_validates_and_settles_return_exactly_once() -> void:
	var calls: Array[String] = []
	var target := ReturnTarget.new(calls)
	var playback := ScenarioPlaybackContext.recollection(
		Callable(target, "return_to_gallery"))

	assert_true(playback.is_valid_for_entry())
	assert_true(playback.is_recollection())
	assert_eq(playback.get_status(), ScenarioPlaybackContext.Status.ACTIVE)
	assert_true(playback.try_begin_return())
	assert_false(playback.try_begin_return(), "only one terminal path may claim return")
	assert_true(playback.complete_return())
	assert_eq(calls, ["returned"])
	assert_eq(playback.get_status(), ScenarioPlaybackContext.Status.RETURNED)
	assert_false(playback.complete_return())
	target.free()


func test_playback_context_defers_invalid_target_failure_until_after_claim() -> void:
	var calls: Array[String] = []
	var target := ReturnTarget.new(calls)
	var playback := ScenarioPlaybackContext.recollection(
		Callable(target, "return_to_gallery"))
	assert_true(playback.is_valid_for_entry())
	target.free()

	assert_true(playback.is_valid_for_entry(),
		"entry acceptance is sealed before a scene handoff can free the target")
	assert_true(playback.try_begin_return(),
		"a lost caller must not prevent Runtime from claiming cleanup")
	assert_false(playback.complete_return())
	assert_eq(playback.get_status(), ScenarioPlaybackContext.Status.CANCELLED)
	assert_eq(calls, [])


func test_playback_context_rejects_a_target_invalid_at_construction() -> void:
	var playback := ScenarioPlaybackContext.recollection(Callable())

	assert_false(playback.is_valid_for_entry())
	assert_false(playback.try_begin_return(),
		"an unaccepted entry cannot claim a return lifecycle")


func test_story_exit_is_noop_and_preserves_ordinary_advance_serial() -> void:
	var registry := CommandRegistry.new()
	var tracking := TrackingHandler.new()
	registry.register(RecollectionExitHandler.new())
	registry.register(tracking)
	var engine := ScenarioEngine.new()
	engine.registry = registry
	engine.load_scenario(_scenario([
		_command("recollection_exit", 4),
		_command("tracking", 5, {"value": "continued"}),
	]))
	var executed: Array[String] = []
	engine.command_executed.connect(
		func(command: CommandData) -> void: executed.append(command.type))
	var advance_serial := SignalBus.current_advance_dispatch_serial()

	await engine.run()

	assert_eq(tracking.calls, ["continued"])
	assert_eq(executed, ["recollection_exit", "tracking"],
		"story dispatch executes the following command exactly once")
	assert_eq(SignalBus.current_advance_dispatch_serial(), advance_serial,
		"the no-op cannot forge or consume a player advance")


func test_recollection_exit_ends_generation_before_following_command() -> void:
	var registry := CommandRegistry.new()
	var tracking := TrackingHandler.new()
	registry.register(RecollectionExitHandler.new())
	registry.register(tracking)
	var engine := ScenarioEngine.new()
	engine.registry = registry
	engine.load_scenario(_scenario([
		_command("recollection_exit", 8),
		_command("tracking", 9, {"value": "must_not_run"}),
	]))
	var target := ReturnTarget.new([])
	var playback := ScenarioPlaybackContext.recollection(
		Callable(target, "return_to_gallery"))
	assert_true(engine.context.set_playback_context(playback))
	var ended := [0]
	engine.scenario_ended.connect(func(_id: String) -> void: ended[0] += 1)

	await engine.run()

	assert_eq(tracking.calls, [])
	assert_eq(ended, [1])
	assert_eq(engine.context.recollection_exit_line, 8)
	assert_eq(playback.get_status(), ScenarioPlaybackContext.Status.ACTIVE,
		"only Runtime owns cleanup and caller settlement")
	target.free()


func test_programmatic_parallel_rejects_recollection_exit_atomically() -> void:
	var registry := CommandRegistry.new()
	var tracking := TrackingHandler.new()
	registry.register(RecollectionExitHandler.new())
	registry.register(tracking)
	var parallel_handler := ParallelHandler.new()
	parallel_handler.set_registry(registry)
	registry.register(parallel_handler)
	var parallel := _command("parallel", 14, {"commands": [
		_command("tracking", 15, {"value": "partial"}),
		_command("recollection_exit", 16),
	]})
	var engine := ScenarioEngine.new()
	engine.registry = registry
	engine.load_scenario(_scenario([
		parallel,
		_command("tracking", 17, {"value": "outer"}),
	]))
	var target := ReturnTarget.new([])
	assert_true(engine.context.set_playback_context(
		ScenarioPlaybackContext.recollection(
			Callable(target, "return_to_gallery"))))

	await engine.run()

	assert_push_warning("blocking 'recollection_exit' child is not allowed")
	assert_eq(tracking.calls, ["outer"],
		"parallel preflight must reject before the first child mutates state")
	assert_eq(engine.context.recollection_exit_line, 0)
	target.free()


func test_playback_context_is_runtime_only_and_not_snapshotted() -> void:
	var context := ScenarioContext.new(_scenario([]))
	var target := ReturnTarget.new([])
	assert_true(context.set_playback_context(ScenarioPlaybackContext.recollection(
		Callable(target, "return_to_gallery"))))
	var snapshot := context.capture_snapshot()

	assert_false(snapshot.has("playback_context"))
	assert_false(snapshot.has("recollection"))
	var restored := ScenarioContext.new(context.scenario_data)
	restored.restore_snapshot(snapshot)
	assert_false(restored.is_recollection_playback())
	target.free()


func test_recollection_exit_dsl_has_one_zero_argument_active_scene_form() -> void:
	var data := _parse("""@chapter memory "Memory"
@scene start
@recollection_exit
""")

	assert_eq(data.diagnostics, [])
	assert_eq(data.scenes.size(), 1)
	assert_eq(data.scenes[0].commands.size(), 1)
	var command: CommandData = data.scenes[0].commands[0]
	assert_eq(command.type, "recollection_exit")
	assert_eq(command.params, {})
	assert_eq(command.declared_line, 3)


func test_recollection_exit_dsl_fails_closed_outside_its_exact_grammar() -> void:
	var extra := _parse("""@chapter memory
@scene start
@recollection_exit gallery
""")
	assert_true(_has_error(extra,
		"@recollection_exit does not accept arguments at %s:3" % SOURCE_PATH))
	assert_eq(extra.scenes[0].commands, [])

	var outside := _parse("""@chapter memory
@recollection_exit
@scene start
""")
	assert_true(_has_error(outside,
		"@recollection_exit requires an active @scene at %s:2" % SOURCE_PATH))
	assert_eq(outside.scenes[0].commands, [])

	var parallel := _parse("""@chapter memory
@scene start
@parallel
@recollection_exit
@end
""")
	assert_true(_has_error(parallel, "blocking 'recollection_exit'"))
	assert_eq(parallel.scenes[0].commands, [])

	var combine := _parse("""@chapter memory
@scene start
@combine
@recollection_exit
「kept」
@end
""")
	assert_true(_has_error(combine,
		"@recollection_exit is not allowed inside @combine at %s:4" % SOURCE_PATH))
	assert_eq(combine.scenes[0].commands.size(), 1)
	assert_eq(combine.scenes[0].commands[0].type, "dialogue")
