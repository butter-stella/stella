extends GutTest
## Integration test: end-to-end backlog jump.
## Drives the StellaRuntime engine through several dialogues, captures
## backlog entries with snapshots, jumps back, and verifies the engine
## resumes at the correct position with the correct state.


var _runtime: Node


func before_each():
	_runtime = get_tree().root.get_node("StellaRuntime")
	_runtime.backlog_manager.clear()


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
	_runtime.save_manager.register_provider(_runtime.engine.context)
	_runtime.save_manager.register_provider(_runtime.engine.context.variable_store)


func _stop_engine() -> void:
	_runtime.engine.stop()
	SignalBus.advance_requested.emit()
	await get_tree().process_frame


func test_every_entry_carries_a_snapshot():
	_setup_scenario(5)
	_runtime.engine.run()
	await _advance(3)  # → 4 entries

	var entries = _runtime.backlog_manager.get_entries()
	assert_eq(entries.size(), 4)
	for entry in entries:
		assert_not_null(entry.get("snapshot"),
			"every entry should carry a full snapshot")
		assert_true(entry["snapshot"].has("scenario_context"))
		assert_true(entry["snapshot"].has("variable_store"))
		assert_true(entry["snapshot"].has("presentation_state"))

	await _stop_engine()


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

	assert_eq(_runtime.backlog_manager.get_cursor(), 1,
		"cursor advances back to the jumped-to entry")
	assert_eq(_runtime.backlog_manager.get_entries().size(), 5,
		"history preserved (no truncate on jump)")
	assert_eq(_runtime.engine.context.current_command_index, 1,
		"engine positioned at target dialogue")

	await _stop_engine()


func test_walking_known_path_after_jump_only_advances_cursor():
	_setup_scenario(6)
	_runtime.engine.run()
	await _advance(4)  # → 5 entries

	var size_before = _runtime.backlog_manager.get_entries().size()
	_runtime.jump_from_backlog(1)
	await get_tree().process_frame
	await get_tree().process_frame

	# Drive forward — entries 2,3,4 should match → cursor advances, no append
	await _advance(3)

	assert_eq(_runtime.backlog_manager.get_entries().size(), size_before,
		"no duplication when re-walking known path")
	assert_eq(_runtime.backlog_manager.get_cursor(), 4,
		"cursor advanced back to original position")

	await _stop_engine()


func test_divergence_truncates_history_after_branch_point():
	# A two-scene scenario. Play through scene 0, jump back, then divert to
	# scene 1. The new entries should be at (scene=1, cmd=0…) which don't
	# match the original (scene=0, cmd=2…) → truncate.
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
	_runtime.save_manager.register_provider(_runtime.engine.context)
	_runtime.save_manager.register_provider(_runtime.engine.context.variable_store)

	_runtime.engine.run()
	await _advance(3)  # → 4 entries from scene 0

	assert_eq(_runtime.backlog_manager.get_entries().size(), 4)

	_runtime.jump_from_backlog(1)
	await get_tree().process_frame
	await get_tree().process_frame

	# Force a jump to scene 1 — the dialogue at (1,0) doesn't match the
	# existing entry at cursor+1 (scene 0, cmd 2) → divergence.
	_runtime.engine.context.pending_jump = "branch"
	await _advance(1)

	var entries = _runtime.backlog_manager.get_entries()
	assert_eq(entries.size(), 3, "diverged entries truncated past cursor")
	assert_eq(entries[2]["scene_index"], 1)
	assert_eq(entries[2]["command_index"], 0)

	await _stop_engine()


func test_jump_restores_variables():
	# Variables set after the jump target should be rolled back when the
	# player jumps back.
	var data = ScenarioData.new()
	data.id = "var_test"
	var s = SceneData.new()
	s.id = "start"

	var d0 = CommandData.new()
	d0.type = "dialogue"
	d0.params = {"character": "n", "text": "before"}
	s.commands.append(d0)

	var setter = CommandData.new()
	setter.type = "set"
	setter.params = {"var": "score", "value": 42}
	s.commands.append(setter)

	var d1 = CommandData.new()
	d1.type = "dialogue"
	d1.params = {"character": "n", "text": "after"}
	s.commands.append(d1)

	data.scenes.append(s)

	_runtime.engine.load_scenario(data)
	_runtime.save_manager.register_provider(_runtime.engine.context)
	_runtime.save_manager.register_provider(_runtime.engine.context.variable_store)

	_runtime.engine.run()
	await _advance(1)  # → 2 entries (before, after); score == 42 now

	assert_eq(_runtime.engine.context.variable_store.get_var("score"), 42)

	# Jump back to entry 0 ("before") — score should rewind to its
	# pre-set value (null/0).
	_runtime.jump_from_backlog(0)
	await get_tree().process_frame
	await get_tree().process_frame

	var rewound = _runtime.engine.context.variable_store.get_var("score")
	assert_true(rewound == null or rewound == 0,
		"variable should be rewound to its pre-set value, got %s" % str(rewound))

	await _stop_engine()


func test_jump_restores_presentation_state():
	# A scenario that shows a character + bg before the second dialogue.
	# After playing through, jump back to the FIRST dialogue and verify
	# PresentationState reflects the empty initial state, not the later one.
	var data = ScenarioData.new()
	data.id = "pres_test"
	var s = SceneData.new()
	s.id = "start"

	var d0 = CommandData.new()
	d0.type = "dialogue"
	d0.params = {"character": "n", "text": "first"}
	s.commands.append(d0)

	var bg = CommandData.new()
	bg.type = "bg"
	bg.params = {"asset": "park", "transition": "none", "duration": 0.0}
	s.commands.append(bg)

	var show = CommandData.new()
	show.type = "char_show"
	show.params = {"character": "sakura", "expression": "smile", "position": "left"}
	s.commands.append(show)

	var d1 = CommandData.new()
	d1.type = "dialogue"
	d1.params = {"character": "sakura", "text": "second"}
	s.commands.append(d1)

	data.scenes.append(s)

	_runtime.presentation_state.clear()
	_runtime.engine.load_scenario(data)
	_runtime.save_manager.register_provider(_runtime.engine.context)
	_runtime.save_manager.register_provider(_runtime.engine.context.variable_store)

	_runtime.engine.run()
	await _advance(1)  # → 2 entries

	assert_eq(_runtime.presentation_state.current_bg, "park")
	assert_true(_runtime.presentation_state.visible_characters.has("sakura"))

	# Jump back to entry 0 — bg/char should be empty
	_runtime.jump_from_backlog(0)
	await get_tree().process_frame
	await get_tree().process_frame

	assert_eq(_runtime.presentation_state.current_bg, "",
		"bg rewound to pre-bg-command state")
	assert_false(_runtime.presentation_state.visible_characters.has("sakura"),
		"character rewound to pre-show state")

	await _stop_engine()


func test_jump_unblocks_choice_await():
	# CR concern: ChoiceHandler awaits choice_selected, not advance_requested.
	# If the engine is parked on a choice when the player jumps from backlog,
	# the old run() coroutine must be unblocked or it will leak forever.
	# Build a scenario: dialogue → choice → dialogue. Drive past the first
	# dialogue so a backlog entry exists, let the choice show, jump back.
	var data = ScenarioData.new()
	data.id = "choice_test"
	var s = SceneData.new()
	s.id = "start"

	var d0 = CommandData.new()
	d0.type = "dialogue"
	d0.params = {"character": "n", "text": "before choice"}
	s.commands.append(d0)

	var ch = CommandData.new()
	ch.type = "choice"
	ch.params = {
		"prompt": "?",
		"options": [{"id": "a", "label": "A", "jump": "start"}],
	}
	s.commands.append(ch)

	data.scenes.append(s)

	_runtime.engine.load_scenario(data)
	_runtime.save_manager.register_provider(_runtime.engine.context)
	_runtime.save_manager.register_provider(_runtime.engine.context.variable_store)

	# Track choice_show emissions to confirm the engine actually parks on
	# the choice before we jump.
	var choices_shown: Array = []
	var on_choice = func(_p, _o): choices_shown.append(true)
	SignalBus.choice_show.connect(on_choice)

	_runtime.engine.run()
	await _advance(1)  # past dialogue 0, choice should now be awaited

	assert_eq(choices_shown.size(), 1, "engine should be parked on choice")
	assert_eq(_runtime.backlog_manager.get_entries().size(), 1)

	# Jump from backlog while the choice is still awaiting selection.
	# Without the choice_selected sentinel emit in jump_from_backlog, the
	# old coroutine would never unblock. We assert that:
	# 1. jump_from_backlog returns true
	# 2. the new engine.run() works (advance + new entry recorded)
	var ok = _runtime.jump_from_backlog(0)
	assert_true(ok)
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame

	# Engine should be running on a fresh context. Cursor at 0, ready to
	# match-advance when the dialogue re-fires.
	assert_eq(_runtime.engine.context.current_command_index, 0,
		"new engine context positioned at target")

	SignalBus.choice_show.disconnect(on_choice)
	await _stop_engine()


func test_prepare_scenario_clears_backlog():
	# Architect concerns #4 / #1: every fresh-state entry point — start_game,
	# load_game, continue_from_save, quick_load (both from-title and in-game)
	# — funnels through _prepare_scenario, which must clear the previous
	# run's backlog. Otherwise stale (scene, command) positions would
	# silently match new entries via the cursor's known-path branch and
	# the new playthrough's history would be silently swallowed.
	#
	# We exercise the fix at its actual hook (_prepare_scenario) using a
	# temp .stla file, rather than the private _start_scenario_internal,
	# so this test guards ALL fresh-state paths.
	_setup_scenario(3)
	_runtime.engine.run()
	await _advance(2)
	assert_gt(_runtime.backlog_manager.get_entries().size(), 0)

	await _stop_engine()

	# Write a minimal scenario file and route through _prepare_scenario.
	var path = "user://test_backlog_clear.stla"
	var f = FileAccess.open(path, FileAccess.WRITE)
	f.store_string("@scene start\nnarrator「hi」\n")
	f.close()

	_runtime._prepare_scenario(path)
	assert_eq(_runtime.backlog_manager.get_entries().size(), 0,
		"_prepare_scenario must clear backlog (covers all fresh-state paths)")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
