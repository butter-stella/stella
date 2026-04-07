extends GutTest
## Integration test: end-to-end backlog jump.
## Drives the StellaRuntime engine through several dialogues, captures
## backlog entries with snapshots, jumps back, and verifies the engine
## resumes at the correct position with the correct state.


var _runtime: Node


func before_each():
	_runtime = get_tree().root.get_node("StellaRuntime")
	_runtime.backlog_manager.clear()
	_runtime.backlog_manager.anchor_interval = 2  # frequent anchors for tests


func _build_scenario(num_dialogues: int) -> ScenarioData:
	var data = ScenarioData.new()
	data.id = "backlog_test"
	var scene = SceneData.new()
	scene.id = "start"
	for i in range(num_dialogues):
		var cmd = CommandData.new()
		cmd.type = "dialogue"
		cmd.params = {"character": "narrator", "text": "line %d" % i}
		scene.commands.append(cmd)
	data.scenes.append(scene)
	return data


# Drive the engine forward by N dialogues by emitting advance_requested.
func _advance(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame
		SignalBus.advance_requested.emit()
	await get_tree().process_frame


func _setup_scenario(num: int) -> void:
	_runtime.engine.load_scenario(_build_scenario(num))
	_runtime.engine.context.presentation_state = _runtime.presentation_state
	_runtime.save_manager.register_provider(_runtime.engine.context)
	_runtime.save_manager.register_provider(_runtime.engine.context.variable_store)


func test_backlog_records_entries_with_anchors_during_play():
	_setup_scenario(5)
	_runtime.engine.run()
	# First dialogue is dispatched synchronously at run() start; each
	# advance unblocks the next.
	await _advance(3)  # → 4 entries total (0..3)

	var entries = _runtime.backlog_manager.get_entries()
	assert_eq(entries.size(), 4, "should record 4 entries")
	# anchor_interval = 2 → entries at 0, 2 are anchors
	assert_not_null(entries[0].get("snapshot"))
	assert_null(entries[1].get("snapshot"))
	assert_not_null(entries[2].get("snapshot"))
	assert_null(entries[3].get("snapshot"))

	# Stop the engine cleanly
	_runtime.engine.stop()
	SignalBus.advance_requested.emit()
	await get_tree().process_frame


func test_jump_from_backlog_returns_to_target_position():
	_setup_scenario(6)
	_runtime.engine.run()
	await _advance(4)  # → 5 entries (0..4)

	assert_eq(_runtime.backlog_manager.get_entries().size(), 5)
	assert_eq(_runtime.backlog_manager.get_cursor(), 4)

	# Jump back to entry 1
	var ok = _runtime.jump_from_backlog(1)
	assert_true(ok)
	await get_tree().process_frame
	await get_tree().process_frame

	# Engine should now be positioned at the dialogue at index 1, ready to
	# emit show_dialogue. Verify backlog cursor moved without truncating.
	assert_eq(_runtime.backlog_manager.get_cursor(), 1,
		"cursor should be at the jumped-to entry")
	assert_eq(_runtime.backlog_manager.get_entries().size(), 5,
		"history should be preserved (no truncate on jump)")
	assert_eq(_runtime.engine.context.current_command_index, 1,
		"engine positioned at target dialogue")
	assert_false(_runtime.engine.context.is_replay,
		"replay flag cleared at target")

	_runtime.engine.stop()
	SignalBus.advance_requested.emit()
	await get_tree().process_frame


func test_walking_known_path_after_jump_only_advances_cursor():
	_setup_scenario(6)
	_runtime.engine.run()
	await _advance(4)  # → 5 entries (0..4), cursor=4

	var size_before = _runtime.backlog_manager.get_entries().size()
	_runtime.jump_from_backlog(1)
	await get_tree().process_frame
	await get_tree().process_frame

	# After jump, engine is positioned at command 1, about to dispatch its
	# dialogue. That sync dispatch fires while we're inside jump_from_backlog
	# (engine.run() is called and runs until next await). Entries 2,3,4
	# are already re-walked or re-walked on subsequent advances.
	# Drive forward — entries 2,3,4 should match → cursor advances, no append.
	await _advance(3)

	assert_eq(_runtime.backlog_manager.get_entries().size(), size_before,
		"no duplication when re-walking known path")
	assert_eq(_runtime.backlog_manager.get_cursor(), 4,
		"cursor advanced to original position")

	_runtime.engine.stop()
	SignalBus.advance_requested.emit()
	await get_tree().process_frame


func test_divergence_truncates_history_after_branch_point():
	# Build a scenario where dialogue 1's command_index changes after jump:
	# we simulate divergence by having a JUMP at command 2 that goes
	# elsewhere (a separate scene). Then walking the new path produces
	# entries with a different (scene_index, command_index).
	var data = ScenarioData.new()
	data.id = "div_test"
	var s0 = SceneData.new()
	s0.id = "start"
	for i in range(4):
		var c = CommandData.new()
		c.type = "dialogue"
		c.params = {"character": "n", "text": "s0_%d" % i}
		s0.commands.append(c)
	data.scenes.append(s0)
	var s1 = SceneData.new()
	s1.id = "branch"
	for i in range(3):
		var c = CommandData.new()
		c.type = "dialogue"
		c.params = {"character": "n", "text": "s1_%d" % i}
		s1.commands.append(c)
	data.scenes.append(s1)

	_runtime.engine.load_scenario(data)
	_runtime.engine.context.presentation_state = _runtime.presentation_state
	_runtime.save_manager.register_provider(_runtime.engine.context)
	_runtime.save_manager.register_provider(_runtime.engine.context.variable_store)

	_runtime.engine.run()
	await _advance(3)  # → 4 entries from scene 0 (0..3)

	assert_eq(_runtime.backlog_manager.get_entries().size(), 4)

	# Jump back to entry 1 (scene 0, cmd 1)
	_runtime.jump_from_backlog(1)
	await get_tree().process_frame
	await get_tree().process_frame

	# Now manually force a jump to scene 1 (simulating a branch). The next
	# dialogue will be at (scene=1, cmd=0), which doesn't match the existing
	# entry at cursor+1 (which is at scene=0, cmd=2) → divergence.
	_runtime.engine.context.pending_jump = "branch"
	# Advance once: engine processes pending_jump → moves to scene 1,
	# emits scene_changed → force_next_anchor → dispatches first dialogue
	# at (1,0) → backlog truncates from cursor (1) and appends.
	await _advance(1)

	var entries = _runtime.backlog_manager.get_entries()
	# entries should be: [original 0, original 1, new (1,0)] = 3 entries
	assert_eq(entries.size(), 3, "diverged entries truncated")
	assert_eq(entries[2]["scene_index"], 1)
	assert_eq(entries[2]["command_index"], 0)
	# The new entry should be a forced anchor (because scene_changed fired)
	assert_not_null(entries[2].get("snapshot"))

	_runtime.engine.stop()
	SignalBus.advance_requested.emit()
	await get_tree().process_frame
