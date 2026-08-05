extends GutTest
## Tests ScreenEffects presenter — verifies that shake/flash are visually
## applied to rendering layers (not Node2D parent, which has no visual
## effect on CanvasLayer siblings), and that params flow from the signal
## payload through to the actual effect.

const SCREEN_EFFECTS_SCRIPT = preload("res://addons/stella/presentation/effects/screen_effects.gd")

var _parent: Node2D
var _bg_layer: CanvasLayer
var _char_layer: CanvasLayer
var _ui_layer: CanvasLayer
var _effects: Node


func before_each():
	# Mirror the real game.tscn structure: Game (Node2D) with BackgroundLayer,
	# CharacterLayer, UILayer as CanvasLayer children, plus a ScreenEffects Node.
	_parent = Node2D.new()
	_parent.name = "Game"
	add_child_autoqfree(_parent)

	_bg_layer = CanvasLayer.new()
	_bg_layer.name = "BackgroundLayer"
	_bg_layer.layer = 0
	_parent.add_child(_bg_layer)

	_char_layer = CanvasLayer.new()
	_char_layer.name = "CharacterLayer"
	_char_layer.layer = 1
	_parent.add_child(_char_layer)

	_ui_layer = CanvasLayer.new()
	_ui_layer.name = "UILayer"
	_ui_layer.layer = 3
	_parent.add_child(_ui_layer)

	_effects = Node.new()
	_effects.set_script(SCREEN_EFFECTS_SCRIPT)
	var target_paths: Array[NodePath] = [
		NodePath("../BackgroundLayer"),
		NodePath("../CharacterLayer"),
	]
	_effects.shake_target_paths = target_paths
	_parent.add_child(_effects)
	await get_tree().process_frame


func after_each():
	if is_instance_valid(_effects):
		_effects._clear_effects()
		# Disconnect to avoid cross-test signal bleed.
		if SignalBus.effect_requested.is_connected(_effects._on_effect):
			SignalBus.effect_requested.disconnect(_effects._on_effect)
		if SignalBus.engine_abort_requested.is_connected(_effects._clear_effects):
			SignalBus.engine_abort_requested.disconnect(_effects._clear_effects)


# --- Shake: must tween rendering-layer offsets, not the Node2D root ---

func test_shake_moves_background_and_character_layer_offsets():
	# With intensity=50, at least one of the two content layers must be
	# measurably off-origin during the shake.
	var intensity = 50.0
	var duration = 0.3
	SignalBus.effect_requested.emit("shake", {"intensity": intensity, "duration": duration})

	var max_bg := 0.0
	var max_char := 0.0
	for i in range(6):
		await get_tree().create_timer(0.04).timeout
		var bg_off = _bg_layer.offset.length()
		var char_off = _char_layer.offset.length()
		if bg_off > max_bg:
			max_bg = bg_off
		if char_off > max_char:
			max_char = char_off

	assert_gt(max_bg, 5.0, "BackgroundLayer.offset should move measurably during shake")
	assert_gt(max_char, 5.0, "CharacterLayer.offset should move measurably during shake")

	# Return to origin after duration.
	await get_tree().create_timer(duration + 0.15).timeout
	assert_eq(_bg_layer.offset, Vector2.ZERO, "BackgroundLayer.offset must reset")
	assert_eq(_char_layer.offset, Vector2.ZERO, "CharacterLayer.offset must reset")


func test_shake_uses_shared_delta_and_restores_each_layer_baseline():
	var bg_baseline := Vector2(12.0, -4.0)
	var char_baseline := Vector2(-6.0, 8.0)
	_bg_layer.offset = bg_baseline
	_char_layer.offset = char_baseline

	SignalBus.effect_requested.emit("shake", {"intensity": 40.0, "duration": 0.22})
	var saw_motion := false
	for _sample in range(3):
		await get_tree().create_timer(0.055).timeout
		var bg_delta := _bg_layer.offset - bg_baseline
		var char_delta := _char_layer.offset - char_baseline
		assert_lt(
			bg_delta.distance_to(char_delta),
			0.001,
			"all stage layers must receive the same shake delta",
		)
		saw_motion = saw_motion or bg_delta.length() > 0.001
	assert_true(saw_motion, "shake should move the configured layers")

	await get_tree().create_timer(0.12).timeout
	assert_eq(_bg_layer.offset, bg_baseline, "background baseline must be restored")
	assert_eq(_char_layer.offset, char_baseline, "character baseline must be restored")


func test_effect_off_cancels_shake_and_prevents_old_callbacks():
	var bg_baseline := Vector2(5.0, -3.0)
	var char_baseline := Vector2(-2.0, 7.0)
	_bg_layer.offset = bg_baseline
	_char_layer.offset = char_baseline
	SignalBus.effect_requested.emit("shake", {"intensity": 50.0, "duration": 0.5})
	await get_tree().create_timer(0.06).timeout
	assert_ne(_bg_layer.offset, bg_baseline, "sanity: shake should be active before off")

	SignalBus.effect_requested.emit("off", {})
	assert_eq(_bg_layer.offset, bg_baseline, "off must restore background immediately")
	assert_eq(_char_layer.offset, char_baseline, "off must restore character immediately")
	await get_tree().create_timer(0.16).timeout
	assert_eq(_bg_layer.offset, bg_baseline, "cancelled shake must not resume")
	assert_eq(_char_layer.offset, char_baseline, "cancelled shake must not resume")


func test_replacing_shake_preserves_original_baselines():
	var bg_baseline := Vector2(11.0, 3.0)
	var char_baseline := Vector2(-9.0, -2.0)
	_bg_layer.offset = bg_baseline
	_char_layer.offset = char_baseline
	SignalBus.effect_requested.emit("shake", {"intensity": 45.0, "duration": 0.5})
	await get_tree().create_timer(0.06).timeout
	SignalBus.effect_requested.emit("shake", {"intensity": 20.0, "duration": 0.1})
	await get_tree().create_timer(0.16).timeout
	assert_eq(_bg_layer.offset, bg_baseline)
	assert_eq(_char_layer.offset, char_baseline)


func test_shake_does_not_touch_ui_layer():
	# UI must stay still so dialogue remains readable during shake.
	var duration = 0.2
	SignalBus.effect_requested.emit("shake", {"intensity": 40.0, "duration": duration})
	for i in range(5):
		await get_tree().create_timer(0.03).timeout
		assert_eq(
			_ui_layer.offset,
			Vector2.ZERO,
			"UILayer.offset must remain at origin throughout shake",
		)
	await get_tree().create_timer(duration + 0.15).timeout
	assert_eq(_ui_layer.offset, Vector2.ZERO)


func test_shake_does_not_touch_parent_node2d_position():
	# Pre-fix, shake was mutating get_parent().position, which is
	# invisible because all visible children are CanvasLayers (they
	# ignore Node2D transforms). Verify the new behavior leaves the
	# parent Node2D untouched.
	var original = _parent.position
	SignalBus.effect_requested.emit("shake", {"intensity": 30.0, "duration": 0.15})
	await get_tree().create_timer(0.05).timeout
	assert_eq(_parent.position, original, "shake must not mutate parent Node2D position")
	await get_tree().create_timer(0.2).timeout
	assert_eq(_parent.position, original)


func test_custom_named_nested_target_can_be_configured():
	var visuals := Node.new()
	visuals.name = "Visuals"
	_parent.add_child(visuals)
	var custom_layer := CanvasLayer.new()
	custom_layer.name = "Backdrop"
	visuals.add_child(custom_layer)
	var baseline := Vector2(14.0, -8.0)
	custom_layer.offset = baseline
	var custom_paths: Array[NodePath] = [NodePath("../Visuals/Backdrop")]
	_effects.shake_target_paths = custom_paths

	SignalBus.effect_requested.emit("shake", {"intensity": 30.0, "duration": 0.2})
	await get_tree().create_timer(0.06).timeout
	assert_ne(custom_layer.offset, baseline, "configured nested CanvasLayer should shake")
	assert_eq(_bg_layer.offset, Vector2.ZERO, "unconfigured layer must stay still")
	assert_eq(_char_layer.offset, Vector2.ZERO, "unconfigured layer must stay still")
	assert_eq(_ui_layer.offset, Vector2.ZERO, "UI must stay still")

	SignalBus.effect_requested.emit("off", {})
	assert_eq(custom_layer.offset, baseline, "custom target baseline must be restored")


func test_leaving_tree_restores_active_shake_baselines():
	var bg_baseline := Vector2(3.0, 6.0)
	var char_baseline := Vector2(-4.0, 2.0)
	_bg_layer.offset = bg_baseline
	_char_layer.offset = char_baseline
	SignalBus.effect_requested.emit("shake", {"intensity": 40.0, "duration": 0.5})
	await get_tree().create_timer(0.06).timeout
	_effects.queue_free()
	await get_tree().process_frame
	assert_eq(_bg_layer.offset, bg_baseline)
	assert_eq(_char_layer.offset, char_baseline)


func test_reentering_tree_reuses_canvas_and_reconnects_signals():
	var original_canvas = _effects._flash_canvas
	_parent.remove_child(_effects)
	assert_false(SignalBus.effect_requested.is_connected(_effects._on_effect))
	assert_false(SignalBus.engine_abort_requested.is_connected(_effects._clear_effects))

	_parent.add_child(_effects)
	await get_tree().process_frame
	assert_same(_effects._flash_canvas, original_canvas, "re-entry must not duplicate FlashCanvas")
	assert_true(SignalBus.effect_requested.is_connected(_effects._on_effect))
	assert_true(SignalBus.engine_abort_requested.is_connected(_effects._clear_effects))


# --- Flash: must live on a high-layer CanvasLayer so it renders above all UI ---

func test_flash_overlay_lives_on_high_canvas_layer():
	SignalBus.effect_requested.emit("flash", {"duration": 0.1})
	await get_tree().process_frame

	var overlay = _find_flash_overlay()
	assert_not_null(overlay, "flash should create an overlay ColorRect")

	# Walk up to the first CanvasLayer ancestor; it must exist and its
	# layer must be above the UI layer (3).
	var anc = overlay.get_parent()
	while anc != null and not (anc is CanvasLayer):
		anc = anc.get_parent()
	assert_not_null(anc, "flash overlay must be descendant of a CanvasLayer")
	assert_gt(
		(anc as CanvasLayer).layer,
		3,
		"flash overlay CanvasLayer must be above UILayer (layer=3)",
	)


func test_flash_default_color_is_white():
	SignalBus.effect_requested.emit("flash", {"duration": 0.1})
	await get_tree().process_frame
	var overlay = _find_flash_overlay()
	assert_not_null(overlay)
	assert_eq(overlay.color, Color.WHITE, "default flash color should be white")

	await get_tree().create_timer(0.25).timeout
	assert_null(_find_flash_overlay(), "overlay should be freed after flash completes")


func test_flash_red_color():
	SignalBus.effect_requested.emit("flash", {"color": "red", "duration": 0.1})
	await get_tree().process_frame
	var overlay = _find_flash_overlay()
	assert_not_null(overlay)
	assert_eq(overlay.color, Color.RED, "flash with color='red' should produce red overlay")


func test_flash_black_color():
	SignalBus.effect_requested.emit("flash", {"color": "black", "duration": 0.1})
	await get_tree().process_frame
	var overlay = _find_flash_overlay()
	assert_not_null(overlay)
	assert_eq(overlay.color, Color.BLACK, "flash with color='black' should produce black overlay")


func test_flash_hex_color():
	SignalBus.effect_requested.emit("flash", {"color": "#ff0000", "duration": 0.1})
	await get_tree().process_frame
	var overlay = _find_flash_overlay()
	assert_not_null(overlay)
	assert_eq(overlay.color, Color.RED, "flash should accept hexadecimal colors")


func test_flash_unknown_color_falls_back_to_white():
	SignalBus.effect_requested.emit("flash", {"color": "not_a_real_color_name", "duration": 0.1})
	await get_tree().process_frame
	var overlay = _find_flash_overlay()
	assert_not_null(overlay)
	assert_eq(overlay.color, Color.WHITE, "unknown color name should fall back to white")


func test_effect_off_removes_active_flash():
	SignalBus.effect_requested.emit("flash", {"color": "red", "duration": 0.5})
	await get_tree().process_frame
	assert_not_null(_find_flash_overlay(), "sanity: flash should be active before off")

	SignalBus.effect_requested.emit("off", {})
	await get_tree().process_frame
	assert_null(_find_flash_overlay(), "off must remove the active flash overlay")
	await get_tree().create_timer(0.12).timeout
	assert_null(_find_flash_overlay(), "cancelled flash must stay removed")


func test_engine_abort_clears_shake_and_flash():
	var bg_baseline := Vector2(8.0, -5.0)
	var char_baseline := Vector2(-3.0, 4.0)
	_bg_layer.offset = bg_baseline
	_char_layer.offset = char_baseline
	SignalBus.effect_requested.emit("shake", {"intensity": 40.0, "duration": 0.5})
	SignalBus.effect_requested.emit("flash", {"duration": 0.5})
	await get_tree().create_timer(0.06).timeout
	assert_not_null(_find_flash_overlay(), "sanity: flash should be active before abort")

	SignalBus.engine_abort_requested.emit()
	assert_eq(_bg_layer.offset, bg_baseline, "abort must restore background baseline")
	assert_eq(_char_layer.offset, char_baseline, "abort must restore character baseline")
	await get_tree().process_frame
	assert_null(_find_flash_overlay(), "abort must remove flash")
	await get_tree().create_timer(0.16).timeout
	assert_eq(_bg_layer.offset, bg_baseline, "aborted shake must not resume")
	assert_eq(_char_layer.offset, char_baseline, "aborted shake must not resume")


# --- Helpers ---

func _find_flash_overlay() -> ColorRect:
	# Recursively search ScreenEffects' subtree for a ColorRect.
	return _find_color_rect_in(_effects)


func _find_color_rect_in(node: Node) -> ColorRect:
	if node is ColorRect:
		return node
	for child in node.get_children():
		var found = _find_color_rect_in(child)
		if found:
			return found
	return null
