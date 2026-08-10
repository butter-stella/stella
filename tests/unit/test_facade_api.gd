extends GutTest
## Tests for StellaRuntime facade API and overlay management.


## --- Save/Load Facade ---

func test_has_save_returns_false_for_empty():
	var runtime = get_tree().root.get_node("StellaRuntime")
	assert_false(runtime.has_save(99))


func test_get_save_list_returns_array():
	var runtime = get_tree().root.get_node("StellaRuntime")
	var result = runtime.get_save_list()
	assert_typeof(result, TYPE_ARRAY)


func test_get_save_metadata_empty_for_no_save():
	var runtime = get_tree().root.get_node("StellaRuntime")
	var meta = runtime.get_save_metadata(99)
	assert_eq(meta, {})


func test_reset_settings_restores_defaults():
	var runtime = get_tree().root.get_node("StellaRuntime")
	var orig = runtime.get_setting("bgm_volume")
	runtime.set_setting("bgm_volume", 0.12)
	runtime.reset_settings()
	# After reset, should be back to default (0.8)
	assert_almost_eq(runtime.get_setting("bgm_volume"), 0.8, 0.001)
	# Restore to original
	runtime.set_setting("bgm_volume", orig)


## --- Playback Control Facade ---

func test_toggle_auto_play():
	var runtime = get_tree().root.get_node("StellaRuntime")
	var was_active = runtime.is_auto_playing()
	runtime.toggle_auto_play()
	assert_ne(runtime.is_auto_playing(), was_active)
	# Restore
	runtime.toggle_auto_play()


func test_toggle_skip():
	var runtime = get_tree().root.get_node("StellaRuntime")
	var was_active = runtime.is_skipping()
	runtime.toggle_skip()
	assert_ne(runtime.is_skipping(), was_active)
	# Restore
	runtime.toggle_skip()


func test_auto_play_and_skip_mutually_exclusive():
	var runtime = get_tree().root.get_node("StellaRuntime")
	# Start auto play
	if not runtime.is_auto_playing():
		runtime.toggle_auto_play()
	assert_true(runtime.is_auto_playing())

	# Toggle skip should stop auto play
	runtime.toggle_skip()
	assert_true(runtime.is_skipping())
	assert_false(runtime.is_auto_playing())

	# Clean up
	runtime.toggle_skip()


## --- Named Stage Facade ---

func test_named_stage_facade_emits_canonical_operations():
	var runtime = get_tree().root.get_node("StellaRuntime")
	var received: Array = []
	var callback = func(operations, force_cut):
		received.append({
			"operations": operations.duplicate(true),
			"force_cut": force_cut,
		})
	SignalBus.stage_operations_requested.connect(callback)

	runtime.show_stage_layer(
		"hero",
		{"body": "stage:hero_body", "position": [400.0, 600.0]},
		"fade",
		0.25,
	)
	runtime.update_stage_layer("hero", {"face": "stage:hero_sad"})
	runtime.hide_stage_layer("hero", "fade", 0.1)
	runtime.remove_stage_layer("hero")
	runtime.clear_stage_layers()

	assert_eq(received.size(), 5)
	assert_eq(received[0]["operations"][0]["action"], "show")
	assert_eq(received[0]["operations"][0]["id"], "hero")
	assert_eq(
		received[0]["operations"][0]["properties"]["body"],
		"stage:hero_body",
	)
	assert_eq(received[0]["operations"][0]["transition"], "fade")
	assert_almost_eq(received[0]["operations"][0]["duration"], 0.25, 0.001)
	assert_eq(received[1]["operations"][0]["action"], "update")
	assert_eq(received[2]["operations"][0]["action"], "hide")
	assert_eq(received[3]["operations"][0]["action"], "remove")
	assert_eq(received[4]["operations"][0]["action"], "clear")
	SignalBus.stage_operations_requested.disconnect(callback)


func test_apply_stage_operations_deep_copies_caller_batch():
	var runtime = get_tree().root.get_node("StellaRuntime")
	var received: Array = []
	var callback = func(operations, _force_cut):
		received.append(operations)
	SignalBus.stage_operations_requested.connect(callback)
	var operations := [{
		"action": "show",
		"id": "event",
		"properties": {
			"asset": "stage:flash",
			"redraw": [
				{
					"type": "brightness_contrast",
					"brightness": -17,
					"contrast": 23,
				},
				{"type": "blur", "radius": [1, 1]},
				{"type": "blur", "radius": [2, 0]},
			],
		},
	}]
	runtime.apply_stage_operations(operations, true)
	operations[0]["properties"]["asset"] = "changed-after-emit"
	operations[0]["properties"]["redraw"][0]["brightness"] = 255
	operations[0]["properties"]["redraw"][2]["radius"][0] = 32
	assert_eq(received[0][0]["properties"]["asset"], "stage:flash")
	assert_eq(
		received[0][0]["properties"]["redraw"][0]["brightness"],
		-17,
	)
	assert_eq(received[0][0]["properties"]["redraw"][1]["radius"], [1, 1])
	assert_eq(received[0][0]["properties"]["redraw"][2]["radius"], [2, 0])
	SignalBus.stage_operations_requested.disconnect(callback)
	runtime.clear_stage_layers()


func test_named_stage_facade_canonicalizes_layer_id_whitespace():
	var runtime = get_tree().root.get_node("StellaRuntime")
	var received: Array = []
	var callback = func(operations, _force_cut):
		received.append(operations)
	SignalBus.stage_operations_requested.connect(callback)

	runtime.show_stage_layer("  hero  ", {"asset": "stage:hero"})

	assert_eq(received.size(), 1)
	assert_eq(received[0][0]["id"], "hero")
	SignalBus.stage_operations_requested.disconnect(callback)
	runtime.clear_stage_layers()


## --- UI State Facade ---

func test_show_backlog_transitions_state():
	var runtime = get_tree().root.get_node("StellaRuntime")
	runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	runtime.show_backlog()
	assert_eq(runtime.game_state.current_state, GameStateMachine.State.BACKLOG)
	runtime.close_overlay()


func test_show_save_load_transitions_state():
	var runtime = get_tree().root.get_node("StellaRuntime")
	runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	runtime.show_save_load()
	assert_eq(runtime.game_state.current_state, GameStateMachine.State.SAVE_LOAD)
	runtime.close_overlay()


func test_show_settings_transitions_state():
	var runtime = get_tree().root.get_node("StellaRuntime")
	runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	runtime.show_settings()
	assert_eq(runtime.game_state.current_state, GameStateMachine.State.SETTINGS)
	runtime.close_overlay()


func test_close_overlay_returns_to_previous():
	var runtime = get_tree().root.get_node("StellaRuntime")
	runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	runtime.show_settings()
	runtime.close_overlay()
	assert_eq(runtime.game_state.current_state, GameStateMachine.State.PLAYING)


## --- Backlog Facade ---

func test_get_backlog_returns_array():
	var runtime = get_tree().root.get_node("StellaRuntime")
	var result = runtime.get_backlog()
	assert_typeof(result, TYPE_ARRAY)


## --- Settings Facade ---

func test_get_setting():
	var runtime = get_tree().root.get_node("StellaRuntime")
	var val = runtime.get_setting("bgm_volume")
	assert_typeof(val, TYPE_FLOAT)


func test_set_setting():
	var runtime = get_tree().root.get_node("StellaRuntime")
	var orig = runtime.get_setting("bgm_volume")
	runtime.set_setting("bgm_volume", 0.42)
	assert_almost_eq(runtime.get_setting("bgm_volume"), 0.42, 0.001)
	# Restore
	runtime.set_setting("bgm_volume", orig)


## --- Overlay Lifecycle ---

func test_return_to_title_closes_overlay():
	var runtime = get_tree().root.get_node("StellaRuntime")
	runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	runtime.show_settings()
	assert_not_null(runtime._current_overlay)

	# return_to_title should close the overlay
	runtime.return_to_title()
	assert_null(runtime._current_overlay)


func test_start_game_closes_overlay():
	var runtime = get_tree().root.get_node("StellaRuntime")
	runtime.show_settings()
	assert_not_null(runtime._current_overlay)

	# Clean up without actually changing scene
	runtime._close_current_overlay()
	assert_null(runtime._current_overlay)


## --- Continue Game from Title ---

func test_continue_game_returns_false_when_no_saves():
	var runtime = get_tree().root.get_node("StellaRuntime")
	runtime._last_scenario_path = ""
	var orig_scenario = runtime.config.scenario_path
	runtime.config.scenario_path = ""
	runtime.delete_quick_save()
	runtime.delete_auto_save()

	# No saves, no scenario path → false
	assert_false(runtime.continue_game())

	# Restore
	runtime.config.scenario_path = orig_scenario


func test_continue_game_falls_back_to_config_scenario_path():
	var runtime = get_tree().root.get_node("StellaRuntime")
	var orig_path = runtime._last_scenario_path
	runtime._last_scenario_path = ""

	assert_ne(runtime.config.scenario_path, "", "Config must have scenario_path for this test")

	# Create a quick save so continue has something to load
	runtime.quick_save()
	var result = runtime.continue_game()
	assert_ne(runtime._last_scenario_path, "", "continue_game should resolve scenario path from config")

	# Clean up
	runtime._last_scenario_path = orig_path
	runtime.delete_quick_save()


func test_has_continue_save_with_quick_save():
	var runtime = get_tree().root.get_node("StellaRuntime")
	runtime.delete_quick_save()
	runtime.delete_auto_save()
	assert_false(runtime.has_continue_save())

	runtime.quick_save()
	assert_true(runtime.has_continue_save())
	runtime.delete_quick_save()


func test_has_continue_save_with_auto_save():
	var runtime = get_tree().root.get_node("StellaRuntime")
	runtime.delete_quick_save()
	runtime.delete_auto_save()
	assert_false(runtime.has_continue_save())

	# Force auto save by setting state to PLAYING
	var orig_state = runtime.game_state.current_state
	runtime.game_state.current_state = GameStateMachine.State.PLAYING
	runtime.auto_save()
	runtime.game_state.current_state = orig_state

	assert_true(runtime.has_continue_save())
	runtime.delete_auto_save()


## --- continue_from_save from TITLE state ---

func test_continue_from_save_rejects_missing_save():
	var runtime = get_tree().root.get_node("StellaRuntime")
	runtime._last_scenario_path = runtime.config.scenario_path
	# Missing save → false regardless of state
	runtime.game_state.transition_to(GameStateMachine.State.TITLE)
	var result = await runtime.continue_from_save(99)
	assert_false(result, "Should return false for missing save")

	runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	result = await runtime.continue_from_save(99)
	assert_false(result, "Should return false for missing save in-game too")


func test_continue_from_save_rejects_empty_scenario_path():
	var runtime = get_tree().root.get_node("StellaRuntime")
	var orig_path = runtime._last_scenario_path
	var orig_config = runtime.config.scenario_path
	runtime._last_scenario_path = ""
	runtime.config.scenario_path = ""

	runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	runtime.save(50)
	var result = await runtime.continue_from_save(50)
	assert_false(result, "Should return false when no scenario path available")

	# Restore
	runtime._last_scenario_path = orig_path
	runtime.config.scenario_path = orig_config
	runtime.delete_save(50)


func test_is_on_title_screen_direct():
	var runtime = get_tree().root.get_node("StellaRuntime")
	runtime.game_state.transition_to(GameStateMachine.State.TITLE)
	assert_true(runtime._is_on_title_screen(), "Direct TITLE state")

	runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	assert_false(runtime._is_on_title_screen(), "PLAYING state")


func test_is_on_title_screen_via_overlay():
	var runtime = get_tree().root.get_node("StellaRuntime")
	# Simulate: TITLE → show_save_load → state becomes SAVE_LOAD with previous_state = TITLE
	runtime.game_state.transition_to(GameStateMachine.State.TITLE)
	runtime.game_state.transition_to(GameStateMachine.State.SAVE_LOAD)
	assert_eq(runtime.game_state.current_state, GameStateMachine.State.SAVE_LOAD)
	assert_eq(runtime.game_state.previous_state, GameStateMachine.State.TITLE)
	assert_true(runtime._is_on_title_screen(),
		"SAVE_LOAD with previous=TITLE should be detected as title screen")


func test_is_on_title_screen_in_game_overlay():
	var runtime = get_tree().root.get_node("StellaRuntime")
	# Simulate: PLAYING → show_save_load → state becomes SAVE_LOAD with previous_state = PLAYING
	runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	runtime.game_state.transition_to(GameStateMachine.State.SAVE_LOAD)
	assert_false(runtime._is_on_title_screen(),
		"SAVE_LOAD with previous=PLAYING should NOT be title screen")


func test_continue_from_save_returns_false_no_scenario_path():
	var runtime = get_tree().root.get_node("StellaRuntime")
	var orig_path = runtime._last_scenario_path
	var orig_config = runtime.config.scenario_path
	runtime._last_scenario_path = ""
	runtime.config.scenario_path = ""

	# Even with a valid save, should fail if no scenario path
	runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	runtime.save(52)
	var result = await runtime.continue_from_save(52)
	assert_false(result, "Should return false when no scenario path available")

	# Restore
	runtime._last_scenario_path = orig_path
	runtime.config.scenario_path = orig_config
	runtime.delete_save(52)


func test_continue_from_save_returns_false_without_save():
	var runtime = get_tree().root.get_node("StellaRuntime")
	runtime._last_scenario_path = runtime.config.scenario_path
	var result = await runtime.continue_from_save(99)
	assert_false(result, "continue_from_save should return false for non-existent slot")


## --- show_save_load from TITLE ---

func test_show_save_load_from_title():
	var runtime = get_tree().root.get_node("StellaRuntime")
	runtime.game_state.transition_to(GameStateMachine.State.TITLE)
	runtime.show_save_load("load")
	assert_eq(runtime.game_state.current_state, GameStateMachine.State.SAVE_LOAD)
	runtime.close_overlay()


## --- Load from title: overlay must not interfere with scene change ---

func test_continue_from_save_overlay_not_closed_before_scene_change():
	# Regression: _close_current_overlay() before change_scene_to_file caused
	# tree_changed to fire from overlay removal, not scene change.
	# Verify: calling continue_from_save does NOT synchronously close the overlay.
	# The overlay must survive until after the first await (scene change).
	#
	# Note: We call continue_from_save WITHOUT await. It runs synchronously up to
	# `await tree_changed`, then suspends. This also triggers a deferred
	# change_scene_to_file which loads the game scene into the tree. We must
	# await it to settle before the next test runs.
	var runtime = get_tree().root.get_node("StellaRuntime")
	var orig_path = runtime._last_scenario_path
	runtime._last_scenario_path = runtime.config.scenario_path

	# Create a save to load
	runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	runtime.save(60)

	# Simulate: title → open save/load overlay → state=SAVE_LOAD, prev=TITLE
	runtime.game_state.transition_to(GameStateMachine.State.TITLE)
	runtime.show_save_load("load")
	assert_not_null(runtime._current_overlay, "overlay should exist before continue_from_save")

	# Call continue_from_save WITHOUT await — it runs synchronously up to the
	# first await (change_scene_to_file + tree_changed). At that suspend point,
	# _current_overlay must still be alive (not yet closed).
	runtime.continue_from_save(60)

	# After the synchronous portion, the overlay must NOT have been closed yet.
	# With the bug (old code), _current_overlay would already be null here.
	assert_not_null(runtime._current_overlay,
		"overlay must survive until after scene change — closing it before "
		+ "change_scene_to_file causes tree_changed to fire prematurely")

	# Clean up: abort pending engine, close overlay, restore state.
	runtime.engine.stop()
	runtime._close_current_overlay()
	runtime.presentation_state.clear()
	runtime.game_state.transition_to(GameStateMachine.State.TITLE)
	runtime._last_scenario_path = orig_path
	runtime.delete_save(60)
	# Let the deferred scene change settle — the game scene will load, which
	# adds presenters that connect to SignalBus. Disconnect them to avoid
	# contaminating later signal-based tests.
	await get_tree().process_frame
	await get_tree().process_frame
	_disconnect_game_presenters()


## Helper: disconnect game scene presenters from SignalBus to prevent test contamination.
func _disconnect_game_presenters():
	for sig_name in ["bg_changed", "bgm_play", "bgm_stop", "se_play", "se_stop",
			"voice_play", "system_se_play",
			"show_dialogue", "hide_dialogue", "choice_show", "choice_selected",
			"fade_requested", "effect_requested",
			"scenario_ended_event"]:
		var sig = SignalBus.get(sig_name)
		if sig is Signal:
			for conn in sig.get_connections():
				var callable = conn["callable"]
				if not callable.is_valid():
					continue
				var obj = callable.get_object()
				if obj != null and not obj is GutTest and obj != StellaRuntime \
						and obj != StellaRuntime.presentation_state:
					sig.disconnect(callable)


## --- Overlay Config ---

func test_config_has_overlay_scene_overrides():
	var config = StellaConfig.new()
	assert_eq(config.settings_scene, "")
	assert_eq(config.save_load_scene, "")
	assert_eq(config.backlog_scene, "")
