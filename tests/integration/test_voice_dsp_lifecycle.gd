extends GutTest
## Physical per-voice DSP ownership and queue/replay lifecycle regressions.

const VOICE_PATH := "res://examples/demo/audio/voice/"
const DSP_PATH := "res://tests/fixtures/audio/voice_dsp/"

var _audio: AudioPresenter
var _game_scene: Node
var _original_voice_path: String
var _original_dsp_path: String
var _original_settings: Dictionary
var _original_audio_bus_count: int


func before_each() -> void:
	_original_voice_path = StellaRuntime.voice_path
	_original_dsp_path = StellaRuntime.voice_dsp_path
	_original_settings = {}
	for key in [
		"master_volume", "voice_volume",
		"character_voice_volume", "character_voice_enabled",
	]:
		var value: Variant = StellaRuntime.get_setting(key)
		_original_settings[key] = (
			value.duplicate(true)
			if value is Dictionary or value is Array
			else value
		)
	StellaRuntime.voice_path = VOICE_PATH
	StellaRuntime.voice_dsp_path = DSP_PATH
	_audio = StellaRuntime.get_node("AudioPresenter") as AudioPresenter
	_original_audio_bus_count = AudioServer.bus_count
	SignalBus.hide_dialogue.emit()
	_game_scene = load("res://addons/stella/scenes/game.tscn").instantiate()
	add_child_autoqfree(_game_scene)
	await get_tree().process_frame


func after_each() -> void:
	SignalBus.hide_dialogue.emit()
	SignalBus.engine_abort_requested.emit()
	if is_instance_valid(_game_scene):
		var exited: Signal = _game_scene.tree_exited
		_game_scene.queue_free()
		await exited
	await get_tree().process_frame
	assert_true(_audio._voice_dsp_tail_timer.is_stopped())
	assert_eq(AudioServer.get_bus_effect_count(_bus_index()), 0)
	assert_eq(AudioServer.bus_count, _original_audio_bus_count,
		"staging and replaced private buses must be released exactly")
	for key: String in _original_settings:
		StellaRuntime.set_setting(key, _original_settings[key])
	StellaRuntime.voice_path = _original_voice_path
	StellaRuntime.voice_dsp_path = _original_dsp_path
	_audio = null
	_game_scene = null


func _bus_index() -> int:
	return AudioServer.get_bus_index(_audio._voice_dsp_bus_name)


func _request(
	preset: String,
	asset: String = "narration_001",
) -> VoicePlaybackResponse:
	return SignalBus.request_voice_playback(
		asset,
		"speaker",
		func() -> bool: return is_inside_tree(),
		false,
		preset,
		{"source_path": "res://tests/public_voice_dsp.stla", "line": 12},
	)


func test_dry_filtered_dry_replaces_private_chain_atomically() -> void:
	var dry := _request("")
	assert_true(dry.was_accepted())
	assert_eq(AudioServer.get_bus_effect_count(_bus_index()), 0)

	var filtered := _request("remote", "narration_002")
	assert_true(filtered.was_accepted())
	assert_true(dry.get_completion().is_finished())
	assert_eq(AudioServer.get_bus_effect_count(_bus_index()), 2)
	var high := AudioServer.get_bus_effect(_bus_index(), 0)
	var low := AudioServer.get_bus_effect(_bus_index(), 1)
	assert_true(high is AudioEffectHighPassFilter)
	assert_true(low is AudioEffectLowPassFilter)
	assert_eq((high as AudioEffectHighPassFilter).cutoff_hz, 450.0)
	assert_eq((low as AudioEffectLowPassFilter).cutoff_hz, 3350.0)
	assert_eq((high as AudioEffectHighPassFilter).db, AudioEffectFilter.FILTER_12DB)
	assert_eq((low as AudioEffectLowPassFilter).db, AudioEffectFilter.FILTER_12DB)

	var final_dry := _request("", "narration_003")
	assert_true(final_dry.was_accepted())
	assert_true(filtered.get_completion().is_finished())
	assert_eq(AudioServer.get_bus_effect_count(_bus_index()), 0,
		"a later dry segment cannot inherit the filtered chain")


func test_ordered_chain_maps_wet_delay_without_attenuating_dry() -> void:
	var response := _request("ordered")
	assert_true(response.was_accepted())
	assert_eq(AudioServer.get_bus_effect_count(_bus_index()), 3)
	assert_true(AudioServer.get_bus_effect(_bus_index(), 0) is AudioEffectHighPassFilter)
	assert_true(AudioServer.get_bus_effect(_bus_index(), 1) is AudioEffectLowPassFilter)
	var delay := AudioServer.get_bus_effect(_bus_index(), 2) as AudioEffectDelay
	assert_not_null(delay)
	assert_eq(delay.dry, 1.0)
	assert_eq(delay.tap1_delay_ms, 300.0)
	assert_almost_eq(db_to_linear(delay.tap1_level_db), 0.35, 0.00001)
	assert_eq(delay.feedback_delay_ms, 300.0)
	assert_almost_eq(db_to_linear(delay.feedback_level_db), 0.35, 0.00001)


func test_missing_or_invalid_preset_rejects_without_interrupting_live_voice() -> void:
	var live := _request("remote")
	assert_true(live.was_accepted())
	var live_stream := _audio._voice_player.stream
	var live_token: int = _audio._voice_playback_token
	var missing := _request("missing")
	assert_false(missing.was_accepted())
	assert_push_error("res://tests/public_voice_dsp.stla:12")
	var invalid := _request("invalid_gain")
	assert_false(invalid.was_accepted())
	assert_push_error("at least 0.001")
	assert_eq(_audio._voice_playback_token, live_token)
	assert_same(_audio._voice_player.stream, live_stream)
	assert_eq(AudioServer.get_bus_effect_count(_bus_index()), 2)


func test_delay_tail_is_owned_and_hard_boundary_clears_it() -> void:
	var response := _request("memory")
	assert_true(response.was_accepted())
	_audio._voice_player.stop()
	_audio._on_voice_playback_finished()
	assert_false(_audio._voice_dsp_tail_timer.is_stopped())
	assert_false(response.get_completion().is_finished())
	assert_eq(AudioServer.get_bus_effect_count(_bus_index()), 1)

	SignalBus.hide_dialogue.emit()
	assert_true(_audio._voice_dsp_tail_timer.is_stopped())
	assert_true(response.get_completion().is_finished())
	assert_eq(_audio._voice_playback_token, -1)
	assert_eq(AudioServer.get_bus_effect_count(_bus_index()), 0)


func test_abort_and_reset_boundaries_clear_tail_and_private_chain() -> void:
	var aborted := _request("memory")
	assert_true(aborted.was_accepted())
	_audio._voice_player.stop()
	_audio._on_voice_playback_finished()
	assert_false(_audio._voice_dsp_tail_timer.is_stopped())
	SignalBus.engine_abort_requested.emit()
	assert_true(aborted.get_completion().is_finished())
	assert_true(_audio._voice_dsp_tail_timer.is_stopped())
	assert_eq(AudioServer.get_bus_effect_count(_bus_index()), 0)

	var reset := _request("memory", "narration_002")
	assert_true(reset.was_accepted())
	_audio._voice_player.stop()
	_audio._on_voice_playback_finished()
	assert_false(_audio._voice_dsp_tail_timer.is_stopped())
	# Load, rollback and return-to-title all publish this same presentation reset
	# boundary; AudioPresenter owns no navigation-specific compatibility branch.
	SignalBus.hide_dialogue.emit()
	assert_true(reset.get_completion().is_finished())
	assert_true(_audio._voice_dsp_tail_timer.is_stopped())
	assert_eq(AudioServer.get_bus_effect_count(_bus_index()), 0)


func test_unowned_processed_voice_retires_atomically_on_reset() -> void:
	var response := SignalBus.request_voice_playback(
		"narration_001",
		"extension",
		Callable(),
		false,
		"remote",
		{"source_path": "res://tests/public_voice_dsp.stla", "line": 20},
	)
	assert_true(response.was_accepted())
	var playback_token := response.get_playback_token()
	var stream := _audio._voice_player.stream
	assert_eq(AudioServer.get_bus_effect_count(_bus_index()), 2)

	SignalBus.hide_dialogue.emit()
	assert_true(response.get_completion().is_finished())
	assert_eq(_audio._voice_playback_token, -1)
	assert_null(_audio._voice_player.stream)
	assert_false(_audio._voice_player.playing)
	assert_eq(AudioServer.get_bus_effect_count(_bus_index()), 0)
	assert_ne(_audio._voice_playback_token, playback_token)
	assert_not_same(_audio._voice_player.stream, stream,
		"a processed token cannot continue after its chain is removed")


func test_unowned_dry_voice_keeps_existing_programmatic_boundary_semantics() -> void:
	var response := SignalBus.request_voice_playback(
		"narration_001", "extension", Callable(), false)
	assert_true(response.was_accepted())
	var playback_token := response.get_playback_token()
	var stream := _audio._voice_player.stream
	SignalBus.hide_dialogue.emit()
	assert_false(response.get_completion().is_finished())
	assert_eq(_audio._voice_playback_token, playback_token)
	assert_same(_audio._voice_player.stream, stream)
	assert_true(_audio._voice_player.playing)
	assert_eq(AudioServer.get_bus_effect_count(_bus_index()), 0)
	SignalBus.emit_advance_requested()
	assert_true(response.get_completion().is_finished())


func test_staging_failure_preserves_live_voice_bus_chain_and_token() -> void:
	var live := _request("remote")
	assert_true(live.was_accepted())
	var live_token := _audio._voice_playback_token
	var live_stream := _audio._voice_player.stream
	var live_bus := _audio._voice_dsp_bus_name
	var collision_name := StringName(
		"__stella_voice_dsp_%d_%d"
			% [_audio.get_instance_id(), _audio._voice_dsp_bus_serial + 1])
	var collision_index := AudioServer.bus_count
	AudioServer.add_bus(collision_index)
	AudioServer.set_bus_name(collision_index, collision_name)
	assert_eq(AudioServer.get_bus_index(collision_name), collision_index)

	var rejected := _request("memory", "narration_002")
	assert_false(rejected.was_accepted())
	assert_push_error("private staging bus identity is ambiguous")
	assert_eq(_audio._voice_playback_token, live_token)
	assert_same(_audio._voice_player.stream, live_stream)
	assert_eq(_audio._voice_dsp_bus_name, live_bus)
	assert_eq(_audio._voice_player.bus, live_bus)
	assert_eq(AudioServer.get_bus_effect_count(_bus_index()), 2)
	assert_true(_audio._voice_player.playing)

	var exact_collision_index := AudioServer.get_bus_index(collision_name)
	if exact_collision_index >= 0:
		AudioServer.remove_bus(exact_collision_index)


func test_private_bus_is_the_single_live_and_replacement_gain_authority() -> void:
	StellaRuntime.set_setting("master_volume", 1.0)
	StellaRuntime.set_setting("voice_volume", 1.0)
	StellaRuntime.set_setting("character_voice_volume", {"speaker": 1.0})
	StellaRuntime.set_setting("character_voice_enabled", {"speaker": true})
	var dry := _request("")
	assert_true(dry.was_accepted())
	assert_eq(_audio._voice_player.volume_db, 0.0)
	assert_almost_eq(AudioServer.get_bus_volume_db(_bus_index()), 0.0, 0.0001)

	var filtered := _request("remote", "narration_002")
	assert_true(filtered.was_accepted())
	assert_true(dry.get_completion().is_finished())
	assert_eq(_audio._voice_player.volume_db, 0.0)
	assert_almost_eq(AudioServer.get_bus_volume_db(_bus_index()), 0.0, 0.0001)
	StellaRuntime.set_setting("voice_volume", 0.5)
	assert_eq(_audio._voice_player.volume_db, 0.0)
	assert_almost_eq(
		AudioServer.get_bus_volume_db(_bus_index()), linear_to_db(0.5), 0.0001)

	var final_dry := _request("", "narration_003")
	assert_true(final_dry.was_accepted())
	assert_true(filtered.get_completion().is_finished())
	assert_eq(_audio._voice_player.volume_db, 0.0)
	assert_almost_eq(
		AudioServer.get_bus_volume_db(_bus_index()), linear_to_db(0.5), 0.0001)
	StellaRuntime.set_setting("voice_volume", 1.0)
	assert_almost_eq(AudioServer.get_bus_volume_db(_bus_index()), 0.0, 0.0001)


func test_live_tail_obeys_master_voice_character_volume_and_enabled() -> void:
	StellaRuntime.set_setting("master_volume", 1.0)
	StellaRuntime.set_setting("voice_volume", 1.0)
	StellaRuntime.set_setting("character_voice_volume", {"speaker": 1.0})
	StellaRuntime.set_setting("character_voice_enabled", {"speaker": true})
	var response := _request("memory")
	assert_true(response.was_accepted())
	assert_eq(_audio._voice_player.volume_db, 0.0)
	_audio._voice_player.stop()
	_audio._on_voice_playback_finished()
	assert_false(_audio._voice_dsp_tail_timer.is_stopped())
	assert_almost_eq(AudioServer.get_bus_volume_db(_bus_index()), 0.0, 0.0001)

	StellaRuntime.set_setting("master_volume", 0.0)
	assert_lte(AudioServer.get_bus_volume_db(_bus_index()), -79.0)
	StellaRuntime.set_setting("master_volume", 1.0)
	StellaRuntime.set_setting("voice_volume", 0.0)
	assert_lte(AudioServer.get_bus_volume_db(_bus_index()), -79.0)
	StellaRuntime.set_setting("voice_volume", 1.0)
	StellaRuntime.set_setting("character_voice_volume", {"speaker": 0.0})
	assert_lte(AudioServer.get_bus_volume_db(_bus_index()), -79.0)
	StellaRuntime.set_setting("character_voice_volume", {"speaker": 1.0})
	StellaRuntime.set_setting("character_voice_enabled", {"speaker": false})
	assert_lte(AudioServer.get_bus_volume_db(_bus_index()), -79.0)
	assert_false(_audio._voice_dsp_tail_timer.is_stopped(),
		"settings mute the owned tail without changing its lifecycle")
	StellaRuntime.set_setting("character_voice_enabled", {"speaker": true})
	assert_almost_eq(AudioServer.get_bus_volume_db(_bus_index()), 0.0, 0.0001)


func test_combine_and_backlog_replay_keep_each_segment_preset() -> void:
	var dialogue := _game_scene.get_node("UILayer/DialoguePanel") as Control
	dialogue._char_interval = 0.0
	var presets: Array[String] = []
	var on_request := func(request: VoicePlaybackRequest):
		presets.append(request.get_dsp_preset())
	SignalBus.voice_playback_requested.connect(on_request)
	SignalBus.show_dialogue.emit("speaker", [
		{"text": "one", "voice": "narration_001", "voice_dsp": "remote", "voice_dsp_line": 3},
		{"text": "two", "voice": "narration_002", "voice_dsp": "memory", "voice_dsp_line": 4},
	], "adv")
	assert_eq(presets, ["remote"])
	_audio._voice_player.stop()
	_audio._on_voice_playback_finished()
	assert_eq(presets, ["remote", "memory"])
	SignalBus.hide_dialogue.emit()

	presets.clear()
	SignalBus.dialogue_voice_segment_replay_requested.emit([
		{"voice": "narration_001", "voice_dsp": "memory", "voice_dsp_line": 8},
		{"voice": "narration_002", "voice_dsp": "remote", "voice_dsp_line": 9},
	], "speaker")
	assert_eq(presets, ["memory"])
	_audio._voice_player.stop()
	_audio._on_voice_playback_finished()
	assert_eq(presets, ["memory"], "the next segment waits for the authored DSP tail")
	_audio._on_voice_dsp_tail_timeout()
	assert_eq(presets, ["memory", "remote"])
	SignalBus.voice_playback_requested.disconnect(on_request)
