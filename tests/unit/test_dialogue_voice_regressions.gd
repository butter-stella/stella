extends GutTest
## Dialogue voice, replay, reset, and presentation-isolation regressions.

var _game_scene: Node


func before_each():
	_game_scene = load("res://addons/stella/scenes/game.tscn").instantiate()
	add_child_autoqfree(_game_scene)
	await get_tree().process_frame


func _get_stage_presenter() -> StagePresenter:
	return _game_scene.get_node("StageLayer") as StagePresenter


func _open_logical_voice_session(dialogue: Control) -> void:
	dialogue._playback_owner_dialogue_gen = dialogue._dialogue_gen
	dialogue._playback_total_duration = 1.0
	dialogue._playback_is_dialogue = true
	dialogue._playback_dialogue_finished_emitted = false
	dialogue._playback_aborted = false
	dialogue._playback_queue_active = true


func test_voice_handler_enters_the_typed_request_path() -> void:
	var typed_requests: Array[VoicePlaybackRequest] = []
	var compatibility_events: Array = []
	var on_typed: Callable = func(request: VoicePlaybackRequest):
		typed_requests.append(request)
	var on_raw: Callable = func(asset: String, character: String):
		compatibility_events.append([asset, character])
	SignalBus.voice_playback_requested.connect(on_typed)
	SignalBus.voice_play.connect(on_raw)
	var command := CommandData.new()
	command.params = {"asset": "missing_typed_fixture"}

	await VoiceHandler.new().execute(command, null)

	assert_eq(typed_requests.size(), 1)
	assert_eq(typed_requests[0].get_asset(), "missing_typed_fixture")
	assert_eq(compatibility_events, [["missing_typed_fixture", ""]],
		"the old signal remains an outbound compatibility notification")
	SignalBus.voice_playback_requested.disconnect(on_typed)
	SignalBus.voice_play.disconnect(on_raw)


func test_logical_voice_finishes_once_on_advance_show_and_hide() -> void:
	var dialogue := _game_scene.get_node("UILayer/DialoguePanel")
	var finished := [0]
	var on_finished: Callable = func(): finished[0] += 1
	SignalBus.dialogue_voice_finished.connect(on_finished)

	_open_logical_voice_session(dialogue)
	SignalBus.emit_advance_requested()
	assert_eq(finished[0], 1, "advance closes the current logical voice")

	_open_logical_voice_session(dialogue)
	SignalBus.show_dialogue.emit("", [{"text": "replacement", "voice": ""}], "adv")
	assert_eq(finished[0], 2, "direct SHOW closes the replaced logical voice")

	_open_logical_voice_session(dialogue)
	SignalBus.hide_dialogue.emit()
	assert_eq(finished[0], 3, "hard hide closes the current logical voice")
	SignalBus.hide_dialogue.emit()
	assert_eq(finished[0], 3, "repeated hide cannot emit duplicate FINISH")
	SignalBus.dialogue_voice_finished.disconnect(on_finished)


func test_toolbar_and_backlog_replay_logical_event_order() -> void:
	var dialogue := _game_scene.get_node("UILayer/DialoguePanel")
	var events: Array[String] = []
	var on_started: Callable = func(_duration: float): events.append("start")
	var on_finished: Callable = func(): events.append("finish")
	SignalBus.dialogue_voice_started.connect(on_started)
	SignalBus.dialogue_voice_finished.connect(on_finished)
	dialogue._dialogue_segments = [{"text": "", "voice": "narration_001"}]
	dialogue._dialogue_voice_character = ""

	_open_logical_voice_session(dialogue)
	dialogue._on_voice_replay_pressed()
	assert_eq(events, ["finish", "start"],
		"toolbar replay closes the old logical session before its new START")

	events.clear()
	_open_logical_voice_session(dialogue)
	SignalBus.dialogue_voice_replay_requested.emit(["narration_001"], "")
	assert_eq(events, ["finish"],
		"backlog replay closes the old session but owns no dialogue lifecycle")
	SignalBus.dialogue_voice_started.disconnect(on_started)
	SignalBus.dialogue_voice_finished.disconnect(on_finished)


func test_backlog_replay_from_voice_started_does_not_strand_show() -> void:
	var original_voice_path := StellaRuntime.voice_path
	StellaRuntime.voice_path = "res://examples/demo/audio/voice/"
	var dialogue := _game_scene.get_node("UILayer/DialoguePanel")
	dialogue._char_interval = 0.0
	var original_stream := load(
		"res://examples/demo/audio/voice/narration_001.wav") as AudioStream
	var replay_stream := load(
		"res://examples/demo/audio/voice/narration_002.wav") as AudioStream
	assert_not_null(original_stream)
	assert_not_null(replay_stream)
	assert_ne(original_stream.get_length(), replay_stream.get_length(),
		"fixture voices must distinguish SHOW duration from replay duration")

	var started_count := [0]
	var on_started: Callable = func(_duration: float):
		started_count[0] += 1
		if started_count[0] == 1:
			SignalBus.dialogue_voice_replay_requested.emit(
				["narration_002"], "backlog")
	SignalBus.dialogue_voice_started.connect(on_started)
	var expected_dialogue_gen: int = dialogue._dialogue_gen + 1
	SignalBus.show_dialogue.emit("", [{
		"text": "Original SHOW remains live",
		"voice": "narration_001",
	}], "adv")
	SignalBus.dialogue_voice_started.disconnect(on_started)
	await get_tree().process_frame
	await get_tree().process_frame

	assert_eq(started_count[0], 1,
		"backlog replay must not open another high-level dialogue voice session")
	assert_eq(dialogue._dialogue_gen, expected_dialogue_gen,
		"audio-only replay must stay within the SHOW's dialogue generation")
	assert_false(dialogue._is_typing,
		"synchronous replay must not strand the SHOW before its typewriter starts")
	assert_eq(dialogue.text_label.visible_characters, -1,
		"the original SHOW must continue through its typewriter pipeline")
	assert_almost_eq(
		dialogue._dialogue_total_duration,
		original_stream.get_length(),
		0.001,
		"toolbar duration belongs to the original SHOW, not backlog replay",
	)
	assert_not_null(dialogue._voice_replay_btn)
	if dialogue._voice_replay_btn != null:
		assert_true(dialogue._voice_replay_btn.visible,
			"the original voiced SHOW must retain toolbar replay visibility")

	SignalBus.hide_dialogue.emit()
	var audio_presenter := StellaRuntime.get_node_or_null("AudioPresenter")
	if audio_presenter != null:
		audio_presenter._voice_player.stop()
		audio_presenter._on_voice_playback_finished()
	StellaRuntime.voice_path = original_voice_path


func test_combine_voice_replay_restarts_from_first_segment():
	# Setup: play a combined dialogue, let the queue run, then click replay
	var segments = [
		{"text": "一", "voice": "sakura_013"},
		{"text": "二", "voice": "sakura_018"},
		{"text": "三", "voice": "sakura_019"},
	]

	var dialogue = _game_scene.get_node("UILayer/DialoguePanel")
	SignalBus.show_dialogue.emit("sakura", segments, "adv")
	await get_tree().process_frame

	# Segments should be stored for replay
	assert_eq(dialogue._dialogue_segments.size(), 3,
		"segments should be snapshotted for replay")

	# Simulate replay — should not crash and should kick off the queue again
	var voice_play_count := [0]
	SignalBus.voice_play.connect(func(_a, _c): voice_play_count[0] += 1)
	dialogue._on_voice_replay_pressed()
	await get_tree().process_frame
	assert_true(voice_play_count[0] >= 1,
		"replay should emit at least one voice_play for segment 0")


func test_single_segment_dialogue_stores_one_segment():
	# Normal single-line dialogue should also populate _dialogue_segments
	# (size 1) so the unified replay path works.
	var dialogue = _game_scene.get_node("UILayer/DialoguePanel")
	SignalBus.show_dialogue.emit("sakura",
		[{"text": "hello", "voice": "v1"}], "adv")
	await get_tree().process_frame
	assert_eq(dialogue._dialogue_segments.size(), 1,
		"single-segment dialogue should snapshot a 1-element segments array")


func test_combine_with_empty_voices_does_not_hang():
	# All segments have empty voice — queue should drain synchronously without hanging
	var segments = [
		{"text": "一", "voice": ""},
		{"text": "二", "voice": ""},
	]
	var dialogue = _game_scene.get_node("UILayer/DialoguePanel")
	SignalBus.show_dialogue.emit("sakura", segments, "adv")
	await get_tree().process_frame
	# After one frame the queue should already be inactive (nothing to await)
	assert_false(dialogue._playback_queue_active,
		"queue must not stall when all segments have empty voices")


func test_dialogue_voice_progress_emits_with_total_duration():
	# A combined dialogue should emit dialogue_voice_started exactly once with
	# the SUM of all segment voice durations (not per-segment).
	var started_payloads: Array = []
	SignalBus.dialogue_voice_started.connect(func(d): started_payloads.append(d))

	var segments = [
		{"text": "一", "voice": "sakura_013"},
		{"text": "二", "voice": "sakura_018"},
		{"text": "三", "voice": "sakura_019"},
	]
	SignalBus.show_dialogue.emit("sakura", segments, "adv")
	await get_tree().process_frame

	assert_eq(started_payloads.size(), 1,
		"dialogue_voice_started should fire exactly once for a combined dialogue")
	# Total should be > 0 and equal sum of three real wav durations
	assert_gt(started_payloads[0], 0.0,
		"total duration should be positive (sum of segment voice lengths)")


func test_dialogue_voice_progress_relays_cumulative_position():
	# Manually drive voice_progress and verify dialogue_voice_progress reports
	# cumulative position = played_duration + current_clip_position.
	var dialogue = _game_scene.get_node("UILayer/DialoguePanel")
	# Pretend we are in a combined dialogue with 1.0s already played
	dialogue._playback_total_duration = 3.0
	dialogue._playback_played_duration = 1.0

	var received: Array = []
	var conn = func(pos, total): received.append([pos, total])
	SignalBus.dialogue_voice_progress.connect(conn)

	SignalBus.voice_progress.emit(0.5, 2.0)  # 0.5s into current clip

	# Synchronous emission — relay should have fired exactly once for our emit.
	# We don't await a frame here because the audio_presenter _process tick can
	# emit additional voice_progress events that pollute the count.
	SignalBus.dialogue_voice_progress.disconnect(conn)

	assert_eq(received.size(), 1)
	assert_almost_eq(float(received[0][0]), 1.5, 0.001,
		"cumulative position should be played(1.0) + clip_pos(0.5) = 1.5")
	assert_almost_eq(float(received[0][1]), 3.0, 0.001,
		"total duration should be the precomputed combined total")


func test_voice_replay_re_emits_dialogue_voice_started():
	# Bug: replay button restarted the voice queue but never re-fired
	# dialogue_voice_started, so the demo progress bar stayed hidden.
	var dialogue = _game_scene.get_node("UILayer/DialoguePanel")
	var segments = [
		{"text": "一", "voice": "sakura_013"},
		{"text": "二", "voice": "sakura_018"},
	]
	SignalBus.show_dialogue.emit("sakura", segments, "adv")
	await get_tree().process_frame

	var started_count := [0]
	SignalBus.dialogue_voice_started.connect(func(_d): started_count[0] += 1)

	dialogue._on_voice_replay_pressed()
	assert_eq(started_count[0], 1,
		"replay should fire dialogue_voice_started so the progress bar shows again")


func test_dialogue_voice_finished_waits_for_last_segment():
	# Bug: dialogue_voice_finished fired the moment the last segment STARTED
	# playing (loop exited after kicking it off). The progress bar would
	# disappear at the start of the final segment instead of at its end.
	var original_voice_path := StellaRuntime.voice_path
	StellaRuntime.voice_path = "res://examples/demo/audio/voice/"
	var segments = [
		{"text": "一", "voice": "narration_001", "expression": ""},
		{"text": "二", "voice": "narration_002", "expression": ""},
		{"text": "三", "voice": "narration_003", "expression": ""},
	]

	var finished_count := [0]
	SignalBus.dialogue_voice_finished.connect(func(): finished_count[0] += 1)

	var dialogue = _game_scene.get_node("UILayer/DialoguePanel")
	# Stub the queue with our segments + non-zero total so the started/finished
	# signals are wired up. Run the queue directly so we control exactly when
	# voice_finished is delivered.
	dialogue._dialogue_segments = segments
	dialogue._playback_total_duration = 3.0
	dialogue._playback_played_duration = 0.0
	dialogue._playback_segment_durations = [1.0, 1.0, 1.0]
	dialogue._playback_aborted = false
	dialogue._playback_queue_gen += 1
	dialogue._playback_owner_dialogue_gen = dialogue._dialogue_gen
	var queue_gen: int = dialogue._playback_queue_gen

	dialogue._run_voice_queue(
		"sakura", segments, dialogue._dialogue_gen, queue_gen)
	await get_tree().process_frame
	var audio_presenter := StellaRuntime.get_node_or_null("AudioPresenter")
	assert_not_null(audio_presenter)
	if audio_presenter == null:
		StellaRuntime.voice_path = original_voice_path
		return

	# After kickoff: seg[0]'s voice is "playing"; queue is awaiting voice_finished.
	# dialogue_voice_finished must NOT have fired yet.
	assert_eq(finished_count[0], 0, "must not finish before any segment ends")

	# Simulate seg[0] ending → queue advances to seg[1]
	audio_presenter._voice_player.stop()
	audio_presenter._on_voice_playback_finished()
	await get_tree().process_frame
	assert_eq(finished_count[0], 0, "must not finish after seg[0] ends")

	# seg[1] ends → queue advances to seg[2]
	audio_presenter._voice_player.stop()
	audio_presenter._on_voice_playback_finished()
	await get_tree().process_frame
	assert_eq(finished_count[0], 0,
		"must not finish when LAST segment merely STARTS — wait for its end")

	# seg[2] (last) ends → queue should now emit dialogue_voice_finished
	audio_presenter._voice_player.stop()
	audio_presenter._on_voice_playback_finished()
	await get_tree().process_frame
	assert_eq(finished_count[0], 1,
		"dialogue_voice_finished must fire only after the last segment ends")
	StellaRuntime.voice_path = original_voice_path


func test_reset_presentation_clears_backlog():
	# Bug: load reuses _reset_presentation() but it didn't clear the backlog,
	# so the previous run's entries leaked into the loaded game.
	StellaRuntime.backlog_manager.clear()
	StellaRuntime.backlog_manager.add_entry(
		"sakura", [{"text": "old run", "voice": ""}]
	)
	assert_eq(StellaRuntime.backlog_manager.get_entries().size(), 1,
		"sanity: entry was added")

	StellaRuntime._reset_presentation()
	assert_eq(StellaRuntime.backlog_manager.get_entries().size(), 0,
		"_reset_presentation must clear the backlog")


func test_reset_presentation_clears_screen_effects():
	var received: Array = []
	var listener := func(effect_type: String, _params: Dictionary):
		received.append(effect_type)
	SignalBus.effect_requested.connect(listener)
	StellaRuntime._reset_presentation()
	SignalBus.effect_requested.disconnect(listener)
	assert_true(received.has("off"), "in-place load reset must cancel active screen effects")


func test_replay_button_visible_when_only_later_segment_has_voice():
	# Latent bug: replay button visibility was based on segments[0].voice only.
	# A combine where seg[0] is voice-less but seg[1] has a voice would hide
	# the button even though replay would play the later voice.
	var dialogue = _game_scene.get_node("UILayer/DialoguePanel")
	# Create the replay button via the toolbar setup the presenter expects
	if dialogue._voice_replay_btn == null:
		dialogue._voice_replay_btn = Button.new()
		add_child_autoqfree(dialogue._voice_replay_btn)

	var segments = [
		{"text": "一", "voice": ""},
		{"text": "二", "voice": "sakura_018"},
	]
	SignalBus.show_dialogue.emit("sakura", segments, "adv")
	await get_tree().process_frame

	assert_true(dialogue._voice_replay_btn.visible,
		"replay button should show whenever ANY segment has a voice")


func test_backlog_replay_request_drives_dialogue_presenter_queue():
	# The backlog ▶ button should fire dialogue_voice_replay_requested, and the
	# DialoguePresenter should pick it up + run the voice queue. (Whether the
	# in-game progress bar lights up is checked by a separate test —
	# test_backlog_replay_does_not_emit_dialogue_voice_signals.)
	var voice_play_count := [0]
	SignalBus.voice_play.connect(func(_a, _c): voice_play_count[0] += 1)

	SignalBus.dialogue_voice_replay_requested.emit(
		["sakura_013", "sakura_018", "sakura_019"], "sakura"
	)
	await get_tree().process_frame

	assert_true(voice_play_count[0] >= 1,
		"at least segment 0's voice_play should fire from the replay request")


func test_backlog_replay_does_not_corrupt_dialogue_state():
	# Critical: a backlog replay (which carries arbitrary old segments) must NOT
	# overwrite the current dialogue's _dialogue_segments — otherwise the toolbar
	# 重听 button afterwards would replay the backlog entry instead of the
	# current dialogue.
	var dialogue = _game_scene.get_node("UILayer/DialoguePanel")

	# Set up a "current dialogue" with two segments (the toolbar replay target)
	var dialogue_segments = [
		{"text": "current一", "voice": "sakura_011"},
		{"text": "current二", "voice": "sakura_012"},
	]
	SignalBus.show_dialogue.emit("sakura", dialogue_segments, "adv")
	await get_tree().process_frame
	assert_eq(dialogue._dialogue_segments.size(), 2,
		"sanity: current dialogue snapshot has 2 segments")

	# Fire a backlog replay with a DIFFERENT (3-segment) entry
	SignalBus.dialogue_voice_replay_requested.emit(
		["sakura_013", "sakura_018", "sakura_019"], "sakura"
	)
	await get_tree().process_frame

	# _dialogue_segments must still be the original 2 — not the backlog's 3
	assert_eq(dialogue._dialogue_segments.size(), 2,
		"backlog replay must NOT overwrite _dialogue_segments")
	assert_eq(dialogue._dialogue_segments[0]["voice"], "sakura_011",
		"first segment should still be the current dialogue's, not the backlog's")

	# Now press the toolbar 重听 button — it must replay the CURRENT dialogue's
	# voices (sakura_011 then sakura_012), NOT the backlog's (sakura_013/018/019).
	var played: Array = []
	var conn = func(asset, _c): played.append(asset)
	SignalBus.voice_play.connect(conn)
	dialogue._on_voice_replay_pressed()
	await get_tree().process_frame
	SignalBus.voice_play.disconnect(conn)

	assert_true(played.size() >= 1,
		"toolbar replay should fire at least one voice_play")
	assert_eq(played[0], "sakura_011",
		"toolbar replay must play the current dialogue's first voice, not the backlog's")


func test_backlog_replay_does_not_change_named_stage_layers():
	SignalBus.emit_stage_operations([{
		"action": "show",
		"id": "sakura",
		"properties": {"asset": "character:sakura/happy"},
		"transition": "cut",
		"duration": 0.0,
	}], true)
	await get_tree().process_frame
	var layer := _get_stage_presenter().get_layer_node("sakura")
	var sprite := layer.find_child("AssetSprite", true, false) as Sprite2D
	assert_not_null(sprite)
	var initial_texture := sprite.texture

	# Fire a replay request — voices only, no expression metadata
	SignalBus.dialogue_voice_replay_requested.emit(["sakura_013"], "sakura")
	await get_tree().process_frame

	assert_same(sprite.texture, initial_texture,
		"dialogue replay must not mutate independent stage state")


func test_backlog_replay_does_not_emit_dialogue_voice_signals():
	# The backlog ▶ button reuses the voice queue but should NOT light up the
	# in-game progress bar — that bar belongs to the dialogue toolbar and should
	# only react to the current dialogue's playback.
	var started_count := [0]
	var progress_count := [0]
	var finished_count := [0]
	SignalBus.dialogue_voice_started.connect(func(_d): started_count[0] += 1)
	SignalBus.dialogue_voice_progress.connect(func(_p, _t): progress_count[0] += 1)
	SignalBus.dialogue_voice_finished.connect(func(): finished_count[0] += 1)

	SignalBus.dialogue_voice_replay_requested.emit(["sakura_013"], "sakura")
	await get_tree().process_frame
	# Tick a low-level voice_progress to verify the relay is gated too
	SignalBus.voice_progress.emit(0.5, 1.0)

	assert_eq(started_count[0], 0,
		"backlog replay must not emit dialogue_voice_started")
	assert_eq(progress_count[0], 0,
		"backlog replay must not emit dialogue_voice_progress")
	assert_eq(finished_count[0], 0,
		"backlog replay must not emit dialogue_voice_finished")


func test_hide_dialogue_cancels_in_flight_voice_queue():
	# Bug: _on_hide_dialogue did not bump _playback_queue_gen, so a backlog
	# replay queue still in flight would survive into the next dialogue and
	# leave _playback_queue_active true.
	var dialogue = _game_scene.get_node("UILayer/DialoguePanel")

	# Start a multi-segment playback (simulates backlog replay still queued)
	dialogue._playback_queue_active = true
	var gen_before = dialogue._playback_queue_gen

	SignalBus.hide_dialogue.emit()
	await get_tree().process_frame

	assert_gt(dialogue._playback_queue_gen, gen_before,
		"hide_dialogue must bump _playback_queue_gen so any in-flight queue exits")
	assert_false(dialogue._playback_queue_active,
		"_playback_queue_active must be cleared on hide_dialogue")


func test_single_segment_dialogue_emits_voice_play_exactly_once():
	# Regression for the double-queue bug (commit 5c95349):
	# _on_show_dialogue used to call _run_voice_queue twice — once via
	# _start_voice_playback and once directly — causing seg[0]'s voice_play
	# to fire twice in the same frame. This test guards against that
	# regressing silently.
	var counts := [0]
	var conn = func(_a, _c): counts[0] += 1
	SignalBus.voice_play.connect(conn)

	SignalBus.show_dialogue.emit("sakura",
		[{"text": "hi", "voice": "sakura_011"}], "adv")
	await get_tree().process_frame

	SignalBus.voice_play.disconnect(conn)
	assert_eq(counts[0], 1, "voice_play must fire exactly once per dialogue")
