extends GutTest
## Disk-backed E2E coverage for screen-effect DSL commands.
##
## Each test exercises the production path:
## .stla file -> lexer -> parser -> scenario engine -> registered handler ->
## SignalBus -> ScreenEffects in the built-in game scene.

const GAME_SCENE := preload("res://addons/stella/scenes/game.tscn")
const DEMO_GAME_SCENE := preload("res://examples/demo/scenes/game.tscn")
const FIXTURE_ROOT := "res://tests/fixtures/scenarios/screen_effects"
const COVERAGE_EPSILON := 0.01
const EFFECT_SETTINGS_PATH := "user://tests/issue138_effect_settings.json"

var _game: Node2D
var _background_layer: CanvasLayer
var _stage_layer: CanvasLayer
var _ui_layer: CanvasLayer
var _background_shake_root: Control
var _stage_shake_root: Control
var _effects: Node
var _engine: ScenarioEngine
var _effect_events: Array[Dictionary] = []
var _effect_listener: Callable
var _original_settings: Dictionary
var _original_settings_path: String


func before_each() -> void:
	_original_settings = StellaRuntime.settings_manager.settings.to_dict()
	_original_settings_path = StellaRuntime.settings_manager.settings_path
	StellaRuntime.set_setting("effect_enabled", true)
	_engine = null
	_game = GAME_SCENE.instantiate()
	add_child_autoqfree(_game)
	await get_tree().process_frame

	_background_layer = _game.get_node("BackgroundLayer")
	_stage_layer = _game.get_node("StageLayer")
	_ui_layer = _game.get_node("UILayer")
	_background_shake_root = _game.get_node("BackgroundLayer/ShakeRoot")
	_stage_shake_root = _game.get_node("StageLayer/ShakeRoot")
	_effects = _game.get_node("ScreenEffects")

	_effect_events.clear()
	_effect_listener = func(effect_type: String, params: Dictionary):
		_effect_events.append({
			"type": effect_type,
			"params": params.duplicate(true),
		})
	SignalBus.effect_requested.connect(_effect_listener)


func after_each() -> void:
	if _effect_listener.is_valid() and SignalBus.effect_requested.is_connected(_effect_listener):
		SignalBus.effect_requested.disconnect(_effect_listener)

	# Release a failed test from @wait click and clear any active presentation
	# state before the next test starts.
	if _engine != null and _engine.context != null and not _engine.context.is_finished:
		_engine.stop()
		SignalBus.engine_abort_requested.emit()
		await get_tree().process_frame

	if is_instance_valid(_game):
		_game.queue_free()
		await get_tree().process_frame
	for key in _original_settings:
		StellaRuntime.settings_manager.set_value(key, _original_settings[key])
	StellaRuntime.settings_manager.settings_path = _original_settings_path
	if FileAccess.file_exists(EFFECT_SETTINGS_PATH):
		DirAccess.remove_absolute(
			ProjectSettings.globalize_path(EFFECT_SETTINGS_PATH))


func test_builtin_shake_coverage_handles_absolute_maximum_at_all_corners() -> void:
	var background: TextureRect = _game.get_node("BackgroundLayer/ShakeRoot/BgFront")
	var viewport_size := _game.get_viewport().get_visible_rect().size
	background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	background.texture = _exact_texture(Vector2i(viewport_size))
	background.modulate.a = 1.0
	await get_tree().process_frame

	var root_position := _background_shake_root.position
	var root_scale := _background_shake_root.scale
	var root_pivot := _background_shake_root.pivot_offset
	var root_size := _background_shake_root.size
	var stage_scale := _stage_shake_root.scale
	assert_eq(
		_effects.shake_coverage_target_paths,
		[NodePath("../BackgroundLayer/ShakeRoot")],
	)

	var intensity: float = _effects.ABSOLUTE_MAX_SHAKE_INTENSITY
	SignalBus.effect_requested.emit("shake", {"intensity": intensity, "duration": 5.0})
	var tween: Tween = _effects._shake_tween
	assert_not_null(tween)
	if tween == null:
		return
	assert_almost_eq(_effects._shake_intensity, intensity, 0.001)
	assert_gt(_background_shake_root.scale.x, 1.0)
	assert_eq(_background_shake_root.scale.x, _background_shake_root.scale.y)
	assert_eq(_background_shake_root.size, root_size)
	assert_eq(_stage_shake_root.scale, stage_scale)
	_assert_four_corner_coverage(background, tween, intensity, viewport_size)

	SignalBus.effect_requested.emit("off", {})
	assert_eq(_background_shake_root.position, root_position)
	assert_eq(_background_shake_root.scale, root_scale)
	assert_eq(_background_shake_root.pivot_offset, root_pivot)
	assert_eq(_background_shake_root.size, root_size)
	assert_eq(_stage_shake_root.scale, stage_scale)


func test_active_shake_recomputes_coverage_after_viewport_resize() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1920, 1080)
	add_child_autoqfree(viewport)
	_game.reparent(viewport, false)
	await get_tree().process_frame
	await get_tree().process_frame

	var background: TextureRect = _game.get_node("BackgroundLayer/ShakeRoot/BgFront")
	background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	background.texture = _exact_texture(viewport.size)
	background.modulate.a = 1.0
	await get_tree().process_frame

	var root_position := _background_shake_root.position
	var root_scale := _background_shake_root.scale
	var root_pivot := _background_shake_root.pivot_offset
	var stage_scale := _stage_shake_root.scale
	var intensity := 100.0
	SignalBus.effect_requested.emit("shake", {"intensity": intensity, "duration": 5.0})
	var tween: Tween = _effects._shake_tween
	assert_not_null(tween)
	if tween == null:
		return
	var scale_before_resize := _background_shake_root.scale

	var resized_size := Vector2i(960, 540)
	viewport.size = resized_size
	background.texture = _exact_texture(resized_size)
	var settled: bool = await wait_until(
		func(): return _background_shake_root.size.is_equal_approx(Vector2(resized_size)),
		1.0,
		"ShakeRoot follows the resized SubViewport",
	)
	assert_true(settled)
	if not settled:
		return
	await get_tree().process_frame

	assert_gt(
		_background_shake_root.scale.x,
		scale_before_resize.x,
		"smaller viewport requires a larger coverage scale",
	)
	assert_true(
		_background_shake_root.pivot_offset.is_equal_approx(Vector2(resized_size) * 0.5)
	)
	assert_true(_stage_shake_root.size.is_equal_approx(Vector2(resized_size)))
	assert_eq(_stage_shake_root.scale, stage_scale)
	_assert_four_corner_coverage(background, tween, intensity, Vector2(resized_size))

	SignalBus.effect_requested.emit("off", {})
	assert_eq(_background_shake_root.position, root_position)
	assert_eq(_background_shake_root.scale, root_scale)
	assert_eq(_background_shake_root.pivot_offset, root_pivot)
	assert_true(_background_shake_root.size.is_equal_approx(Vector2(resized_size)))
	assert_eq(_stage_shake_root.scale, stage_scale)


func test_shake_coverage_composes_with_slide_left_transition() -> void:
	var front: TextureRect = _game.get_node("BackgroundLayer/ShakeRoot/BgFront")
	var back: TextureRect = _game.get_node("BackgroundLayer/ShakeRoot/BgBack")
	var viewport_size := _game.get_viewport().get_visible_rect().size
	front.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	back.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	var old_texture := _exact_texture(Vector2i(viewport_size), Color.RED)
	var new_texture := _exact_texture(Vector2i(viewport_size), Color.BLUE)
	front.texture = old_texture
	front.modulate.a = 1.0
	back.texture = null
	back.modulate.a = 0.0
	await get_tree().process_frame

	var front_origin := front.position
	var back_origin := back.position
	var root_position := _background_shake_root.position
	var root_scale := _background_shake_root.scale
	var root_pivot := _background_shake_root.pivot_offset
	var intensity := 64.0
	var duration := 0.4
	SignalBus.effect_requested.emit("shake", {"intensity": intensity, "duration": 5.0})
	var tween: Tween = _effects._shake_tween
	assert_not_null(tween)
	if tween == null:
		return

	_background_layer._transition_slide(new_texture, duration, "slide_left")
	var saw_transition_motion := false
	for sample in range(6):
		await get_tree().create_timer(0.05).timeout
		var delta := (
			Vector2(intensity, intensity)
			if sample % 2 == 0
			else Vector2(-intensity, -intensity)
		)
		_effects._apply_shake_offset(tween, delta)
		saw_transition_motion = (
			saw_transition_motion or not front.position.is_equal_approx(front_origin)
		)
		_assert_slide_pair_covers_viewport(front, back, viewport_size)

	assert_true(saw_transition_motion, "slide_left must actually animate")
	await get_tree().create_timer(duration + 0.1).timeout
	assert_eq(front.position, front_origin)
	assert_eq(back.position, back_origin)
	assert_same(front.texture, new_texture)
	assert_almost_eq(front.modulate.a, 1.0, 0.001)
	assert_almost_eq(back.modulate.a, 0.0, 0.001)

	SignalBus.effect_requested.emit("off", {})
	assert_eq(_background_shake_root.position, root_position)
	assert_eq(_background_shake_root.scale, root_scale)
	assert_eq(_background_shake_root.pivot_offset, root_pivot)


func test_builtin_and_demo_scenes_configure_background_coverage_only() -> void:
	assert_eq(
		_effects.shake_coverage_target_paths,
		[NodePath("../BackgroundLayer/ShakeRoot")],
	)
	var demo_game := DEMO_GAME_SCENE.instantiate()
	var demo_effects: Node = demo_game.get_node("ScreenEffects")
	assert_eq(
		demo_effects.shake_coverage_target_paths,
		[NodePath("../BackgroundLayer/ShakeRoot")],
	)
	demo_game.free()


func test_dynamic_stage_layer_moves_with_the_stage_shake_root() -> void:
	var stage := _stage_layer as StagePresenter
	stage._on_stage_operations_requested([{
		"action": "show",
		"id": "shake_probe",
		"properties": {"position": [320.0, 240.0]},
		"transition": "cut",
		"duration": 0.0,
	}], true)
	var layer := stage.get_layer_node("shake_probe")
	assert_same(layer.get_parent(), _stage_shake_root)
	var root_baseline := _stage_shake_root.position
	var layer_global_baseline := layer.global_position

	SignalBus.effect_requested.emit("shake", {"intensity": 32.0, "duration": 5.0})
	var tween: Tween = _effects._shake_tween
	assert_not_null(tween)
	if tween == null:
		return
	var delta := Vector2(17.0, -11.0)
	_effects._apply_shake_offset(tween, delta)
	assert_eq(_stage_shake_root.position, root_baseline + delta)
	assert_eq(layer.global_position, layer_global_baseline + delta)
	SignalBus.effect_requested.emit("off", {})
	assert_eq(_stage_shake_root.position, root_baseline)
	assert_eq(layer.global_position, layer_global_baseline)


func test_shake_fixture_reaches_the_real_game_presenter() -> void:
	var background_root_baseline := Vector2(11.0, -7.0)
	var stage_root_baseline := Vector2(-5.0, 9.0)
	var background_layer_baseline := Vector2(40.0, -12.0)
	var stage_layer_baseline := Vector2(-18.0, 30.0)
	var ui_baseline := Vector2(2.0, -3.0)
	_background_shake_root.position = background_root_baseline
	_stage_shake_root.position = stage_root_baseline
	_background_layer.offset = background_layer_baseline
	_stage_layer.offset = stage_layer_baseline
	_ui_layer.offset = ui_baseline

	_start_fixture("shake_params.stla")
	if not await _wait_for_command(1, "shake fixture reaches its active checkpoint"):
		return
	if not _has_effect_events(1, "shake fixture must emit its effect event"):
		return

	assert_eq(_event_types(), ["shake"])
	assert_almost_eq(_effect_events[0]["params"].get("intensity", 0.0), 32.0, 0.001)
	assert_almost_eq(_effect_events[0]["params"].get("duration", 0.0), 5.0, 0.001)
	assert_not_null(_effects._shake_tween, "the production presenter must start a shake tween")
	assert_true(_effects._shake_targets.has(_background_shake_root))
	assert_true(_effects._shake_targets.has(_stage_shake_root))
	assert_eq(_effects._shake_targets.size(), 2, "UI must not be a shake target")
	assert_eq(_effects._shake_baselines.get(_background_shake_root), background_root_baseline)
	assert_eq(_effects._shake_baselines.get(_stage_shake_root), stage_root_baseline)

	# Sample several random deltas. Their exact values are deliberately not
	# asserted; only actual movement and the rigid-stage invariant are relevant.
	var observed_movement := false
	for _frame in range(4):
		await get_tree().process_frame
		var background_delta := _background_shake_root.position - background_root_baseline
		var stage_delta := _stage_shake_root.position - stage_root_baseline
		observed_movement = observed_movement or background_delta.length() > 0.001
		assert_lt(background_delta.distance_to(stage_delta), 0.001)
	assert_true(observed_movement, "shake must move the configured stage layers")
	assert_eq(_background_layer.offset, background_layer_baseline)
	assert_eq(_stage_layer.offset, stage_layer_baseline)
	assert_eq(_ui_layer.offset, ui_baseline)

	# Exercise real composition: camera/pan state can change after shake starts.
	var updated_background_offset := Vector2(77.0, -25.0)
	var updated_stage_offset := Vector2(-33.0, 61.0)
	_background_layer.offset = updated_background_offset
	_stage_layer.offset = updated_stage_offset
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(_background_layer.offset, updated_background_offset)
	assert_eq(_stage_layer.offset, updated_stage_offset)

	SignalBus.advance_requested.emit()
	if not await _wait_for_command(3, "shake fixture reaches its cleared checkpoint"):
		return
	assert_eq(_event_types(), ["shake", "off"])
	assert_null(_effects._shake_tween)
	assert_eq(_background_shake_root.position, background_root_baseline)
	assert_eq(_stage_shake_root.position, stage_root_baseline)
	assert_eq(_background_layer.offset, updated_background_offset)
	assert_eq(_stage_layer.offset, updated_stage_offset)
	assert_eq(_ui_layer.offset, ui_baseline)
	await _finish_fixture()


func test_flash_fixture_reaches_the_real_game_presenter() -> void:
	var configured_flash_canvas: CanvasLayer = _effects.get_node("FlashCanvas")
	assert_eq(_effects.flash_canvas_path, NodePath("FlashCanvas"))
	assert_same(_effects._flash_canvas, configured_flash_canvas)
	assert_false(_effects._owns_flash_canvas, "built-in scene should use its serialized host")
	var highest_other_layer := -2147483648
	for canvas in _game.find_children("*", "CanvasLayer", true, false):
		if canvas != configured_flash_canvas:
			highest_other_layer = maxi(highest_other_layer, (canvas as CanvasLayer).layer)
	assert_gt(
		configured_flash_canvas.layer,
		highest_other_layer,
		"built-in flash host must be above every other serialized CanvasLayer",
	)

	_start_fixture("flash_params.stla")
	if not await _wait_for_command(1, "flash fixture reaches its active checkpoint"):
		return
	if not _has_effect_events(1, "flash fixture must emit its effect event"):
		return

	assert_eq(_event_types(), ["flash"])
	assert_eq(_effect_events[0]["params"].get("color", ""), "#ff3366")
	assert_almost_eq(_effect_events[0]["params"].get("duration", 0.0), 5.0, 0.001)
	var overlay := _find_flash_overlay()
	assert_not_null(overlay, "the production presenter must create a flash overlay")
	if overlay != null:
		assert_eq(overlay.color, Color.from_string("#ff3366", Color.WHITE))
		assert_eq(overlay.mouse_filter, Control.MOUSE_FILTER_IGNORE)
		var canvas := _find_canvas_ancestor(overlay)
		assert_not_null(canvas)
		if canvas != null:
			assert_same(canvas, configured_flash_canvas)
			assert_gt(canvas.layer, highest_other_layer, "flash must render above every scene layer")
		assert_eq(overlay.z_index, RenderingServer.CANVAS_ITEM_Z_MAX)

	SignalBus.advance_requested.emit()
	if not await _wait_for_command(3, "flash fixture reaches its cleared checkpoint"):
		return
	assert_eq(_event_types(), ["flash", "off"])
	assert_null(_effects._flash_tween)
	assert_null(_effects._flash_overlay)
	await get_tree().process_frame
	assert_null(_find_flash_overlay(), "@effect off must free the old flash overlay")
	await _finish_fixture()


func test_off_fixture_clears_shake_and_flash_together() -> void:
	var background_baseline := Vector2(7.0, 4.0)
	var stage_baseline := Vector2(-8.0, 3.0)
	_background_shake_root.position = background_baseline
	_stage_shake_root.position = stage_baseline

	_start_fixture("effect_off.stla")
	if not await _wait_for_command(2, "off fixture reaches its active checkpoint"):
		return

	assert_eq(_event_types(), ["shake", "flash"])
	assert_not_null(_effects._shake_tween)
	assert_not_null(_effects._flash_tween)
	assert_not_null(_find_flash_overlay())

	SignalBus.advance_requested.emit()
	if not await _wait_for_command(4, "off fixture reaches its cleared checkpoint"):
		return
	if not _has_effect_events(3, "off fixture must emit shake, flash, and off events"):
		return
	assert_eq(_event_types(), ["shake", "flash", "off"])
	assert_true(_effect_events[2]["params"].get("off", false))
	assert_null(_effects._shake_tween)
	assert_null(_effects._flash_tween)
	assert_null(_effects._flash_overlay)
	assert_eq(_background_shake_root.position, background_baseline)
	assert_eq(_stage_shake_root.position, stage_baseline)
	await _finish_fixture()


func test_disabled_dsl_effects_complete_without_builtin_mutation_or_replay() -> void:
	var background_baseline := Vector2(9.0, -4.0)
	var stage_baseline := Vector2(-6.0, 7.0)
	_background_shake_root.position = background_baseline
	_stage_shake_root.position = stage_baseline
	StellaRuntime.set_setting("effect_enabled", false)

	_start_fixture("disabled_policy.stla")
	if not await _wait_for_command(2,
			"suppressed non-blocking effects reach the authored click checkpoint"):
		return

	assert_eq(_event_types(), ["shake", "flash"],
		"the setting gates only the built-in presenter, not the public signal")
	assert_null(_effects._shake_tween)
	assert_null(_effects._flash_tween)
	assert_null(_effects._flash_overlay)
	assert_true(_effects._shake_targets.is_empty())
	assert_eq(_background_shake_root.position, background_baseline)
	assert_eq(_stage_shake_root.position, stage_baseline)

	var custom := CommandData.new()
	custom.type = "effect"
	custom.params = {
		"effect_type": "synthetic_project_effect",
		"args": ["payload"],
	}
	StellaRuntime.registry.get_handler("effect").execute(
		custom, _engine.context)
	assert_eq(_event_types(), ["shake", "flash", "synthetic_project_effect"],
		"project-defined effects remain observable while built-ins are disabled")
	assert_eq(_effect_events[-1]["params"].get("args", []), ["payload"])
	assert_null(_effects._shake_tween)
	assert_null(_effects._flash_tween)

	var fade_events: Array[Dictionary] = []
	var stage_events: Array[Dictionary] = []
	var on_fade := func(direction: String, duration: float) -> void:
		fade_events.append({"direction": direction, "duration": duration})
	var on_stage := func(operations: Array, force_cut: bool) -> void:
		stage_events.append({
			"operations": operations.duplicate(true),
			"force_cut": force_cut,
		})
	SignalBus.fade_requested.connect(on_fade)
	SignalBus.stage_operations_requested.connect(on_stage)
	var fade := CommandData.new()
	fade.type = "fade"
	fade.params = {"direction": "out", "duration": 0.0}
	StellaRuntime.registry.get_handler("fade").execute(fade, _engine.context)
	var stage := CommandData.new()
	stage.type = "stage_layer"
	stage.params = {
		"action": "clear",
		"id": "",
		"properties": {},
		"transition": "cut",
		"duration": 0.0,
	}
	StellaRuntime.registry.get_handler("stage_layer").execute(stage, _engine.context)
	SignalBus.fade_requested.disconnect(on_fade)
	SignalBus.stage_operations_requested.disconnect(on_stage)
	assert_eq(fade_events, [{"direction": "out", "duration": 0.0}],
		"effect suppression cannot consume independent fade commands")
	assert_eq(stage_events.size(), 1,
		"effect suppression cannot consume independent stage commands")
	if not stage_events.is_empty():
		assert_eq(stage_events[0]["operations"][0].get("action", ""), "clear")

	StellaRuntime.set_setting("effect_enabled", true)
	assert_null(_effects._shake_tween,
		"suppressed shake requests are dropped rather than replayed")
	assert_null(_effects._flash_tween,
		"suppressed flash requests are dropped rather than replayed")
	SignalBus.effect_requested.emit("flash", {"color": "blue", "duration": 5.0})
	assert_not_null(_effects._flash_tween,
		"a newly authored effect is admitted after re-enable")


func test_successful_runtime_load_disables_active_effects_and_reset_readmits_new_ones() -> void:
	StellaRuntime.settings_manager.settings_path = EFFECT_SETTINGS_PATH
	StellaRuntime.set_setting("effect_enabled", false)
	StellaRuntime.settings_manager.save()
	StellaRuntime.set_setting("effect_enabled", true)

	SignalBus.effect_requested.emit("shake", {"intensity": 20.0, "duration": 5.0})
	SignalBus.effect_requested.emit("flash", {"color": "red", "duration": 5.0})
	assert_not_null(_effects._shake_tween)
	assert_not_null(_effects._flash_tween)
	StellaRuntime.settings_manager.load_settings()

	assert_false(bool(StellaRuntime.get_setting("effect_enabled")))
	assert_null(_effects._shake_tween,
		"the successful load notification synchronously neutralizes active shake")
	assert_null(_effects._flash_tween,
		"the successful load notification synchronously neutralizes active flash")
	assert_null(_effects._flash_overlay)
	assert_eq(_background_shake_root.position, Vector2.ZERO)
	assert_eq(_stage_shake_root.position, Vector2.ZERO)

	StellaRuntime.reset_settings()
	assert_true(bool(StellaRuntime.get_setting("effect_enabled")))
	SignalBus.effect_requested.emit("shake", {"intensity": 8.0, "duration": 5.0})
	SignalBus.effect_requested.emit("flash", {"color": "blue", "duration": 5.0})
	assert_not_null(_effects._shake_tween,
		"reset re-enables only subsequently requested effects")
	assert_not_null(_effects._flash_tween)


func _start_fixture(file_name: String) -> void:
	assert_not_null(StellaRuntime.registry, "the production command registry must exist")
	assert_true(StellaRuntime.registry.has_handler("effect"), "EffectHandler must be registered")
	assert_true(StellaRuntime.registry.has_handler("wait"), "WaitHandler must be registered")

	_engine = ScenarioEngine.new()
	_engine.registry = StellaRuntime.registry
	_engine.load_scenario(_load_fixture(file_name))
	_engine.run()


func _load_fixture(file_name: String) -> ScenarioData:
	var path := FIXTURE_ROOT.path_join(file_name)
	var file := FileAccess.open(path, FileAccess.READ)
	assert_not_null(file, "fixture must exist: %s" % path)
	if file == null:
		return ScenarioData.new()

	var source := file.get_as_text()
	file.close()
	var data := DslParser.parse(DslLexer.tokenize(source), file_name.get_basename())
	assert_eq(data.diagnostics, [], "fixture must parse without diagnostics: %s" % path)
	assert_eq(data.scenes.size(), 1, "fixture should stay focused on one scene")
	return data


func _wait_for_command(command_index: int, message: String) -> bool:
	var reached: bool = await wait_until(
		func(): return _engine.context.current_command_index == command_index,
		1.0,
		message,
	)
	assert_true(reached, message)
	return reached


func _finish_fixture() -> void:
	SignalBus.advance_requested.emit()
	var finished: bool = await wait_until(
		func(): return _engine.context.is_finished,
		1.0,
		"fixture reaches completion after its final checkpoint",
	)
	assert_true(finished)


func _event_types() -> Array:
	var types: Array = []
	for event in _effect_events:
		types.append(event["type"])
	return types


func _has_effect_events(minimum: int, message: String) -> bool:
	var has_events := _effect_events.size() >= minimum
	assert_true(has_events, message)
	return has_events


func _find_flash_overlay() -> ColorRect:
	return _find_color_rect_in(_effects)


func _find_color_rect_in(node: Node) -> ColorRect:
	if node is ColorRect:
		return node
	for child in node.get_children():
		var found := _find_color_rect_in(child)
		if found != null:
			return found
	return null


func _find_canvas_ancestor(node: Node) -> CanvasLayer:
	var ancestor := node.get_parent()
	while ancestor != null and not ancestor is CanvasLayer:
		ancestor = ancestor.get_parent()
	return ancestor as CanvasLayer


func _canvas_aabb(item: Control) -> Rect2:
	var transform := item.get_global_transform_with_canvas()
	var points := [
		transform * Vector2.ZERO,
		transform * Vector2(item.size.x, 0.0),
		transform * item.size,
		transform * Vector2(0.0, item.size.y),
	]
	var minimum: Vector2 = points[0]
	var maximum: Vector2 = points[0]
	for point: Vector2 in points:
		minimum.x = minf(minimum.x, point.x)
		minimum.y = minf(minimum.y, point.y)
		maximum.x = maxf(maximum.x, point.x)
		maximum.y = maxf(maximum.y, point.y)
	return Rect2(minimum, maximum - minimum)


func _exact_texture(size: Vector2i, color: Color = Color.WHITE) -> ImageTexture:
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return ImageTexture.create_from_image(image)


func _assert_four_corner_coverage(
	background: TextureRect,
	tween: Tween,
	intensity: float,
	viewport_size: Vector2,
) -> void:
	for delta in [
		Vector2(intensity, intensity),
		Vector2(intensity, -intensity),
		Vector2(-intensity, intensity),
		Vector2(-intensity, -intensity),
	]:
		_effects._apply_shake_offset(tween, delta)
		var covered_rect := _canvas_aabb(background)
		assert_true(
			covered_rect.position.x <= COVERAGE_EPSILON \
				and covered_rect.position.y <= COVERAGE_EPSILON \
				and covered_rect.end.x >= viewport_size.x - COVERAGE_EPSILON \
				and covered_rect.end.y >= viewport_size.y - COVERAGE_EPSILON,
			"%s must cover %s at shake delta %s" % [covered_rect, viewport_size, delta],
		)


func _assert_slide_pair_covers_viewport(
	front: TextureRect,
	back: TextureRect,
	viewport_size: Vector2,
) -> void:
	var front_rect := _canvas_aabb(front)
	var back_rect := _canvas_aabb(back)
	var left_rect := front_rect
	var right_rect := back_rect
	if left_rect.position.x > right_rect.position.x:
		var swap := left_rect
		left_rect = right_rect
		right_rect = swap

	assert_true(front_rect.position.y <= COVERAGE_EPSILON)
	assert_true(front_rect.end.y >= viewport_size.y - COVERAGE_EPSILON)
	assert_true(back_rect.position.y <= COVERAGE_EPSILON)
	assert_true(back_rect.end.y >= viewport_size.y - COVERAGE_EPSILON)
	assert_true(left_rect.position.x <= COVERAGE_EPSILON)
	assert_true(right_rect.end.x >= viewport_size.x - COVERAGE_EPSILON)
	assert_true(
		left_rect.end.x >= right_rect.position.x - COVERAGE_EPSILON,
		"slide backgrounds must remain adjacent: %s / %s" % [left_rect, right_rect],
	)
