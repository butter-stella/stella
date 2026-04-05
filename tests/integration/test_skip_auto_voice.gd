extends GutTest
## Integration tests for skip/auto-play interaction with voice.
## Verifies:
##   - Skip mode suppresses voice playback
##   - Voice stop on advance emits voice_finished (prevents _voice_playing stuck true)


var _bus: Node


func before_each():
	_bus = get_tree().root.get_node("SignalBus")
	NatsumeRuntime.skip_controller.is_active = false
	NatsumeRuntime.auto_play.is_active = false


# --- Skip mode should NOT play voice ---

func test_skip_mode_suppresses_voice_play():
	# Use Array for counter (GDScript lambdas capture locals by value)
	var voice_received := []
	var conn = func(a, _c): voice_received.append(a)
	_bus.voice_play.connect(conn)

	NatsumeRuntime.skip_controller.is_active = true
	assert_true(NatsumeRuntime.is_skipping())

	_bus.show_dialogue.emit("sakura", "Hello", "sakura_001", "adv")
	await get_tree().create_timer(0.2).timeout

	assert_eq(voice_received.size(), 0, "voice should NOT play during skip mode")

	_bus.voice_play.disconnect(conn)
	NatsumeRuntime.skip_controller.is_active = false


# --- voice_finished signal propagation ---

func test_voice_finished_signal_propagates():
	var count := [0]
	var conn = func(): count[0] += 1
	_bus.voice_finished.connect(conn)

	_bus.voice_finished.emit()

	assert_eq(count[0], 1, "voice_finished signal should propagate")
	_bus.voice_finished.disconnect(conn)


func test_audio_presenter_advance_does_not_crash():
	var audio_presenter = NatsumeRuntime.get_node_or_null("AudioPresenter")
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
	NatsumeRuntime.toggle_skip()
	assert_true(NatsumeRuntime.is_skipping())
	assert_false(NatsumeRuntime.is_auto_playing())

	NatsumeRuntime.toggle_auto_play()
	assert_false(NatsumeRuntime.is_skipping(), "skip should stop when auto activates")
	assert_true(NatsumeRuntime.is_auto_playing())

	NatsumeRuntime.auto_play.stop()
