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
	SignalBus.show_dialogue.emit("sakura",
		"我本来很开心的...[surprised]但是听说下周要期中考...[sad]我数学肯定完蛋了。",
		"", "adv")

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
	SignalBus.show_dialogue_combined.emit("sakura", segments, "adv")
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
	SignalBus.show_dialogue_combined.emit("sakura", segments, "adv")
	await get_tree().process_frame

	# Segments should be stored for replay
	assert_eq(dialogue._current_combine_segments.size(), 3,
		"segments should be snapshotted for replay")

	# Simulate replay — should not crash and should kick off the queue again
	var voice_play_count := [0]
	SignalBus.voice_play.connect(func(_a, _c): voice_play_count[0] += 1)
	dialogue._replay_combine_voices()
	await get_tree().process_frame
	assert_true(voice_play_count[0] >= 1,
		"replay should emit at least one voice_play for segment 0")


func test_normal_dialogue_clears_combine_segments():
	var dialogue = _game_scene.get_node("UILayer/DialoguePanel")
	dialogue._current_combine_segments = [{"text": "stale"}]
	SignalBus.show_dialogue.emit("sakura", "hello", "", "adv")
	await get_tree().process_frame
	assert_eq(dialogue._current_combine_segments.size(), 0,
		"single-dialogue path should clear stale combine state")


func test_combine_with_empty_voices_does_not_hang():
	# All segments have empty voice — queue should drain synchronously without hanging
	var segments = [
		{"text": "一", "voice": "", "expression": ""},
		{"text": "二", "voice": "", "expression": ""},
	]
	var dialogue = _game_scene.get_node("UILayer/DialoguePanel")
	SignalBus.show_dialogue_combined.emit("sakura", segments, "adv")
	await get_tree().process_frame
	# After one frame the queue should already be inactive (nothing to await)
	assert_false(dialogue._combine_queue_active,
		"queue must not stall when all segments have empty voices")
