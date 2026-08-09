extends GutTest
## Tests for snapshot provider implementations (VariableStore, ScenarioContext).


func test_variable_store_snapshot_protocol():
	var store = VariableStore.new()
	store.set_var("hp", 100, VariableStore.Scope.SCENARIO)
	store.set_var("cg_unlocked", true, VariableStore.Scope.GLOBAL)

	assert_eq(store.get_provider_id(), "variable_store")

	var snapshot = store.capture_snapshot()
	store.set_var("hp", 0, VariableStore.Scope.SCENARIO)
	store.restore_snapshot(snapshot)

	assert_eq(store.get_var("hp"), 100)
	assert_eq(store.get_var("cg_unlocked"), true)


func test_scenario_context_snapshot_protocol():
	var scenario = ScenarioData.new()
	scenario.id = "chapter1"
	var scene1 = SceneData.new()
	scene1.id = "start"
	var scene2 = SceneData.new()
	scene2.id = "middle"
	scenario.scenes = [scene1, scene2]

	var ctx = ScenarioContext.new(scenario)
	ctx.current_scene_index = 1
	ctx.current_command_index = 5
	ctx.current_dialogue_mode = "nvl"
	ctx.nvl_page_epoch = 7

	assert_eq(ctx.get_provider_id(), "scenario_context")

	var snapshot = ctx.capture_snapshot()

	ctx.current_scene_index = 0
	ctx.current_command_index = 0
	ctx.current_dialogue_mode = "overlay"
	ctx.nvl_page_epoch = 99

	ctx.restore_snapshot(snapshot)

	assert_eq(ctx.current_scene_index, 1)
	assert_eq(ctx.current_command_index, 5)
	assert_eq(ctx.current_dialogue_mode, "nvl")
	assert_eq(ctx.nvl_page_epoch, 7)


func test_scenario_context_old_snapshot_restores_dialogue_mode_defaults():
	var ctx = ScenarioContext.new(ScenarioData.new())
	ctx.current_dialogue_mode = "nvl"
	ctx.nvl_page_epoch = 12

	ctx.restore_snapshot({
		"scene_index": 0,
		"command_index": 0,
		"is_finished": false,
		"return_stack": [],
	})

	assert_eq(ctx.current_dialogue_mode, "adv",
		"snapshots created before runtime mode tracking must restore the legacy mode")
	assert_eq(ctx.nvl_page_epoch, 0,
		"an old snapshot must not inherit the context's pre-restore page identity")
