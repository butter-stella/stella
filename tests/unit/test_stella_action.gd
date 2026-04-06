extends GutTest
## Tests for StellaAction — zero-code button binding component.

var _btn: Button
var _action: StellaAction


func before_each():
	_btn = Button.new()
	_action = StellaAction.new()
	_btn.add_child(_action)
	add_child(_btn)


func after_each():
	_btn.queue_free()


## --- Connection ---

func test_auto_connects_to_parent_button():
	_action.action = StellaAction.Action.TOGGLE_AUTO_PLAY
	var connections = _btn.pressed.get_connections()
	var found = false
	for conn in connections:
		if conn["callable"].get_object() == _action:
			found = true
			break
	assert_true(found, "StellaAction should connect to parent button's pressed signal")


func test_does_not_crash_on_non_button_parent():
	_btn.queue_free()
	var node = Node.new()
	var action = StellaAction.new()
	action.action = StellaAction.Action.QUICK_SAVE
	node.add_child(action)
	add_child(node)
	# Should not crash, just warn
	assert_true(true)
	node.queue_free()
	# Re-create for after_each
	_btn = Button.new()
	_action = StellaAction.new()
	_btn.add_child(_action)
	add_child(_btn)


func test_default_action_is_none():
	assert_eq(_action.action, StellaAction.Action.NONE)


## --- Playback Control ---

func test_toggle_auto_play():
	var runtime = get_tree().root.get_node("StellaRuntime")
	_action.action = StellaAction.Action.TOGGLE_AUTO_PLAY
	var was_active = runtime.is_auto_playing()

	_btn.pressed.emit()
	assert_ne(runtime.is_auto_playing(), was_active)

	# Restore
	runtime.toggle_auto_play()


func test_toggle_skip():
	var runtime = get_tree().root.get_node("StellaRuntime")
	_action.action = StellaAction.Action.TOGGLE_SKIP
	var was_active = runtime.is_skipping()

	_btn.pressed.emit()
	assert_ne(runtime.is_skipping(), was_active)

	# Restore
	runtime.toggle_skip()


## --- UI State ---

func test_show_settings_transitions_state():
	var runtime = get_tree().root.get_node("StellaRuntime")
	runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	_action.action = StellaAction.Action.SHOW_SETTINGS

	_btn.pressed.emit()
	assert_eq(runtime.game_state.current_state, GameStateMachine.State.SETTINGS)

	# Clean up overlay
	runtime._close_current_overlay()
	runtime.game_state.transition_to(GameStateMachine.State.TITLE)


func test_show_save_transitions_state():
	var runtime = get_tree().root.get_node("StellaRuntime")
	runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	_action.action = StellaAction.Action.SHOW_SAVE

	_btn.pressed.emit()
	assert_eq(runtime.game_state.current_state, GameStateMachine.State.SAVE_LOAD)

	runtime._close_current_overlay()
	runtime.game_state.transition_to(GameStateMachine.State.TITLE)


func test_show_load_transitions_state():
	var runtime = get_tree().root.get_node("StellaRuntime")
	runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	_action.action = StellaAction.Action.SHOW_LOAD

	_btn.pressed.emit()
	assert_eq(runtime.game_state.current_state, GameStateMachine.State.SAVE_LOAD)

	runtime._close_current_overlay()
	runtime.game_state.transition_to(GameStateMachine.State.TITLE)


func test_show_backlog_transitions_state():
	var runtime = get_tree().root.get_node("StellaRuntime")
	runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	_action.action = StellaAction.Action.SHOW_BACKLOG

	_btn.pressed.emit()
	assert_eq(runtime.game_state.current_state, GameStateMachine.State.BACKLOG)

	runtime._close_current_overlay()
	runtime.game_state.transition_to(GameStateMachine.State.TITLE)


## --- Save/Load ---

func test_quick_save_creates_save():
	var runtime = get_tree().root.get_node("StellaRuntime")
	_action.action = StellaAction.Action.QUICK_SAVE

	_btn.pressed.emit()
	assert_true(runtime.has_quick_save())

	# Clean up
	runtime.delete_quick_save()


func test_none_action_does_nothing():
	_action.action = StellaAction.Action.NONE
	# Should not crash, just warn
	_btn.pressed.emit()
	assert_true(true)
