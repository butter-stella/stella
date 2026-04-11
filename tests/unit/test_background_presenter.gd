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
	return _game_scene.get_node("BackgroundLayer/BgFront")


func _bg_back() -> TextureRect:
	return _game_scene.get_node("BackgroundLayer/BgBack")


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
