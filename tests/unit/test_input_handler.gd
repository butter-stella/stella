extends GutTest
## Tests for InputHandler logic.


# ─── Mouse advance ───

func test_left_click_advances_when_playing():
	var handler = _make_handler()
	NatsumeRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)
	var received := []
	var cb = func(): received.append(true)
	SignalBus.advance_requested.connect(cb)

	# Simulate: _input with left click, no hovered control (headless has no GUI)
	var event = InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	handler._input(event)

	assert_eq(received.size(), 1, "should advance on left click when PLAYING")
	SignalBus.advance_requested.disconnect(cb)
	handler.queue_free()


func test_left_click_blocked_when_not_playing():
	var handler = _make_handler()
	NatsumeRuntime.game_state.transition_to(GameStateMachine.State.SAVE_LOAD)
	var received := []
	var cb = func(): received.append(true)
	SignalBus.advance_requested.connect(cb)

	var event = InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	handler._input(event)

	assert_eq(received.size(), 0, "should NOT advance when not PLAYING")
	SignalBus.advance_requested.disconnect(cb)
	handler.queue_free()


# ─── Keyboard ───

func test_space_advances_when_playing():
	var handler = _make_handler()
	NatsumeRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)
	var received := []
	var cb = func(): received.append(true)
	SignalBus.advance_requested.connect(cb)

	var event = InputEventKey.new()
	event.keycode = KEY_SPACE
	event.pressed = true
	handler._unhandled_input(event)

	assert_eq(received.size(), 1)
	SignalBus.advance_requested.disconnect(cb)
	handler.queue_free()


func test_enter_advances_when_playing():
	var handler = _make_handler()
	NatsumeRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)
	var received := []
	var cb = func(): received.append(true)
	SignalBus.advance_requested.connect(cb)

	var event = InputEventKey.new()
	event.keycode = KEY_ENTER
	event.pressed = true
	handler._unhandled_input(event)

	assert_eq(received.size(), 1)
	SignalBus.advance_requested.disconnect(cb)
	handler.queue_free()


func test_keyboard_blocked_when_not_playing():
	var handler = _make_handler()
	NatsumeRuntime.game_state.transition_to(GameStateMachine.State.SAVE_LOAD)
	var received := []
	var cb = func(): received.append(true)
	SignalBus.advance_requested.connect(cb)

	var event = InputEventKey.new()
	event.keycode = KEY_SPACE
	event.pressed = true
	handler._unhandled_input(event)

	assert_eq(received.size(), 0)
	SignalBus.advance_requested.disconnect(cb)
	handler.queue_free()


func test_key_echo_ignored():
	var handler = _make_handler()
	NatsumeRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)
	var received := []
	var cb = func(): received.append(true)
	SignalBus.advance_requested.connect(cb)

	var event = InputEventKey.new()
	event.keycode = KEY_SPACE
	event.pressed = true
	event.echo = true
	handler._unhandled_input(event)

	assert_eq(received.size(), 0, "echo events should be ignored")
	SignalBus.advance_requested.disconnect(cb)
	handler.queue_free()


# ─── Helpers ───

func _make_handler() -> Node:
	var handler = preload("res://addons/natsume/presentation/input/input_handler.gd").new()
	add_child(handler)
	return handler
