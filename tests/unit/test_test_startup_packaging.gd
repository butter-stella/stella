extends GutTest
## Source-package regressions for deterministic clean headless test startup.

const AUDIO_STATE_SOURCES := [
	"res://addons/stella/core/data/bgm_channel_state.gd",
	"res://addons/stella/core/data/loop_se_channel_state.gd",
]
const GUT_PLUGIN_PATH := "res://addons/gut/gut_plugin.gd"
const GUT_ROOT := "res://addons/gut"
const AGENT_INSTRUCTIONS_PATH := "res://AGENTS.md"
const CI_WORKFLOW_PATH := "res://.github/workflows/tests.yml"


func _collect_gut_text_resources(root: String) -> Array[String]:
	var result: Array[String] = []
	for filename: String in DirAccess.get_files_at(root):
		if filename.get_extension() in ["tscn", "tres"]:
			result.append(root.path_join(filename))
	for directory: String in DirAccess.get_directories_at(root):
		result.append_array(_collect_gut_text_resources(root.path_join(directory)))
	return result


func test_audio_state_sources_do_not_construct_an_unrepresentable_nul() -> void:
	var parser_noisy_escape := "\\" + "u" + "0000"
	for path: String in AUDIO_STATE_SOURCES:
		var source := FileAccess.get_file_as_string(path)
		assert_false(parser_noisy_escape in source, path)


func test_gut_imported_asset_references_do_not_pin_project_local_uids() -> void:
	var imported_asset_references := 0
	for path: String in _collect_gut_text_resources(GUT_ROOT):
		for line: String in FileAccess.get_file_as_string(path).split("\n"):
			if (
				line.begins_with("[ext_resource")
				and (
					".ttf\"" in line
					or ".png\"" in line
					or ".svg\"" in line
				)
			):
				imported_asset_references += 1
				assert_false(" uid=" in line, "%s: %s" % [path, line])
	assert_gt(imported_asset_references, 0,
		"the packaging gate must exercise real GUT imported assets")


func test_gut_editor_gui_dependencies_are_deferred_after_the_headless_gate() -> void:
	var source := FileAccess.get_file_as_string(GUT_PLUGIN_PATH)
	var headless_gate := source.find(
		'if(DisplayServer.get_name() == "headless")')
	var first_gui_dependency := source.find(
		'\tVersionConversion = load("res://addons/gut/version_conversion.gd")')
	assert_gte(headless_gate, 0)
	assert_gt(first_gui_dependency, headless_gate,
		"headless import must return before loading editor-only GUT dependencies")
	assert_false("preload('res://addons/gut/gui/GutBottomPanel.tscn')" in source)


func test_hermetic_test_entry_points_keep_settings_and_audio_cleanup_gates() -> void:
	var instructions := FileAccess.get_file_as_string(AGENT_INSTRUCTIONS_PATH)
	assert_true("STELLA_DISABLE_IMPLICIT_SETTINGS_LOAD=1" in instructions)
	assert_true(
		"-gpost_run_script=res://tests/helpers/gut_post_run.gd" in instructions)
	var workflow := FileAccess.get_file_as_string(CI_WORKFLOW_PATH)
	assert_true('STELLA_DISABLE_IMPLICIT_SETTINGS_LOAD: "1"' in workflow)
	assert_true(
		"-gpost_run_script=res://tests/helpers/gut_post_run.gd" in workflow)
