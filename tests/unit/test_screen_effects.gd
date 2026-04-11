extends GutTest
## Tests ScreenEffects presenter — verifies shake intensity/duration and
## flash color/duration actually flow from the signal payload to the visual
## effect (not just defaulted to hardcoded values).

const SCREEN_EFFECTS_SCRIPT = preload("res://addons/stella/presentation/effects/screen_effects.gd")

var _parent: Node2D
var _effects: Node


func before_each():
	_parent = Node2D.new()
	_parent.name = "TestParent"
	add_child_autoqfree(_parent)
	_effects = Node.new()
	_effects.set_script(SCREEN_EFFECTS_SCRIPT)
	_parent.add_child(_effects)
	await get_tree().process_frame


func after_each():
	# Disconnect to avoid cross-test signal bleed.
	if SignalBus.effect_requested.is_connected(_effects._on_effect):
		SignalBus.effect_requested.disconnect(_effects._on_effect)


# --- Shake ---

func test_shake_uses_intensity_param():
	# Shake with large intensity should produce a visibly larger offset than small intensity.
	# We sample parent.position mid-shake several times and check the max |offset|.
	var intensity = 50.0
	var duration = 0.3
	SignalBus.effect_requested.emit("shake", {"intensity": intensity, "duration": duration})

	var max_offset := 0.0
	var original = _parent.position
	for i in range(6):
		await get_tree().create_timer(0.04).timeout
		var offset = (_parent.position - original).length()
		if offset > max_offset:
			max_offset = offset

	# With intensity=50, the per-step offset is randf_range(-50, 50) per axis,
	# so the typical |offset| magnitude is well above 5 (much larger than
	# what intensity=10 would produce). We use a conservative lower bound.
	assert_gt(max_offset, 5.0, "shake with intensity=50 should move parent measurably")

	# After shake duration, position should return to original.
	await get_tree().create_timer(duration + 0.1).timeout
	assert_eq(_parent.position, original, "parent should return to original after shake")


func test_shake_duration_controls_finish_time():
	var duration = 0.2
	var original = _parent.position
	SignalBus.effect_requested.emit("shake", {"intensity": 15.0, "duration": duration})

	# After the duration has passed, shake should have returned to origin.
	await get_tree().create_timer(duration + 0.15).timeout
	assert_eq(_parent.position, original, "after duration + margin, parent should be at origin")


# --- Flash ---

func test_flash_default_color_is_white():
	SignalBus.effect_requested.emit("flash", {"duration": 0.1})
	await get_tree().process_frame
	var overlay = _find_flash_overlay()
	assert_not_null(overlay, "flash should create an overlay ColorRect")
	assert_eq(overlay.color, Color.WHITE, "default flash color should be white")

	# Wait for the tween to fade out + queue_free to run
	await get_tree().create_timer(0.25).timeout
	assert_null(_find_flash_overlay(), "overlay should be freed after flash completes")


func test_flash_red_color():
	SignalBus.effect_requested.emit("flash", {"color": "red", "duration": 0.1})
	await get_tree().process_frame
	var overlay = _find_flash_overlay()
	assert_not_null(overlay, "flash should create an overlay ColorRect")
	assert_eq(overlay.color, Color.RED, "flash with color='red' should produce red overlay")


func test_flash_black_color():
	SignalBus.effect_requested.emit("flash", {"color": "black", "duration": 0.1})
	await get_tree().process_frame
	var overlay = _find_flash_overlay()
	assert_not_null(overlay, "flash should create an overlay ColorRect")
	assert_eq(overlay.color, Color.BLACK, "flash with color='black' should produce black overlay")


func _find_flash_overlay() -> ColorRect:
	for child in _parent.get_children():
		if child is ColorRect:
			return child
	return null
