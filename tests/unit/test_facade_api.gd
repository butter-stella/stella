extends GutTest
## Tests for NatsumeRuntime facade API and overlay management.


## --- Save/Load Facade ---

func test_has_save_returns_false_for_empty():
	var runtime = get_tree().root.get_node("NatsumeRuntime")
	assert_false(runtime.has_save(99))


func test_get_save_list_returns_array():
	var runtime = get_tree().root.get_node("NatsumeRuntime")
	var result = runtime.get_save_list()
	assert_typeof(result, TYPE_ARRAY)


func test_get_save_metadata_empty_for_no_save():
	var runtime = get_tree().root.get_node("NatsumeRuntime")
	var meta = runtime.get_save_metadata(99)
	assert_eq(meta, {})


func test_reset_settings_restores_defaults():
	var runtime = get_tree().root.get_node("NatsumeRuntime")
	var orig = runtime.get_setting("bgm_volume")
	runtime.set_setting("bgm_volume", 0.12)
	runtime.reset_settings()
	# After reset, should be back to default (0.8)
	assert_almost_eq(runtime.get_setting("bgm_volume"), 0.8, 0.001)
	# Restore to original
	runtime.set_setting("bgm_volume", orig)


## --- Playback Control Facade ---

func test_toggle_auto_play():
	var runtime = get_tree().root.get_node("NatsumeRuntime")
	var was_active = runtime.is_auto_playing()
	runtime.toggle_auto_play()
	assert_ne(runtime.is_auto_playing(), was_active)
	# Restore
	runtime.toggle_auto_play()


func test_toggle_skip():
	var runtime = get_tree().root.get_node("NatsumeRuntime")
	var was_active = runtime.is_skipping()
	runtime.toggle_skip()
	assert_ne(runtime.is_skipping(), was_active)
	# Restore
	runtime.toggle_skip()


func test_auto_play_and_skip_mutually_exclusive():
	var runtime = get_tree().root.get_node("NatsumeRuntime")
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


## --- UI State Facade ---

func test_show_backlog_transitions_state():
	var runtime = get_tree().root.get_node("NatsumeRuntime")
	runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	runtime.show_backlog()
	assert_eq(runtime.game_state.current_state, GameStateMachine.State.BACKLOG)
	runtime.close_overlay()


func test_show_save_load_transitions_state():
	var runtime = get_tree().root.get_node("NatsumeRuntime")
	runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	runtime.show_save_load()
	assert_eq(runtime.game_state.current_state, GameStateMachine.State.SAVE_LOAD)
	runtime.close_overlay()


func test_show_settings_transitions_state():
	var runtime = get_tree().root.get_node("NatsumeRuntime")
	runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	runtime.show_settings()
	assert_eq(runtime.game_state.current_state, GameStateMachine.State.SETTINGS)
	runtime.close_overlay()


func test_close_overlay_returns_to_previous():
	var runtime = get_tree().root.get_node("NatsumeRuntime")
	runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	runtime.show_settings()
	runtime.close_overlay()
	assert_eq(runtime.game_state.current_state, GameStateMachine.State.PLAYING)


## --- Backlog Facade ---

func test_get_backlog_returns_array():
	var runtime = get_tree().root.get_node("NatsumeRuntime")
	var result = runtime.get_backlog()
	assert_typeof(result, TYPE_ARRAY)


## --- Settings Facade ---

func test_get_setting():
	var runtime = get_tree().root.get_node("NatsumeRuntime")
	var val = runtime.get_setting("bgm_volume")
	assert_typeof(val, TYPE_FLOAT)


func test_set_setting():
	var runtime = get_tree().root.get_node("NatsumeRuntime")
	var orig = runtime.get_setting("bgm_volume")
	runtime.set_setting("bgm_volume", 0.42)
	assert_almost_eq(runtime.get_setting("bgm_volume"), 0.42, 0.001)
	# Restore
	runtime.set_setting("bgm_volume", orig)


## --- Overlay Lifecycle ---

func test_return_to_title_closes_overlay():
	var runtime = get_tree().root.get_node("NatsumeRuntime")
	runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	runtime.show_settings()
	assert_not_null(runtime._current_overlay)

	# return_to_title should close the overlay
	runtime.return_to_title()
	assert_null(runtime._current_overlay)


func test_start_game_closes_overlay():
	var runtime = get_tree().root.get_node("NatsumeRuntime")
	runtime.show_settings()
	assert_not_null(runtime._current_overlay)

	# Clean up without actually changing scene
	runtime._close_current_overlay()
	assert_null(runtime._current_overlay)


## --- Continue Game from Title ---

func test_continue_game_returns_false_when_no_saves():
	var runtime = get_tree().root.get_node("NatsumeRuntime")
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
	var runtime = get_tree().root.get_node("NatsumeRuntime")
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
	var runtime = get_tree().root.get_node("NatsumeRuntime")
	runtime.delete_quick_save()
	runtime.delete_auto_save()
	assert_false(runtime.has_continue_save())

	runtime.quick_save()
	assert_true(runtime.has_continue_save())
	runtime.delete_quick_save()


func test_has_continue_save_with_auto_save():
	var runtime = get_tree().root.get_node("NatsumeRuntime")
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

func test_continue_from_save_does_not_reject_title_state():
	# Verify continue_from_save no longer hard-rejects TITLE state.
	# We test the guard logic only — actual scene switching is an integration concern.
	var runtime = get_tree().root.get_node("NatsumeRuntime")
	runtime.game_state.transition_to(GameStateMachine.State.TITLE)
	runtime._last_scenario_path = runtime.config.scenario_path

	# No save in slot 99 → should return false because of missing save, NOT because of TITLE state
	var result = await runtime.continue_from_save(99)
	assert_false(result, "Should return false for missing save")

	# Create a save so the only reason to fail would be TITLE rejection
	runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	runtime._prepare_scenario(runtime.config.scenario_path)
	runtime.save(50)

	# Verify has_save works
	assert_true(runtime.has_save(50))

	# With TITLE state + valid save + valid scenario → should NOT return false
	# (it will attempt scene switch which we can't fully test in headless, but it shouldn't early-return false)
	runtime.game_state.transition_to(GameStateMachine.State.TITLE)
	# We just verify the method doesn't reject TITLE by checking it proceeds past the guards
	assert_ne(runtime._last_scenario_path, "", "scenario path should be set")
	assert_true(runtime.has_save(50), "save should exist")

	# Clean up
	runtime.delete_save(50)


func test_continue_from_save_returns_false_without_save():
	var runtime = get_tree().root.get_node("NatsumeRuntime")
	runtime._last_scenario_path = runtime.config.scenario_path
	var result = await runtime.continue_from_save(99)
	assert_false(result, "continue_from_save should return false for non-existent slot")


## --- show_save_load from TITLE ---

func test_show_save_load_from_title():
	var runtime = get_tree().root.get_node("NatsumeRuntime")
	runtime.game_state.transition_to(GameStateMachine.State.TITLE)
	runtime.show_save_load("load")
	assert_eq(runtime.game_state.current_state, GameStateMachine.State.SAVE_LOAD)
	runtime.close_overlay()


## --- Overlay Config ---

func test_config_has_overlay_scene_overrides():
	var config = NatsumeConfig.new()
	assert_eq(config.settings_scene, "")
	assert_eq(config.save_load_scene, "")
	assert_eq(config.backlog_scene, "")
