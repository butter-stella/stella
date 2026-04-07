extends GutTest
## Tests for ScenarioContext / ScenarioEngine replay mode.
##
## Replay mode is the engine state used when jumping from backlog: the
## engine starts at an anchor position (set up by the runtime) with
## `is_replay = true` and a `replay_target` position. The main loop must
## clear `is_replay` once the engine reaches the target so the target
## command executes normally.

var _engine: ScenarioEngine
var _registry: CommandRegistry


# A handler that counts executions and records whether is_replay was set.
class CountingHandler extends CommandHandler:
	var count: int = 0
	var seen_replay_flags: Array = []

	func get_command_type() -> String:
		return "count"

	func execute(_data: CommandData, context: ScenarioContext) -> void:
		count += 1
		seen_replay_flags.append(context.is_replay)


func before_each():
	_registry = CommandRegistry.new()
	_engine = ScenarioEngine.new()
	_engine.registry = _registry


func _build_scenario(num_cmds: int) -> ScenarioData:
	var data = ScenarioData.new()
	data.id = "test"
	var scene = SceneData.new()
	scene.id = "start"
	for i in range(num_cmds):
		var cmd = CommandData.new()
		cmd.type = "count"
		scene.commands.append(cmd)
	data.scenes.append(scene)
	return data


# ─── ScenarioContext fields ───

func test_context_default_replay_flags():
	var ctx = ScenarioContext.new()
	assert_false(ctx.is_replay)
	assert_eq(ctx.replay_target_scene, -1)
	assert_eq(ctx.replay_target_command, -1)


func test_context_snapshot_does_not_persist_replay_flags():
	var ctx = ScenarioContext.new(_build_scenario(1))
	ctx.is_replay = true
	ctx.replay_target_scene = 0
	ctx.replay_target_command = 5
	var snap = ctx.capture_snapshot()
	assert_false(snap.has("is_replay"),
		"replay flags are runtime-only, not in save snapshots")


# ─── Engine main loop ───

func test_engine_replay_clears_flag_at_target_then_executes_normally():
	var handler = CountingHandler.new()
	_registry.register(handler)
	_engine.load_scenario(_build_scenario(5))

	var ctx = _engine.context
	ctx.is_replay = true
	ctx.replay_target_scene = 0
	ctx.replay_target_command = 3
	# Engine starts at command 0, replays through 0,1,2; at command 3 the
	# flag must clear so the target executes in normal mode.

	await _engine.run()
	# Engine ran 5 commands total (0..4)
	assert_eq(handler.count, 5)
	# Flags seen by handler when executed:
	# cmd 0: replay (haven't reached target)
	# cmd 1: replay
	# cmd 2: replay
	# cmd 3: NORMAL (target reached, flag cleared before dispatch)
	# cmd 4: normal
	assert_eq(handler.seen_replay_flags, [true, true, true, false, false])
	assert_false(ctx.is_replay)


func test_engine_replay_target_at_start_clears_immediately():
	var handler = CountingHandler.new()
	_registry.register(handler)
	_engine.load_scenario(_build_scenario(2))

	var ctx = _engine.context
	ctx.is_replay = true
	ctx.replay_target_scene = 0
	ctx.replay_target_command = 0

	await _engine.run()
	# Both commands executed in normal mode (target was the first one).
	assert_eq(handler.seen_replay_flags, [false, false])


func test_engine_normal_run_unaffected():
	var handler = CountingHandler.new()
	_registry.register(handler)
	_engine.load_scenario(_build_scenario(3))

	# is_replay defaults to false; everything runs normally.
	await _engine.run()
	assert_eq(handler.count, 3)
	assert_eq(handler.seen_replay_flags, [false, false, false])
