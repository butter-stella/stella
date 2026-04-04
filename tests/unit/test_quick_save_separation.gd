extends GutTest
## Tests for quick save / auto save / manual save slot separation.


func test_quick_save_uses_separate_file():
	var sm = SaveManager.new()
	sm.quick_save()
	assert_true(sm.has_quick_save())
	assert_true(FileAccess.file_exists(sm.save_dir + "quicksave.json"))

	# Manual slot 1 should not exist
	assert_false(sm.has_save(1))

	# Clean up
	sm.delete_quick_save()


func test_quick_save_does_not_appear_in_save_list():
	var sm = SaveManager.new()
	sm.quick_save()
	sm.save(1)

	var save_list = sm.get_save_list()
	assert_true(save_list.has(1))
	# Quick save should not be in the manual save list
	assert_false(save_list.has(0), "Quick save should not appear as slot 0")

	# Clean up
	sm.delete_quick_save()
	sm.delete_save(1)


func test_manual_save_does_not_overwrite_quick_save():
	var sm = SaveManager.new()
	sm.quick_save()
	sm.save(1)

	assert_true(sm.has_quick_save())
	assert_true(sm.has_save(1))

	sm.delete_save(1)
	# Quick save should still exist
	assert_true(sm.has_quick_save())

	sm.delete_quick_save()


func test_quick_load_reads_quick_save_file():
	var sm = SaveManager.new()
	sm.quick_save()
	assert_true(sm.has_quick_save())

	var loaded = sm.quick_load()
	assert_true(loaded)

	sm.delete_quick_save()


func test_quick_load_returns_false_without_save():
	var sm = SaveManager.new()
	sm.delete_quick_save()
	assert_false(sm.has_quick_save())
	assert_false(sm.quick_load())


func test_get_quick_save_metadata():
	var sm = SaveManager.new()
	sm.quick_save()

	var meta = sm.get_quick_save_metadata()
	assert_true(meta.has("timestamp"))
	assert_true(meta.has("timestamp_str"))

	sm.delete_quick_save()


func test_get_quick_save_metadata_empty_without_save():
	var sm = SaveManager.new()
	sm.delete_quick_save()
	var meta = sm.get_quick_save_metadata()
	assert_eq(meta, {})


## --- Facade integration ---

func test_runtime_quick_save_uses_separate_slot():
	var runtime = get_tree().root.get_node("NatsumeRuntime")
	runtime.quick_save()
	assert_true(runtime.has_quick_save())

	# Should not pollute manual save list
	var save_list = runtime.get_save_list()
	assert_false(save_list.has(0))

	runtime.delete_quick_save()


func test_runtime_has_quick_save():
	var runtime = get_tree().root.get_node("NatsumeRuntime")
	assert_false(runtime.has_quick_save())
	runtime.quick_save()
	assert_true(runtime.has_quick_save())
	runtime.delete_quick_save()


## --- Auto Save ---

func test_auto_save_uses_separate_file():
	var sm = SaveManager.new()
	sm.auto_save()
	assert_true(sm.has_auto_save())
	assert_true(FileAccess.file_exists(sm.save_dir + "autosave.json"))

	# Should not affect quick save or manual slots
	assert_false(sm.has_quick_save())
	assert_false(sm.has_save(1))

	sm.delete_auto_save()


func test_auto_save_does_not_appear_in_save_list():
	var sm = SaveManager.new()
	sm.auto_save()
	sm.save(1)

	var save_list = sm.get_save_list()
	assert_true(save_list.has(1))
	assert_false(save_list.has(0), "Auto save should not appear in manual save list")

	sm.delete_auto_save()
	sm.delete_save(1)


func test_auto_load_reads_auto_save_file():
	var sm = SaveManager.new()
	sm.auto_save()
	assert_true(sm.has_auto_save())

	var loaded = sm.auto_load()
	assert_true(loaded)

	sm.delete_auto_save()


func test_auto_load_returns_false_without_save():
	var sm = SaveManager.new()
	sm.delete_auto_save()
	assert_false(sm.has_auto_save())
	assert_false(sm.auto_load())


func test_auto_save_independent_from_quick_save():
	var sm = SaveManager.new()
	sm.auto_save()
	sm.quick_save()

	assert_true(sm.has_auto_save())
	assert_true(sm.has_quick_save())

	sm.delete_quick_save()
	assert_true(sm.has_auto_save(), "Deleting quick save should not affect auto save")

	sm.delete_auto_save()
	assert_false(sm.has_auto_save())


func test_get_auto_save_metadata():
	var sm = SaveManager.new()
	sm.auto_save()

	var meta = sm.get_auto_save_metadata()
	assert_true(meta.has("timestamp"))
	assert_true(meta.has("timestamp_str"))

	sm.delete_auto_save()


## --- Latest continue save (quick save vs auto save) ---

func test_get_latest_continue_timestamp_picks_newer():
	var sm = SaveManager.new()
	# Create auto save first
	sm.auto_save()
	# Wait a tiny bit so timestamps differ
	OS.delay_msec(50)
	# Create quick save (should be newer)
	sm.quick_save()

	var latest = sm.get_latest_continue_type()
	assert_eq(latest, "quick", "Quick save is newer, should be picked")

	sm.delete_quick_save()
	sm.delete_auto_save()


func test_get_latest_continue_type_only_auto():
	var sm = SaveManager.new()
	sm.delete_quick_save()
	sm.auto_save()

	var latest = sm.get_latest_continue_type()
	assert_eq(latest, "auto")

	sm.delete_auto_save()


func test_get_latest_continue_type_only_quick():
	var sm = SaveManager.new()
	sm.delete_auto_save()
	sm.quick_save()

	var latest = sm.get_latest_continue_type()
	assert_eq(latest, "quick")

	sm.delete_quick_save()


func test_get_latest_continue_type_none():
	var sm = SaveManager.new()
	sm.delete_auto_save()
	sm.delete_quick_save()

	var latest = sm.get_latest_continue_type()
	assert_eq(latest, "")


## --- Runtime auto save facade ---

func test_runtime_auto_save():
	var runtime = get_tree().root.get_node("NatsumeRuntime")
	runtime.delete_auto_save()
	assert_false(runtime.has_auto_save())

	# auto_save only works when PLAYING
	var orig_state = runtime.game_state.current_state
	runtime.game_state.current_state = GameStateMachine.State.PLAYING
	runtime.auto_save()
	runtime.game_state.current_state = orig_state

	assert_true(runtime.has_auto_save())
	runtime.delete_auto_save()


func test_runtime_auto_save_skips_when_not_playing():
	var runtime = get_tree().root.get_node("NatsumeRuntime")
	runtime.delete_auto_save()
	runtime.game_state.current_state = GameStateMachine.State.TITLE
	runtime.auto_save()
	assert_false(runtime.has_auto_save(), "auto_save should not save when on title screen")
