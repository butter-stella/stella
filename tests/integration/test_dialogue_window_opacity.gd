extends GutTest
## Native GameSettings.text_window_opacity consumption and ownership coverage.

const FIXTURE := preload(
	"res://tests/integration/fixtures/dialogue_window_opacity.tscn")
const SETTINGS_PATH := "user://issue137_dialogue_window_opacity.json"
const AUTHORED_BACKGROUND_MODULATE := Color(0.75, 1.0, 0.5, 0.6)
const AUTHORED_BACKGROUND_SELF_MODULATE := Color(0.8, 0.7, 0.6, 0.75)

var _original_settings: Dictionary
var _original_settings_path: String
var _presenters: Array[Control] = []


func before_each() -> void:
	_original_settings = StellaRuntime.settings_manager.to_dict()
	_original_settings_path = StellaRuntime.settings_manager.settings_path
	_presenters.clear()
	_remove_settings_fixture()


func after_each() -> void:
	for presenter: Control in _presenters:
		if not is_instance_valid(presenter):
			continue
		if presenter.get_parent() != null:
			presenter.get_parent().remove_child(presenter)
		presenter.free()
	_presenters.clear()
	StellaRuntime.settings_manager.settings_path = _original_settings_path
	for key: String in _original_settings:
		StellaRuntime.settings_manager.set_value(key, _original_settings[key])
	_remove_settings_fixture()


func test_initial_and_live_boundaries_only_project_the_background() -> void:
	assert_true(StellaRuntime.set_setting("text_window_opacity", 0.5))
	var presenter := _add_presenter()
	var background := _background(presenter)
	var unaffected := _unaffected_visuals(presenter)
	var unaffected_state := _capture_canvas_state(unaffected)

	assert_eq(background.modulate, AUTHORED_BACKGROUND_MODULATE)
	_assert_background_projection(background, 0.5)
	for opacity: float in [0.0, 1.0, 0.5]:
		assert_true(StellaRuntime.set_setting("text_window_opacity", opacity))
		_assert_background_projection(background, opacity)
		assert_eq(background.modulate, AUTHORED_BACKGROUND_MODULATE,
			"live changes preserve the authored/Profile modulation channel")
		_assert_canvas_state(unaffected, unaffected_state)


func test_active_live_change_does_not_reopen_or_replace_dialogue() -> void:
	assert_true(StellaRuntime.set_setting("character_interval", 0))
	assert_true(StellaRuntime.set_setting("punctuation_pause", 0))
	assert_true(StellaRuntime.set_setting("text_window_opacity", 1.0))
	var presenter := _add_presenter()
	SignalBus.emit_show_dialogue("Speaker", [{
		"text": "Active live dialogue",
		"voice_layers": [],
		"presentation_ops": [],
	}], "adv")
	var generation: int = presenter.get("_dialogue_gen")
	var label: RichTextLabel = presenter.get_node("TextRegion/TextLabel")
	var name_label: Label = presenter.get_node("TextRegion/NameLabel")
	var background := _background(presenter)
	assert_true(presenter.visible)
	assert_eq(label.text, "Active live dialogue")
	assert_eq(name_label.text, "Speaker")

	assert_true(StellaRuntime.set_setting("text_window_opacity", 0.0))
	assert_eq(presenter.get("_dialogue_gen"), generation)
	assert_true(presenter.visible)
	assert_eq(label.text, "Active live dialogue")
	assert_eq(name_label.text, "Speaker")
	_assert_background_projection(background, 0.0)
	assert_eq(label.self_modulate.a, 1.0)
	assert_eq(name_label.self_modulate.a, 1.0)
	assert_eq(
		(presenter.get_node("AvatarContainer/AvatarProbe") as CanvasItem
		).self_modulate.a,
		1.0,
	)
	assert_eq(
		(presenter.get_node("FocusableProbe") as CanvasItem).self_modulate.a,
		1.0,
	)


func test_load_and_reset_update_the_same_live_owner_atomically() -> void:
	StellaRuntime.settings_manager.settings_path = SETTINGS_PATH
	assert_true(StellaRuntime.set_setting("text_window_opacity", 0.25))
	assert_eq(StellaRuntime.save_settings(), OK)
	assert_true(StellaRuntime.set_setting("text_window_opacity", 1.0))
	var presenter := _add_presenter()
	var background := _background(presenter)
	_assert_background_projection(background, 1.0)
	var background_id := background.get_instance_id()

	assert_eq(StellaRuntime.settings_manager.load_settings(), OK)
	assert_eq(background.get_instance_id(), background_id)
	_assert_background_projection(background, 0.25)
	StellaRuntime.reset_settings()
	assert_eq(background.get_instance_id(), background_id)
	_assert_background_projection(
		background, GameSettings.new().text_window_opacity)


func test_profile_restore_and_repeated_live_updates_never_multiply_twice() -> void:
	assert_true(StellaRuntime.set_setting("text_window_opacity", 0.5))
	var presenter := _add_presenter()
	var background := _background(presenter)
	var profile := DialogueModeProfile.from_dictionary({
		"background_modulate": Color(0.2, 0.4, 0.8, 0.4),
	})

	for _iteration: int in range(3):
		presenter.call("_apply_mode_profile", "nvl", profile)
		assert_almost_eq(background.modulate.a, 0.4, 0.000001)
		_assert_background_projection(background, 0.5)
		assert_almost_eq(_effective_background_alpha(background), 0.15, 0.000001,
			"profile alpha × authored self alpha × setting is applied once")
		assert_true(StellaRuntime.set_setting("text_window_opacity", 1.0))
		_assert_background_projection(background, 1.0)
		assert_almost_eq(_effective_background_alpha(background), 0.3, 0.000001)
		assert_true(StellaRuntime.set_setting("text_window_opacity", 0.5))
		presenter.call("_restore_authored_presentation")
		assert_eq(background.modulate, AUTHORED_BACKGROUND_MODULATE)
		_assert_background_projection(background, 0.5)
		assert_almost_eq(_effective_background_alpha(background), 0.225, 0.000001)


func test_scene_replacement_reads_current_value_and_retires_old_owner() -> void:
	assert_true(StellaRuntime.set_setting("text_window_opacity", 0.5))
	var retired := _add_presenter()
	var retired_background := _background(retired)
	_assert_background_projection(retired_background, 0.5)
	remove_child(retired)

	var replacement := _add_presenter()
	var replacement_background := _background(replacement)
	_assert_background_projection(replacement_background, 0.5)
	assert_true(StellaRuntime.set_setting("text_window_opacity", 0.25))
	_assert_background_projection(replacement_background, 0.25)
	_assert_background_projection(retired_background, 0.5)
	assert_false(SignalBus.settings_changed.is_connected(
		retired._on_presenter_setting_changed),
		"retired scene ownership disconnects the settings consumer")
	assert_true(SignalBus.settings_changed.is_connected(
		replacement._on_presenter_setting_changed))


func test_invalid_explicit_bindings_fail_closed_without_tree_guessing() -> void:
	var presenter := FIXTURE.instantiate() as Control
	presenter.dialogue_background_path = NodePath()
	assert_null(presenter.call("_resolve_text_window_background"))
	assert_push_warning("dialogue_background_path is empty")
	presenter.dialogue_background_path = NodePath("MissingBackground")
	assert_null(presenter.call("_resolve_text_window_background"))
	assert_push_warning(
		"dialogue_background_path 'MissingBackground' does not resolve")
	presenter.dialogue_background_path = NodePath("NonControlProbe")
	assert_null(presenter.call("_resolve_text_window_background"))
	assert_push_warning(
		"dialogue_background_path 'NonControlProbe' must resolve to Control, got Node2D")
	assert_eq(
		(presenter.get_node("WindowBackground") as Control).self_modulate,
		AUTHORED_BACKGROUND_SELF_MODULATE,
		"a sibling background-looking node is never guessed as a fallback",
	)
	presenter.free()


func test_self_ancestor_sibling_and_absolute_bindings_fail_strict_ownership() -> void:
	var host := Control.new()
	host.name = "BindingHost"
	host.self_modulate = Color(0.2, 0.3, 0.4, 0.7)
	add_child_autoqfree(host)
	var external := ColorRect.new()
	external.name = "ExternalControl"
	external.offset_left = 12.0
	external.offset_top = 14.0
	external.offset_right = 112.0
	external.offset_bottom = 74.0
	external.modulate = Color(0.9, 0.8, 0.7, 0.6)
	external.self_modulate = Color(0.5, 0.4, 0.3, 0.8)
	host.add_child(external)
	var host_state := _capture_control_state(host)
	var external_state := _capture_control_state(external)
	var bindings: Array[NodePath] = [
		NodePath("."),
		NodePath(".."),
		NodePath("../ExternalControl"),
		external.get_path(),
	]
	var opacity_changes: Array[float] = [0.0, 1.0, 0.5, 0.25]

	for index: int in range(bindings.size()):
		var presenter := FIXTURE.instantiate() as Control
		presenter.dialogue_background_path = bindings[index]
		host.add_child(presenter)
		var resolved_path := presenter.get_path()
		if index == 1:
			resolved_path = host.get_path()
		elif index > 1:
			resolved_path = external.get_path()
		assert_push_warning((
			"DialoguePresenter scene 'res://tests/integration/fixtures/"
			+ "dialogue_window_opacity.tscn': dialogue_background_path '%s' "
			+ "resolves to '%s' outside strict "
			+ "Presenter descendant ownership"
		) % [bindings[index], resolved_path])
		assert_null(presenter.get("_dialogue_bg"))
		var presenter_self_modulate := presenter.self_modulate
		var internal_background := _background(presenter)
		assert_true(StellaRuntime.set_setting(
			"text_window_opacity", opacity_changes[index]))
		assert_eq(presenter.self_modulate, presenter_self_modulate,
			"a self binding never projects opacity onto the Presenter")
		assert_eq(internal_background.self_modulate,
			AUTHORED_BACKGROUND_SELF_MODULATE,
			"an invalid owner never falls back to a background-looking descendant")
		_assert_control_state(host, host_state)
		_assert_control_state(external, external_state)
		host.remove_child(presenter)
		presenter.free()


func _add_presenter() -> Control:
	var presenter := FIXTURE.instantiate() as Control
	_presenters.append(presenter)
	add_child(presenter)
	return presenter


func _background(presenter: Control) -> Control:
	return presenter.get_node("WindowBackground") as Control


func _unaffected_visuals(presenter: Control) -> Array[CanvasItem]:
	return [
		presenter,
		presenter.get_node("PanelProbe") as CanvasItem,
		presenter.get_node("TextRegion/NameLabel") as CanvasItem,
		presenter.get_node("TextRegion/TextLabel") as CanvasItem,
		presenter.get_node("AvatarContainer/AvatarProbe") as CanvasItem,
		presenter.get_node("Toolbar") as CanvasItem,
		presenter.get_node("FocusableProbe") as CanvasItem,
	]


func _capture_canvas_state(nodes: Array[CanvasItem]) -> Array[Dictionary]:
	var states: Array[Dictionary] = []
	for node: CanvasItem in nodes:
		states.append({
			"modulate": node.modulate,
			"self_modulate": node.self_modulate,
		})
	return states


func _capture_control_state(control: Control) -> Dictionary:
	return {
		"visible": control.visible,
		"modulate": control.modulate,
		"self_modulate": control.self_modulate,
		"anchors": Vector4(
			control.anchor_left,
			control.anchor_top,
			control.anchor_right,
			control.anchor_bottom,
		),
		"offsets": Vector4(
			control.offset_left,
			control.offset_top,
			control.offset_right,
			control.offset_bottom,
		),
	}


func _assert_control_state(control: Control, state: Dictionary) -> void:
	assert_eq(control.visible, state["visible"])
	assert_eq(control.modulate, state["modulate"])
	assert_eq(control.self_modulate, state["self_modulate"])
	assert_eq(Vector4(
		control.anchor_left,
		control.anchor_top,
		control.anchor_right,
		control.anchor_bottom,
	), state["anchors"])
	assert_eq(Vector4(
		control.offset_left,
		control.offset_top,
		control.offset_right,
		control.offset_bottom,
	), state["offsets"])


func _assert_canvas_state(
	nodes: Array[CanvasItem],
	states: Array[Dictionary],
) -> void:
	for index: int in range(nodes.size()):
		assert_eq(nodes[index].modulate, states[index]["modulate"])
		assert_eq(nodes[index].self_modulate, states[index]["self_modulate"])


func _assert_background_projection(background: Control, opacity: float) -> void:
	var expected := AUTHORED_BACKGROUND_SELF_MODULATE
	expected.a *= opacity
	assert_eq(background.self_modulate, expected)


func _effective_background_alpha(background: Control) -> float:
	return background.modulate.a * background.self_modulate.a


func _remove_settings_fixture() -> void:
	if FileAccess.file_exists(SETTINGS_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS_PATH))
