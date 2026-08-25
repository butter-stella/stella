extends GutTest
## Deterministic response checks through the real AudioServer mix thread.

const SOURCE_AMPLITUDE := 0.25
const MEASUREMENT_FRAMES := 32768
const STEADY_OFFSET := 8192
const STEADY_FRAMES := 8192

var _audio: AudioPresenter
var _measurement_bus_names: Array[StringName] = []


func before_each() -> void:
	_audio = StellaRuntime.get_node("AudioPresenter") as AudioPresenter
	assert_not_null(_audio)


func after_each() -> void:
	for bus_name: StringName in _measurement_bus_names:
		var bus_index := AudioServer.get_bus_index(bus_name)
		if bus_index >= 0:
			AudioServer.remove_bus(bus_index)
	_measurement_bus_names.clear()
	await StellaRuntime._await_audio_mix_boundary()
	_audio = null


func _band_pass_effects(order: int) -> Array[AudioEffect]:
	var definition := VoiceDspBandPassEffect.new()
	definition.center_hz = 1900.0
	definition.bandwidth_hz = 2900.0
	definition.order = order
	var effects: Array[AudioEffect] = []
	assert_true(_audio._append_band_pass_effects(effects, definition))
	return effects


func _delay_effects() -> Array[AudioEffect]:
	var definition := VoiceDspDelayEffect.new()
	definition.time_ms = 300.0
	definition.feedback = 0.0
	definition.mix = 0.35
	var effects: Array[AudioEffect] = []
	assert_true(_audio._append_delay_effect(effects, definition))
	return effects


func _sine_frames(frequency_hz: float, frame_count: int) -> PackedVector2Array:
	var sample_rate := float(AudioServer.get_mix_rate())
	var frames := PackedVector2Array()
	frames.resize(frame_count)
	for frame_index: int in range(frame_count):
		var value := SOURCE_AMPLITUDE * sin(
			TAU * frequency_hz * float(frame_index) / sample_rate)
		frames[frame_index] = Vector2(value, value)
	return frames


func _impulse_frames(frame_count: int) -> PackedVector2Array:
	var frames := PackedVector2Array()
	frames.resize(frame_count)
	frames[0] = Vector2(SOURCE_AMPLITUDE, SOURCE_AMPLITUDE)
	return frames


func _render_through_audio_server(
	effects: Array[AudioEffect],
	input_frames: PackedVector2Array,
	minimum_capture_frames: int,
) -> PackedVector2Array:
	var bus_name := StringName("__stella_dsp_response_%d" % Time.get_ticks_usec())
	AudioServer.add_bus(AudioServer.bus_count)
	var bus_index := AudioServer.bus_count - 1
	AudioServer.set_bus_name(bus_index, bus_name)
	AudioServer.set_bus_send(bus_index, &"Master")
	_measurement_bus_names.append(bus_name)
	for effect: AudioEffect in effects:
		AudioServer.add_bus_effect(bus_index, effect)
	var capture := AudioEffectCapture.new()
	capture.buffer_length = 2.0
	AudioServer.add_bus_effect(bus_index, capture)

	var generator := AudioStreamGenerator.new()
	generator.mix_rate = AudioServer.get_mix_rate()
	generator.buffer_length = 2.0
	var player := AudioStreamPlayer.new()
	player.stream = generator
	player.bus = bus_name
	add_child(player)
	player.play()
	var playback := player.get_stream_playback() as AudioStreamGeneratorPlayback
	assert_not_null(playback)
	assert_true(playback.push_buffer(input_frames))

	var reached_capture := false
	for _boundary_index: int in range(128):
		if capture.get_frames_available() >= minimum_capture_frames:
			reached_capture = true
			break
		assert_true(await StellaRuntime._await_audio_mix_boundary(),
			"Dummy audio must expose a bounded real mix boundary")
	assert_true(reached_capture,
		"the real AudioServer chain must produce the requested capture")
	var captured := capture.get_buffer(minimum_capture_frames)
	player.stop()
	var exited: Signal = player.tree_exited
	player.queue_free()
	await exited
	AudioServer.remove_bus(AudioServer.get_bus_index(bus_name))
	_measurement_bus_names.erase(bus_name)
	await StellaRuntime._await_audio_mix_boundary()
	return captured


func _rms(frames: PackedVector2Array, offset: int, count: int) -> float:
	var energy := 0.0
	for index: int in range(offset, offset + count):
		energy += frames[index].x * frames[index].x
	return sqrt(energy / float(count))


func test_band_pass_real_mix_response_and_order_are_monotonic() -> void:
	var order_one := _band_pass_effects(1)
	assert_true(order_one[0] is AudioEffectHighPassFilter)
	assert_true(order_one[1] is AudioEffectLowPassFilter)
	var passband := await _render_through_audio_server(
		order_one, _sine_frames(1900.0, MEASUREMENT_FRAMES),
		STEADY_OFFSET + STEADY_FRAMES)
	var low_stop_one := await _render_through_audio_server(
		_band_pass_effects(1), _sine_frames(100.0, MEASUREMENT_FRAMES),
		STEADY_OFFSET + STEADY_FRAMES)
	var high_stop_one := await _render_through_audio_server(
		_band_pass_effects(1), _sine_frames(10000.0, MEASUREMENT_FRAMES),
		STEADY_OFFSET + STEADY_FRAMES)
	var low_stop_two := await _render_through_audio_server(
		_band_pass_effects(2), _sine_frames(100.0, MEASUREMENT_FRAMES),
		STEADY_OFFSET + STEADY_FRAMES)
	var high_stop_two := await _render_through_audio_server(
		_band_pass_effects(2), _sine_frames(10000.0, MEASUREMENT_FRAMES),
		STEADY_OFFSET + STEADY_FRAMES)

	var pass_rms := _rms(passband, STEADY_OFFSET, STEADY_FRAMES)
	var low_one_rms := _rms(low_stop_one, STEADY_OFFSET, STEADY_FRAMES)
	var high_one_rms := _rms(high_stop_one, STEADY_OFFSET, STEADY_FRAMES)
	var low_two_rms := _rms(low_stop_two, STEADY_OFFSET, STEADY_FRAMES)
	var high_two_rms := _rms(high_stop_two, STEADY_OFFSET, STEADY_FRAMES)
	assert_gt(pass_rms, low_one_rms * 2.0,
		"1900 Hz must pass more strongly than the lower stopband")
	assert_gt(pass_rms, high_one_rms * 2.0,
		"1900 Hz must pass more strongly than the upper stopband")
	assert_lt(low_two_rms, low_one_rms,
		"a higher authored order must attenuate the lower stopband more")
	assert_lt(high_two_rms, high_one_rms,
		"a higher authored order must attenuate the upper stopband more")


func test_delay_real_mix_preserves_dry_impulse_and_adds_wet_tap() -> void:
	var sample_rate := AudioServer.get_mix_rate()
	var tap_distance := int(round(float(sample_rate) * 0.3))
	var captured := await _render_through_audio_server(
		_delay_effects(), _impulse_frames(tap_distance + 4096),
		tap_distance + 4096)
	var direct_index := -1
	for frame_index: int in range(captured.size()):
		if absf(captured[frame_index].x) > SOURCE_AMPLITUDE * 0.5:
			direct_index = frame_index
			break
	assert_gte(direct_index, 0, "the dry impulse must remain audible")
	var tap_index := direct_index + tap_distance
	assert_lt(tap_index, captured.size())
	assert_almost_eq(
		captured[direct_index].x, SOURCE_AMPLITUDE, 0.01,
		"mix is wet tap gain; it must not attenuate the dry branch")
	assert_almost_eq(
		captured[tap_index].x, SOURCE_AMPLITUDE * 0.35, 0.02,
		"the first 300 ms tap uses the authored linear wet gain")
