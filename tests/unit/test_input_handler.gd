extends GutTest
## Tests for InputHandler input routing logic.


func test_deferred_advance_emits_when_playing():
	var handler = _make_handler()
	NatsumeRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)

	var received := []
	SignalBus.advance_requested.connect(func(): received.append(true))

	handler._advance_pending = true
	handler._deferred_advance()

	assert_eq(received.size(), 1, "should emit advance_requested when PLAYING")

	# Cleanup
	for c in SignalBus.advance_requested.get_connections():
		SignalBus.advance_requested.disconnect(c["callable"])
	handler.queue_free()


func test_deferred_advance_skips_when_not_playing():
	var handler = _make_handler()
	NatsumeRuntime.game_state.transition_to(GameStateMachine.State.SAVE_LOAD)

	var received := []
	SignalBus.advance_requested.connect(func(): received.append(true))

	handler._advance_pending = true
	handler._deferred_advance()

	assert_eq(received.size(), 0, "should NOT emit when not PLAYING (button opened overlay)")

	for c in SignalBus.advance_requested.get_connections():
		SignalBus.advance_requested.disconnect(c["callable"])
	handler.queue_free()


func test_deferred_advance_skips_when_not_pending():
	var handler = _make_handler()
	NatsumeRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)

	var received := []
	SignalBus.advance_requested.connect(func(): received.append(true))

	handler._advance_pending = false
	handler._deferred_advance()

	assert_eq(received.size(), 0, "should NOT emit when not pending")

	for c in SignalBus.advance_requested.get_connections():
		SignalBus.advance_requested.disconnect(c["callable"])
	handler.queue_free()


func _make_handler() -> Node:
	var handler = preload("res://addons/natsume/presentation/input/input_handler.gd").new()
	add_child(handler)
	return handler
