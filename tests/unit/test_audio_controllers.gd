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
	bus.se_play.connect(func(a): received.append(a))

	var handler = SeHandler.new()
	var cmd = CommandData.new()
	cmd.type = "se"
	cmd.params = {"asset": "se_click"}
	await handler.execute(cmd, ScenarioContext.new())

	assert_eq(received.size(), 1)
	assert_eq(received[0], "se_click")


func test_se_handler_rejects_removed_loop_and_asset_stop_params():
	for removed_key: String in ["loop", "off"]:
		var handler = SeHandler.new()
		var cmd = CommandData.new()
		cmd.type = "se"
		cmd.params = {"asset": "se_rain"}
		cmd.params[removed_key] = true
		var context := ScenarioContext.new()
		await handler.execute(cmd, context)
		assert_true(context.is_finished)
		assert_push_error("@se accepts exactly one one-shot asset")


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
