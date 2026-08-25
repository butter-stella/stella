extends GutTest
## Parser and canonical-state contract for synchronized multi-stem BGM (#186).

const SOURCE_PATH := "res://synthetic/bgm_stem_contract.stla"


func _parse(source: String) -> ScenarioData:
	return DslParser.parse(
		DslLexer.tokenize(source),
		"bgm_stem_contract",
		SOURCE_PATH,
	)


func _commands(data: ScenarioData) -> Array[CommandData]:
	var result: Array[CommandData] = []
	for scene_value: Variant in data.scenes:
		for command_value: Variant in (scene_value as SceneData).commands:
			result.append(command_value as CommandData)
	return result


func _errors(data: ScenarioData) -> Array:
	return data.diagnostics.filter(func(diagnostic: Dictionary) -> bool:
		return String(diagnostic.get("level", "")) == "error"
	)


func _payload(command: CommandData) -> Dictionary:
	return command.params["operations"][0]["payload"] as Dictionary


func test_play_and_mix_lower_to_one_canonical_bgm_channel() -> void:
	var data := _parse("""@chapter synthetic
@scene start
@bgm play ensemble cue=intro mix=rhythm,harmony:0.5 volume=0.8 fade=0.4
@bgm mix harmony,rhythm:0.25 fade=0.6""")
	assert_eq(_errors(data), [], str(data.diagnostics))
	var commands := _commands(data)
	assert_eq(commands.size(), 2)
	if commands.size() != 2:
		return
	for command: CommandData in commands:
		assert_eq(command.type, "presentation_batch")
		assert_eq(command.get_string("policy"), "fire_and_forget")
		assert_eq(command.params["operations"].size(), 1)
		assert_eq(command.params["operations"][0]["kind"], "bgm")
	assert_eq(_payload(commands[0]), {
		"action": "play",
		"asset": "ensemble",
		"cue": "intro",
		"fade_duration": 0.4,
		"resume_position": 0.0,
		"stem_mix": {"harmony": 0.5, "rhythm": 1.0},
		"volume": 0.8,
	})
	assert_eq(_payload(commands[1]), {
		"action": "mix",
		"asset": "",
		"cue": "",
		"fade_duration": 0.6,
		"resume_position": 0.0,
		"stem_mix": {"harmony": 1.0, "rhythm": 0.25},
		"volume": 1.0,
	})


func test_single_stream_operations_use_the_same_exact_seven_field_schema() -> void:
	var data := _parse("""@chapter synthetic
@scene start
@bgm play theme
@bgm pause
@bgm resume
@bgm stop""")
	assert_eq(_errors(data), [], str(data.diagnostics))
	for command: CommandData in _commands(data):
		var payload := _payload(command)
		assert_true(payload.has("stem_mix"))
		assert_eq(payload["stem_mix"], {})
		var keys := payload.keys()
		keys.sort()
		assert_eq(keys, [
			"action", "asset", "cue", "fade_duration", "resume_position",
			"stem_mix", "volume",
		])


func test_mix_spec_is_closed_canonical_and_source_located() -> void:
	var cases := [
		{"command": "@bgm mix", "message": "stem mix"},
		{"command": "@bgm mix rhythm,rhythm", "message": "duplicate"},
		{"command": "@bgm mix rhythm:1.1", "message": "between 0 and 1"},
		{"command": "@bgm mix rhythm:-0.1", "message": "between 0 and 1"},
		{"command": "@bgm mix rhythm:nan", "message": "finite"},
		{"command": "@bgm mix rhythm:0,harmony:0", "message": "all zero"},
		{"command": "@bgm mix bad:id:0.5", "message": "stem"},
		{"command": "@bgm mix rhythm unknown=1", "message": "unknown"},
		{"command": "@bgm play ensemble mix=", "message": "stem mix"},
		{"command": "@bgm pause mix=rhythm", "message": "does not accept"},
	]
	for case: Dictionary in cases:
		var data := _parse(
			"@chapter synthetic\n@scene start\n" + String(case["command"]))
		assert_eq(_commands(data), [], String(case["command"]))
		assert_eq(_errors(data).size(), 1, str(data.diagnostics))
		if _errors(data).size() == 1:
			var message := String(_errors(data)[0].get("message", ""))
			assert_true(String(case["message"]) in message, message)
			assert_true("%s:3" % SOURCE_PATH in message, message)


func test_mix_order_is_semantically_canonical_but_gain_changes_identity() -> void:
	var first := _parse("""@chapter synthetic
@scene start
@bgm mix rhythm,harmony:0.5""")
	var reordered := _parse("""@chapter synthetic
@scene start
@bgm mix harmony:0.5,rhythm""")
	var changed := _parse("""@chapter synthetic
@scene start
@bgm mix harmony:0.25,rhythm""")
	assert_eq(_errors(first), [])
	assert_eq(_errors(reordered), [])
	assert_eq(_errors(changed), [])
	assert_eq(first.content_fingerprint, reordered.content_fingerprint)
	assert_ne(first.content_fingerprint, changed.content_fingerprint)


func test_canonical_state_requires_full_json_safe_stem_mix() -> void:
	var single := {
		"asset": "theme", "cue": "", "loop": true,
		"position": 1.5, "status": "playing", "stem_mix": {},
		"volume": 0.8,
	}
	var stems := single.duplicate(true)
	stems["asset"] = "ensemble"
	stems["stem_mix"] = {"harmony": 0.5, "rhythm": 1.0}
	assert_true(BgmChannelState.validate_snapshot_state(single, false))
	assert_true(BgmChannelState.validate_snapshot_state(stems, false))
	assert_not_null(JSON.parse_string(JSON.stringify(stems)))
	for invalid: Dictionary in [
		stems.merged({"stem_mix": {"bad:id": 1.0}}, true),
		stems.merged({"stem_mix": {"rhythm": INF}}, true),
		stems.merged({"stem_mix": {"rhythm": -0.1}}, true),
		stems.merged({"stem_mix": {"rhythm": 1.1}}, true),
		stems.merged({"stem_mix": {"harmony": 0.0, "rhythm": 0.0}}, true),
	]:
		assert_false(BgmChannelState.validate_snapshot_state(invalid, false))


func test_mix_operation_requires_an_active_multi_stem_state() -> void:
	var mix := {
		"action": "mix", "asset": "", "cue": "",
		"fade_duration": 0.5, "resume_position": 0.0,
		"stem_mix": {"rhythm": 1.0}, "volume": 1.0,
	}
	var single := {
		"asset": "theme", "cue": "", "loop": true,
		"position": 0.0, "status": "playing", "stem_mix": {},
		"volume": 1.0,
	}
	var stems := single.duplicate(true)
	stems["asset"] = "ensemble"
	stems["stem_mix"] = {"harmony": 0.5, "rhythm": 1.0}
	assert_true(BgmChannelState.validate_operation(mix, false))
	assert_false(BgmChannelState.operation_is_supported({}, mix))
	assert_false(BgmChannelState.operation_is_supported(single, mix))
	assert_true(BgmChannelState.operation_is_supported(stems, mix))
	assert_true(BgmChannelState.operation_has_work(stems, mix))
	var aligned := mix.duplicate(true)
	aligned["stem_mix"] = stems["stem_mix"].duplicate(true)
	assert_false(BgmChannelState.operation_has_work(stems, aligned))


func test_synchronized_stream_limit_is_exactly_the_godot_46_limit() -> void:
	assert_eq(AudioStreamSynchronized.MAX_STREAMS, 32)
	var maximum: Dictionary = {}
	for index in range(AudioStreamSynchronized.MAX_STREAMS):
		maximum["stem_%02d" % index] = 1.0 if index == 0 else 0.0
	assert_true(BgmChannelState.validate_stem_mix(maximum, false, true))
	var too_many := maximum.duplicate(true)
	too_many["stem_32"] = 1.0
	assert_false(BgmChannelState.validate_stem_mix(too_many, false, true))
	var synchronized := AudioStreamSynchronized.new()
	synchronized.stream_count = AudioStreamSynchronized.MAX_STREAMS
	assert_eq(synchronized.stream_count, 32)
	synchronized.set_sync_stream_volume(31, -6.0)
	assert_almost_eq(synchronized.get_sync_stream_volume(31), -6.0, 0.001)
