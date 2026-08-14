extends GutTest
## Tests for title screen integration — signal bridging, state returns.


func test_scenario_ended_bridges_to_signal_bus():
	# StellaRuntime should bridge engine.scenario_ended to SignalBus
	var received: Array = []
	var bus = get_tree().root.get_node("SignalBus")
	var listener := func(id: String) -> void: received.append(id)
	bus.scenario_ended_event.connect(listener)

	# Drive a real active run; forged/stale lifecycle emissions are intentionally
	# ignored by StellaRuntime.
	var runtime = get_tree().root.get_node("StellaRuntime")
	runtime.engine.scenario_ended.emit("forged")
	assert_eq(received, [])
	var scenario := ScenarioData.new()
	scenario.id = "test_scenario"
	runtime.engine.load_scenario(scenario)
	runtime.engine.run()

	assert_eq(received, ["test_scenario"])
	var cleanup_navigation: int = runtime._begin_navigation("test_cleanup")
	runtime._cancel_active_gameplay()
	runtime._finish_navigation(cleanup_navigation)
	if bus.scenario_ended_event.is_connected(listener):
		bus.scenario_ended_event.disconnect(listener)


func test_scenario_ended_bus_reentrancy_cannot_append_stale_title_return():
	var bus := get_tree().root.get_node("SignalBus")
	var runtime := get_tree().root.get_node("StellaRuntime")
	var replacement_navigations: Array[int] = []
	var listener := func(_id: String) -> void:
		replacement_navigations.append(
			runtime._begin_navigation("ended_replacement"),
		)
	bus.scenario_ended_event.connect(listener, CONNECT_ONE_SHOT)

	var scenario := ScenarioData.new()
	scenario.id = "reentrant_end"
	runtime.engine.load_scenario(scenario)
	runtime.engine.run()

	assert_eq(replacement_navigations.size(), 1)
	assert_gt(replacement_navigations[0], 0)
	assert_eq(runtime._navigation_kind, "ended_replacement")
	assert_false(runtime._return_to_title_pending)
	runtime._cancel_active_gameplay()
	runtime._finish_navigation(replacement_navigations[0])


func test_game_state_stores_previous_state():
	var gsm = GameStateMachine.new()
	gsm.transition_to(GameStateMachine.State.PLAYING)
	gsm.transition_to(GameStateMachine.State.SETTINGS)
	assert_eq(gsm.previous_state, GameStateMachine.State.PLAYING)

	gsm.transition_to(GameStateMachine.State.PLAYING)
	gsm.transition_to(GameStateMachine.State.SAVE_LOAD)
	assert_eq(gsm.previous_state, GameStateMachine.State.PLAYING)


func test_game_state_return_to_previous():
	var gsm = GameStateMachine.new()
	gsm.transition_to(GameStateMachine.State.PLAYING)
	gsm.transition_to(GameStateMachine.State.SETTINGS)
	gsm.return_to_previous()
	assert_eq(gsm.current_state, GameStateMachine.State.PLAYING)


func test_game_state_return_from_title_overlay():
	# When settings is opened from TITLE, closing should return to TITLE
	var gsm = GameStateMachine.new()
	# State is TITLE by default
	gsm.transition_to(GameStateMachine.State.SETTINGS)
	assert_eq(gsm.previous_state, GameStateMachine.State.TITLE)
	gsm.return_to_previous()
	assert_eq(gsm.current_state, GameStateMachine.State.TITLE)
