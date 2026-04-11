extends GutTest
## Integration test: end-to-end "回到上一选项" (jump_to_previous_choice).
## Builds scenarios with multiple @choice commands, drives the engine past
## them, and verifies that the runtime façade rewinds to the correct
## previous choice with scenario / variable / presentation state rolled back.


var _runtime: Node


func before_each():
	_runtime = get_tree().root.get_node("StellaRuntime")
	_runtime.backlog_manager.clear()
	_runtime.choice_history_manager.clear()


func _advance(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame
		SignalBus.advance_requested.emit()
	await get_tree().process_frame


func _select(id: String) -> void:
	await get_tree().process_frame
	SignalBus.choice_selected.emit(id)
	await get_tree().process_frame


func _stop_engine() -> void:
	_runtime.engine.stop()
	SignalBus.advance_requested.emit()
	SignalBus.engine_abort_requested.emit()
	await get_tree().process_frame


# Build: dialogue → choice1 → dialogue → choice2 → dialogue.
# Both choices just fall through (no jump).
func _build_two_choice_scenario() -> ScenarioData:
	var data = ScenarioData.new()
	data.id = "two_choice_test"
	var s = SceneData.new()
	s.id = "start"

	var d0 = CommandData.new()
	d0.type = "dialogue"
	d0.params = {"character": "n", "text": "intro"}
	s.commands.append(d0)

	var c1 = CommandData.new()
	c1.type = "choice"
	c1.params = {
		"prompt": "pick1",
		"options": [{"id": "a", "label": "A"}, {"id": "b", "label": "B"}],
	}
	s.commands.append(c1)

	var d1 = CommandData.new()
	d1.type = "dialogue"
	d1.params = {"character": "n", "text": "middle"}
	s.commands.append(d1)

	var c2 = CommandData.new()
	c2.type = "choice"
	c2.params = {
		"prompt": "pick2",
		"options": [{"id": "a", "label": "A"}, {"id": "b", "label": "B"}],
	}
	s.commands.append(c2)

	var d2 = CommandData.new()
	d2.type = "dialogue"
	d2.params = {"character": "n", "text": "tail"}
	s.commands.append(d2)

	data.scenes.append(s)
	return data


func _setup(data: ScenarioData) -> void:
	_runtime.engine.load_scenario(data)
	_runtime.save_manager.register_provider(_runtime.engine.context)
	_runtime.save_manager.register_provider(_runtime.engine.context.variable_store)


# ─── Recording ───

func test_choice_show_records_snapshot():
	_setup(_build_two_choice_scenario())
	_runtime.engine.run()
	await _advance(1)  # past d0 → engine parks on choice1

	assert_eq(_runtime.choice_history_manager.size(), 1,
		"a choice_show should push one entry")

	await _select("a")
	await _advance(1)  # past d1 → engine parks on choice2

	assert_eq(_runtime.choice_history_manager.size(), 2,
		"second choice_show pushes a second entry")

	await _select("a")
	await _stop_engine()


# ─── Jump while past a choice ───

func test_jump_from_after_choice_returns_to_that_choice():
	# Progress through choice1 (select A), past d1, into choice2.
	# Then call jump_to_previous_choice() while parked on choice2 — since
	# choice2 is the top entry and its uid matches the current command,
	# pop_previous skips it and returns choice1.
	_setup(_build_two_choice_scenario())
	var shown: Array = []
	var on_show = func(_p, _o): shown.append(true)
	SignalBus.choice_show.connect(on_show)

	_runtime.engine.run()
	await _advance(1)  # → choice1 shown
	assert_eq(shown.size(), 1)
	await _select("a")
	await _advance(1)  # past d1 → choice2 shown
	assert_eq(shown.size(), 2)
	assert_eq(_runtime.choice_history_manager.size(), 2)

	var ok = _runtime.jump_to_previous_choice()
	assert_true(ok, "should rewind to choice1")
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame

	# After rewind, the new engine context should be at choice1's index
	# (command index 1 in the scenario) AND choice_show should have been
	# re-emitted for it → total emissions = 3.
	assert_eq(shown.size(), 3, "choice1 menu re-appears")
	assert_eq(_runtime.engine.context.current_command_index, 1,
		"engine positioned at choice1 command")

	SignalBus.choice_show.disconnect(on_show)
	await _select("a")
	await _stop_engine()


# ─── Jump while parked on a choice ───

func test_jump_while_parked_on_second_choice_goes_to_first():
	# This is the canonical "park on choice2 → press 回选项 → land on choice1"
	# flow. Engine is mid-await on choice2; jump_to_previous_choice must
	# unblock via engine_abort_requested and restart at choice1.
	_setup(_build_two_choice_scenario())
	var shown: Array = []
	var on_show = func(_p, _o): shown.append(true)
	SignalBus.choice_show.connect(on_show)

	_runtime.engine.run()
	await _advance(1)
	await _select("a")
	await _advance(1)  # engine now parked on choice2 await
	assert_eq(shown.size(), 2)

	var ok = _runtime.jump_to_previous_choice()
	assert_true(ok)
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame

	assert_eq(_runtime.engine.context.current_command_index, 1,
		"landed on choice1 command")
	assert_eq(shown.size(), 3, "choice1 menu re-appeared after abort")

	SignalBus.choice_show.disconnect(on_show)
	await _select("a")
	await _stop_engine()


# ─── Returns false when no history ───

func test_jump_returns_false_when_no_previous_choice():
	_setup(_build_two_choice_scenario())
	_runtime.engine.run()
	await _advance(1)  # parked on choice1 — only this choice recorded

	# Stack has exactly the current choice. pop_previous skips it → {}.
	var ok = _runtime.jump_to_previous_choice()
	assert_false(ok)

	await _select("a")
	await _stop_engine()


func test_jump_returns_false_before_any_choice():
	_setup(_build_two_choice_scenario())
	_runtime.engine.run()
	await get_tree().process_frame  # not even past d0 yet

	var ok = _runtime.jump_to_previous_choice()
	assert_false(ok)

	await _stop_engine()


# ─── Variable rollback ───

func test_jump_rolls_back_variable_set_between_choices():
	# choice1 sets score via its option's `set`; then engine reaches choice2.
	# Rewinding to choice1 should wipe that variable (scenario-scope rollback).
	var data = ScenarioData.new()
	data.id = "var_choice_test"
	var s = SceneData.new()
	s.id = "start"

	var c1 = CommandData.new()
	c1.type = "choice"
	c1.params = {
		"prompt": "p1",
		"options": [{"id": "a", "label": "A", "set": {"score": "= 42"}}],
	}
	s.commands.append(c1)

	var c2 = CommandData.new()
	c2.type = "choice"
	c2.params = {
		"prompt": "p2",
		"options": [{"id": "a", "label": "A"}],
	}
	s.commands.append(c2)

	data.scenes.append(s)
	_setup(data)

	_runtime.engine.run()
	await get_tree().process_frame  # choice1 fires
	await _select("a")  # score = 42, engine advances to choice2
	await get_tree().process_frame
	await get_tree().process_frame

	assert_eq(_runtime.engine.context.variable_store.get_var("score"), 42)
	assert_eq(_runtime.choice_history_manager.size(), 2)

	# Parked on choice2. Rewind to choice1 — score should be gone.
	var ok = _runtime.jump_to_previous_choice()
	assert_true(ok)
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame

	var rewound = _runtime.engine.context.variable_store.get_var("score")
	assert_true(rewound == null or rewound == 0,
		"score rewound to pre-set value, got %s" % str(rewound))

	await _select("a")
	await _stop_engine()


# ─── Clear on fresh scenario ───

func test_prepare_scenario_clears_choice_history():
	_setup(_build_two_choice_scenario())
	_runtime.engine.run()
	await _advance(1)
	assert_gt(_runtime.choice_history_manager.size(), 0)

	# Force-stop (choice is awaiting; abort releases it)
	SignalBus.engine_abort_requested.emit()
	await _stop_engine()

	var path = "user://test_choice_clear.stla"
	var f = FileAccess.open(path, FileAccess.WRITE)
	f.store_string("@chapter ch\n@scene start\nnarrator「hi」\n")
	f.close()

	_runtime._prepare_scenario(path)
	assert_eq(_runtime.choice_history_manager.size(), 0,
		"_prepare_scenario must clear choice history alongside backlog")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
