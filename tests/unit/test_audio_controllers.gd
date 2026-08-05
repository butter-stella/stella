extends GutTest
## Tests for BgmController, SeController, VoiceController.
## These controllers manage AudioStreamPlayers and respond to SignalBus signals.
## Since we're testing in headless mode, we test the logic and signal wiring,
## not actual audio playback.


# --- BgmHandler ---

func test_bgm_handler_type():
	var handler = BgmHandler.new()
	assert_eq(handler.get_command_type(), "bgm")


func test_bgm_handler_emits_play_signal():
	var received: Array = []
	var bus = get_tree().root.get_node("SignalBus")
	bus.bgm_play.connect(func(a, f): received.append({"asset": a, "fade": f}))

	var handler = BgmHandler.new()
	var cmd = CommandData.new()
	cmd.type = "bgm"
	cmd.params = {"asset": "bgm_spring", "fade_duration": 1.5}

	var ctx = ScenarioContext.new()
	await handler.execute(cmd, ctx)

	assert_eq(received.size(), 1)
	assert_eq(received[0]["asset"], "bgm_spring")


func test_bgm_handler_stop_emits_signal():
	var received: Array = []
	var bus = get_tree().root.get_node("SignalBus")
	bus.bgm_stop.connect(func(f): received.append(f))

	var handler = BgmHandler.new()
	var cmd = CommandData.new()
	cmd.type = "bgm"
	cmd.params = {"off": true, "fade_duration": 2.0}

	var ctx = ScenarioContext.new()
	await handler.execute(cmd, ctx)

	assert_eq(received.size(), 1)
	assert_almost_eq(received[0], 2.0, 0.01)


func test_bgm_handler_defaults():
	var received: Array = []
	var bus = get_tree().root.get_node("SignalBus")
	bus.bgm_play.connect(func(a, f): received.append({"fade": f}))

	var handler = BgmHandler.new()
	var cmd = CommandData.new()
	cmd.type = "bgm"
	cmd.params = {"asset": "bgm_test"}
	await handler.execute(cmd, ScenarioContext.new())

	assert_almost_eq(received[0]["fade"], 1.0, 0.01)


# --- SeHandler ---

func test_se_handler_type():
	var handler = SeHandler.new()
	assert_eq(handler.get_command_type(), "se")


func test_se_handler_emits_play_signal():
	var received: Array = []
	var bus = get_tree().root.get_node("SignalBus")
	bus.se_play.connect(func(a, l): received.append({"asset": a, "loop": l}))

	var handler = SeHandler.new()
	var cmd = CommandData.new()
	cmd.type = "se"
	cmd.params = {"asset": "se_click", "loop": false}
	await handler.execute(cmd, ScenarioContext.new())

	assert_eq(received.size(), 1)
	assert_eq(received[0]["asset"], "se_click")
	assert_false(received[0]["loop"])


func test_se_handler_stop_emits_signal():
	var received: Array = []
	var bus = get_tree().root.get_node("SignalBus")
	bus.se_stop.connect(func(a): received.append(a))

	var handler = SeHandler.new()
	var cmd = CommandData.new()
	cmd.type = "se"
	cmd.params = {"asset": "se_rain", "off": true}
	await handler.execute(cmd, ScenarioContext.new())

	assert_eq(received, ["se_rain"])


# --- FadeHandler ---

func test_fade_handler_type():
	var handler = FadeHandler.new()
	assert_eq(handler.get_command_type(), "fade")


func test_fade_handler_emits_signal():
	var received: Array = []
	var bus = get_tree().root.get_node("SignalBus")
	bus.fade_requested.connect(func(d, dur): received.append({"direction": d, "duration": dur}))

	var handler = FadeHandler.new()
	var cmd = CommandData.new()
	cmd.type = "fade"
	cmd.params = {"direction": "out", "duration": 1.0}
	await handler.execute(cmd, ScenarioContext.new())

	assert_eq(received.size(), 1)
	assert_eq(received[0]["direction"], "out")


# --- WaitHandler ---

func test_wait_handler_type():
	var handler = WaitHandler.new()
	assert_eq(handler.get_command_type(), "wait")


# --- VoiceHandler ---

func test_voice_handler_type():
	var handler = VoiceHandler.new()
	assert_eq(handler.get_command_type(), "voice")


func test_voice_handler_emits_play_signal():
	var received: Array = []
	var bus = get_tree().root.get_node("SignalBus")
	bus.voice_play.connect(func(a, c): received.append({"asset": a, "character": c}))

	var handler = VoiceHandler.new()
	var cmd = CommandData.new()
	cmd.type = "voice"
	cmd.params = {"asset": "sakura_001"}
	await handler.execute(cmd, ScenarioContext.new())

	assert_eq(received.size(), 1)
	assert_eq(received[0]["asset"], "sakura_001")


func test_voice_handler_empty_asset_does_not_emit():
	var received: Array = []
	var bus = get_tree().root.get_node("SignalBus")
	bus.voice_play.connect(func(a, c): received.append(a))

	var handler = VoiceHandler.new()
	var cmd = CommandData.new()
	cmd.type = "voice"
	cmd.params = {"asset": ""}
	await handler.execute(cmd, ScenarioContext.new())

	assert_eq(received.size(), 0, "empty asset should not emit voice_play")


# --- AudioPresenter asset compatibility ---

func test_audio_presenter_loads_wav_bgm():
	var presenter = StellaRuntime.get_node("AudioPresenter")
	var original_bgm_path = StellaRuntime.bgm_path
	StellaRuntime.bgm_path = "res://examples/demo/audio/se/"
	presenter._bgm_player.stop()
	presenter._bgm_player.stream = null

	presenter._on_bgm_play("se_select", 0.0)

	assert_not_null(presenter._bgm_player.stream, "WAV must be accepted as a BGM asset")
	if presenter._bgm_player.stream:
		assert_true(
			presenter._bgm_player.stream is AudioStreamWAV,
			"the requested WAV BGM must load as an AudioStreamWAV",
		)
	presenter._bgm_player.stop()
	presenter._bgm_player.stream = null
	StellaRuntime.bgm_path = original_bgm_path


func test_audio_presenter_applies_loop_to_wav_se():
	var presenter = StellaRuntime.get_node("AudioPresenter")
	var original_se_path = StellaRuntime.se_path
	StellaRuntime.se_path = "res://examples/demo/audio/se/"
	for player in presenter._se_players:
		player.stop()
		player.stream = null

	presenter._on_se_play("se_select", true)

	var stream: AudioStream = presenter._se_players[0].stream
	assert_not_null(stream, "looping SE should load into an available channel")
	if stream is AudioStreamWAV:
		assert_ne(
			stream.loop_mode,
			AudioStreamWAV.LOOP_DISABLED,
			"loop=true must enable WAV stream looping",
		)
	else:
		assert_true("loop" in stream and stream.loop, "loop=true must enable stream looping")
	for player in presenter._se_players:
		player.stop()
		player.stream = null
	presenter._se_player_assets.clear()
	StellaRuntime.se_path = original_se_path
