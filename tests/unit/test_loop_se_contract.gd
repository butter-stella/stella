extends GutTest
## Synthetic parser and canonical-state contract for issue #167.

const SOURCE_PATH := "res://tests/fixtures/scenarios/audio/loop_se_contract.stla"


func _parse(source: String) -> ScenarioData:
	return DslParser.parse(
		DslLexer.tokenize(source),
		"loop_se_contract",
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


func test_one_shot_se_stays_short_and_rejects_false_loop_or_asset_stop() -> void:
	assert_false(SignalBus.has_signal(&"se_stop"),
		"one-shot audio exposes no asset-addressed stop authority")
	var valid := _parse("""@chapter synthetic
@scene start
@se click""")
	assert_eq(_errors(valid), [], str(valid.diagnostics))
	assert_eq(_commands(valid).size(), 1)
	assert_eq(_commands(valid)[0].type, "se")
	assert_eq(_commands(valid)[0].params, {"asset": "click"})

	for invalid_source: String in ["@se rain loop", "@se rain off", "@se"]:
		var invalid := _parse("@chapter synthetic\n@scene start\n" + invalid_source)
		assert_eq(_commands(invalid), [], invalid_source)
		assert_eq(_errors(invalid).size(), 1, invalid_source)
		assert_true("@loop_se" in String(_errors(invalid)[0].get("message", "")))
		assert_eq(int(_errors(invalid)[0].get("line", 0)), 3)


func test_standalone_play_and_stop_lower_to_single_fire_and_forget_children() -> void:
	var data := _parse("""@chapter synthetic
@scene start
@loop_se ambience play rain
@loop_se ambience stop fade=0.75""")
	assert_eq(_errors(data), [], str(data.diagnostics))
	var commands := _commands(data)
	assert_eq(commands.size(), 2)
	if commands.size() != 2:
		return
	for command: CommandData in commands:
		assert_eq(command.type, "presentation_batch")
		assert_eq(command.get_string("policy"), "fire_and_forget")
		assert_eq(command.params["operation_lines"], [command.declared_line])
		assert_eq(command.params["operations"].size(), 1)
		assert_eq(command.params["operations"][0]["kind"], "loop_se")
	assert_eq(commands[0].params["operations"][0]["payload"], {
		"action": "play",
		"asset": "rain",
		"channel": "ambience",
		"fade_duration": 0.0,
		"resume_position": 0.0,
		"volume": 1.0,
	})
	assert_eq(commands[1].params["operations"][0]["payload"], {
		"action": "stop",
		"asset": "",
		"channel": "ambience",
		"fade_duration": 0.75,
		"resume_position": 0.0,
		"volume": 1.0,
	})


func test_mixed_presentation_batch_reuses_canonical_child_and_authored_policy() -> void:
	var data := _parse("""@chapter synthetic
@scene start
@presentation_batch policy=join
  @dialogue_visibility hide transition=fade duration=0.5
  @loop_se crowd play crowd_tone volume=0.4 fade=0.5
  @stage light show asset=stage:light transition=fade duration=0.5
@end""")
	assert_eq(_errors(data), [], str(data.diagnostics))
	var commands := _commands(data)
	assert_eq(commands.size(), 1)
	if commands.size() != 1:
		return
	var command := commands[0]
	assert_eq(command.type, "presentation_batch")
	assert_eq(command.get_string("policy"), "join")
	assert_eq(command.params["operation_lines"], [4, 5, 6])
	assert_eq(command.params["operations"].map(
		func(operation: Dictionary) -> String:
			return String(operation.get("kind", ""))
	), ["dialogue_visibility", "loop_se", "stage"])
	assert_eq(command.params["operations"][1]["payload"]["volume"], 0.4)


func test_duplicate_channel_and_closed_options_fail_at_authored_line() -> void:
	var duplicate := _parse("""@chapter synthetic
@scene start
@presentation_batch policy=join
  @loop_se weather play rain
  @loop_se weather stop fade=1
@end""")
	assert_eq(_commands(duplicate), [])
	assert_eq(_errors(duplicate).size(), 1, str(duplicate.diagnostics))
	assert_eq(int(_errors(duplicate)[0].get("line", 0)), 5)
	assert_true("duplicate loop-SE channel" in String(
		_errors(duplicate)[0].get("message", "")))

	var cases := [
		{"line": "@loop_se bad:id play rain", "message": "channel"},
		{"line": "@loop_se ambience PLAY rain", "message": "action"},
		{"line": "@loop_se ambience play", "message": "asset"},
		{"line": "@loop_se ambience play rain volume=1.1", "message": "volume"},
		{"line": "@loop_se ambience stop volume=1", "message": "does not accept"},
		{"line": "@loop_se ambience stop fade=-1", "message": "fade"},
		{"line": "@loop_se ambience play rain policy=join", "message": "unknown"},
	]
	for case: Dictionary in cases:
		var data := _parse("@chapter synthetic\n@scene start\n" + String(case["line"]))
		assert_eq(_commands(data), [], String(case["line"]))
		assert_eq(_errors(data).size(), 1, String(case["line"]))
		if _errors(data).size() == 1:
			assert_eq(int(_errors(data)[0].get("line", 0)), 3)
			assert_true(String(case["message"]) in String(
				_errors(data)[0].get("message", "")), String(case["line"]))
			assert_true("%s:3" % SOURCE_PATH in String(
				_errors(data)[0].get("message", "")), String(case["line"]))


func test_channel_state_is_json_safe_addressed_and_position_is_not_target_identity() -> void:
	var play := {
		"action": "play",
		"asset": "synthetic_a",
		"channel": "ambience",
		"fade_duration": 0.5,
		"resume_position": 0.0,
		"volume": 0.6,
	}
	assert_true(LoopSeChannelState.validate_operation(play, false))
	var channels := LoopSeChannelState.reduce({}, [play], false)
	assert_eq(channels, {
		"ambience": {
			"asset": "synthetic_a",
			"loop": true,
			"position": 0.0,
			"volume": 0.6,
		},
	})
	assert_not_null(JSON.parse_string(JSON.stringify(channels)))
	var captured := LoopSeChannelState.with_positions(channels, {"ambience": 1.25})
	assert_false(LoopSeChannelState.operation_has_work(captured, play),
		"same asset+volume at a restored cursor must not duplicate playback")
	var volume_replace := play.duplicate(true)
	volume_replace["volume"] = 0.5
	assert_true(LoopSeChannelState.operation_has_work(captured, volume_replace))
	assert_eq(
		LoopSeChannelState.reduce(captured, [volume_replace], false)["ambience"]["position"],
		1.25,
		"same-asset volume reduction preserves the canonical playback cursor",
	)
	var asset_replace := play.duplicate(true)
	asset_replace["asset"] = "synthetic_b"
	assert_true(LoopSeChannelState.operation_has_work(captured, asset_replace))
	var stop := {
		"action": "stop", "asset": "", "channel": "ambience",
		"fade_duration": 1.0, "resume_position": 0.0, "volume": 1.0,
	}
	assert_true(LoopSeChannelState.operation_has_work(captured, stop))
	assert_eq(LoopSeChannelState.reduce(captured, [stop], false), {})
	assert_false(LoopSeChannelState.operation_has_work({}, stop),
		"stopping an absent stable channel is an idempotent no-op")


func test_loop_se_is_highlighted_and_has_no_legacy_editor_alias() -> void:
	var editor_script := load(
		"res://addons/stella/editor/stla_editor.gd") as Script
	assert_not_null(editor_script)
	if editor_script == null:
		return
	var editor := editor_script.new() as Control
	add_child_autofree(editor)
	var highlighter: CodeHighlighter = editor.get("_highlighter")
	assert_not_null(highlighter)
	if highlighter == null:
		return
	assert_true(highlighter.has_keyword_color("@loop_se"))
	assert_false(highlighter.has_keyword_color("@lse"))
	assert_false(highlighter.has_keyword_color("@loopse"))


func test_loop_se_fails_closed_in_combine_and_parallel() -> void:
	var combine := _parse("""@chapter synthetic
@scene start
@combine
  @loop_se ambience play rain
@end""")
	assert_eq(_commands(combine), [])
	assert_eq(_errors(combine).size(), 1, str(combine.diagnostics))
	assert_eq(int(_errors(combine)[0].get("line", 0)), 4)
	assert_true("not allowed inside @combine" in String(
		_errors(combine)[0].get("message", "")))

	var parallel := _parse("""@chapter synthetic
@scene start
@parallel
  @loop_se ambience play rain
@end""")
	assert_eq(_commands(parallel), [])
	assert_eq(_errors(parallel).size(), 1, str(parallel.diagnostics))
	assert_eq(int(_errors(parallel)[0].get("line", 0)), 4)
	assert_true("blocking 'presentation_batch'" in String(
		_errors(parallel)[0].get("message", "")))
