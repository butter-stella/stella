extends GutTest

const GAME_SCENE := preload("res://addons/stella/scenes/game.tscn")
const PROFILE_PATH := "res://tests/fixtures/auto_timing_profile.tres"
const INVALID_PROFILE_PATH := \
	"res://tests/fixtures/invalid_auto_timing_profile.tres"

var _game_scene: Node
var _dialogue: Control
var _original_auto_play_delay: float
var _original_state: int


func before_each() -> void:
	_original_auto_play_delay = float(StellaRuntime.get_setting("auto_play_delay"))
	_original_state = StellaRuntime.game_state.current_state
	StellaRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)
	StellaRuntime.auto_play.is_active = false
	_game_scene = GAME_SCENE.instantiate()
	add_child_autoqfree(_game_scene)
	await get_tree().process_frame
	_dialogue = _game_scene.get_node("UILayer/DialoguePanel") as Control


func after_each() -> void:
	StellaRuntime.auto_play.is_active = false
	StellaRuntime.set_setting("auto_play_delay", _original_auto_play_delay)
	if is_instance_valid(_game_scene):
		var exited: Signal = _game_scene.tree_exited
		_game_scene.queue_free()
		await exited
		await get_tree().process_frame
	_game_scene = null
	_dialogue = null
	StellaRuntime.game_state.transition_to(_original_state)


func test_profile_uses_existing_auto_timer_authority_with_exact_delay() -> void:
	var profile := load(PROFILE_PATH) as AutoTimingProfile
	assert_not_null(profile)
	StellaRuntime.set_setting("auto_play_delay", 1.5)
	_dialogue._active_auto_timing_profile = profile.duplicate(true)
	_dialogue._active_auto_timing_provenance = {
		"source_path": "res://tests/fixtures/auto_timing.stla",
		"line": 7,
		"profile_name": "synthetic",
	}
	_dialogue._active_auto_visible_character_count = 4
	_dialogue._active_auto_has_voice = false
	StellaRuntime.auto_play.is_active = true

	_dialogue._continue_auto_play_after_ready(_dialogue._dialogue_gen)
	assert_eq(_dialogue._dialogue_timer_waiters.size(), 1)
	var waiter: Variant = _dialogue._dialogue_timer_waiters.values()[0]
	assert_eq(waiter.purpose, &"auto")
	assert_almost_eq(waiter.timer.wait_time, 1.04, 0.000001,
		"the declarative policy feeds the sole Presenter-owned Auto timer")

	_dialogue._retire_auto_play_attempt()
	assert_true(_dialogue._dialogue_timer_waiters.is_empty())


func test_setting_change_is_observed_by_the_next_auto_tail() -> void:
	var profile := load(PROFILE_PATH) as AutoTimingProfile
	_dialogue._active_auto_timing_profile = profile.duplicate(true)
	_dialogue._active_auto_visible_character_count = 10
	_dialogue._active_auto_has_voice = true

	StellaRuntime.set_setting("auto_play_delay", 2.0)
	var first: Dictionary = _dialogue._resolve_auto_play_delay()
	assert_true(first["ok"])
	assert_almost_eq(float(first["delay"]), 1.55, 0.000001)

	StellaRuntime.set_setting("auto_play_delay", 0.5)
	var second: Dictionary = _dialogue._resolve_auto_play_delay()
	assert_true(second["ok"])
	assert_almost_eq(float(second["delay"]), 0.8, 0.000001)


func test_stla_profile_preflight_returns_typed_snapshot_and_provenance() -> void:
	var activation := DialogueActivation.new()
	var request := DialogueRequest.new(
		"", [{"text": "synthetic", "voice_layers": []}], "adv",
		{"auto_timing_profile": PROFILE_PATH}, true, "",
		{
			"profile_name": "synthetic",
			"source_path": "res://tests/fixtures/auto_timing.stla",
			"field_lines": {"auto_timing_profile": 7},
		}, [], "", 1, activation)
	var result: Dictionary = _dialogue._preflight_auto_timing_profile(request)
	assert_true(result["ok"])
	assert_true(result["profile"] is AutoTimingProfile)
	assert_eq(result["provenance"].get("source_path"),
		"res://tests/fixtures/auto_timing.stla")
	assert_eq(result["provenance"].get("line"), 7)


func test_authored_voice_presence_does_not_depend_on_decoder_duration() -> void:
	var segment := {
		"text": "synthetic",
		"voice_layers": [{
			"id": "main",
			"asset": "narration_001",
			"character": "sakura",
			"dsp": "",
			"line": 3,
		}],
	}
	assert_true(_dialogue._canonical_dialogue_has_voice([segment]),
		"Auto metadata follows the canonical authored voice group")
	assert_false(_dialogue._canonical_dialogue_has_voice([{
		"text": "silent",
		"voice_layers": [],
	}]))


func test_invalid_runtime_binding_aborts_before_replacing_visible_dialogue() -> void:
	var old_activation := DialogueActivation.new()
	var old_request := DialogueRequest.new(
		"", [{"text": "old", "voice_layers": []}], "adv", {}, false, "", {},
		[], "", 1, old_activation)
	_dialogue._on_dialogue_requested(old_request)
	assert_eq(_dialogue._current_dialogue_activation, old_activation)

	var invalid_activation := DialogueActivation.new()
	var invalid_request := DialogueRequest.new(
		"", [{"text": "invalid", "voice_layers": []}], "adv",
		{"auto_timing_profile": INVALID_PROFILE_PATH}, true, "",
		{
			"profile_name": "broken",
			"source_path": "res://tests/fixtures/auto_timing.stla",
			"field_lines": {"auto_timing_profile": 9},
		}, [], "", 2, invalid_activation)
	_dialogue._on_dialogue_requested(invalid_request)

	assert_push_error("res://tests/fixtures/auto_timing.stla:9")
	assert_false(invalid_activation.is_pending())
	assert_eq(invalid_activation.get_outcome(), DialogueActivation.Outcome.ABORTED)
	assert_eq(_dialogue._current_dialogue_activation, old_activation,
		"invalid Auto timing cannot retire the currently accepted dialogue")
