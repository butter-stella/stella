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
	handler.free()


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
	handler.free()


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
	handler.free()


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
	handler.free()


func test_gamepad_a_advances_when_playing() -> void:
	var handler = _make_handler()
	StellaRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)
	var received := []
	var callback := func(): received.append(true)
	SignalBus.advance_requested.connect(callback)

	var event := InputEventJoypadButton.new()
	event.button_index = JOY_BUTTON_A
	event.pressed = true
	handler._unhandled_input(event)

	assert_eq(received.size(), 1,
		"gamepad A shares the normal dialogue/wait advance path")
	SignalBus.advance_requested.disconnect(callback)
	handler.free()


func test_ready_normal_inputs_advance_once_and_stop_event_propagation() -> void:
	var original_auto := StellaRuntime.auto_play.is_active
	var original_skip := StellaRuntime.skip_controller.is_active
	StellaRuntime.auto_play.is_active = false
	StellaRuntime.skip_controller.is_active = false
	StellaRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)
	var received := []
	var callback := func(): received.append(true)
	SignalBus.advance_requested.connect(callback)

	for test_case in _normal_advance_events():
		# A fresh SubViewport gives every route an independent handled flag, so a
		# missing set_input_as_handled() cannot inherit another event's result.
		var viewport := SubViewport.new()
		viewport.size = Vector2i(32, 32)
		add_child(viewport)
		var handler = preload(
			"res://addons/stella/presentation/input/input_handler.gd").new()
		viewport.add_child(handler)
		var before := received.size()

		_dispatch_normal_advance(handler, test_case)

		assert_eq(received.size(), before + 1,
			"%s resolves exactly one ready fallback" % test_case["label"])
		assert_true(viewport.is_input_handled(),
			"%s stops the accepted event before it reaches a new owner"
			% test_case["label"])
		viewport.free()

	SignalBus.advance_requested.disconnect(callback)
	StellaRuntime.auto_play.is_active = original_auto
	StellaRuntime.skip_controller.is_active = original_skip


func test_gamepad_release_and_other_buttons_do_not_advance() -> void:
	var handler = _make_handler()
	StellaRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)
	var received := []
	var callback := func(): received.append(true)
	SignalBus.advance_requested.connect(callback)

	var release := InputEventJoypadButton.new()
	release.button_index = JOY_BUTTON_A
	release.pressed = false
	handler._unhandled_input(release)
	var other_button := InputEventJoypadButton.new()
	other_button.button_index = JOY_BUTTON_A + 1
	other_button.pressed = true
	handler._unhandled_input(other_button)

	assert_eq(received.size(), 0)
	SignalBus.advance_requested.disconnect(callback)
	handler.free()


func test_gamepad_a_is_blocked_outside_playing() -> void:
	var handler = _make_handler()
	StellaRuntime.game_state.transition_to(GameStateMachine.State.SAVE_LOAD)
	var received := []
	var callback := func(): received.append(true)
	SignalBus.advance_requested.connect(callback)

	var event := InputEventJoypadButton.new()
	event.button_index = JOY_BUTTON_A
	event.pressed = true
	handler._unhandled_input(event)

	assert_eq(received.size(), 0,
		"gamepad input must not reach the scenario beneath an overlay")
	SignalBus.advance_requested.disconnect(callback)
	handler.free()


func test_gamepad_a_restores_hidden_dialogue_without_advancing() -> void:
	var scene = _make_scene_with_dialogue()
	var handler = scene.get_node("InputHandler")
	var dialogue = scene.get_node("%DialoguePanel")
	dialogue._ui_hidden = true
	dialogue.visible = false
	StellaRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)
	var received := []
	var callback := func(): received.append(true)
	SignalBus.advance_requested.connect(callback)

	var event := InputEventJoypadButton.new()
	event.button_index = JOY_BUTTON_A
	event.pressed = true
	handler._unhandled_input(event)

	assert_false(dialogue._ui_hidden)
	assert_true(dialogue.visible)
	assert_eq(received.size(), 0,
		"the input that restores soft-hidden UI must be consumed")
	SignalBus.advance_requested.disconnect(callback)
	scene.free()


func test_gamepad_a_completes_typewriter_before_advancing() -> void:
	var scene = _make_scene_with_dialogue()
	var handler = scene.get_node("InputHandler")
	var dialogue = scene.get_node("%DialoguePanel")
	dialogue.text_label.text = "Typing"
	dialogue.text_label.visible_characters = 1
	dialogue._is_typing = true
	StellaRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)
	var received := []
	var callback := func(): received.append(true)
	SignalBus.advance_requested.connect(callback)

	var event := InputEventJoypadButton.new()
	event.button_index = JOY_BUTTON_A
	event.pressed = true
	handler._unhandled_input(event)

	assert_false(dialogue._is_typing)
	assert_eq(dialogue.text_label.visible_characters, -1)
	assert_eq(received.size(), 0,
		"finishing the current typewriter consumes the first gamepad press")
	SignalBus.advance_requested.disconnect(callback)
	scene.free()


func test_gamepad_a_matches_keyboard_advance_policy_during_auto_and_skip() -> void:
	var handler = _make_handler()
	StellaRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)
	var received := []
	var callback := func(): received.append(true)
	SignalBus.advance_requested.connect(callback)
	var key := InputEventKey.new()
	key.keycode = KEY_SPACE
	key.pressed = true
	var gamepad := InputEventJoypadButton.new()
	gamepad.button_index = JOY_BUTTON_A
	gamepad.pressed = true

	for controller in [StellaRuntime.auto_play, StellaRuntime.skip_controller]:
		StellaRuntime.auto_play.is_active = false
		StellaRuntime.skip_controller.is_active = false
		controller.is_active = true
		var before := received.size()
		handler._unhandled_input(key)
		handler._unhandled_input(gamepad)
		assert_eq(received.size(), before + 2,
			"gamepad A and Space are both real advance input in this mode")

	StellaRuntime.auto_play.is_active = false
	StellaRuntime.skip_controller.is_active = false
	SignalBus.advance_requested.disconnect(callback)
	handler.free()


func test_click_to_complete_false_consumes_all_normal_inputs_without_mutation() -> void:
	var original_setting: Variant = StellaRuntime.get_setting("click_to_complete")
	var original_auto := StellaRuntime.auto_play.is_active
	var original_skip := StellaRuntime.skip_controller.is_active
	StellaRuntime.set_setting("click_to_complete", false)
	StellaRuntime.auto_play.is_active = false
	StellaRuntime.skip_controller.is_active = false
	StellaRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)
	var scene = _make_scene_with_dialogue()
	var handler = scene.get_node("InputHandler")
	var dialogue = scene.get_node("%DialoguePanel")
	var received := []
	var callback := func(): received.append(true)
	SignalBus.advance_requested.connect(callback)

	for test_case in _normal_advance_events():
		dialogue.text_label.text = "Typing"
		dialogue.text_label.visible_characters = 1
		dialogue._is_typing = true
		var generation_before: int = dialogue._dialogue_gen
		_dispatch_normal_advance(handler, test_case)
		assert_true(dialogue._is_typing,
			"%s is consumed without completing" % test_case["label"])
		assert_eq(dialogue.text_label.visible_characters, 1,
			"%s preserves the visible boundary" % test_case["label"])
		assert_eq(dialogue._dialogue_gen, generation_before,
			"%s cannot retire the typing generation" % test_case["label"])
		assert_eq(received.size(), 0,
			"%s cannot fall through to owner/global advance" % test_case["label"])

	SignalBus.advance_requested.disconnect(callback)
	StellaRuntime.set_setting("click_to_complete", original_setting)
	StellaRuntime.auto_play.is_active = original_auto
	StellaRuntime.skip_controller.is_active = original_skip
	scene.free()


func test_click_to_complete_is_read_live_for_the_active_typing_line() -> void:
	var original_setting: Variant = StellaRuntime.get_setting("click_to_complete")
	var original_auto := StellaRuntime.auto_play.is_active
	var original_skip := StellaRuntime.skip_controller.is_active
	StellaRuntime.auto_play.is_active = false
	StellaRuntime.skip_controller.is_active = false
	StellaRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)
	var scene = _make_scene_with_dialogue()
	var handler = scene.get_node("InputHandler")
	var dialogue = scene.get_node("%DialoguePanel")
	dialogue.text_label.text = "Typing"
	dialogue.text_label.visible_characters = 1
	dialogue._is_typing = true
	var received := []
	var callback := func(): received.append(true)
	SignalBus.advance_requested.connect(callback)

	StellaRuntime.set_setting("click_to_complete", false)
	_dispatch_normal_advance(handler, _normal_advance_events()[1])
	assert_true(dialogue._is_typing,
		"the current line observes false at the first input boundary")
	assert_eq(received.size(), 0)

	StellaRuntime.set_setting("click_to_complete", true)
	_dispatch_normal_advance(handler, _normal_advance_events()[2])
	assert_false(dialogue._is_typing,
		"the same active line observes a later direct setting change")
	assert_eq(dialogue.text_label.visible_characters, -1)
	assert_eq(received.size(), 0,
		"completion consumes the input instead of also advancing")

	SignalBus.advance_requested.disconnect(callback)
	StellaRuntime.set_setting("click_to_complete", original_setting)
	StellaRuntime.auto_play.is_active = original_auto
	StellaRuntime.skip_controller.is_active = original_skip
	scene.free()


func test_gamepad_accept_advances_when_playing() -> void:
	var handler = _make_handler()
	StellaRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)
	var received := []
	var cb = func(): received.append(true)
	SignalBus.advance_requested.connect(cb)

	var event := InputEventJoypadButton.new()
	event.button_index = JOY_BUTTON_A
	event.pressed = true
	handler._unhandled_input(event)

	assert_eq(received.size(), 1)
	SignalBus.advance_requested.disconnect(cb)
	handler.queue_free()


func test_other_gamepad_buttons_do_not_advance() -> void:
	var handler = _make_handler()
	StellaRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)
	var received := []
	var cb = func(): received.append(true)
	SignalBus.advance_requested.connect(cb)

	var event := InputEventJoypadButton.new()
	event.button_index = JOY_BUTTON_B
	event.pressed = true
	handler._unhandled_input(event)

	assert_eq(received.size(), 0)
	SignalBus.advance_requested.disconnect(cb)
	handler.queue_free()


func test_gamepad_accept_is_blocked_by_overlay_state() -> void:
	var handler = _make_handler()
	StellaRuntime.game_state.transition_to(GameStateMachine.State.SAVE_LOAD)
	var received := []
	var cb = func(): received.append(true)
	SignalBus.advance_requested.connect(cb)

	var event := InputEventJoypadButton.new()
	event.button_index = JOY_BUTTON_A
	event.pressed = true
	handler._unhandled_input(event)

	assert_eq(received.size(), 0)
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
	handler.free()


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
	handler.free()


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
	handler.free()


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

	scene.free()


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
	scene.free()


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
	scene.free()


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

	scene.free()


# ─── Helpers ───


func _make_handler() -> Node:
	var handler = preload("res://addons/stella/presentation/input/input_handler.gd").new()
	add_child(handler)
	return handler


func _make_scene_with_dialogue() -> Node:
	var scene = preload("res://addons/stella/scenes/game.tscn").instantiate()
	add_child(scene)
	return scene


func _normal_advance_events() -> Array[Dictionary]:
	var mouse := InputEventMouseButton.new()
	mouse.button_index = MOUSE_BUTTON_LEFT
	mouse.pressed = true
	var space := InputEventKey.new()
	space.keycode = KEY_SPACE
	space.pressed = true
	var enter := InputEventKey.new()
	enter.keycode = KEY_ENTER
	enter.pressed = true
	var joypad := InputEventJoypadButton.new()
	joypad.button_index = JOY_BUTTON_A
	joypad.pressed = true
	return [
		{"label": "left click", "event": mouse, "mouse": true},
		{"label": "Space", "event": space, "mouse": false},
		{"label": "Enter", "event": enter, "mouse": false},
		{"label": "Joy A", "event": joypad, "mouse": false},
	]


func _dispatch_normal_advance(handler: Node, test_case: Dictionary) -> void:
	if bool(test_case["mouse"]):
		handler._input(test_case["event"])
	else:
		handler._unhandled_input(test_case["event"])
