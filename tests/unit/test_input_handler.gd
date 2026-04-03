extends GutTest
## Tests for InputHandler — _process advance + button cancellation.


# ─── _process advance ───

func test_process_advances_when_playing():
	var handler = _make_handler()
	NatsumeRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)
	var received := []
	var cb = func(): received.append(true)
	SignalBus.advance_requested.connect(cb)

	handler._advance_pending = true
	handler._button_pressed = false
	handler._process(0.0)

	assert_eq(received.size(), 1, "should advance when PLAYING and no button pressed")
	assert_false(handler._advance_pending, "pending should be cleared")
	SignalBus.advance_requested.disconnect(cb)
	handler.queue_free()


func test_process_blocked_when_not_playing():
	var handler = _make_handler()
	NatsumeRuntime.game_state.transition_to(GameStateMachine.State.SAVE_LOAD)
	var received := []
	var cb = func(): received.append(true)
	SignalBus.advance_requested.connect(cb)

	handler._advance_pending = true
	handler._button_pressed = false
	handler._process(0.0)

	assert_eq(received.size(), 0, "should NOT advance when not PLAYING")
	SignalBus.advance_requested.disconnect(cb)
	handler.queue_free()


func test_process_cancelled_by_button():
	var handler = _make_handler()
	NatsumeRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)
	var received := []
	var cb = func(): received.append(true)
	SignalBus.advance_requested.connect(cb)

	handler._advance_pending = true
	handler._button_pressed = true
	handler._process(0.0)

	assert_eq(received.size(), 0, "should NOT advance when button was pressed")
	assert_false(handler._button_pressed, "button flag should be cleared")
	SignalBus.advance_requested.disconnect(cb)
	handler.queue_free()


func test_process_noop_when_not_pending():
	var handler = _make_handler()
	NatsumeRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)
	var received := []
	var cb = func(): received.append(true)
	SignalBus.advance_requested.connect(cb)

	handler._advance_pending = false
	handler._process(0.0)

	assert_eq(received.size(), 0, "should NOT advance when not pending")
	SignalBus.advance_requested.disconnect(cb)
	handler.queue_free()


# ─── Full flow simulation ───

func test_click_then_button_signal_cancels_advance():
	var handler = _make_handler()
	NatsumeRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)
	var received := []
	var cb = func(): received.append(true)
	SignalBus.advance_requested.connect(cb)

	# Step 1: _input sets pending (simulating left click on button area)
	handler._advance_pending = true
	handler._button_pressed = false

	# Step 2: GUI processes button → signal fires
	SignalBus.toolbar_button_pressed.emit()

	# Step 3: _process runs after input
	handler._process(0.0)

	assert_eq(received.size(), 0, "button signal should cancel advance")
	SignalBus.advance_requested.disconnect(cb)
	handler.queue_free()


func test_click_without_button_advances():
	var handler = _make_handler()
	NatsumeRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)
	var received := []
	var cb = func(): received.append(true)
	SignalBus.advance_requested.connect(cb)

	# Step 1: _input sets pending (click on empty area)
	handler._advance_pending = true
	handler._button_pressed = false

	# Step 2: No button pressed (GUI finds no button at click position)
	# Step 3: _process runs
	handler._process(0.0)

	assert_eq(received.size(), 1, "should advance when no button interfered")
	SignalBus.advance_requested.disconnect(cb)
	handler.queue_free()


# ─── Keyboard ───

func test_keyboard_advance_when_playing():
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


func test_keyboard_blocked_when_not_playing():
	var handler = _make_handler()
	NatsumeRuntime.game_state.transition_to(GameStateMachine.State.SAVE_LOAD)
	var received := []
	var cb = func(): received.append(true)
	SignalBus.advance_requested.connect(cb)

	var event = InputEventKey.new()
	event.keycode = KEY_ENTER
	event.pressed = true
	handler._unhandled_input(event)

	assert_eq(received.size(), 0)
	SignalBus.advance_requested.disconnect(cb)
	handler.queue_free()


# ─── Helpers ───

func _make_handler() -> Node:
	var handler = preload("res://addons/natsume/presentation/input/input_handler.gd").new()
	add_child(handler)
	return handler
