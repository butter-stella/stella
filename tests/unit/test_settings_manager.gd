extends GutTest
## Tests for SettingsManager — game settings persistence and notification.


var _manager: SettingsManager
var _settings_path: String = "user://test_settings.json"


func before_each():
	_manager = SettingsManager.new()
	_manager.settings_path = _settings_path


func after_each():
	if FileAccess.file_exists(_settings_path):
		DirAccess.remove_absolute(_settings_path)


func test_default_values():
	var s = _manager.settings
	assert_eq(s.character_interval, 50)
	assert_almost_eq(s.auto_play_delay, 1.5, 0.01)
	assert_true(s.skip_only_read)
	assert_almost_eq(s.master_volume, 1.0, 0.01)
	assert_almost_eq(s.bgm_volume, 0.8, 0.01)


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
		"character_voice_volume": {"sakura": 0.1},
		"character_voice_enabled": {"sakura": false},
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
