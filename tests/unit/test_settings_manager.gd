extends GutTest
## Tests for SettingsManager — game settings persistence and notification.


var _manager: SettingsManager
var _settings_path: String = "user://test_settings.json"


func before_each():
	_manager = SettingsManager.new()
	_manager.settings_path = _settings_path


func after_each():
	if FileAccess.file_exists(_settings_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_settings_path))


func test_default_values():
	var s = _manager.settings
	assert_eq(s.character_interval, 50)
	assert_almost_eq(s.auto_play_delay, 1.5, 0.01)
	assert_true(s.skip_only_read)
	assert_almost_eq(s.master_volume, 1.0, 0.01)
	assert_almost_eq(s.bgm_volume, 0.8, 0.01)
	assert_true(s.effect_enabled)


func test_set_and_get():
	_manager.set_value("character_interval", 30)
	assert_eq(_manager.settings.character_interval, 30)


func test_set_emits_signal():
	var changed: Array = []
	_manager.settings_changed.connect(func(key, val): changed.append({"key": key, "value": val}))

	_manager.set_value("bgm_volume", 0.5)

	assert_eq(changed.size(), 1)
	assert_eq(changed[0]["key"], "bgm_volume")
	assert_almost_eq(float(changed[0]["value"]), 0.5, 0.01)


func test_save_and_load():
	_manager.set_value("character_interval", 30)
	_manager.set_value("bgm_volume", 0.3)
	_manager.save()

	# Create new manager and load
	var manager2 = SettingsManager.new()
	manager2.settings_path = _settings_path
	manager2.load_settings()

	assert_eq(manager2.settings.character_interval, 30)
	assert_almost_eq(manager2.settings.bgm_volume, 0.3, 0.01)


func test_load_applies_changed_present_keys_atomically_and_notifies_current_values():
	_manager.set_value("character_interval", 77)
	_manager.settings.character_voice_volume["sakura"] = 0.5
	var retained_character_volumes := _manager.settings.character_voice_volume
	var changed_keys: Array[String] = []
	var snapshots: Array[Dictionary] = []
	_manager.settings_changed.connect(func(key: String, _value: Variant) -> void:
		changed_keys.append(key)
		snapshots.append(_manager.settings.to_dict())
	)
	_write_settings_text(
		'{"future_setting":"ignored","effect_enabled":false,'
		+ '"click_to_complete":true,"bgm_volume":0.25}')

	_manager.load_settings()

	assert_eq(_manager.settings.character_interval, 77,
		"an omitted persisted key must preserve its current in-memory value")
	assert_same(_manager.settings.character_voice_volume, retained_character_volumes,
		"an omitted mutable setting keeps its extension-visible identity")
	assert_almost_eq(_manager.settings.bgm_volume, 0.25, 0.001)
	assert_false(_manager.settings.effect_enabled)
	assert_eq(changed_keys, ["bgm_volume", "effect_enabled"],
		"a successful load reports only real changes in canonical field order")
	for snapshot in snapshots:
		assert_eq(snapshot, _manager.settings.to_dict(),
			"all loaded fields must be committed before the first notification")


func test_invalid_effect_enabled_rejects_the_whole_load_candidate() -> void:
	_manager.settings.character_interval = 77
	var baseline := _manager.settings.to_dict()
	var changed_keys: Array[String] = []
	_manager.settings_changed.connect(func(key: String, _value: Variant) -> void:
		changed_keys.append(key)
	)
	for invalid_value in [0, 1]:
		_manager.settings.from_dict(baseline)
		changed_keys.clear()
		_write_settings_text(JSON.stringify({
			"bgm_volume": 0.25,
			"effect_enabled": invalid_value,
		}))

		_manager.load_settings()

		assert_eq(_manager.settings.to_dict(), baseline,
			"effect_enabled accepts bool only; no sibling field may apply")
		assert_eq(changed_keys, [],
			"a rejected candidate publishes no partial settings notifications")


func test_invalid_effect_enabled_direct_write_preserves_state_and_emits_nothing() -> void:
	var baseline := _manager.settings.to_dict()
	var changed_keys: Array[String] = []
	_manager.settings_changed.connect(func(key: String, _value: Variant) -> void:
		changed_keys.append(key)
	)
	for invalid_value in [0, 1]:
		_manager.settings.from_dict(baseline)
		changed_keys.clear()

		_manager.set_value("effect_enabled", invalid_value)

		assert_push_warning("effect_enabled must be a bool")
		assert_eq(_manager.settings.to_dict(), baseline,
			"direct writes must not use typed-property bool coercion")
		assert_eq(changed_keys, [])


func test_missing_or_non_dictionary_load_is_an_atomic_noop_without_notifications():
	_manager.settings.character_interval = 77
	_manager.settings.effect_enabled = false
	var baseline := _manager.settings.to_dict()
	var changed_keys: Array[String] = []
	_manager.settings_changed.connect(func(key: String, _value: Variant) -> void:
		changed_keys.append(key)
	)

	_manager.load_settings()
	assert_eq(_manager.settings.to_dict(), baseline)
	assert_eq(changed_keys, [], "a missing file cannot publish settings changes")

	_write_settings_text("[]")
	_manager.load_settings()
	assert_eq(_manager.settings.to_dict(), baseline)
	assert_eq(changed_keys, [], "a non-object settings document is rejected atomically")


func test_reset_to_default():
	_manager.set_value("character_interval", 10)
	_manager.reset_to_default()
	assert_eq(_manager.settings.character_interval, 50)


func test_reset_preserves_identity_and_emits_changed_defaults_after_atomic_restore():
	var original_settings := _manager.settings
	var defaults := GameSettings.new().to_dict()
	_manager.settings.from_dict({
		"character_interval": 0,
		"punctuation_pause": 0,
		"click_to_complete": false,
		"text_window_opacity": 0.1,
		"auto_play_delay": 0.1,
		"auto_play_wait_voice": false,
		"auto_play_pause_on_choice": false,
		"auto_play_click_interrupt": false,
		"skip_interval": 1,
		"skip_only_read": false,
		"skip_unread_confirm": false,
		"skip_stop_on_choice": false,
		"master_volume": 0.1,
		"bgm_volume": 0.1,
		"se_volume": 0.1,
		"system_se_volume": 0.1,
		"voice_volume": 0.1,
		"movie_volume": 0.1,
		"character_voice_volume": {"sakura": 0.1},
		"character_voice_enabled": {"sakura": false},
		"movie_right_click_skip": false,
		"movie_skip_on_skip": true,
		"voice_continue_on_advance": true,
		"voice_replay_on_backlog": false,
		"fullscreen": true,
		"resolution": "1280x720",
		"effect_enabled": false,
	})
	var changed_keys: Array[String] = []
	var changed_values: Array[Variant] = []
	var snapshots_during_notifications: Array[Dictionary] = []
	_manager.settings_changed.connect(func(key: String, value: Variant) -> void:
		changed_keys.append(key)
		changed_values.append(value)
		snapshots_during_notifications.append(_manager.settings.to_dict())
	)

	_manager.reset_to_default()

	assert_same(_manager.settings, original_settings,
		"long-lived consumers may retain the GameSettings object")
	assert_eq(_manager.settings.to_dict(), defaults)
	assert_eq(changed_keys, defaults.keys(),
		"changed fields should be reported in the canonical settings order")
	for i in changed_keys.size():
		assert_eq(changed_values[i], defaults[changed_keys[i]])
		assert_eq(snapshots_during_notifications[i], defaults,
			"all fields must be restored before the first notification")


func test_reset_emits_only_actual_changes_and_does_not_save_implicitly():
	_manager.set_value("character_interval", 10)
	_manager.save()
	var changed: Array[String] = []
	_manager.settings_changed.connect(func(key: String, _value: Variant) -> void:
		changed.append(key)
	)

	_manager.reset_to_default()

	assert_eq(changed, ["character_interval"])
	var loaded := SettingsManager.new()
	loaded.settings_path = _settings_path
	loaded.load_settings()
	assert_eq(loaded.settings.character_interval, 10,
		"resetting in memory must not overwrite persisted settings")

	changed.clear()
	_manager.reset_to_default()
	assert_eq(changed, [], "an unchanged reset must not emit redundant notifications")


func test_reset_notifications_use_current_values_after_synchronous_reentry():
	_manager.settings.from_dict({
		"character_interval": 10,
		"bgm_volume": 0.1,
	})
	var bgm_values: Array[float] = []
	_manager.settings_changed.connect(func(key: String, _value: Variant) -> void:
		if key == "character_interval":
			_manager.set_value("bgm_volume", 0.25)
	)
	_manager.settings_changed.connect(func(key: String, value: Variant) -> void:
		if key == "bgm_volume":
			bgm_values.append(float(value))
	)

	_manager.reset_to_default()

	assert_almost_eq(_manager.settings.bgm_volume, 0.25, 0.001)
	assert_eq(bgm_values.size(), 2,
		"the nested write and the reset's planned notification should both be observable")
	for value in bgm_values:
		assert_almost_eq(value, 0.25, 0.001,
			"reset must not emit a cached default after a listener changes the value")


func test_character_voice_notifications_emit_complete_stable_dictionaries():
	var volume_payloads: Array[Dictionary] = []
	var enabled_payloads: Array[Dictionary] = []
	_manager.settings_changed.connect(func(key: String, value: Variant) -> void:
		if key == "character_voice_volume":
			volume_payloads.append(value)
		elif key == "character_voice_enabled":
			enabled_payloads.append(value)
	)

	_manager.set_character_voice_volume("sakura", 0.5)
	_manager.set_character_voice_volume("yuzu", 0.25)
	_manager.set_character_voice_enabled("sakura", false)
	_manager.set_character_voice_enabled("yuzu", true)

	assert_eq(volume_payloads, [
		{"sakura": 0.5},
		{"sakura": 0.5, "yuzu": 0.25},
	])
	assert_eq(enabled_payloads, [
		{"sakura": false},
		{"sakura": false, "yuzu": true},
	])


func test_character_voice_volume():
	_manager.set_character_voice_volume("sakura", 0.5)
	assert_almost_eq(_manager.get_character_voice_volume("sakura"), 0.5, 0.01)
	# Default for unknown character
	assert_almost_eq(_manager.get_character_voice_volume("unknown"), 1.0, 0.01)


func test_character_voice_enabled():
	_manager.set_character_voice_enabled("sakura", false)
	assert_false(_manager.is_character_voice_enabled("sakura"))
	# Default for unknown character
	assert_true(_manager.is_character_voice_enabled("unknown"))


func _write_settings_text(contents: String) -> void:
	var file := FileAccess.open(_settings_path, FileAccess.WRITE)
	assert_not_null(file, "the synthetic settings fixture must be writable")
	if file == null:
		return
	file.store_string(contents)
	file.close()
