extends GutTest

var _runtime_snapshot: Dictionary
var _original_backgrounds_path: String
var _original_stage_assets_path: String


func before_each() -> void:
	_runtime_snapshot = StellaRuntime.presentation_state.capture_snapshot()
	StellaRuntime.presentation_state.clear()
	_original_backgrounds_path = StellaRuntime.backgrounds_path
	_original_stage_assets_path = StellaRuntime.stage_assets_path
	StellaRuntime.backgrounds_path = "res://examples/demo/art/backgrounds/"
	StellaRuntime.stage_assets_path = "res://examples/demo/art/backgrounds/"


func after_each() -> void:
	StellaRuntime.backgrounds_path = _original_backgrounds_path
	StellaRuntime.stage_assets_path = _original_stage_assets_path
	StellaRuntime.presentation_state.restore_snapshot(_runtime_snapshot)


func test_stage_operations_are_tracked_and_json_roundtrip_exactly() -> void:
	var state := PresentationState.new()
	state.connect_signals()
	SignalBus.emit_stage_operations([{
		"action": "show",
		"id": "hero",
		"properties": {
			"body": "stage:bg_cafe",
			"face": "stage:bg_hallway",
			"position": [640.0, 720.0],
			"redraw": [
				{
					"type": "color_overlay",
					"color": "#2a5c8e40",
					"blend": "soft_light",
				},
				{"type": "brightness_contrast", "brightness": 17, "contrast": -24},
				{"type": "blur", "radius": [1, 1]},
				{"type": "blur", "radius": [2, 0]},
				{"type": "blur", "radius": [0, 3]},
				{"type": "blur", "radius": [4, 2]},
				{
					"type": "clip",
					"asset": "stage:synthetic_alpha_mask",
					"offset": [2.0, 3.0],
					"fit": "native",
				},
			],
		},
		"transition": "cut",
		"duration": 0.0,
	}], false)
	SignalBus.emit_stage_operations([{
		"action": "update",
		"id": "hero",
		"properties": {"face": "stage:bg_outside"},
	}], false)

	var encoded := JSON.stringify(state.capture_snapshot())
	var restored := PresentationState.new()
	restored.restore_snapshot(JSON.parse_string(encoded))
	assert_eq(restored.stage_layers["hero"]["body"], "stage:bg_cafe")
	assert_eq(restored.stage_layers["hero"]["face"], "stage:bg_outside")
	assert_eq(restored.stage_layers["hero"]["position"], [640.0, 720.0])
	assert_eq(restored.stage_layers["hero"]["redraw"], [
		{
			"type": "color_overlay",
			"color": "#2a5c8e40",
			"blend": "soft_light",
		},
		{"type": "brightness_contrast", "brightness": 17, "contrast": -24},
		{"type": "blur", "radius": [1, 1]},
		{"type": "blur", "radius": [2, 0]},
		{"type": "blur", "radius": [0, 3]},
		{"type": "blur", "radius": [4, 2]},
		{
			"type": "clip",
			"asset": "stage:synthetic_alpha_mask",
			"offset": [2.0, 3.0],
			"fit": "native",
		},
	])
	state.disconnect_signals()


func test_snapshot_without_stage_layers_restores_empty_stage() -> void:
	var state := PresentationState.new()
	state.stage_layers = {"old": StageLayerState.default_state()}
	state.restore_snapshot({"bg": "", "bgm": {}})
	assert_true(state.stage_layers.is_empty())


func test_complete_projection_resets_stale_visuals_and_empty_background() -> void:
	var game: Node = load("res://addons/stella/scenes/game.tscn").instantiate()
	add_child_autoqfree(game)
	await get_tree().process_frame
	var presenter := game.get_node("StageLayer") as StagePresenter

	SignalBus.emit_stage_operations([{
		"action": "show",
		"id": "stale",
		"properties": {"asset": "stage:bg_outside"},
	}], true)
	SignalBus.bg_changed.emit("bg_school_gate", "cut", 0.0)
	assert_not_null(presenter.get_layer_node("stale"))

	var restored := PresentationState.new()
	restored.current_bg = ""
	restored.stage_layers = {
		"kept": StageLayerState.normalize_full({"asset": "stage:bg_cafe"}),
	}
	restored.apply_to_presenters()
	await get_tree().process_frame

	assert_null(presenter.get_layer_node("stale"))
	assert_not_null(presenter.get_layer_node("kept"))
	assert_null(game.get_node("BackgroundLayer/ShakeRoot/BgFront").texture)
	assert_null(game.get_node("BackgroundLayer/ShakeRoot/BgBack").texture)


func test_projection_payload_is_a_deep_copy() -> void:
	var state := PresentationState.new()
	state.stage_layers = {
		"hero": StageLayerState.normalize_full({"body": "stage:bg_cafe"}),
	}
	var received: Array = []
	var callback := func(layers: Dictionary): received.append(layers)
	SignalBus.stage_state_apply_requested.connect(callback)
	state.apply_to_presenters()
	SignalBus.stage_state_apply_requested.disconnect(callback)

	assert_eq(received.size(), 1)
	received[0]["hero"]["body"] = "listener-mutated"
	assert_eq(state.stage_layers["hero"]["body"], "stage:bg_cafe")


func test_dialogue_projection_defaults_and_restore_are_stable() -> void:
	var state := PresentationState.new()
	var snapshot := state.capture_snapshot()
	assert_eq(snapshot.get("dialogue_visibility"), {
		"surface": true,
		"quick_menu": true,
	})
	assert_eq(snapshot.get("dialogue_content"), {
		"version": 1,
		"active": false,
		"mode": "adv",
		"profile_name": "",
		"declarative_presentation": false,
		"character": "",
		"segments": [],
		"avatar_expression": "",
		"nvl_entries": [],
	})
	var stable := {
		"bg": "",
		"stage_layers": {},
		"bgm": {},
		"loop_se_channels": {},
		"dialogue_visibility": {"surface": false, "quick_menu": true},
		"dialogue_content": {
			"version": 1,
			"active": true,
			"mode": "adv",
			"profile_name": "message",
			"declarative_presentation": true,
			"character": "sakura",
			"segments": [{"text": "Stable line"}],
			"avatar_expression": "happy",
			"nvl_entries": [],
		},
	}
	state.restore_snapshot(stable)
	assert_eq(state.capture_snapshot(), stable)
