extends GutTest
## Behavior-level coverage for feature flags with built-in runtime/UI consumers.

const RuntimeTestSupport = preload("res://tests/helpers/runtime_test_support.gd")
const GAME_SCENE = preload("res://addons/stella/scenes/game.tscn")

var _runtime: Node
var _original_backlog_enabled: bool


func before_each() -> void:
	_runtime = get_tree().root.get_node("StellaRuntime")
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	_original_backlog_enabled = _runtime.config.backlog


func after_each() -> void:
	_runtime._close_current_overlay()
	_runtime.config.backlog = _original_backlog_enabled
	await get_tree().process_frame
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())


func test_disabled_backlog_does_not_open_overlay_or_change_game_state() -> void:
	_runtime.config.backlog = false
	_runtime.game_state.transition_to(GameStateMachine.State.PLAYING)

	_runtime.show_backlog()

	assert_null(_runtime._current_overlay)
	assert_eq(_runtime.game_state.current_state, GameStateMachine.State.PLAYING,
		"a disabled feature must not leave the visible scene and state split")


func test_disabled_backlog_is_absent_from_builtin_dialogue_toolbar() -> void:
	_runtime.config.backlog = false
	var game: Node = GAME_SCENE.instantiate()
	add_child_autoqfree(game)
	await get_tree().process_frame

	var toolbar: HBoxContainer = game.get_node("UILayer/DialoguePanel/Toolbar")
	assert_null(_find_button_with_text(toolbar, "记录"),
		"the built-in toolbar must not create a disabled backlog action")


func test_enabled_backlog_is_present_in_builtin_dialogue_toolbar() -> void:
	_runtime.config.backlog = true
	var game: Node = GAME_SCENE.instantiate()
	add_child_autoqfree(game)
	await get_tree().process_frame

	var toolbar: HBoxContainer = game.get_node("UILayer/DialoguePanel/Toolbar")
	assert_not_null(_find_button_with_text(toolbar, "记录"))


func _find_button_with_text(toolbar: HBoxContainer, text: String) -> Button:
	for child in toolbar.get_children():
		if child is Button and child.text == text:
			return child
	return null
