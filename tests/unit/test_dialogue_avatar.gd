extends GutTest
## Tests for dialogue box avatar feature.

var _game_scene: Node


func before_each():
	_game_scene = load("res://addons/natsume/scenes/game.tscn").instantiate()
	add_child_autoqfree(_game_scene)
	await get_tree().process_frame


func _get_presenter():
	return _game_scene.get_node("UILayer/DialoguePanel")


func _get_avatar() -> TextureRect:
	return _game_scene.get_node("UILayer/DialoguePanel/MarginContainer/HBox/AvatarTexture")


# --- CharacterConfig avatar support ---

func test_config_get_avatar_returns_mapping():
	var config = CharacterConfig.new()
	config.load_from_dict({
		"render_mode": "sprite",
		"avatars": {
			"default": "avatar_default",
			"smile": "avatar_smile",
		}
	})
	assert_eq(config.get_avatar("default"), "avatar_default")
	assert_eq(config.get_avatar("smile"), "avatar_smile")


func test_config_get_avatar_fallback_to_default():
	var config = CharacterConfig.new()
	config.load_from_dict({
		"render_mode": "sprite",
		"avatars": {
			"default": "avatar_default",
			"smile": "avatar_smile",
		}
	})
	assert_eq(config.get_avatar("nonexistent"), "avatar_default")


func test_config_get_avatar_empty_when_no_avatars():
	var config = CharacterConfig.new()
	assert_eq(config.get_avatar("smile"), "")


func test_config_has_avatars_true():
	var config = CharacterConfig.new()
	config.load_from_dict({
		"avatars": {"default": "avatar_default"}
	})
	assert_true(config.has_avatars())


func test_config_has_avatars_false_when_empty():
	var config = CharacterConfig.new()
	assert_false(config.has_avatars())


func test_config_has_avatars_false_when_dict_empty():
	var config = CharacterConfig.new()
	config.load_from_dict({"avatars": {}})
	assert_false(config.has_avatars())


func test_config_avatars_loaded_from_dict():
	var config = CharacterConfig.new()
	config.load_from_dict({
		"render_mode": "layered",
		"default_body": "body_school",
		"expressions": {"default": "face_default"},
		"avatars": {
			"default": "av_default",
			"happy": "av_happy",
			"sad": "av_sad",
		}
	})
	assert_eq(config.avatars.size(), 3)
	assert_eq(config.get_avatar("happy"), "av_happy")
	# Layered + avatars coexist fine
	assert_true(config.is_layered())
	assert_true(config.has_avatars())


# --- Presenter avatar visibility ---

func test_avatar_hidden_initially():
	var avatar = _get_avatar()
	assert_false(avatar.visible, "avatar should be hidden initially")


func test_avatar_hidden_in_nvl_mode():
	SignalBus.show_dialogue.emit("sakura", "Hello", "", "nvl")
	await get_tree().process_frame
	var avatar = _get_avatar()
	assert_false(avatar.visible, "avatar should be hidden in NVL mode")


func test_avatar_hidden_in_overlay_mode():
	SignalBus.show_dialogue.emit("sakura", "Hello", "", "overlay")
	await get_tree().process_frame
	var avatar = _get_avatar()
	assert_false(avatar.visible, "avatar should be hidden in overlay mode")


func test_avatar_hidden_for_narrator():
	SignalBus.show_dialogue.emit("", "Narration text", "", "adv")
	await get_tree().process_frame
	var avatar = _get_avatar()
	assert_false(avatar.visible, "avatar should be hidden for narrator (empty character)")


func test_avatar_hidden_when_no_avatar_files():
	# Character with no avatar files — avatar should stay hidden
	SignalBus.show_dialogue.emit("nonexistent_char", "Hello", "", "adv")
	await get_tree().process_frame
	var avatar = _get_avatar()
	assert_false(avatar.visible, "avatar should be hidden when no avatar files exist")


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
	var avatar = _get_avatar()
	# Simulate showing then hiding dialogue
	presenter._current_character = "sakura"
	SignalBus.hide_dialogue.emit()
	assert_eq(presenter._current_character, "")
	assert_false(avatar.visible)
	assert_null(avatar.texture)
