extends GutTest
## Declarative project settings schema, migration, facade-model, and persistence.

const SCHEMA_PATH := "user://tests/settings_schema/project_settings.json"
const SETTINGS_PATH := "user://tests/settings_schema/settings.json"

var _manager: SettingsManager


func before_each() -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path("user://tests/settings_schema"))
	_write_schema(_valid_schema())
	_manager = SettingsManager.new()
	_manager.settings_path = SETTINGS_PATH
	assert_eq(_manager.configure_project_schema(SCHEMA_PATH), OK)


func after_each() -> void:
	for path: String in [SCHEMA_PATH, SETTINGS_PATH]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_manager = null


func test_schema_registers_all_types_and_authored_built_in_defaults() -> void:
	assert_almost_eq(float(_manager.get_value("bgm_volume")), 0.7, 0.000001)
	assert_almost_eq(float(_manager.get_value("se_volume")), 0.6, 0.000001)
	assert_true(_manager.get_value("project.confirm_quit"))
	assert_eq(_manager.get_value("project.auto_base_wait"), 50)
	assert_almost_eq(float(_manager.get_value("project.ui_scale")), 1.0, 0.000001)
	assert_eq(_manager.get_value("project.text_mode"), "normal")
	assert_eq(_manager.get_value("project.character_enabled"), {})
	assert_eq(_manager.get_value("project.character_gain"), {})
	assert_eq(typeof(_manager.get_value("project.auto_base_wait")), TYPE_INT)
	assert_eq(typeof(_manager.get_value("auto_play_delay")), TYPE_FLOAT)
	assert_almost_eq(
		float(_manager.get_definition("bgm_volume")["default"]),
		0.7,
		0.000001,
	)
	assert_eq(
		_manager.get_definition("project.auto_base_wait"),
		{"type": "integer", "default": 50, "minimum": 0, "maximum": 100},
	)


func test_registered_values_validate_and_emit_complete_defensive_snapshots() -> void:
	var events: Array[Dictionary] = []
	_manager.settings_changed.connect(func(key: String, value: Variant) -> void:
		events.append({"key": key, "value": value})
	)
	assert_true(_manager.set_value("project.confirm_quit", false))
	assert_true(_manager.set_value("project.auto_base_wait", 80))
	assert_true(_manager.set_value("project.ui_scale", 1.25))
	assert_true(_manager.set_value("project.text_mode", "compact"))
	assert_true(_manager.set_value(
		"project.character_enabled", {"guide": true, "hero": false}))
	assert_true(_manager.set_value(
		"project.character_gain", {"guide": 0.75, "hero": 0.25}))

	assert_eq(events.map(func(event: Dictionary) -> String:
		return event["key"]), [
		"project.confirm_quit",
		"project.auto_base_wait",
		"project.ui_scale",
		"project.text_mode",
		"project.character_enabled",
		"project.character_gain",
	])
	var payload: Dictionary = events[-2]["value"]
	payload["guide"] = false
	var read_value: Dictionary = _manager.get_value("project.character_enabled")
	read_value["hero"] = true
	assert_eq(_manager.get_value("project.character_enabled"), {
		"guide": true,
		"hero": false,
	})


func test_invalid_direct_values_and_unknown_keys_fail_closed() -> void:
	var baseline := _manager.to_dict()
	for invalid: Variant in [-1, 101, 50.5, "50"]:
		assert_false(_manager.set_value("project.auto_base_wait", invalid))
		assert_push_warning("project.auto_base_wait")
	assert_false(_manager.set_value("project.text_mode", "unknown"))
	assert_push_warning("project.text_mode")
	assert_false(_manager.set_value(
		"project.character_enabled", {"hero": 1}))
	assert_push_warning("project.character_enabled")
	assert_false(_manager.set_value(
		"project.character_gain", {"hero": NAN}))
	assert_push_warning("project.character_gain")
	assert_false(_manager.set_value(
		"project.character_gain", {"hero": 1.1}))
	assert_push_warning("project.character_gain")
	assert_false(_manager.set_value(
		"project.character_enabled", {1: true, "hero": false}))
	assert_push_warning("project.character_enabled")
	assert_false(_manager.set_value("project.unregistered", true))
	assert_push_warning("unknown or unregistered setting 'project.unregistered'")
	assert_null(_manager.get_value("project.unregistered"))
	assert_push_warning("unknown or unregistered setting 'project.unregistered'")
	assert_eq(_manager.to_dict(), baseline)


func test_serialized_integer_conversion_rejects_out_of_range_exponents() -> void:
	var baseline := _manager.to_dict()
	_write_raw((
		'{"schema_version":3,"values":'
		+ '{"project.auto_base_wait":9.223372036854776e18}}'
	))

	assert_eq(_manager.load_settings(), ERR_INVALID_DATA)
	assert_push_warning("$.values.project.auto_base_wait")
	assert_eq(_manager.to_dict(), baseline)

	_write_schema_raw((
		'{"version":1,"settings":{"project.count":'
		+ '{"type":"integer","default":9.223372036854776e18}}}'
	))
	var candidate := SettingsSchema.new()
	assert_eq(candidate.load_from_path(SCHEMA_PATH), ERR_INVALID_DATA)
	assert_eq(candidate.last_error_field, "$.settings.project.count.default")


func test_minimal_version_and_settings_schema_uses_one_unified_registry() -> void:
	_write_schema({
		"version": 1,
		"settings": {
			"project.enabled": {"type": "boolean", "default": true},
		},
	})
	var candidate := SettingsManager.new()
	assert_eq(candidate.configure_project_schema(SCHEMA_PATH), OK)
	assert_true(candidate.has_setting("bgm_volume"))
	assert_true(candidate.has_setting("project.enabled"))
	assert_true(candidate.get_value("project.enabled"))
	assert_almost_eq(float(candidate.get_value("bgm_volume")), 0.8, 0.000001)


func test_json_persistence_round_trips_registered_values_and_version() -> void:
	_manager.set_value("bgm_volume", 0.4)
	_manager.set_value("project.auto_base_wait", 88)
	_manager.set_value("project.text_mode", "compact")
	_manager.set_value("project.character_enabled", {"hero": true})
	assert_eq(_manager.save(), OK)

	var parsed: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string(SETTINGS_PATH))
	assert_eq(parsed.keys(), ["schema_version", "values"])
	assert_eq(int(parsed["schema_version"]), 3)
	assert_true((parsed["values"] as Dictionary).has("bgm_volume"))
	assert_true((parsed["values"] as Dictionary).has("project.auto_base_wait"))

	var loaded := SettingsManager.new()
	loaded.settings_path = SETTINGS_PATH
	assert_eq(loaded.configure_project_schema(SCHEMA_PATH), OK)
	assert_eq(loaded.load_settings(), OK)
	assert_almost_eq(float(loaded.get_value("bgm_volume")), 0.4, 0.000001)
	assert_eq(loaded.get_value("project.auto_base_wait"), 88)
	assert_eq(loaded.get_value("project.text_mode"), "compact")
	var detached: Dictionary = loaded.get_value("project.character_enabled")
	detached["hero"] = false
	assert_eq(loaded.get_value("project.character_enabled"), {"hero": true})


func test_load_commits_atomically_then_notifies_in_registry_order() -> void:
	_manager.set_value("bgm_volume", 0.2)
	_manager.set_value("project.auto_base_wait", 10)
	var notifications: Array[String] = []
	var snapshots: Array[Dictionary] = []
	_manager.settings_changed.connect(func(key: String, _value: Variant) -> void:
		notifications.append(key)
		snapshots.append(_manager.to_dict())
	)
	_write_persistence(3, {
		"bgm_volume": 0.5,
		"project.auto_base_wait": 75,
		"project.confirm_quit": false,
	})

	assert_eq(_manager.load_settings(), OK)
	assert_eq(notifications, [
		"bgm_volume",
		"project.auto_base_wait",
		"project.confirm_quit",
	])
	for snapshot: Dictionary in snapshots:
		assert_almost_eq(float(snapshot["bgm_volume"]), 0.5, 0.000001)
		assert_eq(snapshot["project.auto_base_wait"], 75)
		assert_false(snapshot["project.confirm_quit"])


func test_unknown_persisted_key_rejects_every_sibling_without_notifications() -> void:
	_manager.set_value("project.auto_base_wait", 40)
	var baseline := _manager.to_dict()
	var notifications: Array[String] = []
	_manager.settings_changed.connect(func(key: String, _value: Variant) -> void:
		notifications.append(key)
	)
	_write_persistence(3, {
		"project.auto_base_wait": 70,
		"project.unregistered": true,
	})

	assert_eq(_manager.load_settings(), ERR_INVALID_DATA)
	assert_push_warning("$.values.project.unregistered")
	assert_eq(_manager.to_dict(), baseline)
	assert_eq(notifications, [])


func test_invalid_persisted_project_value_rejects_every_sibling() -> void:
	_manager.set_value("project.auto_base_wait", 40)
	var baseline := _manager.to_dict()
	_write_persistence(3, {
		"project.auto_base_wait": 70,
		"project.character_gain": {"hero": 1.5},
	})

	assert_eq(_manager.load_settings(), ERR_INVALID_DATA)
	assert_push_warning("$.values.project.character_gain")
	assert_eq(_manager.last_error_field, "$.values.project.character_gain")
	assert_eq(_manager.to_dict(), baseline)


func test_reset_uses_authored_defaults_and_notifies_actual_changes_once() -> void:
	_manager.set_value("bgm_volume", 0.1)
	_manager.set_value("project.auto_base_wait", 90)
	_manager.set_value("project.confirm_quit", false)
	var notifications: Array[String] = []
	var snapshots: Array[Dictionary] = []
	_manager.settings_changed.connect(func(key: String, _value: Variant) -> void:
		notifications.append(key)
		snapshots.append(_manager.to_dict())
	)

	_manager.reset_to_default()

	assert_eq(notifications, [
		"bgm_volume",
		"project.auto_base_wait",
		"project.confirm_quit",
	])
	for snapshot: Dictionary in snapshots:
		assert_almost_eq(float(snapshot["bgm_volume"]), 0.7, 0.000001)
		assert_eq(snapshot["project.auto_base_wait"], 50)
		assert_true(snapshot["project.confirm_quit"])
	notifications.clear()
	_manager.reset_to_default()
	assert_eq(notifications, [])


func test_contiguous_rename_and_remove_migrations_are_deterministic() -> void:
	_write_persistence(1, {
		"project.auto_delay": 65,
		"project.removed": true,
		"project.obsolete": "gone",
		"project.confirm_quit": false,
	})

	assert_eq(_manager.load_settings(), OK)
	assert_eq(_manager.get_value("project.auto_base_wait"), 65)
	assert_false(_manager.get_value("project.confirm_quit"))
	assert_false(_manager.to_dict().has("project.auto_delay"))
	assert_false(_manager.to_dict().has("project.removed"))
	assert_false(_manager.to_dict().has("project.obsolete"))


func test_migration_conflict_future_version_and_old_flat_json_fail_closed() -> void:
	var baseline := _manager.to_dict()
	_write_persistence(1, {
		"project.auto_delay": 65,
		"project.auto_base_wait": 70,
	})
	assert_eq(_manager.load_settings(), ERR_INVALID_DATA)
	assert_push_warning("conflicts at target 'project.auto_base_wait'")
	assert_eq(_manager.last_error_field, "$.values.project.auto_base_wait")
	assert_eq(_manager.to_dict(), baseline)

	_write_persistence(4, {"project.auto_base_wait": 70})
	assert_eq(_manager.load_settings(), ERR_INVALID_DATA)
	assert_push_warning("newer than the project schema")
	assert_eq(_manager.last_error_field, "$.schema_version")
	assert_eq(_manager.to_dict(), baseline)

	_write_raw(JSON.stringify({"project.auto_base_wait": 70}))
	assert_eq(_manager.load_settings(), ERR_INVALID_DATA)
	assert_push_warning("unknown persistence field")
	assert_eq(_manager.to_dict(), baseline)


func test_invalid_schema_is_atomic_and_reports_exact_source_field() -> void:
	var original_keys := _manager.get_registered_keys()
	_write_schema({
		"version": 1,
		"settings": {
			"not_namespaced": {"type": "boolean", "default": true},
		},
	})
	assert_eq(_manager.configure_project_schema(SCHEMA_PATH), ERR_INVALID_DATA)
	assert_eq(_manager.last_error_source, SCHEMA_PATH)
	assert_eq(_manager.last_error_field, "$.settings.not_namespaced")
	assert_eq(_manager.get_registered_keys(), original_keys)
	assert_true(_manager.has_setting("project.auto_base_wait"))


func test_invalid_schema_json_reports_source_and_parse_line_atomically() -> void:
	var original := _manager.to_dict()
	_write_schema_raw("{\n  \"version\": 1,\n  \"settings\": [\n}")
	assert_eq(_manager.configure_project_schema(SCHEMA_PATH), ERR_PARSE_ERROR)
	assert_eq(_manager.last_error_source, SCHEMA_PATH)
	assert_eq(_manager.last_error_field, "$")
	assert_string_contains(_manager.last_error_detail, "line 3")
	assert_eq(_manager.to_dict(), original)


func test_schema_rejects_shadowing_bad_ranges_and_incomplete_migrations() -> void:
	var invalid_documents: Array[Dictionary] = [
		{
			"version": 1,
			"settings": {
				"bgm_volume": {"type": "number", "default": 0.5},
			},
		},
		{
			"version": 1,
			"settings": {
				"project.speed": {
					"type": "number",
					"default": 1.0,
					"minimum": 2.0,
					"maximum": 1.0,
				},
			},
		},
		{
			"version": 2,
			"settings": {
				"project.enabled": {"type": "boolean", "default": true},
			},
		},
	]
	for document: Dictionary in invalid_documents:
		_write_schema(document)
		var candidate := SettingsSchema.new()
		assert_eq(candidate.load_from_path(SCHEMA_PATH), ERR_INVALID_DATA)


func _valid_schema() -> Dictionary:
	return {
		"version": 3,
		"defaults": {
			"bgm_volume": 0.7,
			"se_volume": 0.6,
		},
		"settings": {
			"project.confirm_quit": {
				"type": "boolean",
				"default": true,
			},
			"project.auto_base_wait": {
				"type": "integer",
				"default": 50,
				"minimum": 0,
				"maximum": 100,
			},
			"project.ui_scale": {
				"type": "number",
				"default": 1.0,
				"minimum": 0.5,
				"maximum": 2.0,
			},
			"project.text_mode": {
				"type": "enum",
				"default": "normal",
				"values": ["normal", "compact"],
			},
			"project.character_enabled": {
				"type": "dictionary",
				"default": {},
				"value_type": "boolean",
			},
			"project.character_gain": {
				"type": "dictionary",
				"default": {},
				"value_type": "number",
				"minimum": 0.0,
				"maximum": 1.0,
			},
		},
		"migrations": [
			{
				"from": 1,
				"to": 2,
				"rename": {
					"project.auto_delay": "project.auto_base_wait",
				},
				"remove": ["project.removed"],
			},
			{
				"from": 2,
				"to": 3,
				"remove": ["project.obsolete"],
			},
		],
	}


func _write_schema(document: Dictionary) -> void:
	_write_schema_raw(JSON.stringify(document, "  "))


func _write_schema_raw(contents: String) -> void:
	var file := FileAccess.open(SCHEMA_PATH, FileAccess.WRITE)
	assert_not_null(file)
	if file == null:
		return
	file.store_string(contents)
	file.close()


func _write_persistence(version: int, values: Dictionary) -> void:
	_write_raw(JSON.stringify({
		"schema_version": version,
		"values": values,
	}))


func _write_raw(contents: String) -> void:
	var file := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	assert_not_null(file)
	if file == null:
		return
	file.store_string(contents)
	file.close()
