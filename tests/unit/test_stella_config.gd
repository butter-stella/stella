extends GutTest

const TEST_BASE_CONFIG_PATH = "user://test_project_base.cfg"
const TEST_LOCAL_CONFIG_PATH = "user://test_project_local.cfg"
const TEST_MISSING_CONFIG_PATH = "user://test_project_missing.cfg"
const TEST_EMPTY_TITLE_PATH = "user://test_empty_title.scn"
const TEST_MISSING_SCRIPT_TITLE_PATH = "user://test_missing_script_title.tscn"
const TEST_MISSING_NESTED_TITLE_PATH = "user://test_missing_nested_title.tscn"
const TEST_WRONG_SCRIPT_BASE_TITLE_PATH = "user://test_wrong_script_base_title.tscn"
const TEST_UID_RELOCATED_TITLE_PATH = "user://test_uid_relocated_title.tscn"
const TEST_WRONG_TYPED_TEXTURE_TITLE_PATH = (
	"user://test_wrong_typed_texture_title.tscn"
)
const TEST_WRONG_TYPED_TEXTURE_PATH = "user://test_wrong_typed_texture.tres"
const TEST_MALFORMED_TEXTURE_TITLE_PATH = (
	"user://test_malformed_texture_title.tscn"
)
const TEST_MALFORMED_TEXTURE_PATH = "user://test_malformed_texture.tres"
const TEST_MULTILINE_RESOURCE_TITLE_PATH = (
	"user://test_multiline_resource_title.tscn"
)
const UID_DEPENDENCY_SCRIPT = (
	"res://tests/fixtures/pck_smoke/export_probe_runner.gd"
)
const UID_DEPENDENCY_TEXT = "uid://4elip3ufjpp"
const PRIVATE_SENTINEL = "PRIVATE_VALUE_MUST_NOT_APPEAR_IN_DIAGNOSTIC"
const TEST_CONFIG_PATHS = [
	TEST_BASE_CONFIG_PATH,
	TEST_LOCAL_CONFIG_PATH,
	TEST_MISSING_CONFIG_PATH,
	TEST_EMPTY_TITLE_PATH,
	TEST_MISSING_SCRIPT_TITLE_PATH,
	TEST_MISSING_NESTED_TITLE_PATH,
	TEST_WRONG_SCRIPT_BASE_TITLE_PATH,
	TEST_UID_RELOCATED_TITLE_PATH,
	TEST_WRONG_TYPED_TEXTURE_TITLE_PATH,
	TEST_WRONG_TYPED_TEXTURE_PATH,
	TEST_MALFORMED_TEXTURE_TITLE_PATH,
	TEST_MALFORMED_TEXTURE_PATH,
	TEST_MULTILINE_RESOURCE_TITLE_PATH,
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
		var parent := DirAccess.open(absolute_path.get_base_dir())
		if parent != null and parent.is_link(absolute_path.get_file()):
			parent.remove(absolute_path.get_file())
		elif FileAccess.file_exists(path):
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
		file.close()


func _write_project_config_bytes(path: String, contents: PackedByteArray) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert_not_null(file)
	if file != null:
		file.store_buffer(contents)
		file.close()


func test_defaults_when_no_file():
	# Loading a non-existent file should use all defaults
	assert_eq(config.load_from_path(TEST_MISSING_CONFIG_PATH), ERR_FILE_NOT_FOUND)

	assert_eq(StellaConfig.SCHEMA_VERSION, 2)
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


func test_config_file_saved_primitives_round_trip_in_a_base_only_config():
	var expected_title := (
		"First line\nSecond line\tTabbed\rCarriage "
		+ "Quote: \" Backslash: \\ Bell: " + String.chr(7)
		+ " Backspace: " + String.chr(8)
		+ " Form feed: " + String.chr(12)
		+ " Vertical tab: " + String.chr(11)
	)
	_write_project_config(TEST_BASE_CONFIG_PATH, {
		"game": {
			"title": expected_title,
		},
		"features": {
			"backlog": false,
			"save_slots": 100,
		},
	})
	var loaded: StellaConfig = _runtime._load_project_config(
		TEST_BASE_CONFIG_PATH,
		TEST_MISSING_CONFIG_PATH,
	)

	assert_eq(loaded.game_title, expected_title)
	assert_false(loaded.backlog)
	assert_eq(loaded.save_slots, 100)
	assert_eq(loaded.get_applied_sources(), PackedStringArray([
		TEST_BASE_CONFIG_PATH,
	]))
	assert_engine_error_count(0,
		"ConfigFile-generated primitive values must parse without raw engine errors")


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


func test_runtime_applies_default_snapshot_after_config_sources_are_removed():
	# Simulate paths left behind by a previous local configuration.
	_runtime.backgrounds_path = "res://private/backgrounds/"
	_runtime.characters_path = "res://private/characters/"
	_runtime.stage_assets_path = "res://private/stage/"
	_runtime.bgm_path = "res://private/bgm/"
	_runtime.se_path = "res://private/se/"
	_runtime.voice_path = "res://private/voice/"

	_runtime.config = StellaConfig.new()
	_runtime._apply_config()

	assert_eq(_runtime.backgrounds_path, "res://art/backgrounds/")
	assert_eq(_runtime.characters_path, "res://art/characters/")
	assert_eq(_runtime.stage_assets_path, "res://art/stage/")
	assert_eq(_runtime.bgm_path, "res://audio/bgm/")
	assert_eq(_runtime.se_path, "res://audio/se/")
	assert_eq(_runtime.voice_path, "res://audio/voice/")


func test_runtime_title_scene_defaults_to_builtin():
	# Fresh config with no file — title_scene should default to built-in
	_runtime.config = StellaConfig.new()
	_runtime._apply_config()

	assert_eq(_runtime.title_scene_path, "res://addons/stella/scenes/title.tscn")


func test_title_resolver_rejects_bootstrap_scripts_anywhere_in_packed_tree():
	var fallback := load(_runtime.DEFAULT_TITLE_SCENE) as PackedScene
	for recursive_path: String in [
		"res://tests/fixtures/startup/recursive_title.tscn",
		"res://tests/fixtures/startup/inherited_recursive_title.tscn",
		"res://tests/fixtures/startup/nested_recursive_title.tscn",
		"res://tests/fixtures/startup/nested_instance_recursive_title.tscn",
		(
			"res://tests/fixtures/startup/"
			+ "cleared_root_with_recursive_child_title.tscn"
		),
	]:
		_runtime.title_scene_path = recursive_path
		var resolved: PackedScene = _runtime.resolve_title_scene(fallback)
		assert_eq(resolved, fallback)
		assert_eq(_runtime.title_scene_path, _runtime.DEFAULT_TITLE_SCENE)
		assert_push_error("falling back to the built-in title scene")


func test_title_resolver_rejects_empty_and_required_constructor_scenes():
	var empty_scene := PackedScene.new()
	assert_eq(ResourceSaver.save(empty_scene, TEST_EMPTY_TITLE_PATH), OK)
	var fallback := load(_runtime.DEFAULT_TITLE_SCENE) as PackedScene
	for invalid_path: String in [
		TEST_EMPTY_TITLE_PATH,
		"res://tests/fixtures/startup/required_init_title.tscn",
	]:
		_runtime.title_scene_path = invalid_path
		var resolved: PackedScene = _runtime.resolve_title_scene(fallback)
		assert_eq(resolved, fallback)
		assert_eq(_runtime.title_scene_path, _runtime.DEFAULT_TITLE_SCENE)
		assert_push_error("falling back to the built-in title scene")


func test_title_resolver_accepts_inherited_scene_that_explicitly_clears_script():
	var cleared_path := (
		"res://tests/fixtures/startup/cleared_inherited_script_title.tscn"
	)
	_runtime.title_scene_path = cleared_path
	var resolved: PackedScene = _runtime.resolve_title_scene()

	assert_not_null(resolved)
	assert_eq(resolved.resource_path, cleared_path)
	assert_eq(_runtime.title_scene_path, cleared_path)
	assert_engine_error_count(0)


func test_title_dependency_preflight_accepts_multiline_serialized_variants():
	_write_raw_project_config(
		TEST_MULTILINE_RESOURCE_TITLE_PATH,
		(
			"[gd_scene format=3]\n\n"
			+ "[node name=\"MultilineMetadataTitle\" type=\"Node\" "
			+ "groups=[\"alpha\", \"beta\"]]\n"
			+ "metadata/example = {\n"
			+ "\"items\": [1, 2, 3],\n"
			+ "\"nested\": {\n"
			+ "\"enabled\": true\n"
			+ "}\n"
			+ "}\n"
			+ "metadata/paths = Array[NodePath]([\n"
			+ "NodePath(\"One\"),\n"
			+ "NodePath(\"Two\")\n"
			+ "])\n"
		),
	)
	_runtime.title_scene_path = TEST_MULTILINE_RESOURCE_TITLE_PATH

	var resolved: PackedScene = _runtime.resolve_title_scene()

	assert_not_null(resolved)
	assert_eq(resolved.resource_path, TEST_MULTILINE_RESOURCE_TITLE_PATH)
	assert_eq(_runtime.title_scene_path, TEST_MULTILINE_RESOURCE_TITLE_PATH)
	assert_engine_error_count(0)


func test_title_dependency_prefers_relocated_uid_over_stale_fallback_path():
	assert_true(ResourceLoader.exists(UID_DEPENDENCY_SCRIPT, "Script"))
	assert_true(ResourceUID.has_id(ResourceUID.text_to_id(UID_DEPENDENCY_TEXT)))
	_write_raw_project_config(
		TEST_UID_RELOCATED_TITLE_PATH,
		(
			"[gd_scene load_steps=2 format=3]\n\n"
			+ "[ext_resource type=\"Script\" uid=\"%s\" "
			% UID_DEPENDENCY_TEXT
			+ "path=\"user://stale_relocated_dependency.gd\" "
			+ "id=\"1_script\"]\n\n"
			+ "[node name=\"UidRelocatedTitle\" type=\"Node\"]\n"
			+ "script = ExtResource(\"1_script\")\n"
		),
	)

	var dependencies := ResourceLoader.get_dependencies(
		TEST_UID_RELOCATED_TITLE_PATH,
	)
	assert_eq(dependencies.size(), 1)
	assert_eq(
		_runtime._resource_dependency_path(dependencies[0]),
		UID_DEPENDENCY_SCRIPT,
	)
	_runtime.title_scene_path = TEST_UID_RELOCATED_TITLE_PATH
	var resolved: PackedScene = _runtime.resolve_title_scene()
	assert_not_null(resolved)
	assert_eq(resolved.resource_path, TEST_UID_RELOCATED_TITLE_PATH)
	assert_eq(_runtime.title_scene_path, TEST_UID_RELOCATED_TITLE_PATH)
	assert_engine_error_count(0)


func test_title_resolver_rejects_degraded_dependencies_and_wrong_script_base():
	_write_raw_project_config(
		TEST_MISSING_SCRIPT_TITLE_PATH,
		(
			"[gd_scene load_steps=2 format=3]\n\n"
			+ "[ext_resource type=\"Script\" "
			+ "path=\"user://missing_title_dependency.gd\" id=\"1_missing\"]\n\n"
			+ "[node name=\"MissingScriptTitle\" type=\"Node\"]\n"
			+ "script = ExtResource(\"1_missing\")\n"
		),
	)
	_write_raw_project_config(
		TEST_MISSING_NESTED_TITLE_PATH,
		(
			"[gd_scene load_steps=2 format=3]\n\n"
			+ "[ext_resource type=\"PackedScene\" "
			+ "path=\"user://missing_title_dependency.tscn\" id=\"1_missing\"]\n\n"
			+ "[node name=\"MissingNestedTitle\" type=\"Node\"]\n\n"
			+ "[node name=\"MissingChild\" parent=\".\" "
			+ "instance=ExtResource(\"1_missing\")]\n"
		),
	)
	_write_raw_project_config(
		TEST_WRONG_SCRIPT_BASE_TITLE_PATH,
		(
			"[gd_scene load_steps=2 format=3]\n\n"
			+ "[ext_resource type=\"Script\" "
			+ "path=\"res://addons/stella/presentation/dialogue/"
			+ "dialogue_mode_profile.gd\" id=\"1_resource\"]\n\n"
			+ "[node name=\"WrongScriptBaseTitle\" type=\"Node\"]\n"
			+ "script = ExtResource(\"1_resource\")\n"
		),
	)

	var fallback := load(_runtime.DEFAULT_TITLE_SCENE) as PackedScene
	for invalid_path: String in [
		TEST_MISSING_SCRIPT_TITLE_PATH,
		TEST_MISSING_NESTED_TITLE_PATH,
		TEST_WRONG_SCRIPT_BASE_TITLE_PATH,
	]:
		_runtime.title_scene_path = invalid_path
		var resolved: PackedScene = _runtime.resolve_title_scene(fallback)
		assert_eq(resolved, fallback)
		assert_eq(_runtime.title_scene_path, _runtime.DEFAULT_TITLE_SCENE)
		assert_push_error("falling back to the built-in title scene")
	assert_engine_error_count(0,
		"dependency preflight must reject degraded scenes before ResourceLoader "
		+ "prints missing private paths")


func test_title_resolver_rejects_wrong_type_and_unloadable_existing_resources():
	_write_raw_project_config(
		TEST_WRONG_TYPED_TEXTURE_PATH,
		"[gd_resource type=\"Resource\" format=3]\n\n[resource]\n",
	)
	_write_raw_project_config(
		TEST_WRONG_TYPED_TEXTURE_TITLE_PATH,
		(
			"[gd_scene load_steps=2 format=3]\n\n"
			+ "[ext_resource type=\"Texture2D\" "
			+ "path=\"%s\" id=\"1_texture\"]\n\n"
			% TEST_WRONG_TYPED_TEXTURE_PATH
			+ "[node name=\"WrongTypedTextureTitle\" type=\"Sprite2D\"]\n"
			+ "texture = ExtResource(\"1_texture\")\n"
		),
	)
	_write_raw_project_config(
		TEST_MALFORMED_TEXTURE_PATH,
		(
			"[gd_resource type=\"Texture2D\" format=3]\n\n"
			+ "[resource]\n"
			+ "private_value = PRIVATE_DEPENDENCY_VALUE_MUST_NOT_LEAK\n"
		),
	)
	_write_raw_project_config(
		TEST_MALFORMED_TEXTURE_TITLE_PATH,
		(
			"[gd_scene load_steps=2 format=3]\n\n"
			+ "[ext_resource type=\"Texture2D\" "
			+ "path=\"%s\" id=\"1_texture\"]\n\n"
			% TEST_MALFORMED_TEXTURE_PATH
			+ "[node name=\"MalformedTextureTitle\" type=\"Sprite2D\"]\n"
			+ "texture = ExtResource(\"1_texture\")\n"
		),
	)

	var fallback := load(_runtime.DEFAULT_TITLE_SCENE) as PackedScene
	for invalid_path: String in [
		TEST_WRONG_TYPED_TEXTURE_TITLE_PATH,
		TEST_MALFORMED_TEXTURE_TITLE_PATH,
	]:
		_runtime.title_scene_path = invalid_path
		var resolved: PackedScene = _runtime.resolve_title_scene(fallback)
		assert_eq(resolved, fallback)
		assert_eq(_runtime.title_scene_path, _runtime.DEFAULT_TITLE_SCENE)
		assert_push_error("falling back to the built-in title scene")
	assert_engine_error_count(0,
		"Dependency validation must not pass private malformed source to Godot")


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


func test_unknown_section_rejects_the_whole_source_atomically():
	_write_raw_project_config(
		TEST_LOCAL_CONFIG_PATH,
		"[game]\ntitle = \"Must Not Commit\"\n[private]\nsecret = %s\n" % PRIVATE_SENTINEL,
	)

	assert_eq(config.load_from_path(TEST_LOCAL_CONFIG_PATH), ERR_INVALID_DATA)
	assert_eq(config.game_title, "Stella")
	assert_false(config.has_config_file)
	assert_eq(config.get_applied_sources(), PackedStringArray())
	assert_eq(config.last_error_line, 3)
	assert_eq(config.last_error_column, 2)
	assert_true(config.last_error_detail.contains("unknown section"))
	assert_false(config.last_error_detail.contains(PRIVATE_SENTINEL))


func test_unknown_key_rejects_the_whole_source_atomically():
	_write_raw_project_config(
		TEST_LOCAL_CONFIG_PATH,
		"[game]\ntitle = \"Must Not Commit\"\nprivate_key = %s\n" % PRIVATE_SENTINEL,
	)

	assert_eq(config.load_from_path(TEST_LOCAL_CONFIG_PATH), ERR_INVALID_DATA)
	assert_eq(config.game_title, "Stella")
	assert_false(config.has_config_file)
	assert_eq(config.get_applied_sources(), PackedStringArray())
	assert_eq(config.last_error_line, 3)
	assert_eq(config.last_error_column, 1)
	assert_true(config.last_error_detail.contains("unknown key"))
	assert_false(config.last_error_detail.contains(PRIVATE_SENTINEL))


func test_parser_reports_safe_one_based_line_and_column_for_crlf():
	_write_raw_project_config(
		TEST_LOCAL_CONFIG_PATH,
		"[game]\r\n  title = %s\r\n" % PRIVATE_SENTINEL,
	)

	assert_eq(config.load_from_path(TEST_LOCAL_CONFIG_PATH), ERR_INVALID_DATA)
	assert_eq(config.last_error_line, 2)
	assert_eq(config.last_error_column, 11)
	assert_true(config.last_error_detail.contains("line 2, column 11"))
	assert_true(config.last_error_detail.contains("[game] title"))
	assert_false(config.last_error_detail.contains(PRIVATE_SENTINEL))


func test_parser_supports_comments_crlf_whitespace_and_quoted_escapes():
	_write_raw_project_config(
		TEST_LOCAL_CONFIG_PATH,
		(
			"  ; leading comment\r\n"
			+ "[ game ] ; trailing section comment\r\n"
			+ " title = \"Line\\nQuote: \\\";#\\\" Slash: \\\\ Snowman: \\u2603\" ; value comment\r\n"
			+ "[features]; compact trailing comment\r\n"
			+ "\tbacklog = false\r\n"
			+ "\tsave_slots = 12; final comment"
		),
	)

	assert_eq(config.load_from_path(TEST_LOCAL_CONFIG_PATH), OK)
	assert_eq(config.game_title, "Line\nQuote: \";#\" Slash: \\ Snowman: ☃")
	assert_false(config.backlog)
	assert_eq(config.save_slots, 12)
	assert_eq(config.last_error_line, 0)
	assert_eq(config.last_error_column, 0)


func test_hash_trailing_content_rejects_the_whole_source_atomically():
	_write_project_config(TEST_BASE_CONFIG_PATH, {
		"game": {"title": "Committed Base"},
	})
	assert_eq(config.load_from_path(TEST_BASE_CONFIG_PATH), OK)
	_write_raw_project_config(
		TEST_LOCAL_CONFIG_PATH,
		(
			"[game]\n"
			+ "title = \"Rejected Local\"#not-a-stella-comment\n"
			+ "scenario = \"res://must_not_apply.stla\"\n"
		),
	)

	assert_eq(config.load_from_path(TEST_LOCAL_CONFIG_PATH), ERR_PARSE_ERROR)
	assert_eq(config.game_title, "Committed Base")
	assert_eq(config.scenario_path, "res://scenarios/main.stla")
	assert_eq(config.get_applied_sources(), PackedStringArray([
		TEST_BASE_CONFIG_PATH,
	]))
	assert_true(config.last_error_detail.contains("unexpected trailing content"))
	assert_engine_error_count(0)


func test_parser_preserves_config_file_unknown_escape_compatibility():
	_write_raw_project_config(
		TEST_LOCAL_CONFIG_PATH,
		"[game]\ntitle = \"unknown \\q escape\"\n",
	)

	assert_eq(config.load_from_path(TEST_LOCAL_CONFIG_PATH), OK)
	assert_eq(config.game_title, "unknown q escape")
	assert_engine_error_count(0)


func test_parser_matches_config_file_upper_unicode_and_literal_a_v_escapes():
	_write_raw_project_config(
		TEST_LOCAL_CONFIG_PATH,
		"[game]\ntitle = \"Emoji: \\U01f600; replacement: \\U110000; a: \\a; v: \\v\"\n",
	)

	assert_eq(config.load_from_path(TEST_LOCAL_CONFIG_PATH), OK)
	assert_eq(config.game_title, "Emoji: 😀; replacement: �; a: a; v: v")
	assert_engine_error_count(0,
		"Godot 4.6.1 ConfigFile-compatible escapes must not emit parser errors")


func test_parser_matches_config_file_surrogate_pair_escapes():
	for encoded_pair: String in [
		"\\uD83D\\uDE00",
		"\\uD83D\\U00DE00",
		"\\U00D83D\\uDE00",
		"\\U00D83D\\U00DE00",
	]:
		config.reset()
		_write_raw_project_config(
			TEST_LOCAL_CONFIG_PATH,
			"[game]\ntitle = \"%s\"\n" % encoded_pair,
		)
		assert_eq(config.load_from_path(TEST_LOCAL_CONFIG_PATH), OK)
		assert_eq(config.game_title, "😀")
	assert_engine_error_count(0,
		"ConfigFile-compatible surrogate pairs must not emit parser errors")


func test_parser_rejects_unpaired_surrogate_escapes_safely():
	for invalid_pair: String in [
		"\\uD83D",
		"\\uDE00",
		"\\uD83D\\u0041",
	]:
		config.reset()
		_write_raw_project_config(
			TEST_LOCAL_CONFIG_PATH,
			"[game]\ntitle = \"%s\"\n" % invalid_pair,
		)
		assert_eq(config.load_from_path(TEST_LOCAL_CONFIG_PATH), ERR_PARSE_ERROR)
		assert_eq(config.game_title, "Stella")
		assert_true(config.last_error_detail.contains("surrogate pair"))
	assert_engine_error_count(0,
		"Invalid surrogate halves must not reach String.chr()")


func test_malformed_utf8_is_rejected_atomically_with_safe_location():
	var invalid_sequences: Array[PackedByteArray] = [
		PackedByteArray([0xC0, 0xAF]),
		PackedByteArray([0xED, 0xA0, 0x80]),
		PackedByteArray([0xF4, 0x90, 0x80, 0x80]),
		PackedByteArray([0xE2, 0x82]),
	]
	for invalid_sequence: PackedByteArray in invalid_sequences:
		config.reset()
		var contents := "[game]\ntitle = \"".to_utf8_buffer()
		contents.append_array(invalid_sequence)
		contents.append_array((PRIVATE_SENTINEL + "\"\n").to_utf8_buffer())
		_write_project_config_bytes(TEST_LOCAL_CONFIG_PATH, contents)

		assert_eq(config.load_from_path(TEST_LOCAL_CONFIG_PATH), ERR_INVALID_DATA)
		assert_eq(config.game_title, "Stella")
		assert_false(config.has_config_file)
		assert_eq(config.get_applied_sources(), PackedStringArray())
		assert_eq(config.last_error_line, 2)
		assert_eq(config.last_error_column, 10)
		assert_true(config.last_error_detail.contains("source is not valid UTF-8"))
		assert_false(config.last_error_detail.contains(PRIVATE_SENTINEL))
	assert_engine_error_count(0,
		"Malformed UTF-8 must be rejected before Godot inserts replacement characters")


func test_nul_byte_rejects_the_local_source_before_string_conversion():
	_write_project_config(TEST_BASE_CONFIG_PATH, {
		"game": {"title": "Base Game"},
		"features": {"save_slots": 9},
	})
	var local_bytes := "[game]\ntitle = \"Local Must Not Commit\"\n".to_utf8_buffer()
	local_bytes.append(0)
	local_bytes.append_array("[features]\nsave_slots = 0\n".to_utf8_buffer())
	_write_project_config_bytes(TEST_LOCAL_CONFIG_PATH, local_bytes)

	var loaded: StellaConfig = _runtime._load_project_config(
		TEST_BASE_CONFIG_PATH,
		TEST_LOCAL_CONFIG_PATH,
	)
	assert_push_error("failed to load config source")

	assert_eq(loaded.game_title, "Base Game")
	assert_eq(loaded.save_slots, 9)
	assert_eq(loaded.get_applied_sources(), PackedStringArray([
		TEST_BASE_CONFIG_PATH,
	]))
	assert_eq(loaded.last_error, ERR_INVALID_DATA)
	assert_eq(loaded.last_error_source, TEST_LOCAL_CONFIG_PATH)
	assert_eq(loaded.last_error_line, 3)
	assert_eq(loaded.last_error_column, 1)
	assert_true(loaded.last_error_detail.contains("NUL byte"))
	assert_engine_error_count(0)


func test_large_quoted_string_parses_without_quadratic_concatenation():
	var payload := "x".repeat(128 * 1024)
	_write_raw_project_config(
		TEST_LOCAL_CONFIG_PATH,
		"[game]\ntitle = \"" + payload + "\"\n",
	)

	assert_eq(config.load_from_path(TEST_LOCAL_CONFIG_PATH), OK)
	assert_eq(config.game_title.length(), payload.length())
	assert_eq(config.game_title, payload)
	assert_engine_error_count(0)


func test_oversized_quoted_string_is_rejected_atomically():
	var payload := "x".repeat(256 * 1024 + 1)
	_write_raw_project_config(
		TEST_LOCAL_CONFIG_PATH,
		"[game]\ntitle = \"" + payload + "\"\n",
	)

	assert_eq(config.load_from_path(TEST_LOCAL_CONFIG_PATH), ERR_INVALID_DATA)
	assert_eq(config.game_title, "Stella")
	assert_false(config.has_config_file)
	assert_true(config.last_error_detail.contains("262144-byte limit"))
	assert_engine_error_count(0)


func test_oversized_source_is_rejected_before_decoding():
	var contents := PackedByteArray()
	contents.resize(1024 * 1024 + 1)
	contents.fill(0x41)
	_write_project_config_bytes(TEST_LOCAL_CONFIG_PATH, contents)

	assert_eq(config.load_from_path(TEST_LOCAL_CONFIG_PATH), ERR_INVALID_DATA)
	assert_eq(config.game_title, "Stella")
	assert_false(config.has_config_file)
	assert_true(config.last_error_detail.contains("1048576-byte limit"))
	assert_engine_error_count(0)


func test_parser_accepts_a_utf8_bom_without_escaped_unicode_source_literals():
	_write_raw_project_config(
		TEST_LOCAL_CONFIG_PATH,
		String.chr(0xFEFF) + "[game]\ntitle = \"BOM Game\"\n",
	)

	assert_eq(config.load_from_path(TEST_LOCAL_CONFIG_PATH), OK)
	assert_eq(config.game_title, "BOM Game")
	assert_engine_error_count(0)


func test_trailing_content_rejects_the_whole_source():
	_write_raw_project_config(
		TEST_LOCAL_CONFIG_PATH,
		"[game]\ntitle = \"Must Not Commit\" %s\n" % PRIVATE_SENTINEL,
	)

	assert_eq(config.load_from_path(TEST_LOCAL_CONFIG_PATH), ERR_PARSE_ERROR)
	assert_eq(config.game_title, "Stella")
	assert_false(config.has_config_file)
	assert_true(config.last_error_detail.contains("unexpected trailing content"))
	assert_false(config.last_error_detail.contains(PRIVATE_SENTINEL))


func test_out_of_range_int_is_rejected_atomically_without_raw_engine_errors():
	var unsafe_numbers := [
		"9223372036854775808",
		"-9223372036854775809",
		"99999999999999999999999999999999999999999999999999",
	]
	for unsafe_number: String in unsafe_numbers:
		config.reset()
		_write_raw_project_config(
			TEST_LOCAL_CONFIG_PATH,
			(
				"[game]\ntitle = \"Must Not Commit\"\n"
				+ "[features]\nsave_slots = %s\n" % unsafe_number
			),
		)

		assert_eq(config.load_from_path(TEST_LOCAL_CONFIG_PATH), ERR_INVALID_DATA)
		assert_eq(config.game_title, "Stella")
		assert_eq(config.save_slots, 8)
		assert_false(config.has_config_file)
		assert_eq(config.last_error_line, 4)
		assert_true(config.last_error_detail.contains("outside the supported range"))
		assert_false(config.last_error_detail.contains(unsafe_number))
	assert_engine_error_count(0,
		"Range validation must not pass unsafe digits to String.to_int()")


func test_save_slots_accepts_supported_range_boundaries():
	for slot_count: int in [1, 100]:
		config.reset()
		_write_project_config(TEST_LOCAL_CONFIG_PATH, {
			"features": {
				"save_slots": slot_count,
			},
		})

		assert_eq(config.load_from_path(TEST_LOCAL_CONFIG_PATH), OK)
		assert_eq(config.save_slots, slot_count)
	assert_engine_error_count(0)


func test_save_slots_outside_supported_range_is_rejected_atomically_and_safely():
	for slot_count: int in [0, 101, -1]:
		config.reset()
		_write_project_config(TEST_LOCAL_CONFIG_PATH, {
			"game": {
				"title": PRIVATE_SENTINEL,
			},
			"features": {
				"save_slots": slot_count,
			},
		})

		assert_eq(config.load_from_path(TEST_LOCAL_CONFIG_PATH), ERR_INVALID_DATA)
		assert_eq(config.game_title, "Stella",
			"A range failure must reject the entire source")
		assert_eq(config.save_slots, 8)
		assert_false(config.has_config_file)
		assert_eq(config.get_applied_sources(), PackedStringArray())
		assert_true(config.last_error_detail.contains("[features] save_slots"))
		assert_true(config.last_error_detail.contains("between 1 and 100"))
		assert_false(config.last_error_detail.contains(PRIVATE_SENTINEL))
	assert_engine_error_count(0,
		"Business-range validation must not emit raw parser errors")


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


func test_malformed_base_blocks_a_valid_local_source():
	_write_raw_project_config(
		TEST_BASE_CONFIG_PATH,
		"[game]\ntitle = %s\n" % PRIVATE_SENTINEL,
	)
	_write_raw_project_config(
		TEST_LOCAL_CONFIG_PATH,
		"[game]\ntitle = \"Local Must Not Load\"\n",
	)

	var loaded: StellaConfig = _runtime._load_project_config(
		TEST_BASE_CONFIG_PATH,
		TEST_LOCAL_CONFIG_PATH,
	)
	assert_push_error("failed to load config source")

	assert_eq(loaded.game_title, "Stella")
	assert_false(loaded.has_config_file)
	assert_eq(loaded.get_applied_sources(), PackedStringArray())
	assert_eq(loaded.last_error, ERR_INVALID_DATA)
	assert_eq(loaded.last_error_source, TEST_BASE_CONFIG_PATH)
	assert_eq(loaded.last_error_line, 2)
	assert_eq(loaded.last_error_column, 9)
	assert_false(loaded.last_error_detail.contains(PRIVATE_SENTINEL))


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


func test_dangling_local_symlink_reports_error_and_preserves_base():
	_write_project_config(TEST_BASE_CONFIG_PATH, {
		"game": {"title": "Base Game"},
	})
	var absolute_local := ProjectSettings.globalize_path(TEST_LOCAL_CONFIG_PATH)
	var parent := DirAccess.open(absolute_local.get_base_dir())
	assert_not_null(parent)
	if parent == null:
		return
	assert_eq(parent.create_link(
		"missing-private.cfg",
		absolute_local.get_file(),
	), OK)
	assert_true(parent.is_link(absolute_local.get_file()))

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


func test_running_suite_does_not_consume_the_ci_poison_local_config():
	assert_ne(_runtime.config.game_title, "CI_LOCAL_CONFIG_POISON",
		"The Runtime must not resolve values from CI's root poison local config")
	assert_false(_runtime.get_applied_config_sources().has(
		_runtime.LOCAL_CONFIG_PATH,
	), "Hermetic test startup must skip the implicit root local source")
