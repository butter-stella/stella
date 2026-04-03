extends GutTest
## Tests for InputHandler — deferred advance + button cancellation.


# ─── Deferred advance ───

func test_deferred_advance_emits_when_playing():
	var handler = _make_handler()
	NatsumeRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)

	var received := []
	var cb = func(): received.append(true)
	SignalBus.advance_requested.connect(cb)

	handler._advance_pending = true
	handler._button_pressed = false
	handler._deferred_advance()

	assert_eq(received.size(), 1, "should advance when PLAYING and no button pressed")
	SignalBus.advance_requested.disconnect(cb)
	handler.queue_free()


func test_deferred_advance_blocked_when_not_playing():
	var handler = _make_handler()
	NatsumeRuntime.game_state.transition_to(GameStateMachine.State.SAVE_LOAD)

	var received := []
	var cb = func(): received.append(true)
	SignalBus.advance_requested.connect(cb)

	handler._advance_pending = true
	handler._button_pressed = false
	handler._deferred_advance()

	assert_eq(received.size(), 0, "should NOT advance when not PLAYING")
	SignalBus.advance_requested.disconnect(cb)
	handler.queue_free()


func test_deferred_advance_cancelled_by_button():
	var handler = _make_handler()
	NatsumeRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)

	var received := []
	var cb = func(): received.append(true)
	SignalBus.advance_requested.connect(cb)

	handler._advance_pending = true
	handler._button_pressed = true  # Toolbar button was pressed
	handler._deferred_advance()

	assert_eq(received.size(), 0, "should NOT advance when toolbar button was pressed")
	SignalBus.advance_requested.disconnect(cb)
	handler.queue_free()


func test_deferred_advance_skips_when_not_pending():
	var handler = _make_handler()
	NatsumeRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)

	var received := []
	var cb = func(): received.append(true)
	SignalBus.advance_requested.connect(cb)

	handler._advance_pending = false
	handler._deferred_advance()

	assert_eq(received.size(), 0, "should NOT advance when not pending")
	SignalBus.advance_requested.disconnect(cb)
	handler.queue_free()


# ─── Button signal integration ───

func test_toolbar_signal_sets_button_flag():
	var handler = _make_handler()
	handler._button_pressed = false

	SignalBus.toolbar_button_pressed.emit()

	assert_true(handler._button_pressed, "toolbar signal should set flag")
	handler.queue_free()


func test_toolbar_signal_cancels_pending_advance():
	var handler = _make_handler()
	NatsumeRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)

	var received := []
	var cb = func(): received.append(true)
	SignalBus.advance_requested.connect(cb)

	# Simulate: _input sets pending, then button fires, then deferred runs
	handler._advance_pending = true
	handler._button_pressed = false
	SignalBus.toolbar_button_pressed.emit()  # Button callback fires
	handler._deferred_advance()  # Deferred runs

	assert_eq(received.size(), 0, "toolbar signal should cancel advance")
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
