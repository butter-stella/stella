extends GutTest
## Independent movie settings persistence/reset/live UI contract for issue #179.

const RuntimeTestSupport = preload("res://tests/helpers/runtime_test_support.gd")
const SETTINGS_PATH := "user://tests/movie_settings/settings.json"

var _manager: SettingsManager
var _observer: Callable
var _runtime: Node


func before_each() -> void:
	_runtime = get_tree().root.get_node("StellaRuntime")
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	_manager = SettingsManager.new()
	_manager.settings_path = SETTINGS_PATH
	var directory := DirAccess.open("user://")
	if directory != null:
		directory.make_dir_recursive("tests/movie_settings")


func after_each() -> void:
	if (
		_manager != null
		and _observer.is_valid()
		and _manager.settings_changed.is_connected(_observer)
	):
		_manager.settings_changed.disconnect(_observer)
	_observer = Callable()
	if FileAccess.file_exists(SETTINGS_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS_PATH))
	_manager = null
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	_runtime = null


func _write_json(value: Dictionary) -> void:
	var file := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	assert_not_null(file)
	if file != null:
		file.store_string(JSON.stringify({
			"schema_version": 1,
			"values": value,
		}))
		file.close()


func test_defaults_and_canonical_json_include_independent_movie_fields() -> void:
	assert_eq(_manager.settings.movie_volume, 1.0)
	assert_true(_manager.settings.movie_right_click_skip)
	assert_false(_manager.settings.movie_skip_on_skip)
	var encoded := _manager.settings.to_dict()
	assert_eq(encoded["movie_volume"], 1.0)
	assert_eq(encoded["movie_right_click_skip"], true)
	assert_eq(encoded["movie_skip_on_skip"], false)
	assert_ne(encoded["movie_volume"], encoded["bgm_volume"])


func test_save_load_is_atomic_and_partial_settings_use_declared_defaults() -> void:
	_manager.set_value("movie_volume", 0.35)
	_manager.set_value("movie_right_click_skip", false)
	_manager.set_value("movie_skip_on_skip", true)
	_manager.save()
	var loaded := SettingsManager.new()
	loaded.settings_path = SETTINGS_PATH
	loaded.load_settings()
	assert_almost_eq(loaded.settings.movie_volume, 0.35, 0.000001)
	assert_false(loaded.settings.movie_right_click_skip)
	assert_true(loaded.settings.movie_skip_on_skip)

	_write_json({"master_volume": 0.25, "bgm_volume": 0.1})
	var partial := SettingsManager.new()
	partial.settings_path = SETTINGS_PATH
	partial.load_settings()
	assert_eq(partial.settings.movie_volume, 1.0)
	assert_true(partial.settings.movie_right_click_skip)
	assert_false(partial.settings.movie_skip_on_skip)


func test_invalid_movie_candidate_rejects_all_sibling_changes() -> void:
	for invalid: Variant in [-0.1, 1.1, "0.5", true]:
		_manager.settings.master_volume = 0.8
		_manager.settings.movie_volume = 0.6
		_write_json({"master_volume": 0.1, "movie_volume": invalid})
		_manager.load_settings()
		assert_push_warning("$.values.movie_volume")
		assert_eq(_manager.settings.master_volume, 0.8)
		assert_eq(_manager.settings.movie_volume, 0.6)

	for key: String in ["movie_right_click_skip", "movie_skip_on_skip"]:
		_manager.settings.master_volume = 0.8
		var candidate := {"master_volume": 0.1}
		candidate[key] = 1
		_write_json(candidate)
		_manager.load_settings()
		assert_push_warning("$.values.%s" % key)
		assert_eq(_manager.settings.master_volume, 0.8)

	# JSON has no non-finite number representation. Exercise the same public
	# validation fence without making the serializer itself emit test noise.
	for invalid: float in [NAN, INF, -INF]:
		_manager.settings.movie_volume = 0.6
		_manager.set_value("movie_volume", invalid)
		assert_push_warning("movie_volume has an invalid type or range")
		assert_eq(_manager.settings.movie_volume, 0.6)


func test_reset_is_complete_before_notifications_and_emits_only_changes() -> void:
	_manager.settings.movie_volume = 0.2
	_manager.settings.movie_right_click_skip = false
	_manager.settings.movie_skip_on_skip = true
	var events: Array[Dictionary] = []
	_observer = func(key: String, value: Variant) -> void:
		if key.begins_with("movie_"):
			events.append({
				"key": key,
				"value": value,
				"snapshot": _manager.settings.to_dict(),
			})
	_manager.settings_changed.connect(_observer)
	_manager.reset_to_default()
	assert_eq(events.map(func(event: Dictionary) -> String:
		return String(event["key"])), [
		"movie_volume", "movie_right_click_skip", "movie_skip_on_skip",
	])
	for event: Dictionary in events:
		assert_eq(event["snapshot"]["movie_volume"], 1.0)
		assert_eq(event["snapshot"]["movie_right_click_skip"], true)
		assert_eq(event["snapshot"]["movie_skip_on_skip"], false)
	events.clear()
	_manager.reset_to_default()
	assert_eq(events, [])


func test_default_settings_screen_exposes_one_slider_and_two_policy_toggles() -> void:
	var runtime := _runtime
	var original_settings_path: String = runtime.settings_manager.settings_path
	var original_master := float(runtime.get_setting("master_volume"))
	var original_movie := float(runtime.get_setting("movie_volume"))
	var original_right := bool(runtime.get_setting("movie_right_click_skip"))
	var original_skip := bool(runtime.get_setting("movie_skip_on_skip"))
	runtime.settings_manager.settings_path = SETTINGS_PATH
	runtime.set_setting("master_volume", 0.5)
	runtime.set_setting("movie_volume", 1.0)
	runtime.set_setting("movie_right_click_skip", true)
	runtime.set_setting("movie_skip_on_skip", false)
	var packed_scene := load("res://addons/stella/scenes/settings.tscn") as PackedScene
	var screen: Node = packed_scene.instantiate()
	add_child_autoqfree(screen)
	await get_tree().process_frame
	var labels: Array[String] = []
	for label: Node in screen.find_children("", "Label", true, false):
		labels.append(String(label.get("text")))
	assert_eq(labels.count("电影音量"), 1)
	assert_eq(labels.count("右键跳过电影"), 1)
	assert_eq(labels.count("快进模式跳过电影"), 1)
	var movie_row := _row_with_label(screen, "电影音量")
	var right_row := _row_with_label(screen, "右键跳过电影")
	var skip_row := _row_with_label(screen, "快进模式跳过电影")
	var movie_slider := _first_child_of_type(movie_row, "HSlider") as HSlider
	var right_toggle := _first_child_of_type(right_row, "CheckButton") as CheckButton
	var skip_toggle := _first_child_of_type(skip_row, "CheckButton") as CheckButton
	assert_not_null(movie_slider)
	assert_not_null(right_toggle)
	assert_not_null(skip_toggle)
	movie_slider.value = 30.0
	right_toggle.button_pressed = false
	skip_toggle.button_pressed = true
	assert_almost_eq(float(runtime.get_setting("movie_volume")), 0.3, 0.000001)
	assert_false(bool(runtime.get_setting("movie_right_click_skip")))
	assert_true(bool(runtime.get_setting("movie_skip_on_skip")))
	var presenter := runtime.get_node("MoviePresenter") as MoviePresenter
	assert_almost_eq(presenter._player.volume, 0.15, 0.000001,
		"the slider reaches the live Runtime-owned player through the facade")
	runtime.save_settings()
	var persisted := SettingsManager.new()
	persisted.settings_path = SETTINGS_PATH
	persisted.load_settings()
	assert_almost_eq(persisted.settings.movie_volume, 0.3, 0.000001)
	assert_false(persisted.settings.movie_right_click_skip)
	assert_true(persisted.settings.movie_skip_on_skip)
	var reset_events: Array[String] = []
	var on_reset_change := func(key: String, _value: Variant) -> void:
		if key.begins_with("movie_"):
			reset_events.append(key)
	runtime.settings_manager.settings_changed.connect(on_reset_change)
	var reset_button := _button_with_text(screen, "恢复默认")
	assert_not_null(reset_button)
	if reset_button != null:
		reset_button.pressed.emit()
	await get_tree().process_frame
	if runtime.settings_manager.settings_changed.is_connected(on_reset_change):
		runtime.settings_manager.settings_changed.disconnect(on_reset_change)
	assert_eq(reset_events, [
		"movie_volume", "movie_right_click_skip", "movie_skip_on_skip",
	])
	assert_eq(float(runtime.get_setting("movie_volume")), 1.0)
	assert_true(bool(runtime.get_setting("movie_right_click_skip")))
	assert_false(bool(runtime.get_setting("movie_skip_on_skip")))
	assert_eq(presenter._player.volume, 1.0)
	movie_row = _row_with_label(screen, "电影音量")
	right_row = _row_with_label(screen, "右键跳过电影")
	skip_row = _row_with_label(screen, "快进模式跳过电影")
	movie_slider = _first_child_of_type(movie_row, "HSlider") as HSlider
	right_toggle = _first_child_of_type(right_row, "CheckButton") as CheckButton
	skip_toggle = _first_child_of_type(skip_row, "CheckButton") as CheckButton
	assert_eq(movie_slider.value, 100.0)
	assert_true(right_toggle.button_pressed)
	assert_false(skip_toggle.button_pressed)
	runtime.save_settings()
	var reset_persisted := SettingsManager.new()
	reset_persisted.settings_path = SETTINGS_PATH
	reset_persisted.load_settings()
	assert_eq(reset_persisted.settings.movie_volume, 1.0)
	assert_true(reset_persisted.settings.movie_right_click_skip)
	assert_false(reset_persisted.settings.movie_skip_on_skip)
	screen.queue_free()
	await get_tree().process_frame
	runtime.set_setting("master_volume", original_master)
	runtime.set_setting("movie_volume", original_movie)
	runtime.set_setting("movie_right_click_skip", original_right)
	runtime.set_setting("movie_skip_on_skip", original_skip)
	runtime.settings_manager.settings_path = original_settings_path


func _row_with_label(root: Node, text: String) -> Node:
	for label: Node in root.find_children("*", "Label", true, false):
		if String(label.get("text")) == text:
			return label.get_parent()
	return null


func _first_child_of_type(root: Node, type_name: String) -> Node:
	if root == null:
		return null
	var matches := root.find_children("*", type_name, true, false)
	return matches[0] if not matches.is_empty() else null


func _button_with_text(root: Node, text: String) -> Button:
	for button: Node in root.find_children("*", "Button", true, false):
		if String(button.get("text")) == text:
			return button as Button
	return null
