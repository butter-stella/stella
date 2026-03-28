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
