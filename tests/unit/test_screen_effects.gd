extends GutTest
## Tests ScreenEffects presenter — shake composition, defensive parameter
## validation, cancellation, and configurable flash rendering.

const SCREEN_EFFECTS_SCRIPT = preload("res://addons/stella/presentation/effects/screen_effects.gd")

var _parent: Node2D
var _bg_layer: CanvasLayer
var _char_layer: CanvasLayer
var _ui_layer: CanvasLayer
var _bg_shake_root: Node2D
var _char_shake_root: Node2D
var _effects: Node


func before_each() -> void:
	# Mirror the real game scene: camera/pan offsets live on CanvasLayers while
	# ScreenEffects owns dedicated Node2D roots below the two stage layers.
	_parent = Node2D.new()
	_parent.name = "Game"
	add_child_autoqfree(_parent)

	_bg_layer = CanvasLayer.new()
	_bg_layer.name = "BackgroundLayer"
	_bg_layer.layer = 0
	_parent.add_child(_bg_layer)
	_bg_shake_root = Node2D.new()
	_bg_shake_root.name = "ShakeRoot"
	_bg_layer.add_child(_bg_shake_root)

	_char_layer = CanvasLayer.new()
	_char_layer.name = "CharacterLayer"
	_char_layer.layer = 1
	_parent.add_child(_char_layer)
	_char_shake_root = Node2D.new()
	_char_shake_root.name = "ShakeRoot"
	_char_layer.add_child(_char_shake_root)

	_ui_layer = CanvasLayer.new()
	_ui_layer.name = "UILayer"
	_ui_layer.layer = 3
	_parent.add_child(_ui_layer)

	_effects = Node.new()
	_effects.name = "ScreenEffects"
	_effects.set_script(SCREEN_EFFECTS_SCRIPT)
	var target_paths: Array[NodePath] = [
		NodePath("../BackgroundLayer/ShakeRoot"),
		NodePath("../CharacterLayer/ShakeRoot"),
	]
	_effects.shake_target_paths = target_paths
	_parent.add_child(_effects)
	await get_tree().process_frame


func after_each() -> void:
	if is_instance_valid(_effects):
		_effects._clear_effects()
		# Disconnect to avoid cross-test signal bleed.
		if SignalBus.effect_requested.is_connected(_effects._on_effect):
			SignalBus.effect_requested.disconnect(_effects._on_effect)
		if SignalBus.engine_abort_requested.is_connected(_effects._clear_effects):
			SignalBus.engine_abort_requested.disconnect(_effects._clear_effects)


# --- Shake: dedicated roots move together; surrounding layer offsets compose ---

func test_shake_moves_background_and_character_roots() -> void:
	SignalBus.effect_requested.emit("shake", {"intensity": 50.0, "duration": 0.3})

	var max_bg := 0.0
	var max_char := 0.0
	for _sample in range(6):
		await get_tree().create_timer(0.04).timeout
		max_bg = maxf(max_bg, _bg_shake_root.position.length())
		max_char = maxf(max_char, _char_shake_root.position.length())

	assert_gt(max_bg, 5.0, "background ShakeRoot should move measurably")
	assert_gt(max_char, 5.0, "character ShakeRoot should move measurably")
	await get_tree().create_timer(0.2).timeout
	assert_eq(_bg_shake_root.position, Vector2.ZERO, "background root must reset")
	assert_eq(_char_shake_root.position, Vector2.ZERO, "character root must reset")


func test_shake_uses_shared_delta_and_restores_each_root_baseline() -> void:
	var bg_baseline := Vector2(12.0, -4.0)
	var char_baseline := Vector2(-6.0, 8.0)
	_bg_shake_root.position = bg_baseline
	_char_shake_root.position = char_baseline

	SignalBus.effect_requested.emit("shake", {"intensity": 40.0, "duration": 0.22})
	var saw_motion := false
	for _sample in range(3):
		await get_tree().create_timer(0.055).timeout
		var bg_delta := _bg_shake_root.position - bg_baseline
		var char_delta := _char_shake_root.position - char_baseline
		assert_lt(bg_delta.distance_to(char_delta), 0.001, "stage roots need one shared delta")
		saw_motion = saw_motion or bg_delta.length() > 0.001
	assert_true(saw_motion, "shake should move the configured roots")

	await get_tree().create_timer(0.12).timeout
	assert_eq(_bg_shake_root.position, bg_baseline)
	assert_eq(_char_shake_root.position, char_baseline)


func test_canvas_layer_offsets_can_change_while_shake_is_active() -> void:
	SignalBus.effect_requested.emit("shake", {"intensity": 45.0, "duration": 0.5})
	await get_tree().create_timer(0.06).timeout
	assert_ne(_bg_shake_root.position, Vector2.ZERO, "sanity: shake is active")

	# Simulate a camera/pan presenter changing its transform during the effect.
	var new_bg_offset := Vector2(120.0, -35.0)
	var new_char_offset := Vector2(-20.0, 48.0)
	_bg_layer.offset = new_bg_offset
	_char_layer.offset = new_char_offset
	await get_tree().create_timer(0.12).timeout
	assert_eq(_bg_layer.offset, new_bg_offset, "shake must not overwrite camera offset")
	assert_eq(_char_layer.offset, new_char_offset, "shake must not overwrite camera offset")

	SignalBus.effect_requested.emit("off", {})
	assert_eq(_bg_layer.offset, new_bg_offset, "off must preserve external background offset")
	assert_eq(_char_layer.offset, new_char_offset, "off must preserve external character offset")
	assert_eq(_bg_shake_root.position, Vector2.ZERO)
	assert_eq(_char_shake_root.position, Vector2.ZERO)


func test_effect_off_cancels_shake_and_prevents_old_callbacks() -> void:
	var bg_baseline := Vector2(5.0, -3.0)
	var char_baseline := Vector2(-2.0, 7.0)
	_bg_shake_root.position = bg_baseline
	_char_shake_root.position = char_baseline
	SignalBus.effect_requested.emit("shake", {"intensity": 50.0, "duration": 0.5})
	await get_tree().create_timer(0.06).timeout
	assert_ne(_bg_shake_root.position, bg_baseline, "sanity: shake is active")

	SignalBus.effect_requested.emit("off", {})
	assert_eq(_bg_shake_root.position, bg_baseline)
	assert_eq(_char_shake_root.position, char_baseline)
	await get_tree().create_timer(0.16).timeout
	assert_eq(_bg_shake_root.position, bg_baseline, "cancelled shake must not resume")
	assert_eq(_char_shake_root.position, char_baseline, "cancelled shake must not resume")


func test_replacing_shake_preserves_original_root_baselines() -> void:
	var bg_baseline := Vector2(11.0, 3.0)
	var char_baseline := Vector2(-9.0, -2.0)
	_bg_shake_root.position = bg_baseline
	_char_shake_root.position = char_baseline
	SignalBus.effect_requested.emit("shake", {"intensity": 45.0, "duration": 0.5})
	await get_tree().create_timer(0.06).timeout
	SignalBus.effect_requested.emit("shake", {"intensity": 20.0, "duration": 0.1})
	await get_tree().create_timer(0.16).timeout
	assert_eq(_bg_shake_root.position, bg_baseline)
	assert_eq(_char_shake_root.position, char_baseline)


func test_shake_does_not_touch_ui_layer_or_parent() -> void:
	var ui_baseline := Vector2(3.0, -6.0)
	var parent_baseline := Vector2(9.0, 2.0)
	_ui_layer.offset = ui_baseline
	_parent.position = parent_baseline
	SignalBus.effect_requested.emit("shake", {"intensity": 40.0, "duration": 0.2})
	for _sample in range(5):
		await get_tree().create_timer(0.03).timeout
		assert_eq(_ui_layer.offset, ui_baseline, "dialogue UI must stay still")
		assert_eq(_parent.position, parent_baseline, "game root must stay unchanged")


func test_custom_named_nested_node2d_target_can_be_configured() -> void:
	var visuals := Node.new()
	visuals.name = "Visuals"
	_parent.add_child(visuals)
	var custom_root := Node2D.new()
	custom_root.name = "BackdropShake"
	visuals.add_child(custom_root)
	var baseline := Vector2(14.0, -8.0)
	custom_root.position = baseline
	var custom_paths: Array[NodePath] = [NodePath("../Visuals/BackdropShake")]
	_effects.shake_target_paths = custom_paths

	SignalBus.effect_requested.emit("shake", {"intensity": 30.0, "duration": 0.2})
	await get_tree().create_timer(0.06).timeout
	assert_ne(custom_root.position, baseline, "configured nested Node2D should shake")
	assert_eq(_bg_shake_root.position, Vector2.ZERO, "unconfigured root must stay still")
	assert_eq(_char_shake_root.position, Vector2.ZERO, "unconfigured root must stay still")
	SignalBus.effect_requested.emit("off", {})
	assert_eq(custom_root.position, baseline)


func test_leaving_tree_restores_active_shake_roots() -> void:
	var bg_baseline := Vector2(3.0, 6.0)
	var char_baseline := Vector2(-4.0, 2.0)
	_bg_shake_root.position = bg_baseline
	_char_shake_root.position = char_baseline
	SignalBus.effect_requested.emit("shake", {"intensity": 40.0, "duration": 0.5})
	await get_tree().create_timer(0.06).timeout
	_effects.queue_free()
	await get_tree().process_frame
	assert_eq(_bg_shake_root.position, bg_baseline)
	assert_eq(_char_shake_root.position, char_baseline)


func test_reentering_tree_reuses_canvas_and_reconnects_signals() -> void:
	var original_canvas = _effects._flash_canvas
	_parent.remove_child(_effects)
	assert_false(SignalBus.effect_requested.is_connected(_effects._on_effect))
	assert_false(SignalBus.engine_abort_requested.is_connected(_effects._clear_effects))

	_parent.add_child(_effects)
	await get_tree().process_frame
	assert_same(_effects._flash_canvas, original_canvas, "re-entry must not duplicate FlashCanvas")
	assert_true(SignalBus.effect_requested.is_connected(_effects._on_effect))
	assert_true(SignalBus.engine_abort_requested.is_connected(_effects._clear_effects))


func test_ready_does_not_pause_a_shake_started_after_enter_tree() -> void:
	# Models a sibling `_ready()` emission that arrives after `_enter_tree()` has
	# connected the signal but before ScreenEffects receives its own `_ready()`.
	_effects._on_effect("shake", {"intensity": 20.0, "duration": 0.2})
	assert_true(_effects.is_processing())
	_effects._ready()
	assert_true(_effects.is_processing(), "ready must not freeze a startup shake")
	assert_not_null(_effects._shake_tween)


func test_huge_finite_shake_duration_has_constant_setup_and_can_be_cancelled() -> void:
	# The old implementation attempted range(ceil(duration / 0.05)) here and
	# hung before returning. Reaching the assertions proves setup stays bounded.
	SignalBus.effect_requested.emit("shake", {"intensity": 8.0, "duration": 1.0e300})
	assert_not_null(_effects._shake_tween)
	assert_eq(_effects._shake_targets.size(), 2)
	assert_true(_effects.is_processing())
	SignalBus.effect_requested.emit("off", {})
	assert_null(_effects._shake_tween)
	assert_false(_effects.is_processing())


func test_non_finite_and_non_numeric_shake_params_are_rejected() -> void:
	SignalBus.effect_requested.emit("shake", {"intensity": 10.0, "duration": INF})
	assert_null(_effects._shake_tween)
	assert_push_warning("shake duration must be finite")

	SignalBus.effect_requested.emit("shake", {"intensity": NAN, "duration": 1.0})
	assert_null(_effects._shake_tween)
	assert_push_warning("shake intensity must be finite")

	SignalBus.effect_requested.emit("shake", {"intensity": "strong", "duration": 1.0})
	assert_null(_effects._shake_tween)
	assert_push_warning("shake intensity must be a finite number")


func test_invalid_replacement_shake_still_clears_the_previous_one() -> void:
	SignalBus.effect_requested.emit("shake", {"intensity": 20.0, "duration": 1.0})
	assert_not_null(_effects._shake_tween)
	SignalBus.effect_requested.emit("shake", {"intensity": 20.0, "duration": -1.0})
	assert_null(_effects._shake_tween)
	assert_eq(_bg_shake_root.position, Vector2.ZERO)
	assert_eq(_char_shake_root.position, Vector2.ZERO)
	assert_push_warning("shake duration must be non-negative")


func test_negative_intensity_is_normalized_and_large_intensity_is_clamped() -> void:
	_effects.max_shake_intensity = 7.0
	SignalBus.effect_requested.emit("shake", {"intensity": -100.0, "duration": 0.5})
	assert_almost_eq(_effects._shake_intensity, 7.0, 0.001)
	var delta := _bg_shake_root.position
	assert_true(absf(delta.x) <= 7.0 and absf(delta.y) <= 7.0)
	assert_push_warning("negative shake intensity normalized")
	assert_push_warning("exceeds the configured maximum")


# --- Flash: explicit host when configured; configurable fallback otherwise ---

func test_flash_fallback_canvas_uses_configured_layer_and_max_z_index() -> void:
	_effects.flash_canvas_layer = 27
	SignalBus.effect_requested.emit("flash", {"duration": 0.1})
	await get_tree().process_frame

	var overlay := _find_flash_overlay()
	assert_not_null(overlay)
	assert_eq(_effects._flash_canvas.layer, 27)
	assert_eq(overlay.z_index, RenderingServer.CANVAS_ITEM_Z_MAX)
	assert_eq(overlay.mouse_filter, Control.MOUSE_FILTER_IGNORE)


func test_flash_can_use_external_canvas_without_mutating_or_owning_it() -> void:
	var host := CanvasLayer.new()
	host.name = "TopEffectsLayer"
	host.layer = 123
	_parent.add_child(host)
	_effects.flash_canvas_path = NodePath("../TopEffectsLayer")

	SignalBus.effect_requested.emit("flash", {"color": "red", "duration": 0.5})
	await get_tree().process_frame
	var overlay: ColorRect = _effects._flash_overlay
	assert_not_null(overlay)
	assert_same(overlay.get_parent(), host)
	assert_same(_effects._flash_canvas, host)
	assert_false(_effects._owns_flash_canvas)
	assert_eq(host.layer, 123, "ScreenEffects must not rewrite an external host layer")

	_effects.queue_free()
	await get_tree().process_frame
	assert_true(is_instance_valid(host), "freeing ScreenEffects must not free the host")
	assert_eq(host.layer, 123)


func test_switching_back_to_fallback_reuses_the_private_canvas() -> void:
	var fallback_canvas: CanvasLayer = _effects._flash_canvas
	var host := CanvasLayer.new()
	host.name = "TopEffectsLayer"
	_parent.add_child(host)

	_effects.flash_canvas_path = NodePath("../TopEffectsLayer")
	SignalBus.effect_requested.emit("flash", {"duration": 0.2})
	assert_same(_effects._flash_canvas, host)
	SignalBus.effect_requested.emit("off", {})

	_effects.flash_canvas_path = NodePath()
	SignalBus.effect_requested.emit("flash", {"duration": 0.2})
	assert_same(_effects._flash_canvas, fallback_canvas)
	assert_true(_effects._owns_flash_canvas)
	assert_same(_effects._flash_overlay.get_parent(), fallback_canvas)


func test_invalid_explicit_flash_canvas_does_not_fall_back_silently() -> void:
	_effects.flash_canvas_path = NodePath("../MissingEffectsLayer")
	SignalBus.effect_requested.emit("flash", {"duration": 0.2})
	assert_null(_effects._flash_overlay)
	assert_null(_effects._flash_canvas)
	assert_push_warning("flash canvas not found")


func test_flash_default_and_custom_colors() -> void:
	SignalBus.effect_requested.emit("flash", {"duration": 0.1})
	await get_tree().process_frame
	assert_eq(_find_flash_overlay().color, Color.WHITE)

	SignalBus.effect_requested.emit("flash", {"color": "red", "duration": 0.1})
	await get_tree().process_frame
	assert_eq(_find_flash_overlay().color, Color.RED)

	SignalBus.effect_requested.emit("flash", {"color": "#ff0000", "duration": 0.1})
	await get_tree().process_frame
	assert_eq(_find_flash_overlay().color, Color.RED)

	SignalBus.effect_requested.emit(
		"flash", {"color": "not_a_real_color_name", "duration": 0.1}
	)
	await get_tree().process_frame
	assert_eq(_find_flash_overlay().color, Color.WHITE)


func test_invalid_flash_inputs_are_safe() -> void:
	SignalBus.effect_requested.emit("flash", {"duration": INF})
	assert_null(_effects._flash_tween)
	assert_push_warning("flash duration must be finite")

	SignalBus.effect_requested.emit("flash", {"duration": -1.0})
	assert_null(_effects._flash_tween)
	assert_push_warning("flash duration must be non-negative")

	SignalBus.effect_requested.emit("flash", {"color": 42, "duration": 0.2})
	await get_tree().process_frame
	assert_eq(_find_flash_overlay().color, Color.WHITE)
	assert_push_warning("flash color must be a string")


func test_effect_off_removes_active_flash() -> void:
	SignalBus.effect_requested.emit("flash", {"color": "red", "duration": 0.5})
	await get_tree().process_frame
	assert_not_null(_find_flash_overlay(), "sanity: flash should be active")
	SignalBus.effect_requested.emit("off", {})
	await get_tree().process_frame
	assert_null(_find_flash_overlay())
	await get_tree().create_timer(0.12).timeout
	assert_null(_find_flash_overlay(), "cancelled flash must stay removed")


func test_flash_overlay_is_freed_after_completion() -> void:
	SignalBus.effect_requested.emit("flash", {"duration": 0.05})
	assert_not_null(_find_flash_overlay())
	await get_tree().create_timer(0.2).timeout
	assert_null(_find_flash_overlay())


func test_engine_abort_clears_shake_and_flash_without_touching_layer_offsets() -> void:
	var bg_offset := Vector2(8.0, -5.0)
	var char_offset := Vector2(-3.0, 4.0)
	_bg_layer.offset = bg_offset
	_char_layer.offset = char_offset
	SignalBus.effect_requested.emit("shake", {"intensity": 40.0, "duration": 0.5})
	SignalBus.effect_requested.emit("flash", {"duration": 0.5})
	await get_tree().create_timer(0.06).timeout
	assert_not_null(_find_flash_overlay(), "sanity: flash should be active")

	SignalBus.engine_abort_requested.emit()
	assert_eq(_bg_shake_root.position, Vector2.ZERO)
	assert_eq(_char_shake_root.position, Vector2.ZERO)
	assert_eq(_bg_layer.offset, bg_offset)
	assert_eq(_char_layer.offset, char_offset)
	await get_tree().process_frame
	assert_null(_find_flash_overlay())


# --- Helpers ---

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
