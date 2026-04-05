extends GutTest
## Tests for display settings — resolution presets, fullscreen, and apply logic.


var _manager: SettingsManager
var _settings_path: String = "user://test_display_settings.json"


func before_each():
	_manager = SettingsManager.new()
	_manager.settings_path = _settings_path


func after_each():
	if FileAccess.file_exists(_settings_path):
		DirAccess.remove_absolute(_settings_path)


# --- GameSettings resolution field ---

func test_default_resolution_is_1080p():
	var s = GameSettings.new()
	assert_eq(s.resolution, "1920x1080")


func test_default_fullscreen_is_false():
	var s = GameSettings.new()
	assert_false(s.fullscreen)


func test_resolution_persists_in_dict():
	var s = GameSettings.new()
	s.resolution = "1280x720"
	var d = s.to_dict()
	assert_eq(d["resolution"], "1280x720")


func test_resolution_loads_from_dict():
	var s = GameSettings.new()
	s.from_dict({"resolution": "1280x720"})
	assert_eq(s.resolution, "1280x720")


func test_resolution_roundtrip_via_manager():
	_manager.set_value("resolution", "1280x720")
	_manager.save()

	var m2 = SettingsManager.new()
	m2.settings_path = _settings_path
	m2.load_settings()
	assert_eq(m2.settings.resolution, "1280x720")


func test_fullscreen_roundtrip_via_manager():
	_manager.set_value("fullscreen", true)
	_manager.save()

	var m2 = SettingsManager.new()
	m2.settings_path = _settings_path
	m2.load_settings()
	assert_true(m2.settings.fullscreen)


# --- DisplayHelper ---

func test_display_helper_resolution_presets():
	var presets = DisplayHelper.RESOLUTION_PRESETS
	assert_true(presets.size() >= 2, "Should have at least 2 presets")
	assert_true(presets.has("1920x1080"))
	assert_true(presets.has("1280x720"))


func test_display_helper_parse_resolution():
	var size = DisplayHelper.parse_resolution("1920x1080")
	assert_eq(size, Vector2i(1920, 1080))

	var size2 = DisplayHelper.parse_resolution("1280x720")
	assert_eq(size2, Vector2i(1280, 720))


func test_display_helper_parse_invalid_resolution_returns_default():
	var size = DisplayHelper.parse_resolution("invalid")
	assert_eq(size, Vector2i(1920, 1080))


func test_display_helper_preset_labels():
	var labels = DisplayHelper.get_preset_labels()
	assert_true(labels.size() >= 2)
	# Labels should contain resolution strings
	assert_true("1920x1080" in labels[0] or "1080p" in labels[0].to_lower())


func test_reset_restores_default_resolution():
	_manager.set_value("resolution", "1280x720")
	_manager.reset_to_default()
	assert_eq(_manager.settings.resolution, "1920x1080")


func test_reset_restores_default_fullscreen():
	_manager.set_value("fullscreen", true)
	_manager.reset_to_default()
	assert_false(_manager.settings.fullscreen)
