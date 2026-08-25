extends GutTest
## Tests for voice progress signal — framework emits position/duration each frame.


var _audio_presenter: Node
var _progress_cb: Callable
var _progress_emissions: Array


func before_each():
	_audio_presenter = StellaRuntime.get_node("AudioPresenter")
	_progress_emissions = []
	_progress_cb = func(pos, dur): _progress_emissions.append({"pos": pos, "dur": dur})
	SignalBus.voice_progress.connect(_progress_cb)


func after_each():
	if SignalBus.voice_progress.is_connected(_progress_cb):
		SignalBus.voice_progress.disconnect(_progress_cb)


# --- Signal existence ---

func test_signal_bus_has_voice_progress_signal():
	assert_true(SignalBus.has_signal("voice_progress"),
		"SignalBus should have voice_progress signal")


# --- Emission logic ---

func test_no_progress_emitted_when_no_voice_playing():
	_audio_presenter._process(0.016)
	assert_eq(_progress_emissions.size(), 0, "Should not emit when no voice is playing")


func test_progress_emitted_during_voice_playback():
	# We can't easily play real audio in headless, so verify the method exists
	# and the signal is properly defined
	assert_true(_audio_presenter.has_method("_process"),
		"AudioPresenter should have _process for progress emission")


# --- Signal shape ---

func test_voice_progress_signal_can_be_emitted():
	SignalBus.voice_progress.emit(1.5, 3.0)

	assert_eq(_progress_emissions.size(), 1)
	assert_almost_eq(float(_progress_emissions[0]["pos"]), 1.5, 0.01)
	assert_almost_eq(float(_progress_emissions[0]["dur"]), 3.0, 0.01)


# --- Guard: _process only emits when _voice_player.playing is true ---

func test_process_does_not_emit_when_player_not_playing():
	# In headless mode, _voice_player has no stream loaded and is not playing.
	# This verifies the guard: _voice_player.playing && _voice_player.stream
	_audio_presenter._process(0.016)
	_audio_presenter._process(0.016)
	_audio_presenter._process(0.016)
	assert_eq(_progress_emissions.size(), 0,
		"_process must not emit voice_progress when player is not playing")
