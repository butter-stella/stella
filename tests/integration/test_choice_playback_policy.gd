extends GutTest
## Cross-layer regression coverage for issue #139's choice modal and playback
## policy.  Tests use the existing public controller state/facade queries and
## synthetic options only; no typed ChoiceRequest API is assumed.

const GAME_SCENE := preload("res://addons/stella/scenes/game.tscn")
const RuntimeTestSupport = preload("res://tests/helpers/runtime_test_support.gd")

var _contexts: Array[ScenarioContext] = []
var _viewports: Array[SubViewport] = []
var _connections: Array[Dictionary] = []
var _request_serial: int = 0


func before_each() -> void:
	await RuntimeTestSupport.reset_for_test(StellaRuntime, get_tree())
	_contexts.clear()
	_viewports.clear()
	_connections.clear()
	_request_serial = 0
	StellaRuntime.game_state.current_state = GameStateMachine.State.PLAYING
	StellaRuntime.game_state.previous_state = GameStateMachine.State.PLAYING
	StellaRuntime.set_setting("character_interval", 1000)
	StellaRuntime.set_setting("punctuation_pause", 0)
	StellaRuntime.set_setting("click_to_complete", true)
	StellaRuntime.set_setting("auto_play_delay", 0.06)
	StellaRuntime.set_setting("auto_play_wait_voice", false)
	StellaRuntime.set_setting("skip_interval", 60)
	StellaRuntime.set_setting("skip_only_read", false)
	StellaRuntime.set_setting("auto_play_pause_on_choice", true)
	StellaRuntime.set_setting("skip_stop_on_choice", true)


func after_each() -> void:
	for record in _connections:
		var signal_value: Signal = record["signal"]
		var callback: Callable = record["callback"]
		if signal_value.is_connected(callback):
			signal_value.disconnect(callback)
	for context in _contexts:
		if context != null and not context.is_cancellation_requested():
			context.request_cancellation()
	SignalBus.choice_hide.emit()
	SignalBus.hide_dialogue.emit()
	SignalBus.engine_abort_requested.emit()
	StellaRuntime.auto_play.stop()
	StellaRuntime.skip_controller.stop()
	for viewport in _viewports:
		if is_instance_valid(viewport):
			viewport.queue_free()
	await get_tree().process_frame
	_contexts.clear()
	_viewports.clear()
	_connections.clear()


func test_four_setting_combinations_keep_independent_three_phase_state() -> void:
	for auto_pause in [false, true]:
		for skip_stop in [false, true]:
			StellaRuntime.set_setting(
				"auto_play_pause_on_choice", auto_pause)
			StellaRuntime.set_setting("skip_stop_on_choice", skip_stop)
			for source in ["auto", "skip", "neither"]:
				StellaRuntime.auto_play.stop()
				StellaRuntime.skip_controller.stop()
				if source == "auto":
					StellaRuntime.auto_play.is_active = true
				elif source == "skip":
					StellaRuntime.skip_controller.is_active = true

				_assert_controller_phase(
					"before", source, true, true)
				var session := _start_choice()
				assert_false(session["finished"][0],
					"choice must await an explicit option")
				_assert_controller_phase(
					"awaiting auto=%s skip=%s" % [auto_pause, skip_stop],
					source,
					not auto_pause,
					not skip_stop,
				)

				SignalBus.choice_selected.emit("valid")
				await get_tree().process_frame
				assert_true(session["finished"][0],
					"a valid option completes the choice")
				_assert_controller_phase(
					"resolved auto=%s skip=%s" % [auto_pause, skip_stop],
					source,
					true,
					not skip_stop,
				)


func test_choice_policy_is_frozen_per_session_and_next_choice_reads_latest() -> void:
	for initial_stop_policy in [false, true]:
		StellaRuntime.auto_play.stop()
		StellaRuntime.skip_controller.stop()
		StellaRuntime.set_setting(
			"auto_play_pause_on_choice", initial_stop_policy)
		StellaRuntime.set_setting(
			"skip_stop_on_choice", initial_stop_policy)
		StellaRuntime.auto_play.is_active = true
		StellaRuntime.skip_controller.is_active = true
		var first := _start_choice("first")

		assert_true(StellaRuntime.auto_play.is_active)
		assert_true(StellaRuntime.is_auto_playing())
		assert_eq(_auto_is_effective(), not initial_stop_policy)
		assert_eq(
			StellaRuntime.skip_controller.is_active,
			not initial_stop_policy,
		)
		StellaRuntime.set_setting(
			"auto_play_pause_on_choice", not initial_stop_policy)
		StellaRuntime.set_setting(
			"skip_stop_on_choice", not initial_stop_policy)
		assert_eq(_auto_is_effective(), not initial_stop_policy,
			"a live setting edit cannot add or release this choice's token")
		assert_eq(
			StellaRuntime.skip_controller.is_active,
			not initial_stop_policy,
			"a live setting edit cannot retroactively stop or revive Skip",
		)

		SignalBus.choice_selected.emit("first")
		await get_tree().process_frame
		assert_true(first["finished"][0])
		assert_true(StellaRuntime.auto_play.is_active)
		assert_true(_auto_is_effective(),
			"normal resolution releases the first choice's exact token")
		assert_eq(StellaRuntime.skip_controller.is_active,
			not initial_stop_policy)

		# Re-enable both user intents so the next SHOW observes only the newly
		# configured policy, independent of the prior choice's terminal state.
		StellaRuntime.auto_play.is_active = true
		StellaRuntime.skip_controller.is_active = true
		var choice_connections := (
			SignalBus.choice_selected.get_connections().size())
		var abort_connections := (
			SignalBus.engine_abort_requested.get_connections().size())
		var second := _start_choice("second")
		assert_true(StellaRuntime.auto_play.is_active)
		assert_eq(_auto_is_effective(), initial_stop_policy,
			"the next choice snapshots the latest Auto policy")
		assert_eq(StellaRuntime.skip_controller.is_active,
			initial_stop_policy,
			"the next choice snapshots the latest Skip policy")

		second["context"].request_cancellation()
		await get_tree().process_frame
		assert_true(second["finished"][0])
		assert_false(StellaRuntime.auto_play.is_active,
			"non-option cancellation fail-closes retained Auto intent")
		assert_false(StellaRuntime.skip_controller.is_active,
			"non-option cancellation fail-closes retained Skip intent")
		assert_eq(SignalBus.choice_selected.get_connections().size(),
			choice_connections)
		assert_eq(SignalBus.engine_abort_requested.get_connections().size(),
			abort_connections)
		assert_eq(
			second["context"].cancellation_requested.get_connections().size(),
			0,
		)


func test_policy_is_installed_before_synchronous_valid_selection() -> void:
	StellaRuntime.set_setting("auto_play_pause_on_choice", true)
	StellaRuntime.set_setting("skip_stop_on_choice", true)
	StellaRuntime.auto_play.is_active = true
	StellaRuntime.skip_controller.is_active = true
	var observed: Array[Dictionary] = []
	var on_show := func(_prompt: String, _options: Array) -> void:
		observed.append({
			"auto_intent": StellaRuntime.auto_play.is_active,
			"auto_facade": StellaRuntime.is_auto_playing(),
			"auto_effective": _auto_is_effective(),
			"skip_active": StellaRuntime.skip_controller.is_active,
			"skip_effective": StellaRuntime.is_skipping(),
		})
		SignalBus.choice_selected.emit("valid")
	_connect_tracked(SignalBus.choice_show, on_show, CONNECT_ONE_SHOT)

	var session := _start_choice()
	await get_tree().process_frame

	assert_eq(observed.size(), 1)
	if not observed.is_empty():
		assert_true(observed[0]["auto_intent"],
			"Auto pause preserves user intent before SHOW listeners")
		assert_true(observed[0]["auto_facade"],
			"the public facade continues to expose Auto intent")
		assert_false(observed[0]["auto_effective"],
			"the choice suspension is effective before SHOW listeners")
		assert_false(observed[0]["skip_active"],
			"Skip stop precedes SHOW listeners")
		assert_false(observed[0]["skip_effective"])
		assert_true(session["finished"][0],
		"a synchronous valid selection remains observable")
	assert_true(StellaRuntime.auto_play.is_active)
	assert_true(StellaRuntime.is_auto_playing(),
		"normal resolution releases only this choice's Auto suspension")
	assert_false(StellaRuntime.skip_controller.is_active,
		"choice-stopped Skip never resumes")


func test_nested_replacement_show_cannot_be_overwritten_by_outer_signal_tail() -> void:
	var replacement_started := [false]
	var fresh_context: Array[ScenarioContext] = [null]
	var on_outer_show := func(_prompt: String, _options: Array) -> void:
		if replacement_started[0]:
			return
		replacement_started[0] = true
		# Model the production context-transfer boundary while the outer SHOW is
		# still dispatching. The replacement engine run synchronously publishes a
		# fresh SHOW before listeners later in the outer signal have executed.
		StellaRuntime._begin_choice_hard_boundary()
		StellaRuntime.engine.load_scenario(
			_modal_choice_scenario("Fresh choice", "fresh"))
		fresh_context[0] = StellaRuntime.engine.context
		StellaRuntime._finish_choice_hard_boundary(false)
		StellaRuntime.engine.run()
	_connect_tracked(SignalBus.choice_show, on_outer_show)
	# Instantiate after the replacement callback so it runs before the built-in
	# presenter in SignalBus connection order.
	var fixture := await _create_game_fixture()
	var selections := _capture_choice_selections()
	StellaRuntime.engine.load_scenario(
		_modal_choice_scenario("Outer choice", "outer"))
	var outer_context: ScenarioContext = StellaRuntime.engine.context
	StellaRuntime.engine.run()
	await get_tree().process_frame

	assert_true(replacement_started[0])
	assert_true(outer_context.is_cancellation_requested(),
		"the synchronous context transfer retires the outer owner")
	assert_same(StellaRuntime.engine.context, fresh_context[0])
	assert_true(StellaRuntime.is_choice_active())
	assert_true(fixture["choice_panel"].visible)
	var current_button: Button = _choice_buttons(fixture)[0]
	assert_eq(current_button.text, "Fresh",
		"the stale outer SHOW tail cannot repaint over the fresh owner")

	current_button.pressed.emit()
	await get_tree().process_frame

	assert_eq(selections, ["fresh"],
		"the visible option must commit only the fresh semantic owner")
	assert_eq(fresh_context[0].current_command_index, 1,
		"the fresh choice advances exactly once to its click wait")
	assert_false(StellaRuntime.is_choice_active())
	assert_false(fixture["choice_panel"].visible)
	fresh_context[0].request_cancellation()
	await _dispose_fixture(fixture)


func test_synchronous_abort_and_context_replacement_fail_closed() -> void:
	for boundary in ["abort", "replace"]:
		StellaRuntime.set_setting("auto_play_pause_on_choice", true)
		StellaRuntime.set_setting("skip_stop_on_choice", false)
		StellaRuntime.auto_play.is_active = true
		StellaRuntime.skip_controller.is_active = true
		var data := _choice_scenario()
		var context := ScenarioContext.new(data)
		context.variable_store = VariableStore.new()
		_contexts.append(context)
		var engine := ScenarioEngine.new()
		engine.context = context
		var choice_connections := (
			SignalBus.choice_selected.get_connections().size())
		var abort_connections := (
			SignalBus.engine_abort_requested.get_connections().size())
		var cancellation_connections := (
			context.cancellation_requested.get_connections().size())
		var replacement: ScenarioContext = null
		var on_show := func(_prompt: String, _options: Array) -> void:
			if boundary == "abort":
				SignalBus.engine_abort_requested.emit()
			else:
				replacement = ScenarioContext.new(data)
				engine.context = replacement
		_connect_tracked(SignalBus.choice_show, on_show, CONNECT_ONE_SHOT)
		var finished := [false]
		var run := func() -> void:
			await _choice_handler().execute(
				data.scenes[0].commands[0], context)
			finished[0] = true
		run.call()
		await get_tree().process_frame

		assert_true(finished[0], "%s retires the old choice" % boundary)
		assert_false(StellaRuntime.auto_play.is_active,
			"%s clears Auto intent instead of releasing stale pause" % boundary)
		assert_false(StellaRuntime.is_auto_playing())
		assert_false(_auto_is_effective())
		assert_false(StellaRuntime.skip_controller.is_active,
			"%s fail-closes retained Skip" % boundary)
		assert_false(StellaRuntime.is_skipping())
		assert_eq(SignalBus.choice_selected.get_connections().size(),
			choice_connections)
		assert_eq(SignalBus.engine_abort_requested.get_connections().size(),
			abort_connections)
		assert_eq(context.cancellation_requested.get_connections().size(),
			cancellation_connections)
		SignalBus.choice_selected.emit("valid")
		await get_tree().process_frame
		assert_false(StellaRuntime.auto_play.is_active,
			"a late option cannot revive Auto after %s" % boundary)
		assert_false(StellaRuntime.skip_controller.is_active,
			"a late option cannot revive Skip after %s" % boundary)
		if replacement != null:
			replacement.request_cancellation()
		StellaRuntime.auto_play.stop()
		StellaRuntime.skip_controller.stop()


func test_background_advance_inputs_are_consumed_by_choice_modal() -> void:
	for input_case in _normal_input_cases():
		var fixture := await _create_game_fixture()
		var activation := _begin_owned_typing(
			fixture, "Choice owns normal advance input")
		var presenter: Control = fixture["presenter"]
		var generation: int = presenter._dialogue_gen
		var visible_before: int = presenter.text_label.visible_characters
		var session := _start_choice()
		var selections := _capture_choice_selections()
		var advances := _capture_advance_notifications()

		_dispatch(fixture["handler"], input_case["event"])

		assert_true(fixture["choice_panel"].visible)
		assert_false(session["finished"][0],
			"%s cannot choose implicitly" % input_case["label"])
		assert_eq(selections, [],
			"%s cannot select the first option" % input_case["label"])
		assert_eq(advances[0], 0,
			"%s cannot leak to wait-click/global advance" % input_case["label"])
		assert_true(activation.is_pending(),
			"%s cannot advance the dialogue beneath the modal" % input_case["label"])
		assert_true(presenter._is_typing)
		assert_eq(presenter._dialogue_gen, generation)
		assert_eq(presenter.text_label.visible_characters, visible_before)
		assert_true(fixture["viewport"].is_input_handled(),
			"the choice owner consumes %s" % input_case["label"])
		session["context"].request_cancellation()
		activation.abort()
		await _dispose_fixture(fixture)


func test_option_activation_requires_current_visible_enabled_button() -> void:
	for rejected_state in ["disabled", "hidden"]:
		var fixture := await _create_game_fixture()
		var session := _start_choice()
		var selections := _capture_choice_selections()
		var button: Button = _choice_buttons(fixture)[0]
		assert_true(await _wait_for_button_layout(fixture, button))
		var button_center := button.get_global_rect().get_center()
		if rejected_state == "disabled":
			button.disabled = true
		else:
			button.visible = false

		await _push_gui_click(fixture["viewport"], button_center)

		assert_eq(selections, [],
			"a %s option is not an activation" % rejected_state)
		assert_false(session["finished"][0])
		assert_true(fixture["choice_panel"].visible)
		session["context"].request_cancellation()
		await _dispose_fixture(fixture)

	var valid_fixture := await _create_game_fixture()
	var valid_session := _start_choice()
	var valid_selections := _capture_choice_selections()
	var valid_button: Button = _choice_buttons(valid_fixture)[0]
	# This direct semantic callback intentionally bypasses GUI routing: unlike
	# the rejected-state clicks above, it locks the current-presenter generation
	# gate so duplicate callbacks from one option can commit at most once.
	valid_button.pressed.emit()
	valid_button.pressed.emit()
	await get_tree().process_frame
	assert_eq(valid_selections, ["valid"],
		"one current enabled activation resolves exactly once")
	assert_true(valid_session["finished"][0])
	await _dispose_fixture(valid_fixture)


func test_focused_option_accepts_each_supported_ui_input_once() -> void:
	for input_case in _normal_input_cases():
		var fixture := await _create_game_fixture()
		var session := _start_choice()
		var selections := _capture_choice_selections()
		var advances := _capture_advance_notifications()
		var button: Button = _choice_buttons(fixture)[0]
		assert_true(await _wait_for_button_layout(fixture, button))
		if input_case["event"] is InputEventMouseButton:
			var center := button.get_global_rect().get_center()
			var motion := InputEventMouseMotion.new()
			motion.position = center
			fixture["viewport"].push_input(motion, true)
			await get_tree().process_frame
			var mouse := input_case["event"] as InputEventMouseButton
			mouse.position = center
		else:
			button.grab_focus()
			assert_same(fixture["viewport"].gui_get_focus_owner(), button)

		await _push_gui_press_release(
			fixture["viewport"], input_case["event"])

		assert_eq(selections, ["valid"],
			"%s activates the explicitly targeted option" % input_case["label"])
		assert_true(session["finished"][0])
		assert_eq(advances[0], 0,
			"the accepted option cannot leak to dialogue/wait input")
		await _dispose_fixture(fixture)


func test_stale_button_cannot_resolve_replacement_choice() -> void:
	var fixture := await _create_game_fixture()
	var first := _start_choice("old")
	var stale_button: Button = _choice_buttons(fixture)[0]
	first["context"].request_cancellation()
	var second := _start_choice("new")
	var replacement_buttons := _choice_buttons(fixture, false)
	var current_button: Button = replacement_buttons.back()
	var selections := _capture_choice_selections()

	stale_button.pressed.emit()

	assert_eq(selections, [], "a retired button emits no semantic selection")
	assert_false(second["finished"][0],
		"a stale activation cannot resolve the replacement owner")
	assert_true(fixture["choice_panel"].visible)
	current_button.pressed.emit()
	await get_tree().process_frame
	assert_eq(selections, ["new"])
	assert_true(second["finished"][0])
	await _dispose_fixture(fixture)


func test_choice_retires_old_auto_timer_and_next_line_starts_fresh() -> void:
	for pause_on_choice in [false, true]:
		StellaRuntime.set_setting("character_interval", 0)
		StellaRuntime.set_setting(
			"auto_play_pause_on_choice", pause_on_choice)
		var fixture := await _create_game_fixture()
		StellaRuntime.auto_play.is_active = true
		SignalBus.show_dialogue.emit("", [_segment("old auto timer")], "adv")
		assert_true(await wait_until(
			func() -> bool:
				return fixture["presenter"]._auto_pending_dialogue_gen \
					== fixture["presenter"]._dialogue_gen,
			0.5,
			"the authored Auto delay is pending before choice",
		))
		var advances := _capture_advance_notifications()
		var session := _start_choice()

		await get_tree().create_timer(0.09).timeout

		assert_eq(advances[0], 0,
			"the old Auto timer cannot act on the choice owner")
		assert_false(session["finished"][0])
		assert_true(StellaRuntime.auto_play.is_active)
		assert_true(StellaRuntime.is_auto_playing(),
			"the public facade preserves Auto intent while choice is modal")
		assert_eq(_auto_is_effective(), not pause_on_choice,
			"only pause=true suspends Auto execution")
		SignalBus.choice_selected.emit("valid")
		await get_tree().process_frame
		assert_true(StellaRuntime.auto_play.is_active)
		assert_true(StellaRuntime.is_auto_playing())
		assert_true(_auto_is_effective())

		var before_new_line: int = advances[0]
		SignalBus.show_dialogue.emit("", [_segment("fresh auto timer")], "adv")
		assert_true(await wait_until(
			func() -> bool: return advances[0] == before_new_line + 1,
			0.5,
			"the next line starts a complete fresh Auto delay",
		))
		StellaRuntime.auto_play.stop()
		await _dispose_fixture(fixture)


func test_choice_retires_old_skip_timer_and_stop_never_resumes() -> void:
	for stop_on_choice in [false, true]:
		StellaRuntime.set_setting("character_interval", 0)
		StellaRuntime.set_setting("skip_stop_on_choice", stop_on_choice)
		var fixture := await _create_game_fixture()
		StellaRuntime.skip_controller.is_active = true
		SignalBus.show_dialogue.emit("", [_segment("old skip timer")], "adv")
		assert_true(await wait_until(
			func() -> bool:
				return fixture["presenter"]._skip_pending_dialogue_gen \
					== fixture["presenter"]._dialogue_gen,
			0.5,
			"the authored Skip delay is pending before choice",
		))
		var advances := _capture_advance_notifications()
		fixture["presenter"]._ctrl_held = true
		assert_true(fixture["presenter"]._ctrl_held)
		var session := _start_choice()

		await get_tree().create_timer(0.09).timeout

		assert_eq(advances[0], 0,
			"the old Skip timer cannot act on the choice owner")
		assert_false(session["finished"][0])
		assert_eq(StellaRuntime.skip_controller.is_active, not stop_on_choice)
		assert_eq(StellaRuntime.is_skipping(), not stop_on_choice)
		if stop_on_choice:
			assert_false(fixture["presenter"]._ctrl_held,
				"stopping Skip at choice clears held-Ctrl state")
		SignalBus.choice_selected.emit("valid")
		await get_tree().process_frame
		assert_eq(StellaRuntime.skip_controller.is_active, not stop_on_choice,
			"choice-stopped Skip never resumes after resolution")

		if not stop_on_choice:
			var before_new_line: int = advances[0]
			SignalBus.show_dialogue.emit(
				"", [_segment("fresh skip timer")], "adv")
			assert_true(await wait_until(
				func() -> bool: return advances[0] == before_new_line + 1,
				0.5,
				"retained Skip starts a fresh next-line delay",
			))
		StellaRuntime.skip_controller.stop()
		await _dispose_fixture(fixture)


func test_enabling_playback_during_choice_cannot_start_old_dialogue_tail() -> void:
	for source in ["auto", "skip"]:
		StellaRuntime.set_setting("character_interval", 0)
		StellaRuntime.set_setting("auto_play_pause_on_choice", true)
		StellaRuntime.set_setting("skip_stop_on_choice", false)
		var fixture := await _create_game_fixture()
		SignalBus.show_dialogue.emit(
			"", [_segment("ready beneath choice")], "adv")
		assert_true(await wait_until(
			func() -> bool: return fixture["presenter"]._dialogue_ready,
			0.5,
			"the old dialogue is ready before the modal boundary",
		))
		var advances := _capture_advance_notifications()
		var session := _start_choice()

		if source == "auto":
			StellaRuntime.toggle_auto_play()
			assert_true(StellaRuntime.auto_play.is_active)
			assert_true(StellaRuntime.is_auto_playing(),
				"the public facade preserves newly enabled intent")
			assert_false(_auto_is_effective(),
				"the current choice token suspends newly enabled Auto")
		else:
			StellaRuntime.toggle_skip()
			assert_true(StellaRuntime.skip_controller.is_active)

		await get_tree().create_timer(0.09).timeout

		assert_eq(advances[0], 0,
			"enabling %s cannot revive the pre-choice dialogue tail" % source)
		assert_false(session["finished"][0])
		session["context"].request_cancellation()
		StellaRuntime.auto_play.stop()
		StellaRuntime.skip_controller.stop()
		await _dispose_fixture(fixture)


func _assert_controller_phase(
	phase: String,
	source: String,
	_auto_effective_if_active: bool,
	skip_effective_if_active: bool,
) -> void:
	if source == "auto":
		assert_true(StellaRuntime.auto_play.is_active,
			"%s: Auto intent remains active" % phase)
		assert_true(StellaRuntime.is_auto_playing(),
			"%s: public facade preserves Auto intent" % phase)
		assert_eq(
			_auto_is_effective(),
			_auto_effective_if_active,
			"%s: Auto effective state" % phase,
		)
		assert_false(StellaRuntime.skip_controller.is_active)
	elif source == "skip":
		assert_false(StellaRuntime.auto_play.is_active)
		assert_eq(
			StellaRuntime.skip_controller.is_active,
			skip_effective_if_active,
			"%s: Skip intent/state" % phase,
		)
		assert_eq(
			StellaRuntime.is_skipping(),
			skip_effective_if_active,
			"%s: Skip effective state" % phase,
		)
	else:
		assert_false(StellaRuntime.auto_play.is_active,
			"%s: inactive Auto stays inactive" % phase)
		assert_false(StellaRuntime.is_auto_playing())
		assert_false(_auto_is_effective())
		assert_false(StellaRuntime.skip_controller.is_active,
			"%s: inactive Skip stays inactive" % phase)
		assert_false(StellaRuntime.is_skipping())


func _start_choice(option_id: String = "valid") -> Dictionary:
	var data := _choice_scenario(option_id)
	var context := ScenarioContext.new(data)
	context.variable_store = VariableStore.new()
	_contexts.append(context)
	var finished := [false]
	var run := func() -> void:
		await _choice_handler().execute(data.scenes[0].commands[0], context)
		finished[0] = true
	run.call()
	return {"context": context, "finished": finished}


func _choice_handler() -> ChoiceHandler:
	var handler := StellaRuntime.registry.get_handler("choice") as ChoiceHandler
	assert_not_null(handler,
		"the composition root must provide the production choice handler")
	return handler


func _auto_is_effective() -> bool:
	return StellaRuntime.auto_play.is_effective()


func _choice_scenario(option_id: String = "valid") -> ScenarioData:
	var data := ScenarioData.new()
	data.id = "issue139_choice_policy"
	var scene := SceneData.new()
	scene.id = "start"
	var command := CommandData.new()
	command.type = "choice"
	command.params = {
		"prompt": "Choose explicitly",
		"options": [{
			"id": option_id,
			"label": option_id.capitalize(),
			"jump": "selected_scene",
		}],
	}
	scene.commands = [command]
	data.scenes = [scene]
	return data


func _modal_choice_scenario(prompt: String, option_id: String) -> ScenarioData:
	var data := ScenarioData.new()
	data.id = "issue139_nested_choice_%s" % option_id
	var scene := SceneData.new()
	scene.id = "start"
	var choice := CommandData.new()
	choice.type = "choice"
	choice.params = {
		"prompt": prompt,
		"options": [{
			"id": option_id,
			"label": option_id.capitalize(),
		}],
	}
	var wait := CommandData.new()
	wait.type = "wait"
	wait.params = {"mode": "click"}
	scene.commands = [choice, wait]
	data.scenes = [scene]
	return data


func _create_game_fixture() -> Dictionary:
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
		"choice_panel": game.get_node("UILayer/ChoicePanel"),
		"handler": game.get_node("InputHandler"),
	}


func _dispose_fixture(fixture: Dictionary) -> void:
	var viewport: SubViewport = fixture["viewport"]
	if is_instance_valid(viewport):
		viewport.queue_free()
	await get_tree().process_frame


func _begin_owned_typing(fixture: Dictionary, text: String) -> DialogueActivation:
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
		"issue139:%d" % _request_serial,
		_request_serial,
		activation,
	))
	assert_same(fixture["presenter"]._current_dialogue_activation, activation)
	assert_true(fixture["presenter"]._is_typing)
	return activation


func _choice_buttons(
	fixture: Dictionary,
	expect_single: bool = true,
) -> Array[Button]:
	var buttons: Array[Button] = []
	var container: VBoxContainer = (
		fixture["choice_panel"].get_node("%OptionsContainer"))
	for child in container.get_children():
		if child is Button:
			buttons.append(child)
	if expect_single:
		assert_eq(buttons.size(), 1)
	else:
		assert_gte(buttons.size(), 1)
	return buttons


func _wait_for_button_layout(
	fixture: Dictionary,
	button: Button,
) -> bool:
	var choice_panel: Control = fixture["choice_panel"]
	return await wait_until(
		func() -> bool:
			return (
				choice_panel.visible
				and button.is_inside_tree()
				and button.is_visible_in_tree()
				and button.get_global_rect().size.x > 0.0
				and button.get_global_rect().size.y > 0.0
			),
		0.5,
		"the current option has an authoritative GUI hit rectangle",
	)


func _normal_input_cases() -> Array[Dictionary]:
	return [
		{"label": "left click", "event": _mouse_event()},
		{"label": "Space", "event": _key_event(KEY_SPACE)},
		{"label": "Enter", "event": _key_event(KEY_ENTER)},
		{"label": "Joy A", "event": _joy_event()},
	]


func _mouse_event() -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = Vector2(20, 20)
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


func _push_gui_click(viewport: SubViewport, position: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = position
	viewport.push_input(motion, true)
	await get_tree().process_frame
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = position
	await _push_gui_press_release(viewport, event)


func _push_gui_press_release(
	viewport: SubViewport,
	event: InputEvent,
) -> void:
	viewport.push_input(event, true)
	await get_tree().process_frame
	var release: InputEvent = event.duplicate()
	if release is InputEventMouseButton:
		(release as InputEventMouseButton).pressed = false
	elif release is InputEventKey:
		(release as InputEventKey).pressed = false
	elif release is InputEventJoypadButton:
		(release as InputEventJoypadButton).pressed = false
	viewport.push_input(release, true)
	await get_tree().process_frame


func _capture_choice_selections() -> Array[String]:
	var selected: Array[String] = []
	var callback := func(option_id: String) -> void: selected.append(option_id)
	_connect_tracked(SignalBus.choice_selected, callback)
	return selected


func _capture_advance_notifications() -> Array[int]:
	var count: Array[int] = [0]
	var callback := func() -> void: count[0] += 1
	_connect_tracked(SignalBus.advance_requested, callback)
	return count


func _connect_tracked(
	signal_value: Signal,
	callback: Callable,
	flags: int = 0,
) -> void:
	signal_value.connect(callback, flags)
	_connections.append({"signal": signal_value, "callback": callback})


func _segment(text: String) -> Dictionary:
	return {"text": text, "voice_layers": [], "presentation_ops": []}
