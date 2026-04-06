extends GutTest
## Tests for dialogue box avatar feature.

var _game_scene: Node


func before_each():
	_game_scene = load("res://addons/stella/scenes/game.tscn").instantiate()
	add_child_autoqfree(_game_scene)
	await get_tree().process_frame


func _get_presenter():
	return _game_scene.get_node("UILayer/DialoguePanel")


func _get_avatar_container() -> Control:
	return _game_scene.get_node("UILayer/DialoguePanel/HBox/AvatarContainer")

func _get_avatar() -> TextureRect:
	return _game_scene.get_node("UILayer/DialoguePanel/HBox/AvatarContainer/AvatarTexture")


# --- CharacterConfig avatar_rect support ---

func test_config_avatar_rect_default_is_zero():
	var config = CharacterConfig.new()
	assert_eq(config.avatar_rect, Rect2())


func test_config_avatar_rect_loaded_from_dict():
	var config = CharacterConfig.new()
	config.load_from_dict({
		"avatar_rect": {"x": 80, "y": 10, "w": 200, "h": 200}
	})
	assert_eq(config.avatar_rect, Rect2(80, 10, 200, 200))


func test_config_has_avatar_rect_true():
	var config = CharacterConfig.new()
	config.load_from_dict({
		"avatar_rect": {"x": 0, "y": 0, "w": 100, "h": 100}
	})
	assert_true(config.has_avatar_rect())


func test_config_has_avatar_rect_false_when_default():
	var config = CharacterConfig.new()
	assert_false(config.has_avatar_rect())


func test_config_has_avatar_rect_false_when_zero_size():
	var config = CharacterConfig.new()
	config.load_from_dict({
		"avatar_rect": {"x": 50, "y": 50, "w": 0, "h": 0}
	})
	assert_false(config.has_avatar_rect())


func test_config_avatar_rect_partial_dict_uses_defaults():
	var config = CharacterConfig.new()
	config.load_from_dict({
		"avatar_rect": {"x": 100, "h": 150}
	})
	assert_eq(config.avatar_rect, Rect2(100, 0, 0, 150))


func test_config_avatar_rect_coexists_with_layered():
	var config = CharacterConfig.new()
	config.load_from_dict({
		"render_mode": "layered",
		"default_body": "body_school",
		"expressions": {"default": "face_default"},
		"avatar_rect": {"x": 0, "y": 0, "w": 200, "h": 200}
	})
	assert_true(config.is_layered())
	assert_true(config.has_avatar_rect())


# --- Presenter avatar visibility ---

func test_avatar_hidden_initially():
	var container = _get_avatar_container()
	assert_false(container.visible, "avatar should be hidden initially")


func test_avatar_hidden_in_nvl_mode():
	SignalBus.show_dialogue.emit("sakura", "Hello", "", "nvl")
	await get_tree().process_frame
	var container = _get_avatar_container()
	assert_false(container.visible, "avatar should be hidden in NVL mode")


func test_avatar_hidden_in_overlay_mode():
	SignalBus.show_dialogue.emit("sakura", "Hello", "", "overlay")
	await get_tree().process_frame
	var container = _get_avatar_container()
	assert_false(container.visible, "avatar should be hidden in overlay mode")


func test_avatar_hidden_for_narrator():
	SignalBus.show_dialogue.emit("", "Narration text", "", "adv")
	await get_tree().process_frame
	var container = _get_avatar_container()
	assert_false(container.visible, "avatar should be hidden for narrator (empty character)")


func test_avatar_hidden_when_no_avatar_rect():
	# Character without avatar_rect config — avatar should stay hidden
	SignalBus.show_dialogue.emit("nonexistent_char", "Hello", "", "adv")
	await get_tree().process_frame
	var container = _get_avatar_container()
	var avatar = _get_avatar()
	assert_false(container.visible, "avatar should be hidden when no avatar_rect configured")
	assert_null(avatar.texture)


func test_expression_tracking_via_char_show():
	var presenter = _get_presenter()
	SignalBus.char_show.emit("sakura", "smile", "center")
	assert_eq(presenter._known_expressions.get("sakura"), "smile")


func test_expression_tracking_via_char_expression_changed():
	var presenter = _get_presenter()
	SignalBus.char_show.emit("sakura", "default", "center")
	SignalBus.char_expression_changed.emit("sakura", "angry")
	assert_eq(presenter._known_expressions.get("sakura"), "angry")


func test_expression_tracking_cleared_on_char_hide():
	var presenter = _get_presenter()
	SignalBus.char_show.emit("sakura", "smile", "center")
	SignalBus.char_hide.emit("sakura")
	assert_false(presenter._known_expressions.has("sakura"))


func test_expression_tracking_cleared_on_hide_all():
	var presenter = _get_presenter()
	presenter._known_expressions["sakura"] = "smile"
	presenter._known_expressions["kaito"] = "default"
	SignalBus.char_hide.emit("all")
	assert_eq(presenter._known_expressions.size(), 0)


func test_avatar_cleared_on_hide_dialogue():
	var presenter = _get_presenter()
	var container = _get_avatar_container()
	var avatar = _get_avatar()
	presenter._current_character = "sakura"
	SignalBus.hide_dialogue.emit()
	assert_eq(presenter._current_character, "")
	assert_false(container.visible)
	assert_null(avatar.texture)
