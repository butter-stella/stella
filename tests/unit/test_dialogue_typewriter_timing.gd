extends GutTest
## Pure timing contract for issue #135.
##
## Presenter integration tests cover timer ownership separately.  Keeping the
## character-boundary calculation here makes the exact punctuation set and
## additive millisecond semantics deterministic instead of wall-clock based.

const DIALOGUE_PRESENTER_SCRIPT := preload(
	"res://addons/stella/presentation/dialogue/dialogue_presenter.gd")
const TYPEWRITER_PUNCTUATION := "，。！？；：、,.!?;:…—"
const DELAY_METHOD := &"_typewriter_character_delay_seconds"
const SNAPSHOT_METHOD := &"_snapshot_typewriter_delay_seconds"
const INVALID_SETTINGS_PATH := "user://tests/issue135_invalid_settings.json"

var _delay_provider: Object


func before_each() -> void:
	# Dynamic calls keep the baseline failure at the missing behavior assertion;
	# directly naming a not-yet-implemented static method would make this test
	# script fail to parse on main.
	_delay_provider = DIALOGUE_PRESENTER_SCRIPT.new()


func after_each() -> void:
	if is_instance_valid(_delay_provider):
		_delay_provider.free()
	if FileAccess.file_exists(INVALID_SETTINGS_PATH):
		DirAccess.remove_absolute(
			ProjectSettings.globalize_path(INVALID_SETTINGS_PATH))


func test_default_settings_feed_the_expected_ordinary_and_punctuation_delays() -> void:
	var defaults := GameSettings.new()
	assert_eq(defaults.character_interval, 50)
	assert_eq(defaults.punctuation_pause, 200)
	if not _require_delay_seam():
		return

	assert_almost_eq(_delay_seconds("A", 0.05, 0.2), 0.05, 0.000001)
	assert_almost_eq(_delay_seconds("。", 0.05, 0.2), 0.25, 0.000001)


func test_zero_interval_and_100ms_pause_remain_distinct() -> void:
	if not _require_delay_seam():
		return

	assert_almost_eq(_delay_seconds("A", 0.0, 0.1), 0.0, 0.000001)
	assert_almost_eq(_delay_seconds("。", 0.0, 0.1), 0.1, 0.000001)


func test_only_the_frozen_unicode_codepoint_set_receives_the_pause() -> void:
	if not _require_delay_seam():
		return

	assert_eq(TYPEWRITER_PUNCTUATION.length(), 15,
		"the contract contains fifteen Unicode codepoints")
	for character in TYPEWRITER_PUNCTUATION:
		assert_almost_eq(
			_delay_seconds(character, 0.1, 0.2),
			0.3,
			0.000001,
			"%s receives exactly one punctuation pause" % character,
		)
	for ordinary in ["A", "中", "·", "﹐", "︰", "\n"]:
		assert_almost_eq(
			_delay_seconds(ordinary, 0.1, 0.2),
			0.1,
			0.000001,
			"%s is not in the configured punctuation set" % ordinary,
		)


func test_punctuation_delay_is_additive_for_each_visible_codepoint() -> void:
	if not _require_delay_seam():
		return

	var total := 0.0
	for character in "A。…B":
		total += _delay_seconds(character, 0.05, 0.2)
	assert_almost_eq(total, 0.6, 0.000001,
		"two ordinary and two punctuation codepoints add independently")

	var doubled_ellipsis := 0.0
	for character in "……":
		doubled_ellipsis += _delay_seconds(character, 0.05, 0.2)
	assert_almost_eq(doubled_ellipsis, 0.5, 0.000001,
		"repeated punctuation is charged once per Unicode codepoint")


func test_inline_speed_changes_only_the_base_interval_component() -> void:
	if not _require_delay_seam():
		return

	assert_almost_eq(_delay_seconds("A", 0.1, 0.2), 0.1, 0.000001)
	assert_almost_eq(_delay_seconds("。", 0.1, 0.2), 0.3, 0.000001,
		"the punctuation pause remains additive after an inline speed override")


func test_public_settings_direct_and_load_paths_reject_invalid_raw_values() -> void:
	var manager := SettingsManager.new()
	manager.settings_path = INVALID_SETTINGS_PATH
	manager.set_value("character_interval", "fast")
	assert_push_warning("character_interval")
	assert_eq(manager.settings.character_interval, 50,
		"nonnumeric direct values use the independent interval default")
	manager.set_value("punctuation_pause", 30.5)
	assert_push_warning("punctuation_pause")
	assert_eq(manager.settings.punctuation_pause, 200,
		"non-integer direct values use the independent pause default")
	manager.set_value("character_interval", -1)
	assert_push_warning("character_interval")
	assert_eq(manager.settings.character_interval, 50,
		"negative direct values use the interval default")
	manager.set_value("character_interval", 1_000_000)
	assert_eq(manager.settings.character_interval, 1_000_000,
		"valid integer milliseconds have no upper clamp")

	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path("user://tests"))
	var file := FileAccess.open(INVALID_SETTINGS_PATH, FileAccess.WRITE)
	assert_not_null(file)
	if file == null:
		return
	file.store_string(JSON.stringify({
		"character_interval": 80.5,
		"punctuation_pause": -1,
	}))
	file.close()
	manager.settings.character_interval = 10
	manager.settings.punctuation_pause = 10
	manager.load_settings()
	assert_push_warning("character_interval")
	assert_push_warning("punctuation_pause")
	assert_eq(manager.settings.character_interval, 50,
		"persisted non-integer interval falls back instead of coercing")
	assert_eq(manager.settings.punctuation_pause, 200,
		"persisted negative pause falls back independently")

	file = FileAccess.open(INVALID_SETTINGS_PATH, FileAccess.WRITE)
	assert_not_null(file)
	if file == null:
		return
	file.store_string('{"character_interval":80.0,"punctuation_pause":120.0}')
	file.close()
	manager.load_settings()
	assert_eq(manager.settings.character_interval, 80,
		"serialized integral floats normalize back to integer milliseconds")
	assert_eq(manager.settings.punctuation_pause, 120)


func test_invalid_cached_seconds_warn_and_use_independent_defaults() -> void:
	var negative_interval := float(_delay_provider.call(
		SNAPSHOT_METHOD, "character_interval", -0.01))
	assert_push_warning(
		"cached character_interval must be a non-negative finite number")
	assert_almost_eq(negative_interval, 0.05, 0.000001)

	var nonnumeric_pause := float(_delay_provider.call(
		SNAPSHOT_METHOD, "punctuation_pause", "slow"))
	assert_push_warning(
		"cached punctuation_pause must be a non-negative finite number")
	assert_almost_eq(nonnumeric_pause, 0.2, 0.000001)


func _require_delay_seam() -> bool:
	var available := _delay_provider.has_method(DELAY_METHOD)
	assert_true(available,
		"DialoguePresenter exposes the pure character-delay contract")
	return available


func _delay_seconds(
	character: String,
	interval_seconds: float,
	punctuation_pause_seconds: float,
) -> float:
	return float(_delay_provider.call(
		DELAY_METHOD,
		character,
		interval_seconds,
		punctuation_pause_seconds,
	))
