extends GutTest

const SETTINGS_SCHEMA_PATH := "res://tests/fixtures/startup/project_settings.json"


func _project_manager() -> SettingsManager:
	var manager := SettingsManager.new()
	assert_eq(manager.configure_project_schema(SETTINGS_SCHEMA_PATH), OK)
	return manager


func _project_profile() -> AutoTimingProfile:
	var profile := AutoTimingProfile.new()
	profile.setting_key = "project.auto_base_wait"
	profile.base_delay_seconds = 3.0
	profile.setting_scale_seconds = -0.02
	profile.visible_character_scale_seconds = 0.01
	profile.voiced_line_addition_seconds = 0.2
	profile.minimum_delay_seconds = 0.25
	profile.maximum_delay_seconds = 5.0
	return profile


func test_project_setting_and_canonical_metadata_resolve_one_delay() -> void:
	var manager := _project_manager()
	var profile := _project_profile()
	assert_true(profile.validation_errors(manager).is_empty())

	var result := profile.resolve_delay(manager, 20, true)
	assert_true(result["ok"])
	assert_almost_eq(float(result["delay"]), 2.4, 0.000001)

	assert_true(manager.set_value("project.auto_base_wait", 100))
	result = profile.resolve_delay(manager, 20, true)
	assert_true(result["ok"])
	assert_almost_eq(float(result["delay"]), 1.4, 0.000001,
		"a live setting change affects the next resolved Auto tail")

	manager.reset_to_default()
	result = profile.resolve_delay(manager, 20, false)
	assert_true(result["ok"])
	assert_almost_eq(float(result["delay"]), 2.2, 0.000001,
		"reset is read through the same canonical SettingsManager binding")


func test_successful_settings_load_changes_the_next_resolved_delay() -> void:
	var manager := _project_manager()
	var profile := _project_profile()
	var path := "user://auto_timing_profile_settings_test.json"
	manager.settings_path = path
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert_not_null(file)
	if file == null:
		return
	file.store_string(JSON.stringify({
		"schema_version": 1,
		"values": {"project.auto_base_wait": 75},
	}))
	file.close()
	assert_eq(manager.load_settings(), OK)
	var result := profile.resolve_delay(manager, 0, false)
	assert_true(result["ok"])
	assert_almost_eq(float(result["delay"]), 1.5, 0.000001)
	assert_eq(DirAccess.remove_absolute(ProjectSettings.globalize_path(path)), OK)


func test_profile_clamps_the_complete_formula_only_at_its_final_boundary() -> void:
	var manager := _project_manager()
	var profile := _project_profile()
	profile.base_delay_seconds = -100.0
	profile.setting_scale_seconds = 0.0
	var result := profile.resolve_delay(manager, 0, false)
	assert_true(result["ok"])
	assert_almost_eq(float(result["delay"]), 0.25, 0.000001)

	profile.base_delay_seconds = 100.0
	result = profile.resolve_delay(manager, 0, false)
	assert_true(result["ok"])
	assert_almost_eq(float(result["delay"]), 5.0, 0.000001)


func test_missing_or_non_numeric_setting_binding_fails_closed() -> void:
	var manager := _project_manager()
	var profile := _project_profile()
	profile.setting_key = "project.missing"
	assert_true("is not registered" in "; ".join(profile.validation_errors(manager)))
	assert_false(profile.resolve_delay(manager, 1, false)["ok"])

	profile.setting_key = "fullscreen"
	assert_true("integer or number" in "; ".join(profile.validation_errors(manager)))
	assert_false(profile.resolve_delay(manager, 1, false)["ok"])


func test_invalid_formula_and_metadata_fail_closed_without_a_delay() -> void:
	var manager := _project_manager()
	var profile := _project_profile()
	profile.maximum_delay_seconds = 3600.1
	assert_true("cannot exceed" in "; ".join(profile.validation_errors(manager)))
	assert_false(profile.resolve_delay(manager, 1, false)["ok"])

	profile.maximum_delay_seconds = 5.0
	profile.minimum_delay_seconds = -0.1
	assert_true("cannot be negative" in "; ".join(profile.validation_errors(manager)))
	assert_false(profile.resolve_delay(manager, 1, false)["ok"])

	profile.minimum_delay_seconds = 0.0
	assert_false(profile.resolve_delay(manager, -1, false)["ok"])
