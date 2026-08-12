extends GutTest

const TEST_BASE_CONFIG_PATH = "user://test_project_base.cfg"
const TEST_LOCAL_CONFIG_PATH = "user://test_project_local.cfg"
const TEST_MISSING_CONFIG_PATH = "user://test_project_missing.cfg"
const PRIVATE_SENTINEL = "PRIVATE_VALUE_MUST_NOT_APPEAR_IN_DIAGNOSTIC"
const TEST_CONFIG_PATHS = [
	TEST_BASE_CONFIG_PATH,
	TEST_LOCAL_CONFIG_PATH,
	TEST_MISSING_CONFIG_PATH,
	"user://test_stella.cfg",
	"user://test_stella_partial.cfg",
	"user://test_stella_has.cfg",
	"user://test_apply_config.cfg",
	"user://test_title_override.cfg",
]

var config: StellaConfig
var _runtime: Node
var _original_runtime_config: StellaConfig
var _original_runtime_values: Dictionary


func before_each():
	_remove_test_project_configs()
	config = StellaConfig.new()
	_runtime = get_tree().root.get_node("StellaRuntime")
	_original_runtime_config = _runtime.config
	_original_runtime_values = {
		"backgrounds_path": _runtime.backgrounds_path,
		"characters_path": _runtime.characters_path,
		"stage_assets_path": _runtime.stage_assets_path,
		"bgm_path": _runtime.bgm_path,
		"se_path": _runtime.se_path,
		"voice_path": _runtime.voice_path,
		"title_scene_path": _runtime.title_scene_path,
	}


func after_each():
	_runtime.config = _original_runtime_config
	for property_name: String in _original_runtime_values:
		_runtime.set(property_name, _original_runtime_values[property_name])
	_remove_test_project_configs()


func _remove_test_project_configs() -> void:
	for path: String in TEST_CONFIG_PATHS:
		var absolute_path := ProjectSettings.globalize_path(path)
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(absolute_path)
		elif DirAccess.dir_exists_absolute(absolute_path):
			DirAccess.remove_absolute(absolute_path)


func _write_project_config(path: String, values: Dictionary) -> void:
	var cf := ConfigFile.new()
	for section: String in values:
		for key: String in values[section]:
			cf.set_value(section, key, values[section][key])
	assert_eq(cf.save(path), OK)


func _write_raw_project_config(path: String, contents: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert_not_null(file)
	if file != null:
		file.store_string(contents)


func test_defaults_when_no_file():
	# Loading a non-existent file should use all defaults
	assert_eq(config.load_from_path(TEST_MISSING_CONFIG_PATH), ERR_FILE_NOT_FOUND)

	assert_false(config.has_config_file)
	assert_eq(config.get_applied_sources(), PackedStringArray())
	assert_eq(config.game_title, "Stella")
	assert_eq(config.scenario_path, "res://scenarios/main.stla")

	assert_eq(config.backgrounds_path, "res://art/backgrounds/")
	assert_eq(config.characters_path, "res://art/characters/")
	assert_eq(config.stage_path, "res://art/stage/")
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
	var path = "user://test_stella.cfg"
	var cf = ConfigFile.new()
	cf.set_value("game", "title", "My VN")
	cf.set_value("game", "scenario", "res://my_scenario.stla")
	cf.set_value("paths", "backgrounds", "res://my/bg/")
	cf.set_value("paths", "characters", "res://my/chars/")
	cf.set_value("paths", "stage", "res://my/stage/")
	cf.set_value("features", "cg_gallery", true)
	cf.set_value("features", "save_slots", 12)
	cf.set_value("overrides", "title_scene", "res://my_title.tscn")
	cf.save(path)

	assert_eq(config.load_from_path(path), OK)

	assert_eq(config.game_title, "My VN")
	assert_eq(config.scenario_path, "res://my_scenario.stla")
	assert_eq(config.backgrounds_path, "res://my/bg/")
	assert_eq(config.characters_path, "res://my/chars/")
	assert_eq(config.stage_path, "res://my/stage/")
	assert_eq(config.cg_gallery, true)
	assert_eq(config.save_slots, 12)
	assert_eq(config.title_scene, "res://my_title.tscn")

	# Defaults should remain for unset values
	assert_eq(config.bgm_path, "res://audio/bgm/")
	assert_eq(config.backlog, true)
	assert_eq(config.game_scene, "")


func test_partial_config_uses_defaults_for_missing():
	var path = "user://test_stella_partial.cfg"
	var cf = ConfigFile.new()
	cf.set_value("game", "title", "Partial")
	cf.save(path)

	assert_eq(config.load_from_path(path), OK)

	assert_eq(config.game_title, "Partial")
	# Everything else should be default
	assert_eq(config.scenario_path, "res://scenarios/main.stla")
	assert_eq(config.save_slots, 8)


func test_has_config_file():
	assert_false(config.has_config_file)

	var path = "user://test_stella_has.cfg"
	var cf = ConfigFile.new()
	cf.set_value("game", "title", "Test")
	cf.save(path)

	assert_eq(config.load_from_path(path), OK)
	assert_true(config.has_config_file)


## Integration: StellaRuntime._apply_config populates paths from config

func test_runtime_applies_config_paths():
	# Write a config with custom paths
	var path = "user://test_apply_config.cfg"
	var cf = ConfigFile.new()
	cf.set_value("paths", "backgrounds", "res://custom/bg/")
	cf.set_value("paths", "characters", "res://custom/chars/")
	cf.set_value("paths", "stage", "res://custom/stage/")
	cf.set_value("paths", "bgm", "res://custom/bgm/")
	cf.set_value("paths", "se", "res://custom/se/")
	cf.set_value("paths", "voice", "res://custom/voice/")
	cf.save(path)

	var loaded_config := StellaConfig.new()
	assert_eq(loaded_config.load_from_path(path), OK)
	_runtime.config = loaded_config
	_runtime._apply_config()

	assert_eq(_runtime.backgrounds_path, "res://custom/bg/")
	assert_eq(_runtime.characters_path, "res://custom/chars/")
	assert_eq(_runtime.stage_assets_path, "res://custom/stage/")
	assert_eq(_runtime.bgm_path, "res://custom/bgm/")
	assert_eq(_runtime.se_path, "res://custom/se/")
	assert_eq(_runtime.voice_path, "res://custom/voice/")


func test_runtime_preserves_paths_without_config():
	# Manually set a custom path (legacy bootstrap pattern)
	_runtime.backgrounds_path = "res://legacy/bg/"

	# Fresh config with no file — should NOT overwrite manual paths
	_runtime.config = StellaConfig.new()
	_runtime._apply_config()

	assert_eq(_runtime.backgrounds_path, "res://legacy/bg/",
		"Without config file, manually set paths should be preserved")


func test_runtime_title_scene_defaults_to_builtin():
	# Fresh config with no file — title_scene should default to built-in
	_runtime.config = StellaConfig.new()
	_runtime._apply_config()

	assert_eq(_runtime.title_scene_path, "res://addons/stella/scenes/title.tscn")


func test_runtime_title_scene_from_config_override():
	var path = "user://test_title_override.cfg"
	var cf = ConfigFile.new()
	cf.set_value("overrides", "title_scene", "res://my/title.tscn")
	cf.save(path)

	var loaded_config := StellaConfig.new()
	assert_eq(loaded_config.load_from_path(path), OK)
	_runtime.config = loaded_config
	_runtime._apply_config()

	assert_eq(_runtime.title_scene_path, "res://my/title.tscn")


func test_runtime_project_config_uses_base_when_local_is_missing():
	_write_project_config(TEST_BASE_CONFIG_PATH, {
		"game": {
			"title": "Base Game",
			"scenario": "res://base/scenario.stla",
		},
	})

	var loaded: StellaConfig = _runtime._load_project_config(
		TEST_BASE_CONFIG_PATH,
		TEST_LOCAL_CONFIG_PATH,
	)

	assert_eq(loaded.game_title, "Base Game")
	assert_eq(loaded.scenario_path, "res://base/scenario.stla")
	assert_eq(loaded.get_applied_sources(), PackedStringArray([
		TEST_BASE_CONFIG_PATH,
	]))
	assert_eq(loaded.last_error, OK)


func test_runtime_project_config_resolves_every_section_before_consumers():
	_write_project_config(TEST_BASE_CONFIG_PATH, {
		"game": {
			"title": "Base Game",
			"scenario": "res://base/scenario.stla",
			"title_bgm": "base_title",
		},
		"paths": {
			"backgrounds": "res://base/backgrounds/",
			"characters": "res://base/characters/",
			"stage": "res://base/stage/",
			"bgm": "res://base/bgm/",
			"se": "res://base/se/",
			"voice": "res://base/voice/",
		},
		"features": {
			"cg_gallery": false,
			"backlog": true,
			"save_slots": 8,
		},
		"system_se": {
			"select": "base_select",
			"cancel": "base_cancel",
		},
		"overrides": {
			"title_scene": "res://base/title.tscn",
			"game_scene": "res://base/game.tscn",
			"settings_scene": "res://base/settings.tscn",
			"save_load_scene": "res://base/save_load.tscn",
			"backlog_scene": "res://base/backlog.tscn",
			"flowchart_scene": "res://base/flowchart.tscn",
		},
	})
	_write_project_config(TEST_LOCAL_CONFIG_PATH, {
		"game": {
			"scenario": "res://private/scenario.stla",
			"title_bgm": "local_title",
		},
		"paths": {
			"stage": "res://private/stage/",
			"voice": "res://private/voice/",
		},
		"features": {
			"cg_gallery": true,
			"save_slots": 12,
		},
		"system_se": {
			"select": "local_select",
		},
		"overrides": {
			"title_scene": "res://private/title.tscn",
			"game_scene": "res://private/game.tscn",
			"settings_scene": "res://private/settings.tscn",
			"save_load_scene": "res://private/save_load.tscn",
			"backlog_scene": "res://private/backlog.tscn",
			"flowchart_scene": "res://private/flowchart.tscn",
		},
	})

	var loaded: StellaConfig = _runtime._load_project_config(
		TEST_BASE_CONFIG_PATH,
		TEST_LOCAL_CONFIG_PATH,
	)

	assert_eq(loaded.game_title, "Base Game")
	assert_eq(loaded.scenario_path, "res://private/scenario.stla")
	assert_eq(loaded.title_bgm, "local_title")
	assert_eq(loaded.backgrounds_path, "res://base/backgrounds/")
	assert_eq(loaded.characters_path, "res://base/characters/")
	assert_eq(loaded.stage_path, "res://private/stage/")
	assert_eq(loaded.bgm_path, "res://base/bgm/")
	assert_eq(loaded.se_path, "res://base/se/")
	assert_eq(loaded.voice_path, "res://private/voice/")
	assert_true(loaded.cg_gallery)
	assert_true(loaded.backlog)
	assert_eq(loaded.save_slots, 12)
	assert_eq(loaded.se_select, "local_select")
	assert_eq(loaded.se_cancel, "base_cancel")
	assert_eq(loaded.title_scene, "res://private/title.tscn")
	assert_eq(loaded.game_scene, "res://private/game.tscn")
	assert_eq(loaded.settings_scene, "res://private/settings.tscn")
	assert_eq(loaded.save_load_scene, "res://private/save_load.tscn")
	assert_eq(loaded.backlog_scene, "res://private/backlog.tscn")
	assert_eq(loaded.flowchart_scene, "res://private/flowchart.tscn")
	assert_eq(loaded.get_applied_sources(), PackedStringArray([
		TEST_BASE_CONFIG_PATH,
		TEST_LOCAL_CONFIG_PATH,
	]))

	_runtime.config = loaded
	_runtime._apply_config()
	assert_eq(_runtime.backgrounds_path, "res://base/backgrounds/")
	assert_eq(_runtime.stage_assets_path, "res://private/stage/")
	assert_eq(_runtime.voice_path, "res://private/voice/")
	assert_eq(_runtime.title_scene_path, "res://private/title.tscn")
	assert_eq(_runtime._get_game_scene_path(), "res://private/game.tscn")
	assert_eq(_runtime.get_applied_config_sources(), PackedStringArray([
		TEST_BASE_CONFIG_PATH,
		TEST_LOCAL_CONFIG_PATH,
	]))

	var returned_sources := loaded.get_applied_sources()
	returned_sources.clear()
	assert_eq(loaded.get_applied_sources().size(), 2,
		"Callers must not be able to mutate config source metadata")


func test_invalid_local_value_is_atomic_and_does_not_leak_contents():
	_write_project_config(TEST_BASE_CONFIG_PATH, {
		"game": {
			"title": "Base Game",
			"scenario": "res://base/scenario.stla",
		},
		"paths": {
			"voice": "res://base/voice/",
		},
	})
	_write_project_config(TEST_LOCAL_CONFIG_PATH, {
		"game": {
			"title": "Must Not Commit",
		},
		"paths": {
			"voice": {"private": PRIVATE_SENTINEL},
		},
	})

	var loaded: StellaConfig = _runtime._load_project_config(
		TEST_BASE_CONFIG_PATH,
		TEST_LOCAL_CONFIG_PATH,
	)
	assert_push_error("failed to load config source")

	assert_eq(loaded.game_title, "Base Game",
		"A valid key before the invalid key must not partially commit")
	assert_eq(loaded.scenario_path, "res://base/scenario.stla")
	assert_eq(loaded.voice_path, "res://base/voice/")
	assert_true(loaded.has_config_file)
	assert_eq(loaded.get_applied_sources(), PackedStringArray([
		TEST_BASE_CONFIG_PATH,
	]))
	assert_eq(loaded.last_error, ERR_INVALID_DATA)
	assert_eq(loaded.last_error_source, TEST_LOCAL_CONFIG_PATH)
	assert_true(loaded.last_error_detail.contains("[paths] voice"))
	assert_false(loaded.last_error_detail.contains(PRIVATE_SENTINEL),
		"Diagnostics must describe the schema error without printing values")


func test_malformed_present_local_reports_error_and_preserves_base():
	_write_project_config(TEST_BASE_CONFIG_PATH, {
		"game": {
			"title": "Base Game",
			"scenario": "res://base/scenario.stla",
		},
	})
	_write_raw_project_config(
		TEST_LOCAL_CONFIG_PATH,
		"[game]\ntitle=%s\n" % PRIVATE_SENTINEL,
	)

	var loaded: StellaConfig = _runtime._load_project_config(
		TEST_BASE_CONFIG_PATH,
		TEST_LOCAL_CONFIG_PATH,
	)
	assert_engine_error_count(0,
		"The raw parser error can echo private malformed values and must be suppressed")
	assert_push_error("failed to load config source")

	assert_eq(loaded.game_title, "Base Game")
	assert_eq(loaded.scenario_path, "res://base/scenario.stla")
	assert_true(loaded.has_config_file)
	assert_ne(loaded.last_error, OK)
	assert_eq(loaded.last_error_source, TEST_LOCAL_CONFIG_PATH)
	assert_false(loaded.last_error_detail.contains(PRIVATE_SENTINEL))
	assert_eq(loaded.get_applied_sources(), PackedStringArray([
		TEST_BASE_CONFIG_PATH,
	]))


func test_unreadable_present_local_reports_error_and_preserves_base():
	_write_project_config(TEST_BASE_CONFIG_PATH, {
		"game": {
			"title": "Base Game",
		},
	})
	assert_eq(DirAccess.make_dir_absolute(
		ProjectSettings.globalize_path(TEST_LOCAL_CONFIG_PATH),
	), OK)

	var loaded: StellaConfig = _runtime._load_project_config(
		TEST_BASE_CONFIG_PATH,
		TEST_LOCAL_CONFIG_PATH,
	)
	assert_push_error("failed to load config source")

	assert_eq(loaded.game_title, "Base Game")
	assert_true(loaded.has_config_file)
	assert_ne(loaded.last_error, OK)
	assert_eq(loaded.last_error_source, TEST_LOCAL_CONFIG_PATH)
	assert_eq(loaded.get_applied_sources(), PackedStringArray([
		TEST_BASE_CONFIG_PATH,
	]))


func test_reinitialization_and_reset_do_not_retain_removed_local_values():
	_write_project_config(TEST_BASE_CONFIG_PATH, {
		"game": {
			"title": "Base Game",
		},
	})
	_write_project_config(TEST_LOCAL_CONFIG_PATH, {
		"game": {
			"scenario": "res://private/scenario.stla",
		},
		"paths": {
			"voice": "res://private/voice/",
		},
	})

	var first: StellaConfig = _runtime._load_project_config(
		TEST_BASE_CONFIG_PATH,
		TEST_LOCAL_CONFIG_PATH,
	)
	assert_eq(first.scenario_path, "res://private/scenario.stla")
	assert_eq(first.voice_path, "res://private/voice/")

	assert_eq(DirAccess.remove_absolute(
		ProjectSettings.globalize_path(TEST_LOCAL_CONFIG_PATH),
	), OK)
	var second: StellaConfig = _runtime._load_project_config(
		TEST_BASE_CONFIG_PATH,
		TEST_LOCAL_CONFIG_PATH,
	)
	assert_ne(first, second)
	assert_eq(second.game_title, "Base Game")
	assert_eq(second.scenario_path, "res://scenarios/main.stla")
	assert_eq(second.voice_path, "res://audio/voice/")
	assert_eq(second.get_applied_sources(), PackedStringArray([
		TEST_BASE_CONFIG_PATH,
	]))

	first.reset()
	assert_eq(first.load_from_path(TEST_BASE_CONFIG_PATH), OK)
	assert_eq(first.scenario_path, "res://scenarios/main.stla")
	assert_eq(first.voice_path, "res://audio/voice/")
	assert_eq(first.get_applied_sources(), PackedStringArray([
		TEST_BASE_CONFIG_PATH,
	]))


func test_gut_command_line_skips_only_implicit_local_config():
	assert_true(_runtime._is_gut_command_line(PackedStringArray([
		"-s",
		"res://addons/gut/gut_cmdln.gd",
	])))
	assert_true(_runtime._is_gut_command_line(PackedStringArray([
		"--script",
		"C:\\project\\addons\\gut\\gut_cmdln.gd",
	])))
	assert_false(_runtime._is_gut_command_line(PackedStringArray([
		"-s",
		"res://tools/check_config.gd",
	])))
	assert_false(_runtime.get_applied_config_sources().has(
		_runtime.LOCAL_CONFIG_PATH,
	), "The running GUT process must not consume a real or CI-poison local config")
