extends GutTest
## Tests for InputHandler logic.


class ResolvedDialogueStub extends Node:
	var request_count: int = 0

	func request_current_dialogue_advance() -> bool:
		request_count += 1
		return false


# ─── Mouse advance ───

func test_left_click_advances_when_playing():
	var handler = _make_handler()
	StellaRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)
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
	StellaRuntime.game_state.transition_to(GameStateMachine.State.SAVE_LOAD)
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
	StellaRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)
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
	StellaRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)
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


func test_resolved_dialogue_falls_back_to_click_wait_notification() -> void:
	var handler = _make_handler()
	var dialogue := ResolvedDialogueStub.new()
	var wait_handler := WaitHandler.new()
	var wait_command := CommandData.new()
	wait_command.type = "wait"
	wait_command.params = {"mode": "click"}
	var wait_done := [false]
	var run_wait := func() -> void:
		await wait_handler.execute(wait_command, ScenarioContext.new())
		wait_done[0] = true
	run_wait.call()

	handler._request_dialogue_advance(dialogue)
	await get_tree().process_frame

	assert_eq(dialogue.request_count, 1)
	assert_true(wait_done[0],
		"a stale resolved dialogue owner must not swallow @wait click input")
	dialogue.free()
	handler.queue_free()


func test_keyboard_blocked_when_not_playing():
	var handler = _make_handler()
	StellaRuntime.game_state.transition_to(GameStateMachine.State.SAVE_LOAD)
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
	StellaRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)
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


# ─── Ctrl held / release ───

func test_ctrl_press_sets_held():
	var scene = _make_scene_with_dialogue()
	var handler = scene.get_node("InputHandler")
	var dialogue = scene.get_node("%DialoguePanel")
	StellaRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)

	var press = InputEventKey.new()
	press.keycode = KEY_CTRL
	press.pressed = true
	handler._unhandled_input(press)
	assert_true(dialogue._ctrl_held, "Ctrl press should set _ctrl_held true")

	scene.queue_free()


func test_ctrl_press_ready_dialogue_is_blocked_outside_playing():
	var scene = _make_scene_with_dialogue()
	var handler = scene.get_node("InputHandler")
	var dialogue = scene.get_node("%DialoguePanel")
	dialogue._is_typing = false
	dialogue._ctrl_held = false
	StellaRuntime.game_state.current_state = GameStateMachine.State.SAVE_LOAD
	var received := []
	var cb = func(): received.append(true)
	SignalBus.advance_requested.connect(cb)

	var press = InputEventKey.new()
	press.keycode = KEY_CTRL
	press.pressed = true
	handler._unhandled_input(press)
	assert_false(dialogue._ctrl_held,
		"Ctrl press in a system overlay must not enable dialogue skipping")
	assert_eq(received.size(), 0,
		"Ctrl press in a system overlay must not advance a ready dialogue")

	SignalBus.advance_requested.disconnect(cb)
	scene.queue_free()


func test_ctrl_press_typing_dialogue_is_blocked_outside_playing():
	var scene = _make_scene_with_dialogue()
	var handler = scene.get_node("InputHandler")
	var dialogue = scene.get_node("%DialoguePanel")
	dialogue._is_typing = true
	# Model an overlay opening while Ctrl was already down. A repeated press in
	# the overlay must clear, not preserve, the underlying fast-forward state.
	dialogue._ctrl_held = true
	dialogue.text_label.visible_characters = 2
	StellaRuntime.game_state.current_state = GameStateMachine.State.SETTINGS
	var received := []
	var cb = func(): received.append(true)
	SignalBus.advance_requested.connect(cb)

	var press = InputEventKey.new()
	press.keycode = KEY_CTRL
	press.pressed = true
	press.echo = true
	handler._unhandled_input(press)
	assert_false(dialogue._ctrl_held,
		"Ctrl press in a system overlay must not fast-forward a typewriter")
	assert_true(dialogue._is_typing)
	assert_eq(dialogue.text_label.visible_characters, 2)
	assert_eq(received.size(), 0)

	SignalBus.advance_requested.disconnect(cb)
	scene.queue_free()


func test_ctrl_release_clears_held_outside_playing():
	var scene = _make_scene_with_dialogue()
	var handler = scene.get_node("InputHandler")
	var dialogue = scene.get_node("%DialoguePanel")
	dialogue._ctrl_held = true
	StellaRuntime.game_state.current_state = GameStateMachine.State.BACKLOG

	var release = InputEventKey.new()
	release.keycode = KEY_CTRL
	release.pressed = false
	handler._unhandled_input(release)
	assert_false(dialogue._ctrl_held,
		"Ctrl release must clear _ctrl_held even outside PLAYING")

	scene.queue_free()


# ─── Helpers ───


func _make_handler() -> Node:
	var handler = preload("res://addons/stella/presentation/input/input_handler.gd").new()
	add_child(handler)
	return handler


func _make_scene_with_dialogue() -> Node:
	var scene = preload("res://addons/stella/scenes/game.tscn").instantiate()
	add_child(scene)
	return scene
