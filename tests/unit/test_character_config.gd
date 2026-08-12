extends GutTest
## Tests for CharacterConfig — dialogue-avatar asset configuration.


func test_avatar_asset_mapping_resolves_expression_names():
	var config := CharacterConfig.new()
	config.load_from_dict({
		"avatar_assets": {
			"default": "portrait_neutral",
			"smile": "portrait_smile",
		},
	})
	assert_eq(config.resolve_avatar_asset("smile"), "portrait_smile")
	assert_eq(config.resolve_avatar_asset("default"), "portrait_neutral")


func test_avatar_asset_mapping_falls_back_to_mapped_default():
	var config := CharacterConfig.new()
	config.load_from_dict({
		"avatar_assets": {"default": "portrait_neutral"},
	})
	assert_eq(config.resolve_avatar_asset("unknown"), "portrait_neutral")


func test_avatar_asset_defaults_to_expression_name_without_mapping():
	var config := CharacterConfig.new()
	assert_eq(config.resolve_avatar_asset("smile"), "smile")


func test_invalid_avatar_asset_mapping_is_ignored():
	var config := CharacterConfig.new()
	config.load_from_dict({"avatar_assets": "not-a-dictionary"})
	assert_push_warning("CharacterConfig: avatar_assets must be a Dictionary")
	assert_true(config.avatar_assets.is_empty())
	assert_eq(config.resolve_avatar_asset("smile"), "smile")


func test_character_config_loader_returns_direct_mapping_for_missing():
	var loader := CharacterConfigLoader.new()
	var config := loader.get_config("nonexistent_character")
	assert_eq(config.resolve_avatar_asset("smile"), "smile")
