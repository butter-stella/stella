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


## Integration: NatsumeRuntime._apply_config populates paths from config

func test_runtime_applies_config_paths():
	var runtime = get_tree().root.get_node("NatsumeRuntime")

	# Write a config with custom paths
	var path = "user://test_apply_config.cfg"
	var cf = ConfigFile.new()
	cf.set_value("paths", "backgrounds", "res://custom/bg/")
	cf.set_value("paths", "characters", "res://custom/chars/")
	cf.set_value("paths", "bgm", "res://custom/bgm/")
	cf.set_value("paths", "se", "res://custom/se/")
	cf.set_value("paths", "voice", "res://custom/voice/")
	cf.save(path)

	# Save originals to restore later
	var orig_bg = runtime.backgrounds_path
	var orig_chars = runtime.characters_path
	var orig_bgm = runtime.bgm_path
	var orig_se = runtime.se_path
	var orig_voice = runtime.voice_path

	runtime.config.load_from_path(path)
	runtime._apply_config()

	assert_eq(runtime.backgrounds_path, "res://custom/bg/")
	assert_eq(runtime.characters_path, "res://custom/chars/")
	assert_eq(runtime.bgm_path, "res://custom/bgm/")
	assert_eq(runtime.se_path, "res://custom/se/")
	assert_eq(runtime.voice_path, "res://custom/voice/")

	# Restore
	runtime.backgrounds_path = orig_bg
	runtime.characters_path = orig_chars
	runtime.bgm_path = orig_bgm
	runtime.se_path = orig_se
	runtime.voice_path = orig_voice
	DirAccess.remove_absolute(path)


func test_runtime_preserves_paths_without_config():
	var runtime = get_tree().root.get_node("NatsumeRuntime")
	var orig_config = runtime.config

	# Manually set a custom path (legacy bootstrap pattern)
	var orig_bg = runtime.backgrounds_path
	runtime.backgrounds_path = "res://legacy/bg/"

	# Fresh config with no file — should NOT overwrite manual paths
	runtime.config = NatsumeConfig.new()
	runtime.config.load_from_path("res://nonexistent.cfg")
	runtime._apply_config()

	assert_eq(runtime.backgrounds_path, "res://legacy/bg/",
		"Without config file, manually set paths should be preserved")

	# Restore
	runtime.config = orig_config
	runtime.backgrounds_path = orig_bg


func test_runtime_title_scene_defaults_to_builtin():
	var runtime = get_tree().root.get_node("NatsumeRuntime")
	var orig_title = runtime.title_scene_path
	var orig_config = runtime.config

	# Fresh config with no file — title_scene should default to built-in
	runtime.config = NatsumeConfig.new()
	runtime.config.load_from_path("res://nonexistent.cfg")
	runtime._apply_config()

	assert_eq(runtime.title_scene_path, "res://addons/natsume/scenes/title.tscn")

	runtime.config = orig_config
	runtime.title_scene_path = orig_title


func test_runtime_title_scene_from_config_override():
	var runtime = get_tree().root.get_node("NatsumeRuntime")
	var orig_title = runtime.title_scene_path

	var path = "user://test_title_override.cfg"
	var cf = ConfigFile.new()
	cf.set_value("overrides", "title_scene", "res://my/title.tscn")
	cf.save(path)

	runtime.config.load_from_path(path)
	runtime._apply_config()

	assert_eq(runtime.title_scene_path, "res://my/title.tscn")

	runtime.title_scene_path = orig_title
	DirAccess.remove_absolute(path)
