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


func before_each() -> void:
	_runtime = get_tree().root.get_node("StellaRuntime")
	_saved_action_registry = _runtime.action_registry
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	_runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	_game = load("res://addons/stella/scenes/game.tscn").instantiate()
	add_child_autoqfree(_game)
	await get_tree().process_frame


func after_each() -> void:
	if _runtime.action_registry != _saved_action_registry:
		_runtime.action_registry = _saved_action_registry
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

	dialogue._setup_toolbar()

	assert_eq(toolbar.get_child_count(), 10)
	for index: int in range(toolbar.get_child_count()):
		var child := toolbar.get_child(index) as BaseButton
		assert_eq(child.get_instance_id(), before_ids[index])
		assert_eq(child.text, before_text[index])
	assert_same(auto_button.icon, authored_icon)
	assert_eq(auto_button.custom_minimum_size, Vector2(137, 41))


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
