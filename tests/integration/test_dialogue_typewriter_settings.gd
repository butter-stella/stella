extends GutTest
## Focused Presenter coverage for issue #135's settings-driven typewriter.
##
## Wall-clock assertions express authored display timing.  Lifecycle assertions
## wait only across the exact retired authored timer horizon.

const FIXTURE := preload(
	"res://tests/integration/fixtures/dialogue_presentation_profile.tscn")
const LOAD_SETTINGS_DIRECTORY := "user://tests/issue135_typewriter_settings"
const LOAD_SETTINGS_PATH := "user://tests/issue135_typewriter_settings/settings.json"

var _presenter: Control
var _original_settings: Dictionary
var _original_presentation_snapshot: Dictionary
var _original_settings_path: String
var _original_auto_active: bool
var _original_skip_active: bool
var _original_game_state: int
var _original_previous_game_state: int
var _original_engine: ScenarioEngine
var _original_stage_assets_path := ""
var _test_stage_engine: ScenarioEngine
var _test_stage_presenter: StagePresenter
var _advance_callbacks: Array[Callable] = []
var _stage_callbacks: Array[Callable] = []
var _settings_callbacks: Array[Callable] = []


func before_each() -> void:
	_presenter = null
	_advance_callbacks.clear()
	_stage_callbacks.clear()
	_settings_callbacks.clear()
	_original_settings = StellaRuntime.settings_manager.settings.to_dict()
	_original_presentation_snapshot = (
		StellaRuntime.presentation_state.capture_snapshot())
	_original_settings_path = StellaRuntime.settings_manager.settings_path
	_original_auto_active = StellaRuntime.auto_play.is_active
	_original_skip_active = StellaRuntime.skip_controller.is_active
	_original_game_state = StellaRuntime.game_state.current_state
	_original_previous_game_state = StellaRuntime.game_state.previous_state
	_original_engine = StellaRuntime.engine
	_original_stage_assets_path = StellaRuntime.stage_assets_path
	_test_stage_engine = null
	_test_stage_presenter = null
	StellaRuntime.auto_play.is_active = false
	StellaRuntime.skip_controller.is_active = false
	StellaRuntime.game_state.current_state = GameStateMachine.State.PLAYING
	StellaRuntime.game_state.previous_state = GameStateMachine.State.PLAYING
	_set_timing(0, 0)


func after_each() -> void:
	if _test_stage_engine != null:
		_test_stage_engine.stop()
	if _test_stage_presenter != null and _test_stage_presenter.get_parent() != null:
		_test_stage_presenter.get_parent().remove_child(_test_stage_presenter)
	StellaRuntime.engine = _original_engine
	StellaRuntime.stage_assets_path = _original_stage_assets_path
	for callback in _advance_callbacks:
		if SignalBus.advance_requested.is_connected(callback):
			SignalBus.advance_requested.disconnect(callback)
	for callback in _stage_callbacks:
		if SignalBus.stage_operations_requested.is_connected(callback):
			SignalBus.stage_operations_requested.disconnect(callback)
	for callback in _settings_callbacks:
		if SignalBus.settings_changed.is_connected(callback):
			SignalBus.settings_changed.disconnect(callback)
	SignalBus.hide_dialogue.emit()
	StellaRuntime.auto_play.is_active = false
	StellaRuntime.skip_controller.is_active = false
	for key in _original_settings:
		StellaRuntime.settings_manager.set_value(key, _original_settings[key])
	DisplayHelper.apply(StellaRuntime.settings_manager.settings)
	StellaRuntime.presentation_state.restore_snapshot(
		_original_presentation_snapshot)
	StellaRuntime.settings_manager.settings_path = _original_settings_path
	StellaRuntime.auto_play.is_active = _original_auto_active
	StellaRuntime.skip_controller.is_active = _original_skip_active
	StellaRuntime.game_state.current_state = _original_game_state
	StellaRuntime.game_state.previous_state = _original_previous_game_state
	_remove_load_settings_fixture()
	await get_tree().process_frame


func test_loaded_values_are_snapshotted_before_reset_and_defaults_apply_next() -> void:
	_remove_load_settings_fixture()
	assert_false(DirAccess.dir_exists_absolute(LOAD_SETTINGS_DIRECTORY),
		"the owned settings parent starts absent")
	assert_eq(DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(LOAD_SETTINGS_DIRECTORY)), OK,
		"the fixture creates its owned settings parent")
	StellaRuntime.settings_manager.settings_path = LOAD_SETTINGS_PATH
	_set_timing(200, 0)
	assert_eq(StellaRuntime.settings_manager.save(), OK,
		"the fixture settings save succeeds")
	_set_timing(0, 0)
	StellaRuntime.settings_manager.load_settings()
	assert_eq(StellaRuntime.get_setting("character_interval"), 200,
		"the authoritative model is loaded before Presenter ready")
	await _create_presenter()

	_show_text("AB")
	await get_tree().process_frame
	assert_eq(_presenter.text_label.visible_characters, 1,
		"the first SHOW uses the persisted 200ms interval")
	var reset_at := Time.get_ticks_msec()
	StellaRuntime.reset_settings()
	if not await _wait_until_ready(0.9, "loaded active SHOW survives reset"):
		return
	assert_gte(Time.get_ticks_msec() - reset_at, 320,
		"reset cannot shorten the active line's two 200ms boundaries")

	var next_started := Time.get_ticks_msec()
	_show_text("A。")
	if not await _wait_until_ready(0.8, "next SHOW uses 50/200 defaults"):
		return
	assert_gte(Time.get_ticks_msec() - next_started, 240,
		"the next line uses default 50ms base plus 200ms punctuation pause")


func _remove_load_settings_fixture() -> void:
	if FileAccess.file_exists(LOAD_SETTINGS_PATH):
		assert_eq(DirAccess.remove_absolute(
			ProjectSettings.globalize_path(LOAD_SETTINGS_PATH)), OK,
			"the exact settings fixture file is removed")
	if DirAccess.dir_exists_absolute(LOAD_SETTINGS_DIRECTORY):
		assert_eq(DirAccess.remove_absolute(
			ProjectSettings.globalize_path(LOAD_SETTINGS_DIRECTORY)), OK,
			"the owned settings fixture directory is removed")


func test_reentrant_reset_show_snapshots_the_atomic_default_pair() -> void:
	_set_timing(0, 0)
	var show_dispatched := [false]
	var callback := func(key: String, _value: Variant) -> void:
		if show_dispatched[0] or key != "character_interval":
			return
		show_dispatched[0] = true
		_show_text("A。")
	_settings_callbacks.append(callback)
	# Connect before Presenter ready.  The callback therefore publishes SHOW
	# before Presenter receives reset's first per-key cache notification.
	SignalBus.settings_changed.connect(callback)
	await _create_presenter()

	var reset_started := Time.get_ticks_msec()
	StellaRuntime.reset_settings()
	assert_true(show_dispatched[0],
		"reset's first timing notification synchronously publishes the line")
	if not await _wait_until_ready(0.8, "reentrant reset SHOW"):
		return
	assert_gte(Time.get_ticks_msec() - reset_started, 240,
		"active SHOW reads atomic 50/200 defaults, not the stale 0/0 cache pair")


func test_queued_request_snapshots_settings_only_when_it_becomes_active() -> void:
	_set_timing(100, 0)
	var scenario := ScenarioData.new()
	scenario.id = "typewriter_stage_fixture"
	scenario.source_path = "res://synthetic/typewriter_stage_fixture.stla"
	var scene := SceneData.new()
	scene.id = "start"
	scenario.scenes.append(scene)
	_test_stage_engine = ScenarioEngine.new()
	_test_stage_engine.context = ScenarioContext.new(scenario)
	StellaRuntime.engine = _test_stage_engine
	StellaRuntime.stage_assets_path = "res://tests/fixtures/stage/"
	_test_stage_presenter = StagePresenter.new()
	add_child_autoqfree(_test_stage_presenter)
	await _create_presenter()
	var replacement_requested := [false]
	var callback := func(operations: Array, force_cut: bool) -> void:
		if force_cut or operations.is_empty() or replacement_requested[0]:
			return
		if String(operations[0].get("id", "")) != "timing_queue_probe":
			return
		replacement_requested[0] = true
		_show_text("QUEUED")
		_set_timing(0, 0)
	_stage_callbacks.append(callback)
	SignalBus.stage_operations_requested.connect(callback)

	SignalBus.emit_show_dialogue("", [{
		"text": "retiring",
		"voice_layers": [],
		"presentation_ops": [{
			"kind": "stage",
			"payload": {
				"action": "show",
				"id": "timing_queue_probe",
				"properties": {"asset": "stage:redraw_source"},
				"transition": "cut",
				"transition_params": {},
				"duration": 0.0,
			},
		}],
		"presentation_operation_lines": [145],
	}], "adv")
	assert_true(replacement_requested[0],
		"replacement SHOW is requested inside the owned stage dispatch")
	assert_eq(_presenter.text_label.text, "QUEUED")
	await get_tree().process_frame
	assert_false(_presenter._is_typing,
		"queued request takes its 0ms snapshot on activation, not at enqueue time")


func test_visible_punctuation_timing_covers_bbcode_nvl_and_combine_effects() -> void:
	_set_timing(0, 180)
	await _create_presenter()
	var cases := [
		{
			"mode": "adv",
			"segments": [_segment("[b]A。[/b]B")],
			"minimum_ms": 140,
			"label": "BBCode",
		},
		{
			"mode": "nvl",
			"segments": [_segment("A。B")],
			"minimum_ms": 140,
			"label": "NVL",
		},
		{
			"mode": "adv",
			"segments": [
				_segment("A。{speed:100}"),
				_segment("B{wait:120}"),
			],
			"minimum_ms": 350,
			"label": "@combine speed plus trailing wait",
		},
	]
	for test_case in cases:
		var started := Time.get_ticks_msec()
		SignalBus.emit_show_dialogue(
			"", test_case["segments"], test_case["mode"])
		if not await _wait_until_ready(
			0.9, "%s punctuation timing" % test_case["label"]):
			return
		assert_gte(
			Time.get_ticks_msec() - started,
			int(test_case["minimum_ms"]),
			"%s uses RichTextLabel's visible character boundaries" %
				test_case["label"],
		)


func test_complete_hide_and_replacement_retire_punctuation_generations() -> void:
	_set_timing(0, 200)
	await _create_presenter()
	_show_text("。old")
	await get_tree().process_frame
	assert_eq(_presenter.text_label.visible_characters, 1,
		"completion starts while the punctuation timer owns the generation")
	assert_true(_presenter.complete_typewriter())
	assert_false(_presenter._is_typing)
	assert_true((_presenter._dialogue_timer_waiters as Dictionary).is_empty(),
		"completion actively settles the punctuation waiter")

	_show_text("。retired")
	await get_tree().process_frame
	_set_timing(0, 0)
	_show_text("replacement")
	await get_tree().process_frame
	assert_eq(_presenter.text_label.text, "replacement")
	assert_false(_presenter._is_typing)
	assert_true((_presenter._dialogue_timer_waiters as Dictionary).is_empty(),
		"replacement generation owns no retired waiter")
	var replacement_gen: int = _presenter._dialogue_gen
	# Cross the retired 200ms punctuation horizon.  Its callback must not mutate
	# the replacement or mark it ready a second time.
	await get_tree().create_timer(0.22).timeout
	assert_eq(_presenter._dialogue_gen, replacement_gen)
	assert_eq(_presenter.text_label.text, "replacement")
	assert_false(_presenter._is_typing)

	_set_timing(0, 200)
	_show_text("。hidden")
	await get_tree().process_frame
	SignalBus.hide_dialogue.emit()
	assert_false(_presenter.visible)
	assert_false(_presenter._is_typing)
	assert_true((_presenter._dialogue_timer_waiters as Dictionary).is_empty(),
		"hard hide synchronously settles the active generation")
	await get_tree().create_timer(0.22).timeout
	assert_false(_presenter.visible,
		"hard hide keeps the retired punctuation generation unreachable")
	assert_false(_presenter._is_typing)

	# Auto owns the same punctuation-completion generation as natural typing.
	# It must wait for that authored boundary and request exactly one advance.
	StellaRuntime.set_setting("auto_play_delay", 0.0)
	StellaRuntime.set_setting("auto_play_wait_voice", false)
	var advance_count := [0]
	var on_advance := func() -> void: advance_count[0] += 1
	_advance_callbacks.append(on_advance)
	SignalBus.advance_requested.connect(on_advance)
	StellaRuntime.auto_play.is_active = true
	var auto_started := Time.get_ticks_msec()
	_show_text("。auto")
	var auto_advanced: bool = await wait_until(
		func(): return advance_count[0] == 1,
		0.8,
		"Auto advances after the punctuation timer",
	)
	assert_true(auto_advanced)
	if not auto_advanced:
		return
	assert_gte(Time.get_ticks_msec() - auto_started, 160,
		"Auto cannot bypass the active punctuation boundary")
	assert_true((_presenter._dialogue_timer_waiters as Dictionary).is_empty(),
		"natural punctuation and Auto timeouts release their exact waiters")
	StellaRuntime.auto_play.stop()

	# Public Skip starts while a 100+200ms punctuation boundary is already
	# running.  It must retire that generation instead of allowing the old timer
	# callback to advance a second time.
	_set_timing(100, 200)
	StellaRuntime.set_setting("skip_interval", 0)
	StellaRuntime.set_setting("skip_only_read", false)
	_show_text("。skip")
	await get_tree().process_frame
	assert_true(_presenter._is_typing)
	assert_eq(_presenter.text_label.visible_characters, 1,
		"Skip begins after the punctuation timer has been installed")
	StellaRuntime.toggle_skip()
	var skip_advanced: bool = await wait_until(
		func(): return advance_count[0] == 2,
		0.4,
		"Skip completes and advances the punctuation line",
	)
	assert_true(skip_advanced)
	assert_false(_presenter._is_typing)
	assert_eq(_presenter.text_label.visible_characters, -1)
	await get_tree().create_timer(0.32).timeout
	assert_eq(advance_count[0], 2,
		"retired punctuation timing cannot emit a late second Skip advance")
	assert_true((_presenter._dialogue_timer_waiters as Dictionary).is_empty(),
		"Skip cancellation leaves the Presenter timer authority empty")


func _create_presenter() -> void:
	_presenter = FIXTURE.instantiate()
	add_child_autoqfree(_presenter)
	await get_tree().process_frame


func _set_timing(character_interval: int, punctuation_pause: int) -> void:
	StellaRuntime.set_setting("character_interval", character_interval)
	StellaRuntime.set_setting("punctuation_pause", punctuation_pause)


func _show_text(text: String, mode: String = "adv") -> void:
	SignalBus.emit_show_dialogue("", [_segment(text)], mode)


func _segment(text: String) -> Dictionary:
	return {"text": text, "voice_layers": [], "presentation_ops": []}


func _wait_until_ready(timeout: float, message: String) -> bool:
	var ready: bool = await wait_until(
		func(): return not _presenter._is_typing,
		timeout,
		message,
	)
	assert_true(ready, message)
	return ready
