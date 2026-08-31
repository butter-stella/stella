extends GutTest
## Scene-authored issue #144 contract using the exact built-in Presenter.

const RuntimeTestSupport = preload("res://tests/helpers/runtime_test_support.gd")
const DIALOGUE_PRESENTER_SCRIPT = preload(
	"res://addons/stella/presentation/dialogue/dialogue_presenter.gd")
const STELLA_ACTION_SCRIPT = preload(
	"res://addons/stella/presentation/ui/stella_action.gd")
const REPLACEMENT_DIALOGUE_FIXTURE = preload(
	"res://tests/integration/fixtures/dialogue_window_opacity.tscn")
const TOOLBAR_ACTION_IDS: Array[StringName] = [
	StellaActionRegistry.ACTION_VOICE_REPLAY,
	StellaActionRegistry.ACTION_AUTO,
	StellaActionRegistry.ACTION_SKIP,
	StellaActionRegistry.ACTION_BACKLOG,
	StellaActionRegistry.ACTION_PREV_CHOICE,
	StellaActionRegistry.ACTION_QUICK_SAVE,
	StellaActionRegistry.ACTION_QUICK_LOAD,
	StellaActionRegistry.ACTION_SAVE,
	StellaActionRegistry.ACTION_LOAD,
	StellaActionRegistry.ACTION_SETTINGS,
]

var _runtime: Node
var _game: Node
var _saved_action_registry: StellaActionRegistry
var _saved_scenario_path: String
var _saved_settings_scene: String
var _saved_navigation_override: Callable
var _saved_save_dir: String
const ACTION_TEST_SAVE_DIR := "user://issue144_action_registry_e2e/"


func before_each() -> void:
	_runtime = get_tree().root.get_node("StellaRuntime")
	_saved_action_registry = _runtime.action_registry
	_saved_scenario_path = _runtime.config.scenario_path
	_saved_settings_scene = _runtime.config.settings_scene
	_saved_navigation_override = _runtime._navigation_scene_change_override
	_saved_save_dir = _runtime.save_manager.save_dir
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	_runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	_game = load("res://addons/stella/scenes/game.tscn").instantiate()
	add_child_autoqfree(_game)
	await get_tree().process_frame


func after_each() -> void:
	if _runtime.action_registry != _saved_action_registry:
		_runtime.action_registry = _saved_action_registry
	_runtime.config.scenario_path = _saved_scenario_path
	_runtime.config.settings_scene = _saved_settings_scene
	_runtime._navigation_scene_change_override = _saved_navigation_override
	_runtime.save_manager.save_dir = _saved_save_dir
	var action_test_dir := ProjectSettings.globalize_path(ACTION_TEST_SAVE_DIR)
	var quick_path := action_test_dir.path_join("quicksave.json")
	if FileAccess.file_exists(quick_path):
		DirAccess.remove_absolute(quick_path)
	if DirAccess.dir_exists_absolute(action_test_dir):
		DirAccess.remove_absolute(action_test_dir)
	if is_instance_valid(_game):
		_game.queue_free()
		await _game.tree_exited
	await get_tree().process_frame
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())


func _dialogue() -> Control:
	return _game.get_node("UILayer/DialoguePanel") as Control


func _toolbar() -> HBoxContainer:
	return _game.get_node("UILayer/DialoguePanel/Toolbar") as HBoxContainer


func _buttons_by_action() -> Dictionary:
	var result: Dictionary = {}
	for child: Node in _toolbar().get_children():
		if not child is BaseButton:
			continue
		for binding_node: Node in child.get_children():
			if binding_node is StellaAction:
				result[(binding_node as StellaAction).get_action_id()] = child
	return result


func test_exact_presenter_admits_before_tracking_ten_authored_buttons() -> void:
	var dialogue := _dialogue()
	assert_same(dialogue.get_script(), DIALOGUE_PRESENTER_SCRIPT,
		"the scene uses the exact framework script, not a project subclass")
	assert_not_null(dialogue._dialogue_clear_participant_capability)
	assert_not_null(dialogue._dialogue_avatar_participant_capability)
	assert_not_null(dialogue._presentation_clip_participant_capability)

	var buttons := _buttons_by_action()
	assert_eq(buttons.size(), TOOLBAR_ACTION_IDS.size())
	for action_id: StringName in TOOLBAR_ACTION_IDS:
		assert_has(buttons, action_id)
		var button := buttons[action_id] as BaseButton
		assert_null(button.get_script(),
			"authored toolbar visuals need no per-Button project script")
		var binding := button.get_node("StellaAction") as StellaAction
		assert_same(binding.get_script(), STELLA_ACTION_SCRIPT)
		assert_false(binding.is_processing())
		assert_false(binding.is_physics_processing())


func test_setup_toolbar_preserves_authored_identity_skin_and_geometry() -> void:
	var dialogue := _dialogue()
	var toolbar := _toolbar()
	var before_ids: Array[int] = []
	var before_text: Array[String] = []
	for child: Node in toolbar.get_children():
		before_ids.append(child.get_instance_id())
		before_text.append((child as BaseButton).text)
	var auto_button := toolbar.get_node("Auto") as Button
	var authored_icon := GradientTexture1D.new()
	auto_button.icon = authored_icon
	auto_button.custom_minimum_size = Vector2(137, 41)
	auto_button.modulate = Color(0.2, 0.4, 0.6, 0.35)

	dialogue._setup_toolbar()

	assert_eq(toolbar.get_child_count(), 10)
	for index: int in range(toolbar.get_child_count()):
		var child := toolbar.get_child(index) as BaseButton
		assert_eq(child.get_instance_id(), before_ids[index])
		assert_eq(child.text, before_text[index])
	assert_same(auto_button.icon, authored_icon)
	assert_eq(auto_button.custom_minimum_size, Vector2(137, 41))
	_runtime.toggle_auto_play()
	assert_eq(auto_button.modulate, Color(0.2, 0.4, 0.6, 0.35),
		"Presenter toggle edges never tint an authored Button")

	var buttons := _buttons_by_action()
	var voice_button := buttons[StellaActionRegistry.ACTION_VOICE_REPLAY] as Button
	var voice_binding := voice_button.get_node("StellaAction") as StellaAction
	voice_binding.sync_availability = false
	voice_binding.hide_when_unavailable = false
	voice_button.disabled = false
	voice_button.visible = true
	voice_button.text = "AUTHORED VOICE"
	voice_button.modulate = Color(0.7, 0.1, 0.3, 0.45)
	dialogue._dialogue_total_duration = 0.0
	_runtime.notify_action_state_changed(StellaActionRegistry.ACTION_VOICE_REPLAY)
	assert_false(voice_button.disabled)
	assert_true(voice_button.visible)
	assert_eq(voice_button.text, "AUTHORED VOICE")
	assert_eq(voice_button.modulate, Color(0.7, 0.1, 0.3, 0.45))

	var prev_button := buttons[StellaActionRegistry.ACTION_PREV_CHOICE] as Button
	var prev_binding := prev_button.get_node("StellaAction") as StellaAction
	prev_binding.sync_availability = false
	prev_button.disabled = false
	_runtime.notify_action_state_changed(StellaActionRegistry.ACTION_PREV_CHOICE)
	assert_false(prev_button.disabled,
		"Presenter state edges respect binding availability opt-out")


func _authored_action_button(action_id: StringName) -> Button:
	var button := Button.new()
	var binding := StellaAction.new()
	binding.action_id = action_id
	button.add_child(binding)
	add_child_autoqfree(button)
	return button


func test_predicate_dependencies_publish_binding_edges_without_polling() -> void:
	var dialogue := _dialogue()
	var hide_button := _authored_action_button(
		StellaActionRegistry.ACTION_HIDE_UI)
	dialogue.visible = true
	dialogue._ui_hidden = false
	dialogue._set_is_typing(true)
	assert_true(hide_button.disabled)
	dialogue._set_is_typing(false)
	assert_false(hide_button.disabled)

	var advance_button := _authored_action_button(
		StellaActionRegistry.ACTION_ADVANCE)
	assert_false(advance_button.disabled)
	var choice_session: int = _runtime._begin_choice_policy_session()
	assert_gt(choice_session, 0)
	assert_true(advance_button.disabled)
	assert_true(_runtime._resolve_choice_policy_session(choice_session))
	assert_false(advance_button.disabled)

	var flowchart_button := _authored_action_button(
		StellaActionRegistry.ACTION_FLOWCHART)
	_runtime._set_scenario_graph(null)
	assert_true(flowchart_button.disabled)
	_runtime._set_scenario_graph(ScenarioGraph.new())
	assert_false(flowchart_button.disabled)

	var quit_button := _authored_action_button(StellaActionRegistry.ACTION_QUIT)
	assert_false(quit_button.disabled)
	var old_quit_requested: bool = _runtime._quit_requested
	var old_quit_code: int = _runtime._quit_exit_code
	assert_true(_runtime._begin_quit_request(0))
	assert_true(quit_button.disabled)
	_runtime._quit_requested = old_quit_requested
	_runtime._quit_exit_code = old_quit_code
	_runtime.notify_action_state_changed(StellaActionRegistry.ACTION_QUIT)


func test_state_projection_listeners_cannot_reenter_runtime_transactions() -> void:
	var nested_results: Array[int] = []
	var watched_action := [StellaActionRegistry.ACTION_ADVANCE]
	var nested_action := [StellaActionRegistry.ACTION_AUTO]
	var listener := func(action_id: StringName) -> void:
		if action_id == watched_action[0]:
			nested_results.append(_runtime.execute_action(nested_action[0]))
	_runtime.action_registry.action_state_changed.connect(listener)

	_runtime.set_setting("auto_play_pause_on_choice", true)
	var choice_session: int = _runtime._begin_choice_policy_session()
	assert_gt(choice_session, 0)
	assert_eq(nested_results, [StellaActionRegistry.ExecuteResult.FAILED])
	assert_false(_runtime.is_auto_playing())
	assert_true(_runtime._active_choice_auto_suspension,
		"the retired listener cannot interrupt the choice begin tail")
	assert_true(_runtime._resolve_choice_policy_session(choice_session))

	nested_results.clear()
	watched_action[0] = StellaActionRegistry.ACTION_CANCEL
	nested_action[0] = StellaActionRegistry.ACTION_CANCEL
	assert_true(_runtime.show_settings())
	assert_false(nested_results.is_empty())
	assert_true(nested_results.all(func(result: int) -> bool:
		return result == StellaActionRegistry.ExecuteResult.FAILED))
	assert_not_null(_runtime._current_overlay)
	assert_true(_runtime._current_overlay.is_inside_tree(),
		"overlay attachment commits despite hostile state listeners")
	assert_eq(_runtime.game_state.current_state, GameStateMachine.State.SETTINGS)
	assert_true(_runtime.close_overlay())

	nested_results.clear()
	watched_action[0] = StellaActionRegistry.ACTION_HIDE_UI
	nested_action[0] = StellaActionRegistry.ACTION_ADVANCE
	var dialogue := _dialogue()
	var dialogue_generation: int = dialogue._dialogue_gen
	dialogue._set_is_typing(true)
	dialogue._set_is_typing(false)
	assert_false(nested_results.is_empty())
	assert_true(nested_results.all(func(result: int) -> bool:
		return result == StellaActionRegistry.ExecuteResult.FAILED))
	assert_eq(dialogue._dialogue_gen, dialogue_generation,
		"a typing projection cannot advance or replace the current line")

	_runtime.action_registry.action_state_changed.disconnect(listener)


func test_failed_navigation_receipt_is_not_reported_as_admitted() -> void:
	var previous_generation: int = _runtime._navigation_generation
	var navigation: int = _runtime._begin_navigation("quick_load")
	assert_eq(navigation, previous_generation + 1)
	_runtime._abort_action_navigation(navigation)
	assert_false(_runtime._navigation_was_admitted(
		previous_generation, "quick_load"))
	assert_eq(_runtime._navigation_failed_generation, navigation)
	assert_eq(_runtime._navigation_kind, "")
	assert_eq(_runtime._navigation_runtime_ownership_generation, 0)
	assert_eq(_runtime._navigation_presentation_reset_generation, 0)


func test_in_game_quick_load_post_begin_failure_settles_action_navigation() -> void:
	var scenario_path := "res://examples/demo/scenarios/demo.stla"
	_runtime.save_manager.save_dir = ACTION_TEST_SAVE_DIR
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(ACTION_TEST_SAVE_DIR))
	assert_true(_runtime._prepare_scenario(scenario_path))
	_runtime._last_scenario_path = scenario_path
	_runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	assert_true(_runtime.quick_save())
	var action_entry: Dictionary = _runtime.action_registry._get_live_entry(
		StellaActionRegistry.ACTION_QUICK_LOAD)
	var execution_count := int(action_entry["execution_count"])
	var transaction_id := 144001
	assert_true(_runtime.presentation_clip_audio_choice_authority.hold(
		transaction_id))

	assert_eq(
		_runtime.execute_action(StellaActionRegistry.ACTION_QUICK_LOAD),
		StellaActionRegistry.ExecuteResult.FAILED,
		"a restore rejected after navigation begin is not reported as executed",
	)
	assert_push_error(
		"StellaRuntime: presentation-clip audio-choice initial checkpoint restore failed")
	assert_eq(int(action_entry["execution_count"]), execution_count)
	assert_eq(_runtime._navigation_kind, "")
	assert_eq(_runtime._navigation_runtime_ownership_generation, 0)
	assert_eq(_runtime._navigation_presentation_reset_generation, 0)
	assert_eq(_runtime.movie_presenter._restore_ticket, 0)
	assert_eq(_runtime.movie_presenter._armed_restore_ticket, 0)
	assert_true(_runtime.presentation_clip_audio_choice_authority.abort(
		transaction_id))


func test_builtin_dispatch_reports_preflight_failure_and_async_admission() -> void:
	_runtime.game_state.transition_to(GameStateMachine.State.TITLE)
	_runtime.config.scenario_path = "res://tests/fixtures/missing/action_registry.stla"
	assert_true(_runtime.can_execute_action(StellaActionRegistry.ACTION_START_GAME),
		"nonempty authored path passes the side-effect-free catalog predicate")
	assert_eq(
		_runtime.execute_action(StellaActionRegistry.ACTION_START_GAME),
		StellaActionRegistry.ExecuteResult.FAILED,
		"the execute callback propagates the facade's real parse rejection",
	)
	assert_push_error("StellaRuntime: cannot open res://tests/fixtures/missing/action_registry.stla")

	_runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	_runtime.config.settings_scene = (
		"res://tests/fixtures/missing/action_registry_settings.tscn")
	assert_eq(
		_runtime.execute_action(StellaActionRegistry.ACTION_SETTINGS),
		StellaActionRegistry.ExecuteResult.FAILED,
		"an unloadable overlay is never reported as executed",
	)
	assert_push_error("StellaRuntime: overlay scene is not available")

	_runtime.game_state.transition_to(GameStateMachine.State.TITLE)
	_runtime.config.scenario_path = "res://examples/demo/scenarios/demo.stla"
	_runtime.save_manager.save_dir = ACTION_TEST_SAVE_DIR
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(ACTION_TEST_SAVE_DIR))
	var corrupt := FileAccess.open(
		ACTION_TEST_SAVE_DIR + "quicksave.json", FileAccess.WRITE)
	assert_not_null(corrupt)
	corrupt.store_string('{"scenario_context":"corrupt"}')
	corrupt.close()
	assert_true(_runtime.can_execute_action(
		StellaActionRegistry.ACTION_QUICK_LOAD))
	assert_eq(
		_runtime.execute_action(StellaActionRegistry.ACTION_QUICK_LOAD),
		StellaActionRegistry.ExecuteResult.FAILED,
		"a corrupt save fails before navigation admission",
	)

	_runtime.game_state.transition_to(GameStateMachine.State.TITLE)
	_runtime.config.scenario_path = "res://examples/demo/scenarios/demo.stla"
	_runtime._navigation_scene_change_override = (
		func(_scene: PackedScene) -> int: return OK)
	assert_eq(
		_runtime.execute_action(StellaActionRegistry.ACTION_START_GAME),
		StellaActionRegistry.ExecuteResult.EXECUTED,
		"successful synchronous preflight reports accepted before async settlement",
	)
	var slot := int(_runtime._navigation_scene_slot_active_serial)
	assert_gt(slot, 0)
	_runtime._settle_navigation_scene_slot(slot, false)
	await wait_until(
		func() -> bool: return _runtime._navigation_kind.is_empty(), 2.0)


func test_authored_buttons_follow_live_availability_and_active_events() -> void:
	var buttons := _buttons_by_action()
	var auto_button := buttons[StellaActionRegistry.ACTION_AUTO] as Button
	var skip_button := buttons[StellaActionRegistry.ACTION_SKIP] as Button
	var voice_button := (
		buttons[StellaActionRegistry.ACTION_VOICE_REPLAY] as Button)
	var prev_button := (
		buttons[StellaActionRegistry.ACTION_PREV_CHOICE] as Button)

	assert_false(auto_button.disabled)
	assert_false(skip_button.disabled)
	assert_true(auto_button.toggle_mode)
	assert_true(skip_button.toggle_mode)
	assert_false(auto_button.button_pressed)
	assert_false(skip_button.button_pressed)
	assert_true(voice_button.disabled)
	assert_false(voice_button.visible)
	assert_true(prev_button.disabled)

	auto_button.pressed.emit()
	assert_true(_runtime.is_auto_playing())
	assert_true(auto_button.button_pressed)
	assert_false(skip_button.button_pressed)

	skip_button.pressed.emit()
	assert_true(_runtime.is_skipping())
	assert_false(_runtime.is_auto_playing())
	assert_true(skip_button.button_pressed)
	assert_false(auto_button.button_pressed)

	_runtime.game_state.transition_to(GameStateMachine.State.SAVE_LOAD)
	for action_id: StringName in TOOLBAR_ACTION_IDS:
		var button := buttons[action_id] as Button
		assert_true(button.disabled,
			"%s becomes unavailable under the overlay state" % action_id)
	assert_false(auto_button.button_pressed)
	assert_false(skip_button.button_pressed)


func test_newest_overlapping_exact_presenter_takes_over_then_old_resumes() -> void:
	var old_presenter := _dialogue()
	old_presenter.visible = true
	old_presenter._ui_hidden = false
	var replacement := REPLACEMENT_DIALOGUE_FIXTURE.instantiate() as Control
	add_child(replacement)
	assert_not_null(replacement._dialogue_clear_participant_capability)
	assert_not_null(replacement._dialogue_avatar_participant_capability)
	assert_not_null(replacement._presentation_clip_participant_capability)
	replacement.visible = true
	replacement._ui_hidden = false
	assert_same(_runtime._get_dialogue_action_presenter(), replacement)

	assert_eq(
		_runtime.execute_action(StellaActionRegistry.ACTION_HIDE_UI),
		StellaActionRegistry.ExecuteResult.EXECUTED,
	)
	assert_true(replacement._ui_hidden)
	assert_false(old_presenter._ui_hidden,
		"the underlay Presenter must not receive the replacement action")

	replacement.queue_free()
	await replacement.tree_exited
	assert_same(_runtime._get_dialogue_action_presenter(), old_presenter)
	old_presenter.visible = true
	old_presenter._ui_hidden = false
	assert_eq(
		_runtime.execute_action(StellaActionRegistry.ACTION_HIDE_UI),
		StellaActionRegistry.ExecuteResult.EXECUTED,
	)
	assert_true(old_presenter._ui_hidden,
		"the next newest live owner resumes after replacement exit")

	var invalid_owner := Node.new()
	var invalid_ref: WeakRef = weakref(invalid_owner)
	invalid_owner.free()
	_runtime._dialogue_action_presenters.append(invalid_ref)
	assert_same(_runtime._get_dialogue_action_presenter(), old_presenter)
	assert_eq(_runtime._dialogue_action_presenters.size(), 1,
		"invalid weak entries are pruned instead of accumulating")


func test_failed_publication_rolls_back_all_three_typed_admissions() -> void:
	var clear_count := SignalBus._dialogue_clear_participants.size()
	var avatar_count := SignalBus._dialogue_avatar_participants.size()
	var clip_count := SignalBus._presentation_clip_dialogue_participants.size()
	_runtime.action_registry = null
	var rejected := REPLACEMENT_DIALOGUE_FIXTURE.instantiate() as Control
	add_child(rejected)
	assert_push_error(
		"DialoguePresenter could not join the public action dispatcher")
	assert_null(rejected._dialogue_clear_participant_capability)
	assert_null(rejected._dialogue_avatar_participant_capability)
	assert_null(rejected._presentation_clip_participant_capability)
	assert_eq(SignalBus._dialogue_clear_participants.size(), clear_count)
	assert_eq(SignalBus._dialogue_avatar_participants.size(), avatar_count)
	assert_eq(
		SignalBus._presentation_clip_dialogue_participants.size(), clip_count)
	assert_eq(_runtime._dialogue_action_presenters.size(), 1)
	_runtime.action_registry = _saved_action_registry
	rejected.free()


func test_runtime_custom_owner_exit_does_not_contaminate_next_registration() -> void:
	var first := preload(
		"res://tests/helpers/action_registry_owner_fixture.gd").new()
	add_child(first)
	assert_true(_runtime.register_action(
		&"e2e.open_codex",
		{"label": "Codex", "category": "test"},
		first,
		Callable(first, "execute_action"),
	))
	first.queue_free()
	await first.tree_exited
	await get_tree().process_frame
	assert_true(_runtime.get_action(&"e2e.open_codex").is_empty())

	var second := preload(
		"res://tests/helpers/action_registry_owner_fixture.gd").new()
	add_child(second)
	assert_true(_runtime.register_action(
		&"e2e.open_codex",
		{"label": "Codex", "category": "test"},
		second,
		Callable(second, "execute_action"),
	))
	assert_eq(_runtime.get_action(&"e2e.open_codex")["label"], "Codex")
	var authored_button := Button.new()
	var binding := StellaAction.new()
	binding.action_id = &"e2e.open_codex"
	authored_button.add_child(binding)
	add_child(authored_button)
	authored_button.pressed.emit()
	assert_eq(second.execute_count, 1)
	authored_button.free()
	second.queue_free()
	await second.tree_exited
	await get_tree().process_frame
	assert_true(_runtime.get_action(&"e2e.open_codex").is_empty())


func test_texture_button_uses_canonical_action_without_a_text_surface() -> void:
	var owner := preload(
		"res://tests/helpers/action_registry_owner_fixture.gd").new()
	add_child(owner)
	var action_id := &"e2e.texture_button"
	assert_true(_runtime.register_action(
		action_id,
		{"label": "Texture action", "category": "test"},
		owner,
		Callable(owner, "execute_action"),
	))
	var initial_catalog_connections: int = (
		_runtime.action_registry.catalog_changed.get_connections().size()
	)
	var initial_state_connections: int = (
		_runtime.action_registry.action_state_changed.get_connections().size()
	)
	var button := TextureButton.new()
	var binding := StellaAction.new()
	binding.action_id = action_id
	binding.sync_label = false
	button.add_child(binding)
	add_child(button)

	assert_false(button.disabled)
	assert_eq(
		_runtime.action_registry.catalog_changed.get_connections().size(),
		initial_catalog_connections + 1,
	)
	assert_eq(
		_runtime.action_registry.action_state_changed.get_connections().size(),
		initial_state_connections + 1,
	)
	button.pressed.emit()
	assert_eq(owner.execute_count, 1)

	button.free()
	assert_eq(
		_runtime.action_registry.catalog_changed.get_connections().size(),
		initial_catalog_connections,
	)
	assert_eq(
		_runtime.action_registry.action_state_changed.get_connections().size(),
		initial_state_connections,
	)
	assert_true(_runtime.unregister_action(action_id, owner))
	owner.queue_free()
	await owner.tree_exited


func test_texture_button_label_projection_fails_closed() -> void:
	var owner := preload(
		"res://tests/helpers/action_registry_owner_fixture.gd").new()
	add_child(owner)
	var action_id := &"e2e.texture_label"
	assert_true(_runtime.register_action(
		action_id,
		{"label": "Texture label", "category": "test"},
		owner,
		Callable(owner, "execute_action"),
	))
	var button := TextureButton.new()
	var binding := StellaAction.new()
	binding.action_id = action_id
	binding.sync_availability = false
	binding.sync_label = true
	button.add_child(binding)
	add_child(button)

	assert_push_error(
		"StellaAction: sync_label requires a Button parent; "
		+ "TextureButton has no text surface"
	)
	assert_true(button.disabled)
	button.pressed.emit()
	assert_eq(owner.execute_count, 0)
	_runtime.notify_action_state_changed(action_id)
	assert_true(button.disabled)
	button.pressed.emit()
	assert_eq(owner.execute_count, 0)

	binding.sync_label = false
	assert_false(button.disabled)
	button.pressed.emit()
	assert_eq(owner.execute_count, 1)
	button.free()
	assert_true(_runtime.unregister_action(action_id, owner))
	owner.queue_free()
	await owner.tree_exited
