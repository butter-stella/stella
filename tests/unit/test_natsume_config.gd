extends GutTest

var config: NatsumeConfig


func before_each():
	config = NatsumeConfig.new()


func test_defaults_when_no_file():
	# Loading a non-existent file should use all defaults
	config.load_from_path("res://nonexistent.cfg")

	assert_eq(config.game_title, "Natsume")
	assert_eq(config.scenario_path, "res://scenarios/main.nat")

	assert_eq(config.backgrounds_path, "res://art/backgrounds/")
	assert_eq(config.characters_path, "res://art/characters/")
	assert_eq(config.bgm_path, "res://audio/bgm/")
	assert_eq(config.se_path, "res://audio/se/")
	assert_eq(config.voice_path, "res://audio/voice/")

	assert_eq(config.cg_gallery, false)
	assert_eq(config.backlog, true)
	assert_eq(config.save_slots, 8)

	assert_eq(config.title_scene, "")
	assert_eq(config.game_scene, "")


func test_load_from_config_file():
	# Write a temp config file
	var path = "user://test_natsume.cfg"
	var cf = ConfigFile.new()
	cf.set_value("game", "title", "My VN")
	cf.set_value("game", "scenario", "res://my_scenario.nat")
	cf.set_value("paths", "backgrounds", "res://my/bg/")
	cf.set_value("paths", "characters", "res://my/chars/")
	cf.set_value("features", "cg_gallery", true)
	cf.set_value("features", "save_slots", 12)
	cf.set_value("overrides", "title_scene", "res://my_title.tscn")
	cf.save(path)

	config.load_from_path(path)

	assert_eq(config.game_title, "My VN")
	assert_eq(config.scenario_path, "res://my_scenario.nat")
	assert_eq(config.backgrounds_path, "res://my/bg/")
	assert_eq(config.characters_path, "res://my/chars/")
	assert_eq(config.cg_gallery, true)
	assert_eq(config.save_slots, 12)
	assert_eq(config.title_scene, "res://my_title.tscn")

	# Defaults should remain for unset values
	assert_eq(config.bgm_path, "res://audio/bgm/")
	assert_eq(config.backlog, true)
	assert_eq(config.game_scene, "")

	# Cleanup
	DirAccess.remove_absolute(path)


func test_partial_config_uses_defaults_for_missing():
	var path = "user://test_natsume_partial.cfg"
	var cf = ConfigFile.new()
	cf.set_value("game", "title", "Partial")
	cf.save(path)

	config.load_from_path(path)

	assert_eq(config.game_title, "Partial")
	# Everything else should be default
	assert_eq(config.scenario_path, "res://scenarios/main.nat")
	assert_eq(config.save_slots, 8)

	DirAccess.remove_absolute(path)


func test_has_config_file():
	assert_false(config.has_config_file)

	var path = "user://test_natsume_has.cfg"
	var cf = ConfigFile.new()
	cf.set_value("game", "title", "Test")
	cf.save(path)

	config.load_from_path(path)
	assert_true(config.has_config_file)

	DirAccess.remove_absolute(path)
