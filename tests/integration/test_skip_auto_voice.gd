extends GutTest
## Integration tests for skip/auto-play interaction with voice.
## Verifies:
##   - Skip mode suppresses voice playback
##   - Voice stop on advance emits voice_finished (prevents _voice_playing stuck true)


const RuntimeTestSupport = preload("res://tests/helpers/runtime_test_support.gd")

var _bus: Node
var _game_scene: Node
var _original_voice_path: String


func before_each() -> void:
	_original_voice_path = StellaRuntime.voice_path
	_bus = get_tree().root.get_node("SignalBus")
	await RuntimeTestSupport.reset_for_test(StellaRuntime, get_tree())
	StellaRuntime.game_state.current_state = GameStateMachine.State.PLAYING
	# Load the game scene so DialoguePanel is available for tests that poke at it.
	_game_scene = load("res://addons/stella/scenes/game.tscn").instantiate()
	add_child_autoqfree(_game_scene)
	await get_tree().process_frame


func after_each() -> void:
	SignalBus.hide_dialogue.emit()
	SignalBus.engine_abort_requested.emit()
	StellaRuntime.auto_play.stop()
	StellaRuntime.skip_controller.stop()
	if is_instance_valid(_game_scene):
		_game_scene.queue_free()
	await get_tree().process_frame
	_game_scene = null
	StellaRuntime.voice_path = _original_voice_path


# --- Skip mode should NOT play voice ---

func test_skip_mode_suppresses_voice_play():
	# Use Array for counter (GDScript lambdas capture locals by value)
	var voice_received := []
	var conn = func(a, _c): voice_received.append(a)
	_bus.voice_play.connect(conn)

	StellaRuntime.skip_controller.is_active = true
	assert_true(StellaRuntime.is_skipping())

	_bus.show_dialogue.emit("sakura", [{"text": "Hello", "voice_layers": [{"id": "main", "asset": "sakura_001", "character": "sakura", "dsp": "", "line": 0}]}], "adv")
	await get_tree().create_timer(0.2).timeout

	assert_eq(voice_received.size(), 0, "voice should NOT play during skip mode")
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	assert_not_null(dialogue)
	if dialogue != null:
		assert_false(dialogue._playback_queue_active,
			"skip-suppressed voice must not await a voice_finished that cannot fire")

	_bus.voice_play.disconnect(conn)
	StellaRuntime.skip_controller.is_active = false


func test_missing_combine_voices_do_not_block_auto_wait_voice() -> void:
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	assert_not_null(dialogue)
	if dialogue == null:
		return
	dialogue._char_interval = 0.0
	StellaRuntime.set_setting("auto_play_wait_voice", true)
	StellaRuntime.set_setting("auto_play_delay", 0.01)
	StellaRuntime.auto_play.is_active = true
	var voice_plays: Array[String] = []
	var on_voice_play := func(asset: String, _character: String):
		voice_plays.append(asset)
	var advance_count := [0]
	var on_advance := func(): advance_count[0] += 1
	_bus.voice_play.connect(on_voice_play)
	_bus.advance_requested.connect(on_advance)

	_bus.show_dialogue.emit("sakura", [
		{"text": "一", "voice_layers": [{"id": "main", "asset": "missing_voice_one", "character": "sakura", "dsp": "", "line": 0}], "expression": ""},
		{"text": "二", "voice_layers": [{"id": "main", "asset": "missing_voice_two", "character": "sakura", "dsp": "", "line": 0}], "expression": ""},
	], "adv")
	assert_push_error("missing_voice_one")
	assert_push_error("missing_voice_two")
	var advanced: bool = await wait_until(
		func(): return advance_count[0] == 1,
		0.6,
		"missing combine voices drain instead of hanging auto wait-voice",
	)
	assert_true(advanced)
	assert_eq(voice_plays, ["missing_voice_one", "missing_voice_two"],
		"each missing asset still reaches AudioPresenter diagnostics")
	assert_false(dialogue._playback_queue_active)
	_bus.voice_play.disconnect(on_voice_play)
	_bus.advance_requested.disconnect(on_advance)


func test_muted_combine_voices_do_not_block_auto_wait_voice() -> void:
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	assert_not_null(dialogue)
	if dialogue == null:
		return
	StellaRuntime.voice_path = "res://examples/demo/audio/voice/"
	dialogue._char_interval = 0.0
	StellaRuntime.set_setting("auto_play_wait_voice", true)
	StellaRuntime.set_setting("auto_play_delay", 0.01)
	StellaRuntime.set_setting("character_voice_enabled", {"sakura": false})
	StellaRuntime.auto_play.is_active = true
	var voice_started_count := [0]
	var on_voice_started := func(_character: String, _asset: String):
		voice_started_count[0] += 1
	var advance_count := [0]
	var on_advance := func(): advance_count[0] += 1
	_bus.voice_started.connect(on_voice_started)
	_bus.advance_requested.connect(on_advance)

	_bus.show_dialogue.emit("sakura", [
		{"text": "一", "voice_layers": [{"id": "main", "asset": "narration_001", "character": "sakura", "dsp": "", "line": 0}], "expression": ""},
		{"text": "二", "voice_layers": [{"id": "main", "asset": "narration_002", "character": "sakura", "dsp": "", "line": 0}], "expression": ""},
	], "adv")
	var advanced: bool = await wait_until(
		func(): return advance_count[0] == 1,
		0.6,
		"muted combine voices drain instead of hanging auto wait-voice",
	)
	assert_true(advanced)
	assert_eq(voice_started_count[0], 0)
	assert_false(dialogue._playback_queue_active)
	_bus.voice_started.disconnect(on_voice_started)
	_bus.advance_requested.disconnect(on_advance)


func test_muted_replacement_does_not_leave_old_voice_waiting_forever() -> void:
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	var audio_presenter := StellaRuntime.get_node_or_null("AudioPresenter")
	assert_not_null(dialogue)
	assert_not_null(audio_presenter)
	if dialogue == null or audio_presenter == null:
		return
	StellaRuntime.voice_path = "res://examples/demo/audio/voice/"
	dialogue._char_interval = 0.0
	StellaRuntime.set_setting("auto_play_wait_voice", true)
	StellaRuntime.set_setting("auto_play_delay", 0.01)

	_bus.show_dialogue.emit("sakura", [{
		"text": "A", "voice_layers": [{"id": "main", "asset": "narration_001", "character": "sakura", "dsp": "", "line": 0}], "expression": "",
	}], "adv")
	assert_true(audio_presenter._voice_player.playing)
	assert_true(dialogue._voice_playing)

	StellaRuntime.set_setting("character_voice_enabled", {"sakura": false})
	_bus.show_dialogue.emit("sakura", [{
		"text": "B", "voice_layers": [{"id": "main", "asset": "narration_002", "character": "sakura", "dsp": "", "line": 0}], "expression": "",
	}], "adv")
	var replacement_ready: bool = await wait_until(
		func(): return dialogue._dialogue_ready,
		0.5,
		"muted replacement reaches its ready boundary",
	)
	assert_true(replacement_ready)
	assert_false(audio_presenter._voice_player.playing)
	assert_false(dialogue._voice_playing,
		"stopping the replaced clip must publish its low-level completion")
	assert_false(dialogue._playback_queue_active)

	var advance_count := [0]
	var on_advance := func(): advance_count[0] += 1
	_bus.advance_requested.connect(on_advance)
	StellaRuntime.auto_play.is_active = true
	var advanced: bool = await wait_until(
		func(): return advance_count[0] == 1,
		0.5,
		"auto wait-voice must not retain the replaced clip's stale flag",
	)
	assert_true(advanced)
	_bus.advance_requested.disconnect(on_advance)


func test_old_voice_finished_tail_cannot_complete_replacement_auto_wait() -> void:
	if is_instance_valid(_game_scene):
		_game_scene.queue_free()
		await get_tree().process_frame
	StellaRuntime.voice_path = "res://examples/demo/audio/voice/"
	StellaRuntime.set_setting("auto_play_wait_voice", true)
	StellaRuntime.set_setting("auto_play_delay", 0.01)
	var did_replace := [false]
	var on_voice_finished_early := func():
		if did_replace[0]:
			return
		did_replace[0] = true
		_bus.show_dialogue.emit("sakura", [{
			"text": "B", "voice_layers": [{"id": "main", "asset": "narration_002", "character": "sakura", "dsp": "", "line": 0}], "expression": "",
		}], "adv")
	# Connect before the replacement game scene so this extension can start a new
	# playback before DialoguePresenter receives the old signal's ordinary tail.
	_bus.voice_finished.connect(on_voice_finished_early)
	_game_scene = load("res://addons/stella/scenes/game.tscn").instantiate()
	add_child_autoqfree(_game_scene)
	await get_tree().process_frame
	var dialogue = _game_scene.get_node("UILayer/DialoguePanel")
	var audio_presenter := StellaRuntime.get_node_or_null("AudioPresenter")
	assert_not_null(audio_presenter)
	if audio_presenter == null:
		_bus.voice_finished.disconnect(on_voice_finished_early)
		return
	dialogue._char_interval = 0.0
	StellaRuntime.auto_play.is_active = true
	var advance_count := [0]
	var on_advance := func(): advance_count[0] += 1
	_bus.advance_requested.connect(on_advance)

	_bus.show_dialogue.emit("sakura", [{
		"text": "A", "voice_layers": [{"id": "main", "asset": "narration_001", "character": "sakura", "dsp": "", "line": 0}], "expression": "",
	}], "adv")
	assert_true(audio_presenter._voice_player.playing)
	# Model the real AudioStreamPlayer.finished callback. Its early listener starts
	# replacement playback synchronously while this no-argument signal is in flight.
	audio_presenter._voice_player.stop()
	audio_presenter._on_voice_playback_finished()
	assert_true(did_replace[0])
	await get_tree().create_timer(0.08).timeout
	assert_eq(advance_count[0], 0,
		"the old completion cannot satisfy replacement auto wait")
	assert_true(audio_presenter._voice_player.playing)
	assert_true(dialogue._voice_playing,
		"the old signal tail cannot clear replacement playback state")
	assert_true(dialogue._playback_queue_active,
		"the replacement queue must still await its own completion")

	audio_presenter._voice_player.stop()
	audio_presenter._on_voice_playback_finished()
	var advanced: bool = await wait_until(
		func(): return advance_count[0] == 1,
		0.5,
		"replacement's own completion releases auto wait",
	)
	assert_true(advanced)
	StellaRuntime.auto_play.is_active = false
	_bus.advance_requested.disconnect(on_advance)
	_bus.voice_finished.disconnect(on_voice_finished_early)


func test_raw_voice_started_from_replaced_finish_wins_over_owned_request() -> void:
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	var audio_presenter := StellaRuntime.get_node_or_null("AudioPresenter")
	assert_not_null(dialogue)
	assert_not_null(audio_presenter)
	if dialogue == null or audio_presenter == null:
		return
	StellaRuntime.voice_path = "res://examples/demo/audio/voice/"
	dialogue._char_interval = 0.0
	_bus.show_dialogue.emit("sakura", [{
		"text": "A", "voice_layers": [{"id": "main", "asset": "narration_001", "character": "sakura", "dsp": "", "line": 0}], "expression": "",
	}], "adv")
	assert_true(audio_presenter._voice_player.playing)
	var did_start_raw := [false]
	var on_replaced_finish := func():
		if did_start_raw[0]:
			return
		did_start_raw[0] = true
		_bus.voice_play.emit("narration_003", "raw")
	_bus.voice_finished.connect(on_replaced_finish)

	# B stops A before loading its own clip. The FINISHED extension starts raw C
	# synchronously; the suspended B request must notice Audio's newer revision.
	_bus.show_dialogue.emit("sakura", [{
		"text": "B", "voice_layers": [{"id": "main", "asset": "narration_002", "character": "sakura", "dsp": "", "line": 0}], "expression": "",
	}], "adv")
	_bus.voice_finished.disconnect(on_replaced_finish)
	assert_true(did_start_raw[0])
	assert_true(audio_presenter._voice_player.playing)
	assert_eq(audio_presenter._current_voice_character, "raw")
	assert_not_null(audio_presenter._voice_player.stream)
	if audio_presenter._voice_player.stream != null:
		assert_true(
			audio_presenter._voice_player.stream.resource_path.ends_with(
				"narration_003.wav"),
			"raw C remains authoritative after suspended owned B resumes",
		)
	assert_false(dialogue._playback_queue_active,
		"the rejected owned B request leaves no orphaned queue wait")
	audio_presenter._voice_player.stop()
	audio_presenter._on_voice_playback_finished()


func test_raw_voice_finished_cannot_complete_an_owned_queue() -> void:
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	var audio_presenter := StellaRuntime.get_node_or_null("AudioPresenter")
	assert_not_null(dialogue)
	assert_not_null(audio_presenter)
	if dialogue == null or audio_presenter == null:
		return
	StellaRuntime.voice_path = "res://examples/demo/audio/voice/"
	dialogue._char_interval = 0.0
	_bus.show_dialogue.emit("sakura", [{
		"text": "raw", "voice_layers": [{"id": "main", "asset": "narration_001", "character": "sakura", "dsp": "", "line": 0}], "expression": "",
	}], "adv")
	assert_true(dialogue._playback_queue_active)
	assert_true(dialogue._voice_playing)

	audio_presenter._voice_player.stop()
	_bus.voice_finished.emit()
	assert_true(dialogue._playback_queue_active,
		"an unrelated raw FINISH cannot claim the current owned token")
	assert_true(dialogue._voice_playing,
		"an unrelated raw FINISH cannot clear canonical playback state")
	audio_presenter._on_voice_playback_finished()
	await get_tree().process_frame
	assert_false(dialogue._playback_queue_active)
	assert_false(dialogue._voice_playing)


func test_synchronous_owned_finish_during_start_does_not_strand_queue() -> void:
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	var audio_presenter := StellaRuntime.get_node_or_null("AudioPresenter")
	assert_not_null(dialogue)
	assert_not_null(audio_presenter)
	if dialogue == null or audio_presenter == null:
		return
	StellaRuntime.voice_path = "res://examples/demo/audio/voice/"
	dialogue._char_interval = 0.0
	var did_finish := [false]
	var on_started := func(_character: String, _asset: String):
		if did_finish[0]:
			return
		did_finish[0] = true
		audio_presenter._voice_player.stop()
		audio_presenter._on_voice_playback_finished()
	_bus.voice_started.connect(on_started)

	_bus.show_dialogue.emit("sakura", [{
		"text": "sync owned", "voice_layers": [{"id": "main", "asset": "narration_001", "character": "sakura", "dsp": "", "line": 0}], "expression": "",
	}], "adv")
	_bus.voice_started.disconnect(on_started)
	assert_true(did_finish[0])
	assert_false(dialogue._voice_playing)
	assert_false(dialogue._playback_queue_active,
		"completion published before the request result remains observable")
	assert_eq(dialogue._playback_voice_token, -1,
		"the queue cannot restore an already completed playback token")


func test_synchronous_raw_finish_during_start_does_not_complete_owned_queue() -> void:
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	var audio_presenter := StellaRuntime.get_node_or_null("AudioPresenter")
	assert_not_null(dialogue)
	assert_not_null(audio_presenter)
	if dialogue == null or audio_presenter == null:
		return
	StellaRuntime.voice_path = "res://examples/demo/audio/voice/"
	dialogue._char_interval = 0.0
	var did_finish := [false]
	var on_started := func(_character: String, _asset: String):
		if did_finish[0]:
			return
		did_finish[0] = true
		audio_presenter._voice_player.stop()
		_bus.voice_finished.emit()
	_bus.voice_started.connect(on_started)

	_bus.show_dialogue.emit("sakura", [{
		"text": "sync raw", "voice_layers": [{"id": "main", "asset": "narration_001", "character": "sakura", "dsp": "", "line": 0}], "expression": "",
	}], "adv")
	_bus.voice_started.disconnect(on_started)
	assert_true(did_finish[0])
	assert_true(dialogue._voice_playing)
	assert_true(dialogue._playback_queue_active,
		"raw completion cannot satisfy a canonical waiter before it is installed")
	assert_gt(dialogue._playback_voice_token, 0)
	audio_presenter._on_voice_playback_finished()
	await get_tree().process_frame
	assert_false(dialogue._playback_queue_active)


func test_old_voice_started_tail_cannot_revive_a_muted_replacement() -> void:
	if is_instance_valid(_game_scene):
		_game_scene.queue_free()
		await get_tree().process_frame
	StellaRuntime.voice_path = "res://examples/demo/audio/voice/"
	StellaRuntime.set_setting("auto_play_wait_voice", true)
	StellaRuntime.set_setting("auto_play_delay", 0.01)
	var did_replace := [false]
	var on_voice_started_early := func(_character: String, _asset: String):
		if did_replace[0]:
			return
		did_replace[0] = true
		StellaRuntime.set_setting(
			"character_voice_enabled", {"sakura": false})
		_bus.show_dialogue.emit("sakura", [{
			"text": "B", "voice_layers": [{"id": "main", "asset": "narration_002", "character": "sakura", "dsp": "", "line": 0}], "expression": "",
		}], "adv")
	# The replacement Presenter connects after this extension, so the old native
	# START tail reaches it only after the nested muted SHOW has completed.
	_bus.voice_started.connect(on_voice_started_early)
	_game_scene = load("res://addons/stella/scenes/game.tscn").instantiate()
	add_child_autoqfree(_game_scene)
	await get_tree().process_frame
	var dialogue = _game_scene.get_node("UILayer/DialoguePanel")
	dialogue._char_interval = 0.0
	StellaRuntime.auto_play.is_active = true
	var advance_count := [0]
	var on_advance := func(): advance_count[0] += 1
	_bus.advance_requested.connect(on_advance)

	_bus.show_dialogue.emit("sakura", [{
		"text": "A", "voice_layers": [{"id": "main", "asset": "narration_001", "character": "sakura", "dsp": "", "line": 0}], "expression": "",
	}], "adv")
	_bus.voice_started.disconnect(on_voice_started_early)
	assert_true(did_replace[0])
	var advanced: bool = await wait_until(
		func(): return advance_count[0] == 1,
		0.6,
		"muted replacement auto wait is not revived by the retired START tail",
	)
	assert_true(advanced)
	assert_false(dialogue._voice_playing,
		"the retired START tail cannot resurrect physical voice state")
	assert_false(dialogue._playback_queue_active)
	StellaRuntime.auto_play.is_active = false
	_bus.advance_requested.disconnect(on_advance)


func test_voice_group_accepts_early_all_disabled_decision_and_drains_auto() -> void:
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	var audio_presenter := StellaRuntime.get_node_or_null("AudioPresenter")
	assert_not_null(dialogue)
	assert_not_null(audio_presenter)
	if dialogue == null or audio_presenter == null:
		return
	StellaRuntime.voice_path = "res://examples/demo/audio/voice/"
	dialogue._char_interval = 0.0
	StellaRuntime.set_setting("auto_play_wait_voice", true)
	StellaRuntime.set_setting("auto_play_delay", 0.01)
	StellaRuntime.set_setting("character_voice_enabled", {"sakura": true})
	var audio_callback := Callable(audio_presenter, "_on_voice_playback_requested")
	assert_true(_bus.voice_playback_requested.is_connected(audio_callback))
	if not _bus.voice_playback_requested.is_connected(audio_callback):
		return
	# Put the mutating extension before AudioPresenter. Presenter has already
	# precomputed the clip duration, but Audio must validate the stream and then
	# synchronously complete the accepted all-disabled group instead of leaving
	# the queue waiting for a physical FINISHED event.
	_bus.voice_playback_requested.disconnect(audio_callback)
	var did_mute := [false]
	var mute_before_audio := func(_request: VoicePlaybackRequest):
		if did_mute[0]:
			return
		did_mute[0] = true
		StellaRuntime.set_setting(
			"character_voice_enabled", {"sakura": false})
	_bus.voice_playback_requested.connect(mute_before_audio)
	_bus.voice_playback_requested.connect(audio_callback)
	StellaRuntime.auto_play.is_active = true
	var advance_count := [0]
	var on_advance := func(): advance_count[0] += 1
	_bus.advance_requested.connect(on_advance)

	_bus.show_dialogue.emit("sakura", [{
		"text": "TOCTOU", "voice_layers": [{"id": "main", "asset": "narration_001", "character": "sakura", "dsp": "", "line": 0}], "expression": "",
	}], "adv")
	_bus.voice_playback_requested.disconnect(mute_before_audio)
	assert_true(did_mute[0])
	var advanced: bool = await wait_until(
		func(): return advance_count[0] == 1,
		0.6,
		"an accepted all-disabled group drains auto wait synchronously",
	)
	assert_true(advanced)
	assert_false(audio_presenter._voice_player.playing)
	assert_false(dialogue._playback_queue_active)
	StellaRuntime.auto_play.is_active = false
	_bus.advance_requested.disconnect(on_advance)


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
	_bus.show_dialogue.emit("sakura", [{"text": "Hello", "voice_layers": []}], "adv")
	await get_tree().process_frame

	assert_gt(dialogue._dialogue_gen, gen_before, "_dialogue_gen should increment on each show_dialogue")
	dialogue._is_typing = false


func test_dialogue_gen_changes_on_successive_dialogues():
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	if dialogue == null:
		pending("DialoguePanel not available in test scene")
		return

	_bus.show_dialogue.emit("sakura", [{"text": "First", "voice_layers": []}], "adv")
	await get_tree().process_frame
	var gen1 = dialogue._dialogue_gen

	_bus.show_dialogue.emit("sakura", [{"text": "Second", "voice_layers": []}], "adv")
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


# --- skip_only_read semantics (PR: feat/skip-unread-setting) ---
# Ctrl-hold always skips (including unread). Toolbar skip respects
# skip_only_read — when true (default), it auto-stops at unread lines.

func _fresh_position(dialogue: Node, index: int = 0) -> void:
	# Tests don't run a real scenario engine, so seed the presenter's cached
	# position fields directly — _on_show_dialogue normally fills them from
	# engine.context.
	dialogue._current_scenario_id = "test_scn"
	dialogue._current_scenario_identity = ""
	dialogue._current_scene_id = "test_scene"
	dialogue._current_command_index = index
	dialogue._current_command_uid = -1
	dialogue._current_dialogue_activation = null


func test_ctrl_held_skips_unread_regardless_of_setting():
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	if dialogue == null:
		pending("DialoguePanel not available in test scene")
		return
	_fresh_position(dialogue, 1000)
	dialogue._ctrl_held = true
	StellaRuntime.skip_controller.is_active = false
	StellaRuntime.set_setting("skip_only_read", true)
	assert_true(dialogue._should_skip_current(), "Ctrl-hold must skip even unread lines")
	dialogue._ctrl_held = false


func test_toolbar_skip_unread_pure_query_returns_false():
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	if dialogue == null:
		pending("DialoguePanel not available in test scene")
		return
	_fresh_position(dialogue, 1001)
	dialogue._ctrl_held = false
	StellaRuntime.set_setting("skip_only_read", true)
	StellaRuntime.skip_controller.is_active = true
	# Pure query must not mutate skip_controller state.
	assert_false(dialogue._should_skip_current(), "toolbar skip should not skip unread when skip_only_read=true")
	assert_true(StellaRuntime.skip_controller.is_active, "query must not stop the skip controller")
	StellaRuntime.skip_controller.is_active = false


func test_apply_unread_skip_gate_stops_toolbar_skip_on_unread():
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	if dialogue == null:
		pending("DialoguePanel not available in test scene")
		return
	_fresh_position(dialogue, 1005)
	dialogue._ctrl_held = false
	StellaRuntime.set_setting("skip_only_read", true)
	StellaRuntime.skip_controller.is_active = true
	dialogue._apply_unread_skip_gate()
	assert_false(StellaRuntime.skip_controller.is_active, "gate must stop toolbar skip on unread line")


func test_apply_unread_skip_gate_noop_on_read():
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	if dialogue == null:
		pending("DialoguePanel not available in test scene")
		return
	_fresh_position(dialogue, 1006)
	StellaRuntime.read_flags.mark_read("test_scn", "test_scene", 1006)
	dialogue._ctrl_held = false
	StellaRuntime.set_setting("skip_only_read", true)
	StellaRuntime.skip_controller.is_active = true
	dialogue._apply_unread_skip_gate()
	assert_true(StellaRuntime.skip_controller.is_active, "gate must be a no-op when current line is read")
	StellaRuntime.skip_controller.is_active = false


func test_apply_unread_skip_gate_noop_when_ctrl_held():
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	if dialogue == null:
		pending("DialoguePanel not available in test scene")
		return
	_fresh_position(dialogue, 1007)
	dialogue._ctrl_held = true
	StellaRuntime.set_setting("skip_only_read", true)
	StellaRuntime.skip_controller.is_active = true
	dialogue._apply_unread_skip_gate()
	assert_true(StellaRuntime.skip_controller.is_active, "Ctrl-hold must bypass the gate")
	dialogue._ctrl_held = false
	StellaRuntime.skip_controller.is_active = false


func test_toolbar_skip_unread_allowed_when_setting_off():
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	if dialogue == null:
		pending("DialoguePanel not available in test scene")
		return
	_fresh_position(dialogue, 1002)
	dialogue._ctrl_held = false
	StellaRuntime.set_setting("skip_only_read", false)
	StellaRuntime.skip_controller.is_active = true
	assert_true(dialogue._should_skip_current(), "toolbar skip should skip unread when skip_only_read=false")
	StellaRuntime.skip_controller.is_active = false
	StellaRuntime.set_setting("skip_only_read", true)


func test_toolbar_skip_read_line_allowed():
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	if dialogue == null:
		pending("DialoguePanel not available in test scene")
		return
	_fresh_position(dialogue, 1003)
	StellaRuntime.read_flags.mark_read("test_scn", "test_scene", 1003)
	dialogue._ctrl_held = false
	StellaRuntime.set_setting("skip_only_read", true)
	StellaRuntime.skip_controller.is_active = true
	assert_true(dialogue._should_skip_current(), "read line should be skippable by toolbar skip")
	StellaRuntime.skip_controller.is_active = false


func test_skip_only_read_setting_default_true():
	var val = StellaRuntime.get_setting("skip_only_read")
	assert_true(val, "skip_only_read should default to true")


# --- _on_skip_pressed mid-typewriter snap behavior ---
# Fix for round-2 Opus UX concern: when the user presses the toolbar skip
# button while the typewriter is running, snap the text to end immediately
# (like click-to-complete). Without this the button highlights but the
# typewriter keeps running, which looks like skip isn't working.

func test_skip_press_while_typing_snaps_text():
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	if dialogue == null:
		pending("DialoguePanel not available in test scene")
		return
	# Leave skip off at test start so _on_skip_pressed toggles it ON.
	StellaRuntime.skip_controller.is_active = false
	dialogue._is_typing = true
	dialogue.text_label.visible_characters = 3
	dialogue._on_skip_pressed()
	assert_false(dialogue._is_typing, "pressing skip while typing must stop the typewriter")
	assert_eq(dialogue.text_label.visible_characters, -1, "pressing skip while typing must snap text to full")
	# Cleanup
	StellaRuntime.skip_controller.is_active = false


func test_skip_press_toggle_off_leaves_state_alone():
	var dialogue = get_tree().root.find_child("DialoguePanel", true, false)
	if dialogue == null:
		pending("DialoguePanel not available in test scene")
		return
	# Skip already on — pressing must toggle it OFF without touching text state.
	StellaRuntime.skip_controller.is_active = true
	dialogue._is_typing = true
	dialogue.text_label.visible_characters = 5
	dialogue._on_skip_pressed()
	assert_false(StellaRuntime.is_skipping(), "pressing skip while active must toggle off")
	assert_true(dialogue._is_typing, "toggling skip off must not disturb in-flight typewriter")
	assert_eq(dialogue.text_label.visible_characters, 5, "toggling skip off must not snap text")
	dialogue._is_typing = false
