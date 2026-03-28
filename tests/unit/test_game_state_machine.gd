extends GutTest
## Tests for GameStateMachine — manages macro game flow.


var _gsm: GameStateMachine


func before_each():
	_gsm = GameStateMachine.new()


func test_initial_state_is_title():
	assert_eq(_gsm.current_state, GameStateMachine.State.TITLE)


func test_transition_title_to_playing():
	_gsm.transition_to(GameStateMachine.State.PLAYING)
	assert_eq(_gsm.current_state, GameStateMachine.State.PLAYING)


func test_transition_playing_to_paused():
	_gsm.transition_to(GameStateMachine.State.PLAYING)
	_gsm.transition_to(GameStateMachine.State.PAUSED)
	assert_eq(_gsm.current_state, GameStateMachine.State.PAUSED)


func test_transition_paused_to_playing():
	_gsm.transition_to(GameStateMachine.State.PLAYING)
	_gsm.transition_to(GameStateMachine.State.PAUSED)
	_gsm.transition_to(GameStateMachine.State.PLAYING)
	assert_eq(_gsm.current_state, GameStateMachine.State.PLAYING)


func test_transition_playing_to_save_load():
	_gsm.transition_to(GameStateMachine.State.PLAYING)
	_gsm.transition_to(GameStateMachine.State.SAVE_LOAD)
	assert_eq(_gsm.current_state, GameStateMachine.State.SAVE_LOAD)


func test_transition_save_load_to_playing():
	_gsm.transition_to(GameStateMachine.State.PLAYING)
	_gsm.transition_to(GameStateMachine.State.SAVE_LOAD)
	_gsm.transition_to(GameStateMachine.State.PLAYING)
	assert_eq(_gsm.current_state, GameStateMachine.State.PLAYING)


func test_transition_playing_to_backlog():
	_gsm.transition_to(GameStateMachine.State.PLAYING)
	_gsm.transition_to(GameStateMachine.State.BACKLOG)
	assert_eq(_gsm.current_state, GameStateMachine.State.BACKLOG)


func test_transition_playing_to_settings():
	_gsm.transition_to(GameStateMachine.State.PLAYING)
	_gsm.transition_to(GameStateMachine.State.SETTINGS)
	assert_eq(_gsm.current_state, GameStateMachine.State.SETTINGS)


func test_transition_back_to_title():
	_gsm.transition_to(GameStateMachine.State.PLAYING)
	_gsm.transition_to(GameStateMachine.State.TITLE)
	assert_eq(_gsm.current_state, GameStateMachine.State.TITLE)


func test_transition_emits_signal():
	var transitions: Array = []
	_gsm.state_changed.connect(func(from, to): transitions.append({"from": from, "to": to}))

	_gsm.transition_to(GameStateMachine.State.PLAYING)

	assert_eq(transitions.size(), 1)
	assert_eq(transitions[0]["from"], GameStateMachine.State.TITLE)
	assert_eq(transitions[0]["to"], GameStateMachine.State.PLAYING)


func test_transition_to_same_state_does_nothing():
	var transitions: Array = []
	_gsm.state_changed.connect(func(from, to): transitions.append({"from": from, "to": to}))

	_gsm.transition_to(GameStateMachine.State.TITLE)

	assert_eq(transitions.size(), 0)


func test_is_playing():
	assert_false(_gsm.is_playing())
	_gsm.transition_to(GameStateMachine.State.PLAYING)
	assert_true(_gsm.is_playing())
