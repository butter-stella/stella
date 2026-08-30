extends GutTest
## Behavior-level coverage for feature flags with built-in runtime/UI consumers.

const RuntimeTestSupport = preload("res://tests/helpers/runtime_test_support.gd")
const GAME_SCENE = preload("res://addons/stella/scenes/game.tscn")

var _runtime: Node
var _original_backlog_enabled: bool
var _original_cg_gallery_enabled: bool


func before_each() -> void:
	_runtime = get_tree().root.get_node("StellaRuntime")
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	_original_backlog_enabled = _runtime.config.backlog
	_original_cg_gallery_enabled = _runtime.config.cg_gallery


func after_each() -> void:
	_runtime._close_current_overlay()
	_runtime.config.backlog = _original_backlog_enabled
	_runtime.config.cg_gallery = _original_cg_gallery_enabled
	await get_tree().process_frame
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())


func test_disabled_backlog_does_not_open_overlay_or_change_game_state() -> void:
	_runtime.config.backlog = false
	_runtime.game_state.transition_to(GameStateMachine.State.PLAYING)

	_runtime.show_backlog()

	assert_null(_runtime._current_overlay)
	assert_eq(_runtime.game_state.current_state, GameStateMachine.State.PLAYING,
		"a disabled feature must not leave the visible scene and state split")


func test_disabled_backlog_authored_control_is_hidden_by_binding() -> void:
	_runtime.config.backlog = false
	var game: Node = GAME_SCENE.instantiate()
	add_child_autoqfree(game)
	await get_tree().process_frame

	var toolbar: HBoxContainer = game.get_node("UILayer/DialoguePanel/Toolbar")
	var backlog_button := _find_button_with_text(toolbar, "记录")
	assert_not_null(backlog_button,
		"the authored product toolbar keeps stable scene-owned controls")
	if backlog_button != null:
		assert_false(backlog_button.visible,
			"the declarative binding hides the unavailable feature")
		assert_true(backlog_button.disabled)


func test_enabled_backlog_is_present_in_builtin_dialogue_toolbar() -> void:
	_runtime.config.backlog = true
	var game: Node = GAME_SCENE.instantiate()
	add_child_autoqfree(game)
	await get_tree().process_frame

	var toolbar: HBoxContainer = game.get_node("UILayer/DialoguePanel/Toolbar")
	assert_not_null(_find_button_with_text(toolbar, "记录"))


func test_disabled_cg_gallery_preserves_but_hides_progress_and_rejects_unlocks() -> void:
	_runtime.config.cg_gallery = false
	_runtime.unlock_manager.unlock("cg", "legacy_cg")

	assert_false(_runtime.unlock_cg("disabled_cg"))
	assert_false(_runtime.is_cg_unlocked("legacy_cg"))
	assert_eq(_runtime.get_unlocked_cgs(), [])
	assert_false(_runtime.unlock_manager.is_unlocked("cg", "disabled_cg"))
	assert_true(_runtime.unlock_manager.is_unlocked("cg", "legacy_cg"),
		"disabling the UI contract must not destroy persisted compatibility data")


func test_enabled_cg_gallery_facade_records_and_exposes_unlocks() -> void:
	_runtime.config.cg_gallery = true

	assert_true(_runtime.unlock_cg("gallery_cg"))
	assert_true(_runtime.is_cg_unlocked("gallery_cg"))
	var unlocked: Array = _runtime.get_unlocked_cgs()
	assert_eq(unlocked, ["gallery_cg"])
	unlocked.clear()
	assert_true(_runtime.is_cg_unlocked("gallery_cg"),
		"callers must receive a copy of persisted gallery state")


func _find_button_with_text(toolbar: HBoxContainer, text: String) -> Button:
	for child in toolbar.get_children():
		if child is Button and child.text == text:
			return child
	return null
