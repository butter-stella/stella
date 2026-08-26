extends GutTest


func test_logical_preset_ids_are_bounded_and_path_safe() -> void:
	for valid in ["remote", "memory/soft", "voice-1"]:
		assert_true(VoiceDspChainDefinition.is_logical_preset_id(valid))
	for invalid in ["", " remote", "remote ", "../remote", "a//b", "res://x", "a.b"]:
		assert_false(VoiceDspChainDefinition.is_logical_preset_id(invalid))


func test_real_acceptance_values_are_losslessly_representable() -> void:
	var cases := [
		[1900.0, 2900.0, 2],
		[2400.0, 2000.0, 1],
		[320.0, 480.0, 2],
	]
	for case_value in cases:
		var case: Array = case_value
		var chain := VoiceDspChainDefinition.new()
		var effect := VoiceDspBandPassEffect.new()
		effect.center_hz = case[0]
		effect.bandwidth_hz = case[1]
		effect.order = case[2]
		chain.effects = [effect]
		assert_eq(chain.validation_errors(), PackedStringArray())
		assert_eq(effect.center_hz, case[0])
		assert_eq(effect.bandwidth_hz, case[1])
		assert_eq(effect.order, case[2])

	var delay_chain := VoiceDspChainDefinition.new()
	var delay := VoiceDspDelayEffect.new()
	delay.time_ms = 300.0
	delay.feedback = 0.35
	delay.mix = 0.35
	delay_chain.effects = [delay]
	delay_chain.tail_seconds = 0.6
	assert_eq(delay_chain.validation_errors(), PackedStringArray())
	assert_eq(delay.time_ms, 300.0)
	assert_eq(delay.feedback, 0.35)
	assert_eq(delay.mix, 0.35)
	assert_eq(delay_chain.tail_seconds, 0.6)


func test_chain_validation_rejects_unrepresentable_values_and_primitives() -> void:
	var chain := VoiceDspChainDefinition.new()
	var delay := VoiceDspDelayEffect.new()
	delay.mix = 0.0005
	chain.effects = [delay]
	assert_true("at least 0.001" in " ".join(chain.validation_errors()))

	var band := VoiceDspBandPassEffect.new()
	band.center_hz = 100.0
	band.bandwidth_hz = 400.0
	chain.effects = [band]
	assert_true("edges must remain" in " ".join(chain.validation_errors()))

	chain.effects = [VoiceDspEffectDefinition.new()]
	assert_true("unsupported primitive" in " ".join(chain.validation_errors()))


func test_voice_request_snapshots_preset_and_source() -> void:
	var source := {"source_path": "res://public/test.stla", "line": 7}
	var request := VoicePlaybackRequest.new(
		"voice", "speaker", Callable(), "remote", source)
	source["line"] = 99
	assert_true(request.is_single_layer())
	assert_eq(request.get_asset(), "voice")
	assert_eq(request.get_character(), "speaker")
	assert_eq(request.get_dsp_preset(), "remote")
	assert_eq(request.get_source().get("line"), 7)
	var observed := request.get_source()
	observed["line"] = 42
	assert_eq(request.get_source().get("line"), 7)


func test_voice_layer_request_is_bounded_ordered_and_defensive() -> void:
	var source := {"source_path": "res://public/layers.stla", "line": 8}
	var layers := [
		{"id": "lead", "asset": "a", "character": "alice", "dsp": "remote", "source": source},
		{"id": "reply", "asset": "b", "character": "bob", "dsp": "", "source": {"line": 8}},
	]
	var request := VoicePlaybackRequest.from_layers(layers)
	source["line"] = 99
	assert_true(request.is_valid())
	assert_false(request.is_single_layer())
	assert_eq(request.get_asset(), "")
	assert_eq(request.get_character(), "")
	assert_eq(request.get_dsp_preset(), "")
	assert_eq(request.get_source(), {},
		"a group has no scalar first-layer compatibility projection")
	assert_eq(request.get_layers().map(func(layer): return layer["id"]), ["lead", "reply"])
	assert_eq(request.get_layers()[0]["source"]["line"], 8)
	var observed: Array = request.get_layers()
	observed[0]["asset"] = "changed"
	assert_eq(request.get_layers()[0]["asset"], "a")

	for invalid_layers: Variant in [
		[layers[0], layers[0]],
		[{"id": "9bad", "asset": "a", "character": "a", "dsp": "", "source": {}}],
		[{"id": "ok", "asset": "../a", "character": "a", "dsp": "", "source": {}}],
	]:
		assert_false(VoicePlaybackRequest.from_layers(invalid_layers).is_valid())
