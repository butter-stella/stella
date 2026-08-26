extends GutTest
## Parser, typed payload, and stable-state contract for issue #168.

const SOURCE_PATH := "res://synthetic/bgm_contract.stla"


func _exported_property_names(resource: Resource) -> Array[StringName]:
	var result: Array[StringName] = []
	for property: Dictionary in resource.get_property_list():
		if int(property.get("usage", 0)) & PROPERTY_USAGE_SCRIPT_VARIABLE:
			result.append(property.get("name", &"") as StringName)
	return result


func _parse(source: String) -> ScenarioData:
	return DslParser.parse(
		DslLexer.tokenize(source),
		"bgm_contract",
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


func test_bgm_definition_contract_has_one_physical_end_sentinel() -> void:
	for resource: Resource in [BgmTrackDefinition.new(), BgmCueDefinition.new()]:
		var property_names := _exported_property_names(resource)
		assert_has(property_names, &"loop_end_position")
		assert_false(property_names.has(&"loop_end"))
		assert_false(property_names.has(&"end_position"))
		if not property_names.has(&"loop_end_position"):
			continue
		assert_eq(resource.get("loop_end_position"), -1.0,
			"-1.0 is the only canonical physical-stream-end sentinel")
		resource.set("loop_end_position", 0.55)
		assert_eq(resource.get("loop_end_position"), 0.55)


func test_standalone_actions_lower_to_canonical_fire_and_forget_children() -> void:
	var data := _parse("""@chapter synthetic
@scene start
@bgm play theme cue=p1 volume=0.65 fade=0.8
@bgm pause fade=0.2
@bgm resume
@bgm stop fade=1""")
	assert_eq(_errors(data), [], str(data.diagnostics))
	var commands := _commands(data)
	assert_eq(commands.size(), 4)
	if commands.size() != 4:
		return
	for command: CommandData in commands:
		assert_eq(command.type, "presentation_batch")
		assert_eq(command.get_string("policy"), "fire_and_forget")
		assert_eq(command.params["operation_lines"], [command.declared_line])
		assert_eq(command.params["operations"].size(), 1)
		assert_eq(command.params["operations"][0]["kind"], "bgm")
	assert_eq(commands[0].params["operations"][0]["payload"], {
		"action": "play", "asset": "theme", "cue": "p1",
		"fade_duration": 0.8, "resume_position": 0.0, "stem_mix": {},
		"volume": 0.65,
	})
	assert_eq(commands[1].params["operations"][0]["payload"], {
		"action": "pause", "asset": "", "cue": "",
		"fade_duration": 0.2, "resume_position": 0.0, "stem_mix": {},
		"volume": 1.0,
	})
	assert_eq(commands[2].params["operations"][0]["payload"]["fade_duration"], 0.0,
		"the new canonical grammar defaults every action to an immediate cut")
	assert_eq(commands[3].params["operations"][0]["payload"]["action"], "stop")


func test_join_reuses_the_same_child_parser_and_fixed_channel_is_unique() -> void:
	var data := _parse("""@chapter synthetic
@scene start
@presentation_batch policy=join
  @stage light show asset=stage:light transition=fade duration=0.5
  @bgm play theme fade=0.5
@end""")
	assert_eq(_errors(data), [], str(data.diagnostics))
	var commands := _commands(data)
	assert_eq(commands.size(), 1)
	if commands.size() != 1:
		return
	assert_eq(commands[0].params["operation_lines"], [4, 5])
	assert_eq(commands[0].params["operations"].map(
		func(operation: Dictionary) -> String:
			return String(operation.get("kind", ""))
	), ["stage", "bgm"])

	var duplicate := _parse("""@chapter synthetic
@scene start
@presentation_batch policy=join
  @bgm play a
  @bgm stop
@end""")
	assert_eq(_commands(duplicate), [])
	assert_eq(_errors(duplicate).size(), 1, str(duplicate.diagnostics))
	assert_eq(int(_errors(duplicate)[0].get("line", 0)), 5)
	assert_true("duplicate BGM channel" in String(
		_errors(duplicate)[0].get("message", "")))


func test_closed_grammar_and_removed_legacy_forms_fail_at_source_line() -> void:
	var cases := [
		{"line": "@bgm theme 1.0", "message": "legacy"},
		{"line": "@bgm off", "message": "legacy"},
		{"line": "@bgm PLAY theme", "message": "action"},
		{"line": "@bgm play", "message": "asset"},
		{"line": "@bgm play theme cue=bad:id", "message": "cue"},
		{"line": "@bgm play theme volume=1.1", "message": "volume"},
		{"line": "@bgm pause volume=1", "message": "does not accept"},
		{"line": "@bgm resume fade=-1", "message": "fade"},
		{"line": "@bgm stop fade=nan", "message": "finite"},
		{"line": "@bgm play theme fade=1 fade=2", "message": "duplicate"},
		{"line": "@bgm play theme policy=join", "message": "unknown"},
	]
	for case: Dictionary in cases:
		var data := _parse("@chapter synthetic\n@scene start\n" + String(case["line"]))
		assert_eq(_commands(data), [], String(case["line"]))
		assert_eq(_errors(data).size(), 1, String(case["line"]))
		if _errors(data).size() == 1:
			assert_eq(int(_errors(data)[0].get("line", 0)), 3)
			var message := String(_errors(data)[0].get("message", ""))
			assert_true(String(case["message"]) in message, String(case["line"]))
			assert_true("%s:3" % SOURCE_PATH in message, String(case["line"]))


func test_stable_state_distinguishes_status_cue_volume_loop_and_position() -> void:
	var playing := {
		"asset": "theme", "cue": "p1", "loop": true,
		"position": 2.25, "status": "playing", "stem_mix": {},
		"volume": 0.7,
	}
	assert_true(BgmChannelState.validate_snapshot_state({}, false))
	assert_true(BgmChannelState.validate_snapshot_state(playing, false))
	assert_not_null(JSON.parse_string(JSON.stringify(playing)))
	var play := {
		"action": "play", "asset": "theme", "cue": "p1",
		"fade_duration": 0.5, "resume_position": 0.0, "stem_mix": {},
		"volume": 0.7,
	}
	assert_false(BgmChannelState.operation_has_work(playing, play),
		"a restored cursor is not itself authored target work")
	var paused := playing.duplicate(true)
	paused["status"] = "paused"
	assert_true(BgmChannelState.operation_has_work(paused, play),
		"play from paused restarts at the authored cue")
	var pause := {
		"action": "pause", "asset": "", "cue": "",
		"fade_duration": 0.2, "resume_position": 0.0, "stem_mix": {},
		"volume": 1.0,
	}
	assert_true(BgmChannelState.operation_has_work(playing, pause))
	assert_false(BgmChannelState.operation_has_work(paused, pause))
	var resume := pause.duplicate(true)
	resume["action"] = "resume"
	assert_true(BgmChannelState.operation_has_work(paused, resume))
	assert_false(BgmChannelState.operation_has_work(playing, resume))
	assert_false(BgmChannelState.operation_is_supported({}, pause))
	assert_false(BgmChannelState.operation_is_supported({}, resume))


func test_bgm_is_not_allowed_in_parallel_or_combine() -> void:
	for block: String in ["parallel", "combine"]:
		var data := _parse("@chapter synthetic\n@scene start\n@%s\n  @bgm play theme\n@end" % block)
		assert_eq(_commands(data), [], block)
		assert_eq(_errors(data).size(), 1, str(data.diagnostics))
		assert_eq(int(_errors(data)[0].get("line", 0)), 4)


func test_semantic_fingerprint_uses_canonical_payload_not_source_layout() -> void:
	var implicit := _parse("""@chapter synthetic
@scene start
@bgm play theme""")
	var explicit := _parse("""@chapter synthetic
@scene start

@bgm play theme volume=1 fade=0""")
	assert_eq(implicit.content_fingerprint, explicit.content_fingerprint)
	for changed_command: String in [
		"@bgm play theme cue=intro",
		"@bgm play theme volume=0.5",
		"@bgm play theme fade=0.2",
		"@bgm stop",
	]:
		var changed := _parse(
			"@chapter synthetic\n@scene start\n" + changed_command)
		assert_ne(implicit.content_fingerprint, changed.content_fingerprint,
			changed_command)


func test_authored_transition_duration_matrix_is_preserved_exactly() -> void:
	var durations := [0.0, 0.2, 1.0, 3.0, 5.0, 8.0]
	for duration: float in durations:
		var data := _parse(
			"@chapter synthetic\n@scene start\n@bgm play theme fade=%s"
			% duration)
		assert_eq(_errors(data), [], str(duration))
		var commands := _commands(data)
		assert_eq(commands.size(), 1, str(duration))
		if commands.size() == 1:
			assert_eq(
				float(commands[0].params["operations"][0]["payload"]["fade_duration"]),
				duration,
				str(duration),
			)


func test_save_schema_accepts_only_exact_stable_dictionary_and_legacy_string_fails() -> void:
	var manager := SaveManager.new()
	var presentation_base := {
		"bg": "",
		"dialogue_visibility": DialogueVisibilityState.default_state(),
		"dialogue_content": PresentationState._inactive_dialogue_content(),
		"dialogue_avatar": DialogueAvatarState.default_state(),
	}
	var active := {
		"asset": "theme", "cue": "intro", "loop": false,
		"position": 1.25, "status": "paused", "stem_mix": {},
		"volume": 0.6,
	}
	assert_true(manager._presentation_snapshot_is_valid(
		presentation_base.merged({"bgm": {}}, true)))
	assert_true(manager._presentation_snapshot_is_valid(
		presentation_base.merged({"bgm": active}, true)))
	var previous_six_field := active.duplicate(true)
	previous_six_field.erase("stem_mix")
	assert_false(manager._presentation_snapshot_is_valid(presentation_base.merged({
		"bgm": previous_six_field,
	}, true)), "pre-stem saves require an explicit host migration; runtime has no legacy branch")
	assert_false(manager._presentation_snapshot_is_valid(presentation_base.merged({
		"bgm": "theme",
	}, true)), "unversioned legacy String saves fail closed; there is no runtime compatibility API")
	for invalid: Variant in [
		active.merged({"status": "fading"}, true),
		active.merged({"position": -1.0}, true),
		active.merged({"volume": INF}, true),
		active.merged({"extra": true}, true),
	]:
		assert_false(manager._presentation_snapshot_is_valid(
			presentation_base.merged({"bgm": invalid}, true)))
