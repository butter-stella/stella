extends GutTest
## Tests that CharacterPresenter updates the stage sprite texture
## when char_expression_changed is emitted (inline [expr] markers
## or @expr command).

var _game_scene: Node


func before_each():
	_game_scene = load("res://addons/stella/scenes/game.tscn").instantiate()
	add_child_autoqfree(_game_scene)
	await get_tree().process_frame


func _get_char_layer() -> CanvasLayer:
	return _game_scene.get_node("CharacterLayer")


func _get_slot_left() -> Control:
	return _game_scene.get_node("CharacterLayer/SlotLeft")


func test_char_show_creates_sprite_node_with_texture():
	SignalBus.char_show.emit("sakura", "smile", "left")
	await get_tree().process_frame
	var slot = _get_slot_left()
	var sprite = slot.get_node_or_null("Sprite")
	assert_not_null(sprite, "Sprite node should be created on char_show")
	assert_not_null(sprite.texture, "Sprite should have a texture loaded")


func test_char_expression_changed_updates_stage_sprite_texture():
	# Show sakura in "smile" on the left
	SignalBus.char_show.emit("sakura", "smile", "left")
	await get_tree().process_frame
	var slot = _get_slot_left()
	var sprite = slot.get_node_or_null("Sprite")
	assert_not_null(sprite, "Sprite node should exist after char_show")
	var smile_texture = sprite.texture
	assert_not_null(smile_texture, "smile texture should be loaded")

	# Change expression (simulating inline [surprised] marker or @expr)
	SignalBus.char_expression_changed.emit("sakura", "surprised")
	await get_tree().process_frame

	# The sprite node's texture should now be different (surprised.png)
	var surprised_texture = sprite.texture
	assert_not_null(surprised_texture, "surprised texture should be loaded")
	assert_ne(
		surprised_texture.resource_path,
		smile_texture.resource_path,
		"Stage sprite texture should change from smile to surprised"
	)


func test_inline_expression_during_typewriter_updates_stage_sprite():
	# Mimic the exact scenario from demo.stla:97
	# @show sakura smile left
	# @expr sakura sad
	# sakura「...[surprised]...[sad]...」
	SignalBus.char_show.emit("sakura", "smile", "left")
	await get_tree().process_frame
	SignalBus.char_expression_changed.emit("sakura", "sad")
	await get_tree().process_frame

	var slot = _get_slot_left()
	var sprite = slot.get_node_or_null("Sprite")
	assert_not_null(sprite)
	var sad_path = sprite.texture.resource_path
	assert_true(sad_path.ends_with("sad.png"),
		"After @expr sakura sad, sprite should be sad.png, got: %s" % sad_path)

	# Now trigger dialogue which should fire inline markers during typewriter
	SignalBus.show_dialogue.emit("sakura", [{
		"text": "我本来很开心的...[surprised]但是听说下周要期中考...[sad]我数学肯定完蛋了。",
		"voice": "",
		"expression": "",
	}], "adv")

	# Wait for typewriter to process inline markers
	# The dialogue has ~30 chars total, 0.03s per char = ~0.9s, plus {wait} etc
	await get_tree().create_timer(1.5).timeout

	# After typewriter finishes, the final expression should be "sad"
	# (from the second inline marker [sad])
	sprite = slot.get_node_or_null("Sprite")
	assert_not_null(sprite, "sprite should still exist after dialogue")
	var final_path = sprite.texture.resource_path
	assert_true(final_path.ends_with("sad.png"),
		"Final stage sprite should be sad.png after inline markers, got: %s" % final_path)


func test_char_expression_changed_tracks_position_correctly():
	# Show on left, not center — default slot should NOT be center
	SignalBus.char_show.emit("sakura", "smile", "left")
	await get_tree().process_frame

	var presenter = _get_char_layer()
	assert_eq(presenter._character_positions.get("sakura"), "left",
		"position should be tracked as 'left'")

	SignalBus.char_expression_changed.emit("sakura", "surprised")
	await get_tree().process_frame

	# The left slot should have the updated texture, not center
	var left_sprite = _get_slot_left().get_node_or_null("Sprite")
	assert_not_null(left_sprite, "left slot sprite should still exist")
	assert_true(left_sprite.texture.resource_path.ends_with("surprised.png"),
		"left slot should show surprised texture, got: %s" % left_sprite.texture.resource_path)


func test_combined_dialogue_plays_segments_sequentially():
	# Simulate a @combine block with 3 segments
	SignalBus.char_show.emit("sakura", "smile", "left")
	await get_tree().process_frame

	var segments = [
		{"text": "我本来很开心的...", "voice": "sakura_013", "expression": "sad"},
		{"text": "但是听说下周要期中考...", "voice": "sakura_018", "expression": "surprised"},
		{"text": "我数学肯定完蛋了。", "voice": "sakura_019", "expression": "sad"},
	]
	SignalBus.show_dialogue.emit("sakura", segments, "adv")
	await get_tree().process_frame

	# Initial segment's expression should be applied
	var slot = _get_slot_left()
	var sprite = slot.get_node_or_null("Sprite")
	assert_not_null(sprite)
	assert_true(sprite.texture.resource_path.ends_with("sad.png"),
		"initial expression from segment[0] should be applied")


func test_combine_voice_replay_restarts_from_first_segment():
	# Setup: play a combined dialogue, let the queue run, then click replay
	SignalBus.char_show.emit("sakura", "smile", "left")
	await get_tree().process_frame

	var segments = [
		{"text": "一", "voice": "sakura_013", "expression": "sad"},
		{"text": "二", "voice": "sakura_018", "expression": "surprised"},
		{"text": "三", "voice": "sakura_019", "expression": "sad"},
	]

	var dialogue = _game_scene.get_node("UILayer/DialoguePanel")
	SignalBus.show_dialogue.emit("sakura", segments, "adv")
	await get_tree().process_frame

	# Segments should be stored for replay
	assert_eq(dialogue._current_combine_segments.size(), 3,
		"segments should be snapshotted for replay")

	# Simulate replay — should not crash and should kick off the queue again
	var voice_play_count := [0]
	SignalBus.voice_play.connect(func(_a, _c): voice_play_count[0] += 1)
	dialogue._on_voice_replay_pressed()
	await get_tree().process_frame
	assert_true(voice_play_count[0] >= 1,
		"replay should emit at least one voice_play for segment 0")


func test_single_segment_dialogue_stores_one_segment():
	# Normal single-line dialogue should also populate _current_combine_segments
	# (size 1) so the unified replay path works.
	var dialogue = _game_scene.get_node("UILayer/DialoguePanel")
	SignalBus.show_dialogue.emit("sakura",
		[{"text": "hello", "voice": "v1", "expression": ""}], "adv")
	await get_tree().process_frame
	assert_eq(dialogue._current_combine_segments.size(), 1,
		"single-segment dialogue should snapshot a 1-element segments array")


func test_combine_with_empty_voices_does_not_hang():
	# All segments have empty voice — queue should drain synchronously without hanging
	var segments = [
		{"text": "一", "voice": "", "expression": ""},
		{"text": "二", "voice": "", "expression": ""},
	]
	var dialogue = _game_scene.get_node("UILayer/DialoguePanel")
	SignalBus.show_dialogue.emit("sakura", segments, "adv")
	await get_tree().process_frame
	# After one frame the queue should already be inactive (nothing to await)
	assert_false(dialogue._combine_queue_active,
		"queue must not stall when all segments have empty voices")


func test_dialogue_voice_progress_emits_with_total_duration():
	# A combined dialogue should emit dialogue_voice_started exactly once with
	# the SUM of all segment voice durations (not per-segment).
	var started_payloads: Array = []
	SignalBus.dialogue_voice_started.connect(func(d): started_payloads.append(d))

	var segments = [
		{"text": "一", "voice": "sakura_013", "expression": ""},
		{"text": "二", "voice": "sakura_018", "expression": ""},
		{"text": "三", "voice": "sakura_019", "expression": ""},
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
	dialogue._combine_total_duration = 3.0
	dialogue._combine_played_duration = 1.0

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


func test_char_show_then_expression_change_uses_new_sprite():
	# Regression: _clear_slot used queue_free, leaving the old "Sprite" node in
	# the tree. add_child("Sprite") would auto-rename due to name collision,
	# and get_node_or_null("Sprite") would return the old (about-to-be-freed)
	# node, silently dropping the texture update. This is the same root cause
	# as the load-from-combine bug where stage立绘 wouldn't update.
	SignalBus.char_show.emit("sakura", "happy", "left")
	await get_tree().process_frame
	# Now show the same character again at a different expression — simulates
	# what presentation_state.emit_restore_signals() does on a load.
	SignalBus.char_show.emit("sakura", "happy", "left")
	# Immediately fire char_expression_changed (no frame elapsed yet, so any
	# queue_freed-but-still-in-tree node is the actual hazard)
	SignalBus.char_expression_changed.emit("sakura", "sad")
	await get_tree().process_frame

	var slot = _get_slot_left()
	var sprite = slot.get_node_or_null("Sprite")
	assert_not_null(sprite, "the live Sprite node must be findable by name")
	assert_true(sprite.texture.resource_path.ends_with("sad.png"),
		"texture should reflect the post-show expression change, got: %s"
			% sprite.texture.resource_path)


func test_voice_replay_re_emits_dialogue_voice_started():
	# Bug: replay button restarted the voice queue but never re-fired
	# dialogue_voice_started, so the demo progress bar stayed hidden.
	var dialogue = _game_scene.get_node("UILayer/DialoguePanel")
	var segments = [
		{"text": "一", "voice": "sakura_013", "expression": ""},
		{"text": "二", "voice": "sakura_018", "expression": ""},
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
	var segments = [
		{"text": "一", "voice": "v1", "expression": ""},
		{"text": "二", "voice": "v2", "expression": ""},
		{"text": "三", "voice": "v3", "expression": ""},
	]

	var finished_count := [0]
	SignalBus.dialogue_voice_finished.connect(func(): finished_count[0] += 1)

	var dialogue = _game_scene.get_node("UILayer/DialoguePanel")
	# Stub the queue with our segments + non-zero total so the started/finished
	# signals are wired up. Run the queue directly so we control exactly when
	# voice_finished is delivered.
	dialogue._current_combine_segments = segments
	dialogue._combine_total_duration = 3.0
	dialogue._combine_played_duration = 0.0
	dialogue._combine_segment_durations = [1.0, 1.0, 1.0]
	dialogue._combine_aborted = false

	dialogue._run_voice_queue("sakura", segments, dialogue._dialogue_gen)
	await get_tree().process_frame

	# After kickoff: seg[0]'s voice is "playing"; queue is awaiting voice_finished.
	# dialogue_voice_finished must NOT have fired yet.
	assert_eq(finished_count[0], 0, "must not finish before any segment ends")

	# Simulate seg[0] ending → queue advances to seg[1]
	SignalBus.voice_finished.emit()
	await get_tree().process_frame
	assert_eq(finished_count[0], 0, "must not finish after seg[0] ends")

	# seg[1] ends → queue advances to seg[2]
	SignalBus.voice_finished.emit()
	await get_tree().process_frame
	assert_eq(finished_count[0], 0,
		"must not finish when LAST segment merely STARTS — wait for its end")

	# seg[2] (last) ends → queue should now emit dialogue_voice_finished
	SignalBus.voice_finished.emit()
	await get_tree().process_frame
	assert_eq(finished_count[0], 1,
		"dialogue_voice_finished must fire only after the last segment ends")
