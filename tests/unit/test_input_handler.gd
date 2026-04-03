extends GutTest
## Tests for InputHandler + DialoguePresenter input routing.


# ─── DialoguePresenter passthrough ───

func test_dialogue_presenter_self_is_ignore():
	var scene = _load_game_scene()
	var dialogue = scene.get_node("%DialoguePanel")
	assert_eq(dialogue.mouse_filter, Control.MOUSE_FILTER_IGNORE,
		"DialoguePanel should be IGNORE so clicks pass through")
	scene.queue_free()


func test_dialogue_presenter_labels_are_ignore():
	var scene = _load_game_scene()
	var name_label = scene.get_node("%NameLabel")
	var text_label = scene.get_node("%TextLabel")
	assert_eq(name_label.mouse_filter, Control.MOUSE_FILTER_IGNORE)
	assert_eq(text_label.mouse_filter, Control.MOUSE_FILTER_IGNORE)
	scene.queue_free()


func test_dialogue_presenter_toolbar_is_ignore():
	var scene = _load_game_scene()
	var toolbar = scene.get_node("%Toolbar")
	assert_eq(toolbar.mouse_filter, Control.MOUSE_FILTER_IGNORE,
		"Toolbar container should be IGNORE, only Buttons keep STOP")
	scene.queue_free()


func test_dialogue_presenter_containers_are_ignore():
	var scene = _load_game_scene()
	var dialogue = scene.get_node("%DialoguePanel")
	var name_label = scene.get_node("%NameLabel")
	# Walk from name_label up — all containers should be IGNORE
	var node = name_label.get_parent()
	while node != null and node != dialogue:
		if node is Control:
			assert_eq(node.mouse_filter, Control.MOUSE_FILTER_IGNORE,
				"%s should be IGNORE" % node.name)
		node = node.get_parent()
	scene.queue_free()


func test_toolbar_buttons_keep_stop():
	var scene = _load_game_scene()
	var toolbar = scene.get_node("%Toolbar")
	# Buttons are dynamically created in _setup_toolbar
	# Wait one frame for _ready to complete
	await get_tree().process_frame
	for child in toolbar.get_children():
		if child is Button:
			assert_eq(child.mouse_filter, Control.MOUSE_FILTER_STOP,
				"Button '%s' should keep STOP" % child.text)
	scene.queue_free()


# ─── InputHandler keyboard (is_playing guard) ───

func test_keyboard_advance_blocked_when_not_playing():
	NatsumeRuntime.game_state.transition_to(GameStateMachine.State.SAVE_LOAD)
	var received := []
	var cb = func(): received.append(true)
	SignalBus.advance_requested.connect(cb)

	var handler = _make_handler()
	var event = InputEventKey.new()
	event.keycode = KEY_SPACE
	event.pressed = true
	handler._unhandled_input(event)

	assert_eq(received.size(), 0, "should NOT advance when not PLAYING")

	SignalBus.advance_requested.disconnect(cb)
	handler.queue_free()


func test_keyboard_advance_works_when_playing():
	NatsumeRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)
	var received := []
	var cb = func(): received.append(true)
	SignalBus.advance_requested.connect(cb)

	var handler = _make_handler()
	var event = InputEventKey.new()
	event.keycode = KEY_SPACE
	event.pressed = true
	handler._unhandled_input(event)

	assert_eq(received.size(), 1, "should advance when PLAYING")

	SignalBus.advance_requested.disconnect(cb)
	handler.queue_free()


func test_mouse_advance_via_unhandled_input():
	NatsumeRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)
	var received := []
	var cb = func(): received.append(true)
	SignalBus.advance_requested.connect(cb)

	var handler = _make_handler()
	var event = InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	handler._unhandled_input(event)

	assert_eq(received.size(), 1, "mouse left click should advance via _unhandled_input")

	SignalBus.advance_requested.disconnect(cb)
	handler.queue_free()


# ─── Helpers ───

func _make_handler() -> Node:
	var handler = preload("res://addons/natsume/presentation/input/input_handler.gd").new()
	add_child(handler)
	return handler


func _load_game_scene() -> Node:
	var scene = preload("res://addons/natsume/scenes/game.tscn").instantiate()
	add_child(scene)
	return scene
