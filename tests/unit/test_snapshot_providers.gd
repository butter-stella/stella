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


func test_scenario_context_snapshot_round_trips_runtime_profile_names_only():
	var scenario := ScenarioData.new()
	scenario.dialogue_profiles = {
		"message": {"line_spacing": 1},
		"novel": {"line_spacing": 2},
	}
	var ctx := ScenarioContext.new(scenario)
	ctx.apply_dialogue_mode_events([{
		"action": "select_adv",
		"mode": "adv",
		"profile_name": "message",
	}])
	ctx.apply_dialogue_mode_events([{
		"action": "select_mode",
		"mode": "nvl",
		"profile_name": "novel",
	}])

	var snapshot := ctx.capture_snapshot()
	assert_eq(snapshot.get("dialogue_profile_name"), "novel")
	assert_eq(snapshot.get("adv_dialogue_profile_name"), "message")
	assert_false(snapshot.has("dialogue_profile"),
		"typed profile dictionaries and diagnostic provenance stay out of saves")
	assert_not_null(JSON.parse_string(JSON.stringify(snapshot)),
		"scenario selection snapshots remain JSON serializable")

	ctx.apply_dialogue_mode_events([{
		"action": "select_adv",
		"mode": "adv",
		"profile_name": "",
	}])
	ctx.restore_snapshot(snapshot)

	assert_eq(ctx.current_dialogue_mode, "nvl")
	assert_eq(ctx.current_dialogue_profile_name, "novel")
	assert_true(ctx.current_dialogue_uses_declarative_presentation)
	assert_eq(ctx.adv_dialogue_profile_name, "message")
	assert_true(ctx.adv_dialogue_uses_declarative_presentation)
	assert_eq(ctx.resolve_current_dialogue_profile(), {"line_spacing": 2})


func test_scenario_context_old_snapshot_restores_dialogue_mode_defaults():
	var ctx = ScenarioContext.new(ScenarioData.new())
	ctx.current_dialogue_mode = "nvl"
	ctx.nvl_page_epoch = 12
	ctx.current_dialogue_profile_name = "stale"
	ctx.current_dialogue_uses_declarative_presentation = true
	ctx.adv_dialogue_profile_name = "stale_adv"
	ctx.adv_dialogue_uses_declarative_presentation = true

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
	assert_eq(ctx.current_dialogue_profile_name, "")
	assert_false(ctx.current_dialogue_uses_declarative_presentation)
	assert_eq(ctx.adv_dialogue_profile_name, "")
	assert_false(ctx.adv_dialogue_uses_declarative_presentation)


func test_scenario_context_snapshot_never_restores_one_shot_monologue_mode():
	var ctx := ScenarioContext.new(ScenarioData.new())
	ctx.restore_snapshot({
		"scene_index": 0,
		"command_index": 0,
		"is_finished": false,
		"return_stack": [],
		"dialogue_mode": "monologue",
	})

	assert_eq(ctx.current_dialogue_mode, "adv",
		"a one-shot monologue must not leak into the next context-driven dialogue")
