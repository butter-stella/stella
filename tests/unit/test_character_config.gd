extends GutTest
## Tests for CharacterConfig — character rendering configuration.


func test_load_from_dict_layered():
	var config = CharacterConfig.new()
	config.load_from_dict({
		"render_mode": "layered",
		"default_body": "body_school",
		"expressions": {
			"default": "face_default",
			"smile": "face_smile",
			"sad": "face_sad",
		}
	})
	assert_eq(config.render_mode, "layered")
	assert_eq(config.default_body, "body_school")
	assert_eq(config.get_face("smile"), "face_smile")
	assert_eq(config.get_face("default"), "face_default")


func test_load_from_dict_sprite():
	var config = CharacterConfig.new()
	config.load_from_dict({
		"render_mode": "sprite",
	})
	assert_eq(config.render_mode, "sprite")


func test_default_render_mode_is_sprite():
	var config = CharacterConfig.new()
	assert_eq(config.render_mode, "sprite")


func test_is_layered():
	var config = CharacterConfig.new()
	assert_false(config.is_layered())
	config.render_mode = "layered"
	assert_true(config.is_layered())


func test_get_face_fallback_to_default():
	var config = CharacterConfig.new()
	config.load_from_dict({
		"render_mode": "layered",
		"default_body": "body_school",
		"expressions": {
			"default": "face_default",
			"smile": "face_smile",
		}
	})
	# Unknown expression falls back to "default"
	assert_eq(config.get_face("nonexistent"), "face_default")


func test_get_face_empty_when_no_expressions():
	var config = CharacterConfig.new()
	assert_eq(config.get_face("smile"), "")


func test_get_body_with_override():
	var config = CharacterConfig.new()
	config.load_from_dict({
		"render_mode": "layered",
		"default_body": "body_school",
		"bodies": {
			"school": "body_school",
			"casual": "body_casual",
		},
		"expressions": {"default": "face_default"}
	})
	assert_eq(config.get_body(""), "body_school")
	assert_eq(config.get_body("casual"), "body_casual")
	assert_eq(config.get_body("school"), "body_school")
	# Unknown body falls back to default
	assert_eq(config.get_body("nonexistent"), "body_school")


func test_character_config_loader_returns_sprite_for_missing():
	var loader = CharacterConfigLoader.new()
	var config = loader.get_config("nonexistent_character")
	assert_eq(config.render_mode, "sprite")
	assert_false(config.is_layered())
