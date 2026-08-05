extends GutTest
## Regression coverage for issue #130: the requested save/load mode must be
## reflected by the real overlay immediately, including its first ready frame.

const RuntimeTestSupport = preload("res://tests/helpers/runtime_test_support.gd")
const SAVE_LOAD_SCENE = preload("res://addons/stella/scenes/save_load.tscn")
const CUSTOM_SAVE_LOAD_SCRIPT = preload(
	"res://tests/integration/fixtures/custom_save_load_screen.gd"
)
const TEST_SAVE_DIR := "user://test_save_load_screen/"

var _runtime: Node
var _original_slot_count: int


func before_each() -> void:
	_runtime = get_tree().root.get_node("StellaRuntime")
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	_original_slot_count = _runtime.config.save_slots
	_runtime.config.save_slots = 2
	_clear_test_saves()
	_runtime.save_manager.save_dir = TEST_SAVE_DIR
	_runtime.save_manager.save(1)


func after_each() -> void:
	_runtime._close_current_overlay()
	_runtime.config.save_slots = _original_slot_count
	await get_tree().process_frame
	_clear_test_saves()
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())


func test_mode_set_before_ready_builds_load_ui() -> void:
	var screen: Control = SAVE_LOAD_SCENE.instantiate()
	screen.set_mode("load")
	add_child_autoqfree(screen)
	await get_tree().process_frame

	_assert_mode_ui(screen, "load")
	_assert_slot_state(screen, 0, false)
	_assert_slot_state(screen, 1, true)


func test_public_mode_transition_preserves_subclass_hook() -> void:
	var screen: Control = SAVE_LOAD_SCENE.instantiate()
	screen.set_script(CUSTOM_SAVE_LOAD_SCRIPT)
	screen.set_mode("load")
	assert_eq(screen.applied_modes, ["load"],
		"set_mode must delegate to the protected extension hook before ready")
	add_child_autoqfree(screen)
	await get_tree().process_frame

	_assert_mode_ui(screen, "load")
	screen.set_mode("save")
	assert_eq(screen.applied_modes, ["load", "save"])
	_assert_mode_ui(screen, "save")


func test_mode_change_after_ready_rebuilds_slots_without_duplicates() -> void:
	var screen: Control = SAVE_LOAD_SCENE.instantiate()
	add_child_autoqfree(screen)
	await get_tree().process_frame

	_assert_mode_ui(screen, "save")
	_assert_slot_state(screen, 1, false)
	screen.set_mode("load")

	_assert_mode_ui(screen, "load")
	assert_eq(screen.slots_container.get_child_count(), 2,
		"old slot buttons must be detached before replacements are added")
	_assert_slot_state(screen, 0, false)
	_assert_slot_state(screen, 1, true)


func test_tabs_use_the_same_public_mode_transition() -> void:
	var screen: Control = SAVE_LOAD_SCENE.instantiate()
	add_child_autoqfree(screen)
	await get_tree().process_frame

	screen.load_tab.pressed.emit()
	_assert_mode_ui(screen, "load")
	_assert_slot_state(screen, 1, true)

	screen.save_tab.pressed.emit()
	_assert_mode_ui(screen, "save")
	_assert_slot_state(screen, 1, false)


func test_invalid_mode_preserves_the_current_ui() -> void:
	var screen: Control = SAVE_LOAD_SCENE.instantiate()
	add_child_autoqfree(screen)
	await get_tree().process_frame
	screen.set_mode("load")

	screen.set_mode("invalid")
	assert_push_warning("mode must be 'save' or 'load'")
	_assert_mode_ui(screen, "load")
	assert_eq(screen.slots_container.get_child_count(), 2)
	_assert_slot_state(screen, 1, true)


func test_facade_opens_load_mode_correctly_from_title() -> void:
	_runtime.game_state.transition_to(GameStateMachine.State.TITLE)
	_runtime.show_save_load("load")

	var screen: Control = _runtime._current_overlay
	assert_not_null(screen)
	_assert_mode_ui(screen, "load")
	_assert_slot_state(screen, 0, false)
	_assert_slot_state(screen, 1, true)
	assert_eq(_runtime.game_state.current_state, GameStateMachine.State.SAVE_LOAD)


func test_facade_opens_save_mode_correctly_during_play() -> void:
	_runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	_runtime.show_save_load("save")

	var screen: Control = _runtime._current_overlay
	assert_not_null(screen)
	_assert_mode_ui(screen, "save")
	_assert_slot_state(screen, 0, false)
	_assert_slot_state(screen, 1, false)
	assert_eq(_runtime.game_state.current_state, GameStateMachine.State.SAVE_LOAD)


func _assert_mode_ui(screen: Control, expected_mode: String) -> void:
	var is_save := expected_mode == "save"
	assert_eq(screen._mode, expected_mode)
	assert_eq(screen.title_label.text, "存档" if is_save else "读档")
	assert_eq(screen.save_tab.modulate, Color.YELLOW if is_save else Color.WHITE)
	assert_eq(screen.load_tab.modulate, Color.WHITE if is_save else Color.YELLOW)


func _assert_slot_state(screen: Control, index: int, expected_disabled: bool) -> void:
	var slots: GridContainer = screen.slots_container
	assert_eq(slots.get_child_count(), 2)
	var slot: Button = slots.get_child(index)
	assert_eq(slot.disabled, expected_disabled)


func _clear_test_saves() -> void:
	var directory := DirAccess.open(TEST_SAVE_DIR)
	if directory != null:
		directory.list_dir_begin()
		var file_name := directory.get_next()
		while file_name != "":
			if not directory.current_is_dir():
				directory.remove(file_name)
			file_name = directory.get_next()
		directory.list_dir_end()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_SAVE_DIR))
