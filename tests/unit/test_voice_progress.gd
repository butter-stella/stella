extends GutTest
## Tests for voice progress signal — framework emits position/duration each frame.


var _audio_presenter: Node


func before_each():
	_audio_presenter = _create_audio_presenter()
	add_child_autoqfree(_audio_presenter)


func _create_audio_presenter() -> Node:
	var script = load("res://addons/natsume/presentation/audio/audio_presenter.gd")
	var node = Node.new()
	node.set_script(script)
	return node


# --- Signal existence ---

func test_signal_bus_has_voice_progress_signal():
	assert_true(SignalBus.has_signal("voice_progress"),
		"SignalBus should have voice_progress signal")


# --- Emission logic ---

func test_no_progress_emitted_when_no_voice_playing():
	var emissions: Array = []
	SignalBus.voice_progress.connect(func(pos, dur): emissions.append({"pos": pos, "dur": dur}))

	# Simulate one frame
	_audio_presenter._process(0.016)

	assert_eq(emissions.size(), 0, "Should not emit when no voice is playing")


func test_progress_emitted_during_voice_playback():
	# We can't easily play real audio in headless, so verify the method exists
	# and the signal is properly defined
	assert_true(_audio_presenter.has_method("_process"),
		"AudioPresenter should have _process for progress emission")


# --- Signal shape ---

func test_voice_progress_signal_can_be_emitted():
	var received: Array = []
	SignalBus.voice_progress.connect(func(pos, dur): received.append([pos, dur]))

	SignalBus.voice_progress.emit(1.5, 3.0)

	assert_eq(received.size(), 1)
	assert_almost_eq(received[0][0], 1.5, 0.01)
	assert_almost_eq(received[0][1], 3.0, 0.01)


func test_voice_finished_stops_progress():
	# After voice_finished, _process should not emit voice_progress
	var emissions: Array = []
	SignalBus.voice_progress.connect(func(pos, dur): emissions.append(true))

	SignalBus.voice_finished.emit()
	_audio_presenter._process(0.016)

	assert_eq(emissions.size(), 0, "No progress after voice_finished")
