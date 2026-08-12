extends GutTest
## Tests BackgroundPresenter slide transitions.
##
## Each direction is tested for three properties:
## 1. During the transition, at least one of (bg_front, bg_back) is off-origin
##    (proves the slide actually animates position, not just fades).
## 2. After completion, positions return to their anchor-resolved origin
##    (proves the tween doesn't leave the layer stuck off-screen).
## 3. The new texture ends up on bg_front (tween handoff completed).

var _game_scene: Node
var _origin_front: Vector2
var _origin_back: Vector2


func before_each():
	_game_scene = load("res://addons/stella/scenes/game.tscn").instantiate()
	add_child_autoqfree(_game_scene)
	# Run a throwaway fade transition to force layout to settle (anchor-based
	# positions only resolve to their final values after a few processing frames).
	SignalBus.bg_changed.emit("bg_school_gate", "fade", 0.02)
	await get_tree().create_timer(0.2).timeout
	_origin_front = _bg_front().position
	_origin_back = _bg_back().position


func _bg_front() -> TextureRect:
	return _game_scene.get_node("BackgroundLayer/ShakeRoot/BgFront")


func _bg_back() -> TextureRect:
	return _game_scene.get_node("BackgroundLayer/ShakeRoot/BgBack")


func test_builtin_shake_root_preserves_viewport_anchored_background_layout() -> void:
	var shake_root: Control = _game_scene.get_node("BackgroundLayer/ShakeRoot")
	var viewport_size := _game_scene.get_viewport().get_visible_rect().size
	assert_eq(shake_root.size, viewport_size, "ShakeRoot must supply the viewport anchor rect")
	assert_eq(shake_root.mouse_filter, Control.MOUSE_FILTER_IGNORE)
	for background in [_bg_front(), _bg_back()]:
		var rect: Rect2 = (background as TextureRect).get_global_rect()
		assert_true(rect.position.x <= 0.0 and rect.position.y <= 0.0)
		assert_true(
			rect.end.x >= viewport_size.x and rect.end.y >= viewport_size.y,
			"anchored backgrounds must still cover the viewport",
		)


func test_legacy_direct_child_scene_still_resolves_background_nodes() -> void:
	var layer := CanvasLayer.new()
	layer.set_script(load("res://addons/stella/presentation/background/background_presenter.gd"))
	var front := TextureRect.new()
	front.name = "BgFront"
	layer.add_child(front)
	var back := TextureRect.new()
	back.name = "BgBack"
	layer.add_child(back)
	add_child_autoqfree(layer)
	await get_tree().process_frame
	assert_same(layer.bg_front, front)
	assert_same(layer.bg_back, back)


func _seed_bg(asset: String) -> void:
	var tex = load(StellaRuntime.backgrounds_path + asset + ".png") as Texture2D
	_bg_front().texture = tex
	_bg_front().modulate.a = 1.0
	_bg_back().texture = null
	_bg_back().modulate.a = 0.0


func _assert_slide(direction: String, new_asset: String) -> void:
	_seed_bg("bg_school_gate")
	var duration = 0.4
	SignalBus.bg_changed.emit(new_asset, direction, duration)

	# --- Mid-transition: at least one layer must be off-origin ---
	await get_tree().create_timer(duration * 0.4).timeout
	var front_moved = _bg_front().position != _origin_front
	var back_moved = _bg_back().position != _origin_back
	assert_true(
		front_moved or back_moved,
		"%s: at least one layer must move off-origin during transition" % direction,
	)

	# --- After completion: positions reset, new texture on bg_front ---
	await get_tree().create_timer(duration * 0.8 + 0.15).timeout
	assert_eq(
		_bg_front().position,
		_origin_front,
		"%s: bg_front position should reset to origin after transition" % direction,
	)
	assert_eq(
		_bg_back().position,
		_origin_back,
		"%s: bg_back position should reset to origin after transition" % direction,
	)
	assert_not_null(_bg_front().texture, "%s: bg_front should have texture" % direction)
	assert_eq(
		_bg_front().texture.resource_path.get_file(),
		new_asset + ".png",
		"%s: bg_front should show new texture" % direction,
	)
	assert_eq(_bg_front().modulate.a, 1.0, "%s: bg_front fully opaque" % direction)
	assert_eq(_bg_back().modulate.a, 0.0, "%s: bg_back fully hidden" % direction)


# --- Direction tests ---

func test_slide_left():
	await _assert_slide("slide_left", "bg_cafe")


func test_slide_right():
	await _assert_slide("slide_right", "bg_hallway")


func test_slide_up():
	await _assert_slide("slide_up", "bg_outside")


func test_slide_down():
	await _assert_slide("slide_down", "bg_cafe")


# --- Regression: existing transitions still work alongside new ones ---

func test_fade_transition_still_works():
	_seed_bg("bg_school_gate")
	SignalBus.bg_changed.emit("bg_cafe", "fade", 0.1)
	await get_tree().create_timer(0.25).timeout

	assert_eq(_bg_front().texture.resource_path.get_file(), "bg_cafe.png")
	assert_eq(_bg_front().modulate.a, 1.0)
	assert_eq(_bg_back().modulate.a, 0.0)


func test_empty_background_projection_clears_both_buffers_and_active_tween():
	_seed_bg("bg_school_gate")
	SignalBus.bg_changed.emit("bg_cafe", "fade", 1.0)
	var presenter = _game_scene.get_node("BackgroundLayer")
	assert_not_null(presenter._active_tween)

	SignalBus.bg_changed.emit("", "none", 0.0)

	assert_null(_bg_front().texture)
	assert_null(_bg_back().texture)
	assert_null(presenter._active_tween)
	assert_false(presenter._has_active_transition)


func test_cut_cancels_in_flight_transition_without_stale_overwrite():
	_seed_bg("bg_school_gate")
	SignalBus.bg_changed.emit("bg_cafe", "fade", 0.1)
	SignalBus.bg_changed.emit("bg_outside", "cut", 0.0)
	await get_tree().create_timer(0.2).timeout
	assert_eq(_bg_front().texture.resource_path.get_file(), "bg_outside.png")
