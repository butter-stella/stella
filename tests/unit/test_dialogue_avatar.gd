extends GutTest
## Tests for dialogue box avatar feature.


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
