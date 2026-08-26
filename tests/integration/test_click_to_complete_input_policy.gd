extends GutTest
## Cross-layer regression coverage for issue #136's live click-to-complete policy.
##
## Inputs are dispatched through the production InputHandler against a real
## DialoguePresenter.  Long character timing keeps the active owner stable
## without arbitrary sleeps; controller timers below express authored Auto/Skip
## behavior and are synchronized by the request-scoped activation.

const GAME_SCENE := preload("res://addons/stella/scenes/game.tscn")
const LOAD_SETTINGS_PATH := "user://tests/issue136_click_to_complete.json"

var _original_settings: Dictionary
var _original_settings_path: String
var _original_auto_active: bool
var _original_skip_active: bool
var _original_game_state: int
var _original_previous_game_state: int
var _viewports: Array[SubViewport] = []
var _signal_callbacks: Array[Dictionary] = []
var _request_serial: int = 0


func before_each() -> void:
	_original_settings = StellaRuntime.settings_manager.settings.to_dict()
	_original_settings_path = StellaRuntime.settings_manager.settings_path
	_original_auto_active = StellaRuntime.auto_play.is_active
	_original_skip_active = StellaRuntime.skip_controller.is_active
	_original_game_state = StellaRuntime.game_state.current_state
	_original_previous_game_state = StellaRuntime.game_state.previous_state
	_viewports.clear()
	_signal_callbacks.clear()
	_request_serial = 0
	StellaRuntime.auto_play.is_active = false
	StellaRuntime.skip_controller.is_active = false
	StellaRuntime.game_state.current_state = GameStateMachine.State.PLAYING
	StellaRuntime.game_state.previous_state = GameStateMachine.State.PLAYING
	StellaRuntime.set_setting("character_interval", 1000)
	StellaRuntime.set_setting("punctuation_pause", 0)
	StellaRuntime.set_setting("click_to_complete", true)


func after_each() -> void:
	for record in _signal_callbacks:
		var signal_value: Signal = record["signal"]
		var callback: Callable = record["callback"]
		if signal_value.is_connected(callback):
			signal_value.disconnect(callback)
	SignalBus.hide_dialogue.emit()
	for viewport in _viewports:
		if is_instance_valid(viewport):
			viewport.queue_free()
	StellaRuntime.auto_play.is_active = false
	StellaRuntime.skip_controller.is_active = false
	for key in _original_settings:
		StellaRuntime.settings_manager.set_value(key, _original_settings[key])
	StellaRuntime.settings_manager.settings_path = _original_settings_path
	StellaRuntime.auto_play.is_active = _original_auto_active
	StellaRuntime.skip_controller.is_active = _original_skip_active
	StellaRuntime.game_state.current_state = _original_game_state
	StellaRuntime.game_state.previous_state = _original_previous_game_state
	if FileAccess.file_exists(LOAD_SETTINGS_PATH):
		DirAccess.remove_absolute(
			ProjectSettings.globalize_path(LOAD_SETTINGS_PATH))
	await get_tree().process_frame
	_viewports.clear()
	_signal_callbacks.clear()


func test_four_inputs_consume_real_typing_owner_when_live_setting_is_false() -> void:
	StellaRuntime.set_setting("click_to_complete", false)
	for input_case in _normal_input_cases():
		var fixture := await _create_fixture()
		var activation := _begin_owned_typing(fixture, "False policy remains typing")
		var presenter: Control = fixture["presenter"]
		var viewport: SubViewport = fixture["viewport"]
		var generation: int = presenter._dialogue_gen
		var visible_before: int = presenter.text_label.visible_characters
		var fallbacks := _capture_advance_notifications()

		_dispatch(fixture["handler"], input_case["event"])

		assert_true(presenter._is_typing,
			"%s consumes without completing" % input_case["label"])
		assert_eq(presenter._dialogue_gen, generation,
			"%s cannot retire the active generation" % input_case["label"])
		assert_eq(presenter.text_label.visible_characters, visible_before,
			"%s leaves the visible text unchanged" % input_case["label"])
		assert_true(activation.is_pending(),
			"%s cannot advance the typing owner" % input_case["label"])
		assert_eq(fallbacks[0], 0,
			"%s cannot fall back to a wait-click signal" % input_case["label"])
		assert_true(viewport.is_input_handled(),
			"%s is consumed even when completion is disabled" % input_case["label"])
		await _dispose_fixture(fixture)


func test_four_inputs_complete_true_typing_then_advance_ready_owner_once() -> void:
	StellaRuntime.set_setting("click_to_complete", true)
	for input_case in _normal_input_cases():
		var typing_fixture := await _create_fixture()
		var typing_activation := _begin_owned_typing(
			typing_fixture, "True policy completes")
		var typing_fallbacks := _capture_advance_notifications()

		_dispatch(typing_fixture["handler"], input_case["event"])

		assert_false(typing_fixture["presenter"]._is_typing,
			"%s completes the active typewriter" % input_case["label"])
		assert_eq(typing_fixture["presenter"].text_label.visible_characters, -1)
		assert_true(typing_activation.is_pending(),
			"the completion input cannot also advance the owner")
		assert_eq(typing_fallbacks[0], 0)
		assert_true(typing_fixture["viewport"].is_input_handled(),
			"the completion input is consumed")
		await _dispose_fixture(typing_fixture)

		var ready_fixture := await _create_fixture()
		var ready_activation := _begin_owned_typing(
			ready_fixture, "Ready policy advances")
		assert_true(ready_fixture["presenter"].complete_typewriter())
		var ready_fallbacks := _capture_advance_notifications()

		_dispatch(ready_fixture["handler"], input_case["event"])

		assert_eq(
			ready_activation.get_outcome(),
			DialogueActivation.Outcome.ADVANCED,
			"%s advances the exact ready owner" % input_case["label"],
		)
		assert_eq(ready_fallbacks[0], 0,
			"an owned ready input cannot also emit the global fallback")
		assert_true(ready_fixture["viewport"].is_input_handled(),
			"%s marks the normal ready path handled" % input_case["label"])
		await _dispose_fixture(ready_fixture)


func test_same_show_stack_input_is_owned_before_later_signal_listeners() -> void:
	for allow_completion in [false, true]:
		StellaRuntime.set_setting("click_to_complete", allow_completion)
		var fixture := await _create_fixture()
		var callbacks_seen := [0]
		var fallbacks := _capture_advance_notifications()
		var callback := func(_request: DialogueRequest) -> void:
			callbacks_seen[0] += 1
			var event := InputEventKey.new()
			event.keycode = KEY_SPACE
			event.pressed = true
			fixture["handler"]._unhandled_input(event)
		_connect_tracked(SignalBus.dialogue_requested, callback)

		var activation := _begin_owned_typing(
			fixture, "Synchronous SHOW owner", false)

		assert_eq(callbacks_seen[0], 1)
		assert_true(activation.is_pending(),
			"same-stack input cannot advance the incoming owner")
		assert_eq(fallbacks[0], 0,
			"same-stack input cannot escape to the global fallback")
		assert_eq(fixture["presenter"]._is_typing, not allow_completion,
			"same-stack input observes the live completion setting")
		assert_true(fixture["viewport"].is_input_handled())
		await _dispose_fixture(fixture)
		_disconnect_tracked(SignalBus.dialogue_requested, callback)


func test_direct_reset_and_silent_load_are_live_at_each_input() -> void:
	var fixture := await _create_fixture()
	var presenter: Control = fixture["presenter"]
	var handler: Node = fixture["handler"]

	var direct_activation := _begin_owned_typing(fixture, "Direct live setting")
	StellaRuntime.set_setting("click_to_complete", false)
	_dispatch(handler, _key_event(KEY_SPACE))
	assert_true(presenter._is_typing)
	assert_true(direct_activation.is_pending())
	StellaRuntime.set_setting("click_to_complete", true)
	_dispatch(handler, _key_event(KEY_ENTER))
	assert_false(presenter._is_typing,
		"a later input reads the new direct value on the same line")
	assert_true(direct_activation.is_pending())

	StellaRuntime.set_setting("click_to_complete", false)
	var reset_activation := _begin_owned_typing(fixture, "Reset live setting")
	StellaRuntime.reset_settings()
	assert_true(StellaRuntime.get_setting("click_to_complete"))
	_dispatch(handler, _mouse_event())
	assert_false(presenter._is_typing,
		"reset restores the default true policy for the next input")
	assert_true(reset_activation.is_pending())

	StellaRuntime.settings_manager.settings_path = LOAD_SETTINGS_PATH
	StellaRuntime.set_setting("click_to_complete", false)
	StellaRuntime.settings_manager.save()
	StellaRuntime.set_setting("click_to_complete", true)
	var load_activation := _begin_owned_typing(fixture, "Load live setting")
	StellaRuntime.settings_manager.load_settings()
	assert_false(StellaRuntime.get_setting("click_to_complete"),
		"the persisted false value loads without a change signal")
	_dispatch(handler, _joy_event())
	assert_true(presenter._is_typing,
		"the next input live-pulls the silently loaded false value")
	assert_true(load_activation.is_pending())
	StellaRuntime.set_setting("click_to_complete", true)
	_dispatch(handler, _joy_event())
	assert_false(presenter._is_typing)
	assert_true(load_activation.is_pending())


func test_ready_input_commits_read_state_without_a_second_global_result() -> void:
	var fixture := await _create_fixture()
	var read_flags := ReadFlagManager.new()
	var dialogue_handler := DialogueHandler.new(read_flags)
	var scenario := _single_dialogue_scenario(
		"issue136_ready_commit", "Ready handler owner")
	var context := ScenarioContext.new(scenario)
	var command: CommandData = scenario.scenes[0].commands[0]
	var handler_finished := [false]
	var run_handler := func() -> void:
		await dialogue_handler.execute(command, context)
		handler_finished[0] = true
	run_handler.call()
	var activation: DialogueActivation = (
		fixture["presenter"]._current_dialogue_activation)
	assert_not_null(activation)
	assert_true(activation.is_pending())
	assert_true(fixture["presenter"].complete_typewriter())
	var notifications := _capture_advance_notifications()
	var dispatch_serial_before := SignalBus.current_advance_dispatch_serial()

	_dispatch(fixture["handler"], _key_event(KEY_SPACE))
	assert_true(fixture["viewport"].is_input_handled())
	await get_tree().process_frame

	assert_true(handler_finished[0])
	assert_eq(activation.get_outcome(), DialogueActivation.Outcome.ADVANCED)
	assert_true(read_flags.is_dialogue_read(
		scenario.get_read_identity(),
		scenario.id,
		"start",
		command.uid,
		0,
	), "the normal ready path commits the authored line as read")
	assert_eq(notifications[0], 1,
		"Core publishes one owned public notification after commit")
	assert_eq(SignalBus.current_advance_dispatch_serial(), dispatch_serial_before,
		"the owned echo is not a second global input dispatch")


func test_hidden_first_input_restores_and_false_second_input_only_consumes() -> void:
	StellaRuntime.set_setting("click_to_complete", false)
	for input_case in _normal_input_cases():
		var fixture := await _create_fixture()
		var activation := _begin_owned_typing(fixture, "Hidden active owner")
		var presenter: Control = fixture["presenter"]
		presenter._ui_hidden = true
		presenter.visible = false
		var generation: int = presenter._dialogue_gen
		var visible_before: int = presenter.text_label.visible_characters
		var fallbacks := _capture_advance_notifications()

		_dispatch(fixture["handler"], input_case["event"])
		assert_false(presenter._ui_hidden,
			"%s first restores the soft-hidden UI" % input_case["label"])
		assert_true(presenter.visible)
		assert_true(presenter._is_typing)
		assert_eq(presenter.text_label.visible_characters, visible_before)
		assert_true(activation.is_pending())
		assert_eq(fallbacks[0], 0)

		_dispatch(fixture["handler"], input_case["event"])
		assert_true(presenter._is_typing,
			"%s second input follows the live false policy" % input_case["label"])
		assert_eq(presenter._dialogue_gen, generation)
		assert_eq(presenter.text_label.visible_characters, visible_before)
		assert_true(activation.is_pending())
		assert_eq(fallbacks[0], 0)
		await _dispose_fixture(fixture)


func test_nonplaying_inputs_neither_restore_nor_consume_the_active_owner() -> void:
	StellaRuntime.set_setting("click_to_complete", true)
	for input_case in _normal_input_cases():
		var fixture := await _create_fixture()
		var activation := _begin_owned_typing(fixture, "Owner below overlay")
		var presenter: Control = fixture["presenter"]
		presenter._ui_hidden = true
		presenter.visible = false
		var generation: int = presenter._dialogue_gen
		var visible_before: int = presenter.text_label.visible_characters
		var fallbacks := _capture_advance_notifications()
		StellaRuntime.game_state.current_state = GameStateMachine.State.SETTINGS

		_dispatch(fixture["handler"], input_case["event"])

		assert_true(presenter._ui_hidden,
			"%s cannot restore UI below a system overlay" % input_case["label"])
		assert_false(presenter.visible)
		assert_true(presenter._is_typing)
		assert_eq(presenter._dialogue_gen, generation)
		assert_eq(presenter.text_label.visible_characters, visible_before)
		assert_true(activation.is_pending())
		assert_eq(fallbacks[0], 0)
		assert_false(fixture["viewport"].is_input_handled(),
			"the story layer does not claim a non-PLAYING input")
		StellaRuntime.game_state.current_state = GameStateMachine.State.PLAYING
		await _dispose_fixture(fixture)


func test_interactive_gui_left_click_is_not_claimed_by_story_input() -> void:
	var fixture := await _create_fixture()
	var activation := _begin_owned_typing(fixture, "GUI-owned click")
	var presenter: Control = fixture["presenter"]
	var button := Button.new()
	button.position = Vector2(8, 8)
	button.size = Vector2(220, 90)
	button.mouse_filter = Control.MOUSE_FILTER_STOP
	button.z_index = 100
	fixture["viewport"].add_child(button)
	await get_tree().process_frame
	var motion := InputEventMouseMotion.new()
	motion.position = Vector2(20, 20)
	fixture["viewport"].push_input(motion, true)
	await get_tree().process_frame
	assert_same(fixture["viewport"].gui_get_hovered_control(), button,
		"the synthetic pointer is over the interactive control")
	var generation: int = presenter._dialogue_gen
	var visible_before: int = presenter.text_label.visible_characters
	var fallbacks := _capture_advance_notifications()

	fixture["handler"]._input(_mouse_event(Vector2(20, 20)))

	assert_true(presenter._is_typing)
	assert_eq(presenter._dialogue_gen, generation)
	assert_eq(presenter.text_label.visible_characters, visible_before)
	assert_true(activation.is_pending())
	assert_eq(fallbacks[0], 0)
	assert_false(fixture["viewport"].is_input_handled(),
		"InputHandler leaves the GUI-owned click to GUI propagation")


func test_auto_source_rules_preserve_false_typing_and_consume_interrupt_click() -> void:
	StellaRuntime.set_setting("click_to_complete", false)
	var click_fixture := await _create_fixture()
	var click_activation := _begin_owned_typing(click_fixture, "Auto click policy")
	StellaRuntime.auto_play.is_active = true
	StellaRuntime.set_setting("auto_play_click_interrupt", false)
	_dispatch(click_fixture["handler"], _mouse_event())
	assert_true(StellaRuntime.auto_play.is_active)
	assert_true(click_fixture["presenter"]._is_typing)
	assert_true(click_activation.is_pending())
	assert_true(click_fixture["viewport"].is_input_handled(),
		"disabled Auto click interruption consumes the whole click")

	StellaRuntime.set_setting("auto_play_click_interrupt", true)
	_dispatch(click_fixture["handler"], _mouse_event())
	assert_false(StellaRuntime.auto_play.is_active,
		"enabled Auto click interruption stops Auto first")
	assert_true(click_fixture["presenter"]._is_typing,
		"the same click then follows live click_to_complete=false")
	assert_true(click_activation.is_pending())
	await _dispose_fixture(click_fixture)

	for input_case in [
		{"label": "Space", "event": _key_event(KEY_SPACE)},
		{"label": "Enter", "event": _key_event(KEY_ENTER)},
		{"label": "Joy A", "event": _joy_event()},
	]:
		var fixture := await _create_fixture()
		var activation := _begin_owned_typing(fixture, "Auto normal input")
		StellaRuntime.auto_play.is_active = true
		_dispatch(fixture["handler"], input_case["event"])
		assert_true(StellaRuntime.auto_play.is_active,
			"%s does not implicitly toggle Auto" % input_case["label"])
		assert_true(fixture["presenter"]._is_typing,
			"%s follows live false while Auto is active" % input_case["label"])
		assert_true(activation.is_pending())
		assert_true(fixture["viewport"].is_input_handled())
		StellaRuntime.auto_play.is_active = false
		await _dispose_fixture(fixture)


func test_skip_click_stops_only_while_keyboard_advances_the_ready_owner() -> void:
	StellaRuntime.set_setting("click_to_complete", false)
	StellaRuntime.set_setting("skip_interval", 1000)
	StellaRuntime.set_setting("skip_only_read", false)
	var fixture := await _create_fixture()
	var activation := _begin_owned_typing(fixture, "Skip source policy")
	var presenter: Control = fixture["presenter"]
	StellaRuntime.skip_controller.is_active = true
	assert_false(presenter._is_typing,
		"toolbar Skip itself snaps the line independently of input policy")
	assert_eq(presenter.text_label.visible_characters, -1)
	var generation: int = presenter._dialogue_gen

	_dispatch(fixture["handler"], _mouse_event())
	assert_false(StellaRuntime.skip_controller.is_active,
		"toolbar Skip left click only stops Skip")
	assert_false(presenter._is_typing)
	assert_eq(presenter._dialogue_gen, generation)
	assert_eq(presenter.text_label.visible_characters, -1)
	assert_true(activation.is_pending())
	assert_true(fixture["viewport"].is_input_handled())

	var keyboard_activation := _begin_owned_typing(
		fixture, "Skip ready keyboard owner")
	StellaRuntime.skip_controller.is_active = true
	assert_false(presenter._is_typing)
	_dispatch(fixture["handler"], _key_event(KEY_SPACE))
	assert_true(StellaRuntime.skip_controller.is_active,
		"Space is normal input rather than a toolbar Skip toggle")
	assert_eq(
		keyboard_activation.get_outcome(),
		DialogueActivation.Outcome.ADVANCED,
		"ready Skip owner advances regardless of click_to_complete=false",
	)
	assert_true(fixture["viewport"].is_input_handled())
	StellaRuntime.skip_controller.is_active = false


func test_auto_and_skip_internal_progress_ignore_click_to_complete_false() -> void:
	for controller_name in ["auto", "skip"]:
		StellaRuntime.set_setting("character_interval", 0)
		StellaRuntime.set_setting("punctuation_pause", 0)
		StellaRuntime.set_setting("click_to_complete", false)
		StellaRuntime.set_setting("auto_play_delay", 0.0)
		StellaRuntime.set_setting("auto_play_wait_voice", false)
		StellaRuntime.set_setting("skip_interval", 0)
		StellaRuntime.set_setting("skip_only_read", false)
		var fixture := await _create_fixture()
		if controller_name == "auto":
			StellaRuntime.auto_play.is_active = true
		else:
			StellaRuntime.skip_controller.is_active = true
		var activation := _begin_owned_typing(
			fixture, "%s internal progress" % controller_name)

		var advanced: bool = await wait_until(
			func(): return (
				activation.get_outcome()
				== DialogueActivation.Outcome.ADVANCED
			),
			0.8,
			"%s advances without a normal input" % controller_name,
		)
		assert_true(advanced,
			"click_to_complete=false cannot strand %s" % controller_name)
		StellaRuntime.auto_play.is_active = false
		StellaRuntime.skip_controller.is_active = false
		await _dispose_fixture(fixture)


func test_no_owner_and_stale_owner_fall_back_exactly_once_and_are_handled() -> void:
	for input_case in _normal_input_cases():
		var fixture := await _create_fixture()
		var fallbacks := _capture_advance_notifications()

		_dispatch(fixture["handler"], input_case["event"])

		assert_eq(fallbacks[0], 1,
			"%s emits one no-owner fallback" % input_case["label"])
		assert_true(fixture["viewport"].is_input_handled(),
			"%s consumes the accepted fallback input" % input_case["label"])
		await _dispose_fixture(fixture)

	var stale_fixture := await _create_fixture()
	var stale_activation := _begin_owned_typing(stale_fixture, "Stale owner")
	assert_true(stale_fixture["presenter"].complete_typewriter())
	assert_true(stale_activation.abort())
	var stale_fallbacks := _capture_advance_notifications()

	_dispatch(stale_fixture["handler"], _key_event(KEY_SPACE))

	assert_eq(stale_fallbacks[0], 1,
		"a resolved owner yields exactly one wait-click fallback")
	assert_null(stale_fixture["presenter"]._current_dialogue_activation)
	assert_true(stale_fixture["viewport"].is_input_handled())


func _create_fixture() -> Dictionary:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280, 720)
	viewport.handle_input_locally = true
	add_child(viewport)
	_viewports.append(viewport)
	var game := GAME_SCENE.instantiate()
	viewport.add_child(game)
	await get_tree().process_frame
	return {
		"viewport": viewport,
		"game": game,
		"presenter": game.get_node("%DialoguePanel"),
		"handler": game.get_node("InputHandler"),
	}


func _dispose_fixture(fixture: Dictionary) -> void:
	var viewport: SubViewport = fixture["viewport"]
	if is_instance_valid(viewport):
		viewport.queue_free()
	await get_tree().process_frame


func _begin_owned_typing(
	fixture: Dictionary,
	text: String,
	expect_typing_after_dispatch: bool = true,
) -> DialogueActivation:
	_request_serial += 1
	var activation := DialogueActivation.new()
	SignalBus.emit_dialogue_request(DialogueRequest.new(
		"",
		[_segment(text)],
		"adv",
		{},
		false,
		"",
		{},
		[],
		"issue136:%d" % _request_serial,
		_request_serial,
		activation,
	))
	assert_same(fixture["presenter"]._current_dialogue_activation, activation)
	if expect_typing_after_dispatch:
		assert_true(fixture["presenter"]._is_typing,
			"SHOW synchronously establishes an active typing owner")
	return activation


func _normal_input_cases() -> Array[Dictionary]:
	return [
		{"label": "left click", "event": _mouse_event()},
		{"label": "Space", "event": _key_event(KEY_SPACE)},
		{"label": "Enter", "event": _key_event(KEY_ENTER)},
		{"label": "Joy A", "event": _joy_event()},
	]


func _mouse_event(position: Vector2 = Vector2.ZERO) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = position
	return event


func _key_event(keycode: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	event.echo = false
	return event


func _joy_event() -> InputEventJoypadButton:
	var event := InputEventJoypadButton.new()
	event.button_index = JOY_BUTTON_A
	event.pressed = true
	event.device = 7
	return event


func _dispatch(handler: Node, event: InputEvent) -> void:
	if event is InputEventMouseButton:
		handler._input(event)
	else:
		handler._unhandled_input(event)


func _capture_advance_notifications() -> Array[int]:
	var count: Array[int] = [0]
	var callback := func() -> void: count[0] += 1
	_connect_tracked(SignalBus.advance_requested, callback)
	return count


func _connect_tracked(signal_value: Signal, callback: Callable) -> void:
	signal_value.connect(callback)
	_signal_callbacks.append({"signal": signal_value, "callback": callback})


func _disconnect_tracked(signal_value: Signal, callback: Callable) -> void:
	if signal_value.is_connected(callback):
		signal_value.disconnect(callback)
	for index in range(_signal_callbacks.size() - 1, -1, -1):
		if _signal_callbacks[index]["callback"] == callback:
			_signal_callbacks.remove_at(index)
			return


func _segment(text: String) -> Dictionary:
	return {"text": text, "voice_layers": [], "presentation_ops": []}


func _single_dialogue_scenario(scenario_id: String, text: String) -> ScenarioData:
	var data := ScenarioData.new()
	data.id = scenario_id
	var scene := SceneData.new()
	scene.id = "start"
	var command := CommandData.new()
	command.type = "dialogue"
	command.params = {"text": text}
	scene.commands = [command]
	data.scenes = [scene]
	data.assign_command_uids()
	return data
