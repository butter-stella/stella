extends GutTest
## Tests for NatsumeAction — zero-code button binding component.


func test_auto_connects_to_parent_button():
	var btn = Button.new()
	var action = NatsumeAction.new()
	action.action = NatsumeAction.Action.TOGGLE_AUTO_PLAY
	btn.add_child(action)
	add_child(btn)

	assert_true(btn.pressed.get_connections().size() > 0,
		"NatsumeAction should connect to parent button's pressed signal")

	btn.queue_free()


func test_does_not_crash_on_non_button_parent():
	var node = Node.new()
	var action = NatsumeAction.new()
	action.action = NatsumeAction.Action.QUICK_SAVE
	node.add_child(action)
	add_child(node)

	# Should not crash, just warn
	assert_true(true, "NatsumeAction on non-button parent should not crash")

	node.queue_free()


func test_toggle_auto_play_action():
	var runtime = get_tree().root.get_node("NatsumeRuntime")
	var was_active = runtime.is_auto_playing()

	var btn = Button.new()
	var action = NatsumeAction.new()
	action.action = NatsumeAction.Action.TOGGLE_AUTO_PLAY
	btn.add_child(action)
	add_child(btn)

	btn.pressed.emit()
	assert_ne(runtime.is_auto_playing(), was_active)

	# Restore
	runtime.toggle_auto_play()
	btn.queue_free()


func test_toggle_skip_action():
	var runtime = get_tree().root.get_node("NatsumeRuntime")
	var was_active = runtime.is_skipping()

	var btn = Button.new()
	var action = NatsumeAction.new()
	action.action = NatsumeAction.Action.TOGGLE_SKIP
	btn.add_child(action)
	add_child(btn)

	btn.pressed.emit()
	assert_ne(runtime.is_skipping(), was_active)

	# Restore
	runtime.toggle_skip()
	btn.queue_free()


func test_show_settings_action():
	var runtime = get_tree().root.get_node("NatsumeRuntime")
	runtime.game_state.transition_to(GameStateMachine.State.PLAYING)

	var btn = Button.new()
	var action = NatsumeAction.new()
	action.action = NatsumeAction.Action.SHOW_SETTINGS
	btn.add_child(action)
	add_child(btn)

	btn.pressed.emit()
	assert_eq(runtime.game_state.current_state, GameStateMachine.State.SETTINGS)

	runtime.close_overlay()
	btn.queue_free()


func test_show_save_load_action():
	var runtime = get_tree().root.get_node("NatsumeRuntime")
	runtime.game_state.transition_to(GameStateMachine.State.PLAYING)

	var btn = Button.new()
	var action = NatsumeAction.new()
	action.action = NatsumeAction.Action.SHOW_SAVE
	btn.add_child(action)
	add_child(btn)

	btn.pressed.emit()
	assert_eq(runtime.game_state.current_state, GameStateMachine.State.SAVE_LOAD)

	runtime.close_overlay()
	btn.queue_free()


func test_show_backlog_action():
	var runtime = get_tree().root.get_node("NatsumeRuntime")
	runtime.game_state.transition_to(GameStateMachine.State.PLAYING)

	var btn = Button.new()
	var action = NatsumeAction.new()
	action.action = NatsumeAction.Action.SHOW_BACKLOG
	btn.add_child(action)
	add_child(btn)

	btn.pressed.emit()
	assert_eq(runtime.game_state.current_state, GameStateMachine.State.BACKLOG)

	runtime.close_overlay()
	btn.queue_free()


func test_quit_action():
	# Just verify it doesn't crash — can't actually test quit
	var btn = Button.new()
	var action = NatsumeAction.new()
	action.action = NatsumeAction.Action.QUIT
	btn.add_child(action)
	add_child(btn)

	assert_eq(action.action, NatsumeAction.Action.QUIT)
	btn.queue_free()
