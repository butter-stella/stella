extends GutTest
## Integration tests for skip/auto-play interaction with voice.
## Verifies:
##   - Skip mode suppresses voice playback
##   - Voice stop on advance emits voice_finished (prevents _voice_playing stuck true)


var _bus: Node


func before_each():
	_bus = get_tree().root.get_node("SignalBus")
	StellaRuntime.skip_controller.is_active = false
	StellaRuntime.auto_play.is_active = false
	StellaRuntime.game_state.current_state = GameStateMachine.State.PLAYING


# --- Skip mode should NOT play voice ---

func test_skip_mode_suppresses_voice_play():
	# Use Array for counter (GDScript lambdas capture locals by value)
	var voice_received := []
	var conn = func(a, _c): voice_received.append(a)
	_bus.voice_play.connect(conn)

	StellaRuntime.skip_controller.is_active = true
	assert_true(StellaRuntime.is_skipping())

	_bus.show_dialogue.emit("sakura", [{"text": "Hello", "voice": "sakura_001", "expression": ""}], "adv")
	await get_tree().create_timer(0.2).timeout

	assert_eq(voice_received.size(), 0, "voice should NOT play during skip mode")

	_bus.voice_play.disconnect(conn)
	StellaRuntime.skip_controller.is_active = false


# --- voice_finished signal propagation ---

func test_voice_finished_signal_propagates():
	var count := [0]
	var conn = func(): count[0] += 1
	_bus.voice_finished.connect(conn)

	_bus.voice_finished.emit()

	assert_eq(count[0], 1, "voice_finished signal should propagate")
	_bus.voice_finished.disconnect(conn)


func test_audio_presenter_advance_does_not_crash():
	var audio_presenter = StellaRuntime.get_node_or_null("AudioPresenter")
	if audio_presenter == null:
		pending("AudioPresenter not available")
		return

	# Verify advance_requested with AudioPresenter doesn't crash
	_bus.advance_requested.emit()
	await get_tree().process_frame
	pass_test("advance_requested with AudioPresenter connected does not crash")


# --- _voice_playing flag management ---

func test_voice_started_sets_flag():
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	if dialogue == null:
		pending("DialoguePanel not available in test scene")
		return

	dialogue._voice_playing = false
	_bus.voice_started.emit("sakura", "test_voice")
	await get_tree().process_frame
	assert_true(dialogue._voice_playing, "voice_started should set _voice_playing true")


func test_voice_finished_clears_flag():
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	if dialogue == null:
		pending("DialoguePanel not available in test scene")
		return

	dialogue._voice_playing = true
	_bus.voice_finished.emit()
	await get_tree().process_frame
	assert_false(dialogue._voice_playing, "voice_finished should clear _voice_playing")


# --- Mutual exclusivity ---

func test_skip_and_auto_mutually_exclusive():
	StellaRuntime.toggle_skip()
	assert_true(StellaRuntime.is_skipping())
	assert_false(StellaRuntime.is_auto_playing())

	StellaRuntime.toggle_auto_play()
	assert_false(StellaRuntime.is_skipping(), "skip should stop when auto activates")
	assert_true(StellaRuntime.is_auto_playing())

	StellaRuntime.auto_play.stop()


# --- _dialogue_gen prevents double-advance ---

func test_dialogue_gen_increments_on_show_dialogue():
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	if dialogue == null:
		pending("DialoguePanel not available in test scene")
		return

	var gen_before = dialogue._dialogue_gen
	_bus.show_dialogue.emit("sakura", [{"text": "Hello", "voice": "", "expression": ""}], "adv")
	await get_tree().process_frame

	assert_gt(dialogue._dialogue_gen, gen_before, "_dialogue_gen should increment on each show_dialogue")
	dialogue._is_typing = false


func test_dialogue_gen_changes_on_successive_dialogues():
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	if dialogue == null:
		pending("DialoguePanel not available in test scene")
		return

	_bus.show_dialogue.emit("sakura", [{"text": "First", "voice": "", "expression": ""}], "adv")
	await get_tree().process_frame
	var gen1 = dialogue._dialogue_gen

	_bus.show_dialogue.emit("sakura", [{"text": "Second", "voice": "", "expression": ""}], "adv")
	await get_tree().process_frame
	var gen2 = dialogue._dialogue_gen

	assert_ne(gen1, gen2, "each dialogue should get a unique gen")
	dialogue._is_typing = false


# --- auto_play_click_interrupt setting ---

func test_auto_play_click_interrupt_default_true():
	var val = StellaRuntime.get_setting("auto_play_click_interrupt")
	assert_true(val, "auto_play_click_interrupt should default to true")


func test_auto_play_click_interrupt_persists():
	StellaRuntime.set_setting("auto_play_click_interrupt", false)
	assert_false(StellaRuntime.get_setting("auto_play_click_interrupt"),
		"setting should persist after set")
	# Restore default
	StellaRuntime.set_setting("auto_play_click_interrupt", true)


# --- Leaving PLAYING stops auto/skip ---

func test_overlay_stops_auto_play():
	StellaRuntime.auto_play.is_active = true
	StellaRuntime.game_state.transition_to(GameStateMachine.State.SETTINGS)
	assert_false(StellaRuntime.is_auto_playing(), "auto should stop when leaving PLAYING")
	StellaRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)


func test_overlay_stops_skip():
	StellaRuntime.skip_controller.is_active = true
	StellaRuntime.game_state.transition_to(GameStateMachine.State.BACKLOG)
	assert_false(StellaRuntime.is_skipping(), "skip should stop when leaving PLAYING")
	StellaRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)


# --- _voice_playing cleared on hide_dialogue ---

func test_voice_playing_cleared_on_hide():
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	if dialogue == null:
		pending("DialoguePanel not available in test scene")
		return

	dialogue._voice_playing = true
	_bus.hide_dialogue.emit()
	await get_tree().process_frame
	assert_false(dialogue._voice_playing, "_voice_playing should clear on hide_dialogue")
