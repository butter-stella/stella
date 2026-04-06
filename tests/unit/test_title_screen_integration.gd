extends GutTest
## Tests for title screen integration — signal bridging, state returns.


func test_scenario_ended_bridges_to_signal_bus():
	# StellaRuntime should bridge engine.scenario_ended to SignalBus
	var received: Array = []
	var bus = get_tree().root.get_node("SignalBus")
	bus.scenario_ended_event.connect(func(id): received.append(id))

	# Simulate engine scenario_ended
	var runtime = get_tree().root.get_node("StellaRuntime")
	runtime.engine.scenario_ended.emit("test_scenario")

	assert_eq(received, ["test_scenario"])


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
