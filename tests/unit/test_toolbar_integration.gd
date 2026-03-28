extends GutTest
## Tests for toolbar integration — auto-play and skip controller wiring.


func test_auto_play_toggle():
	var apc = AutoPlayController.new()
	assert_false(apc.is_active)
	apc.toggle()
	assert_true(apc.is_active)
	apc.toggle()
	assert_false(apc.is_active)


func test_skip_toggle():
	var sc = SkipController.new()
	assert_false(sc.is_active)
	sc.toggle()
	assert_true(sc.is_active)
	sc.toggle()
	assert_false(sc.is_active)


func test_backlog_records_dialogue():
	var blm = BacklogManager.new()
	blm.add_entry("sakura", "Hello!", "voice_001")
	blm.add_entry("kaito", "Hey.", "")
	blm.add_entry("", "Narration text.", "")
	var entries = blm.get_entries()
	assert_eq(entries.size(), 3)
	assert_eq(entries[0]["character"], "sakura")
	assert_eq(entries[2]["character"], "")


func test_game_state_machine_transitions_for_ui():
	var gsm = GameStateMachine.new()
	gsm.transition_to(GameStateMachine.State.PLAYING)
	assert_true(gsm.is_playing())

	gsm.transition_to(GameStateMachine.State.BACKLOG)
	assert_eq(gsm.current_state, GameStateMachine.State.BACKLOG)
	assert_false(gsm.is_playing())

	gsm.transition_to(GameStateMachine.State.PLAYING)
	assert_true(gsm.is_playing())

	gsm.transition_to(GameStateMachine.State.SAVE_LOAD)
	assert_eq(gsm.current_state, GameStateMachine.State.SAVE_LOAD)

	gsm.transition_to(GameStateMachine.State.PLAYING)
	gsm.transition_to(GameStateMachine.State.SETTINGS)
	assert_eq(gsm.current_state, GameStateMachine.State.SETTINGS)
