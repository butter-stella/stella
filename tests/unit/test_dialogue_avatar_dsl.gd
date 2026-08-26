extends GutTest

const SOURCE_PATH := "res://tests/fixtures/scenarios/dialogue/avatar_contract.stla"


func _parse(source: String) -> ScenarioData:
	return DslParser.parse(
		DslLexer.tokenize(source), "dialogue_avatar_contract", SOURCE_PATH)


func _errors(data: ScenarioData) -> Array:
	return data.diagnostics.filter(func(value: Dictionary) -> bool:
		return String(value.get("level", "")) == "error")


func test_standalone_show_lowers_to_join_typed_batch() -> void:
	var data := _parse("""@chapter c
@scene s
@dialogue_avatar show asset=character:portraits/red.png position=-280,-140 origin=-480,320 scale=0.45,0.45 z_index=12 opacity=0.8 transition=fade duration=0.3""")
	assert_true(_errors(data).is_empty(), str(data.diagnostics))
	var command: CommandData = data.scenes[0].commands[0]
	assert_eq(command.type, "presentation_batch")
	assert_eq(command.params["policy"], "join")
	assert_eq(command.params["operation_lines"], [3])
	assert_eq(command.params["operations"], [{
		"kind": "dialogue_avatar",
		"payload": {
			"action": "show",
			"properties": {
				"asset": "character:portraits/red.png",
				"position": [-280.0, -140.0],
				"origin": [-480.0, 320.0],
				"scale": [0.45, 0.45],
				"z_index": 12,
				"opacity": 0.8,
			},
			"transition": "fade",
			"duration": 0.3,
		},
	}])


func test_set_can_prepare_hidden_character_expression_state() -> void:
	var data := _parse("""@chapter c
@scene s
@dialogue_avatar set character=hero expression=neutral visible=false""")
	assert_true(_errors(data).is_empty(), str(data.diagnostics))
	var payload: Dictionary = data.scenes[0].commands[0].params["operations"][0]["payload"]
	assert_eq(payload["properties"], {
		"character": "hero",
		"expression": "neutral",
		"visible": false,
	})
	assert_eq(payload["transition"], "cut")
	assert_eq(payload["duration"], 0.0)


func test_fade_uses_clear_default_duration_and_cut_rejects_nonzero() -> void:
	var valid := _parse("""@chapter c
@scene s
@dialogue_avatar hide transition=fade""")
	assert_true(_errors(valid).is_empty(), str(valid.diagnostics))
	assert_eq(
		valid.scenes[0].commands[0].params["operations"][0]["payload"]["duration"],
		0.25,
	)
	var invalid := _parse("""@chapter c
@scene s
@dialogue_avatar hide transition=cut duration=0.1""")
	assert_eq(_errors(invalid).size(), 1)
	assert_true("%s:3" % SOURCE_PATH in String(_errors(invalid)[0]["message"]))


func test_unknown_source_alias_and_invalid_values_fail_at_authored_line() -> void:
	for source: String in [
		"@dialogue_avatar set xpos=-280",
		"@dialogue_avatar set showmode=0",
		"@dialogue_avatar show asset=red scale=0,1",
		"@dialogue_avatar show asset=red opacity=1.1",
		"@dialogue_avatar show asset=red transition=crossfade",
		"@dialogue_avatar remove asset=red",
	]:
		var data := _parse("@chapter c\n@scene s\n%s" % source)
		assert_eq(_errors(data).size(), 1, source)
		assert_eq(int(_errors(data)[0].get("line", -1)), 3, source)


func test_presentation_batch_accepts_one_avatar_and_rejects_duplicate_channel() -> void:
	var valid := _parse("""@chapter c
@scene s
@presentation_batch policy=fire_and_forget
@stage hero show asset=stage:red
@dialogue_avatar show asset=stage:blue
@dialogue_visibility hide
@end""")
	assert_true(_errors(valid).is_empty(), str(valid.diagnostics))
	var operations: Array = valid.scenes[0].commands[0].params["operations"]
	assert_eq(operations.map(func(value: Dictionary): return value["kind"]), [
		"stage", "dialogue_avatar", "dialogue_visibility",
	])
	var invalid := _parse("""@chapter c
@scene s
@presentation_batch policy=join
@dialogue_avatar show asset=stage:red
@dialogue_avatar set asset=stage:blue
@end""")
	assert_eq(_errors(invalid).size(), 1)
	assert_true("duplicate dialogue avatar" in String(_errors(invalid)[0]["message"]))


func test_combine_retains_one_authored_presentation_order_and_line_sidecar() -> void:
	var data := _parse("""@chapter c
@scene s
@combine
@stage hero show asset=stage:red
@dialogue_avatar set asset=stage:blue visible=false
hero「first」
@dialogue_avatar show transition=fade duration=0.3
@stage hero update opacity=0.5
hero「second」
@end""")
	assert_true(_errors(data).is_empty(), str(data.diagnostics))
	var segments: Array = data.scenes[0].commands[0].params["segments"]
	assert_eq(segments[0]["presentation_operation_lines"], [4, 5])
	assert_eq(segments[0]["presentation_ops"].map(
		func(value: Dictionary): return value["kind"]),
		["stage", "dialogue_avatar"],
	)
	assert_eq(segments[1]["presentation_operation_lines"], [7, 8])
	assert_eq(segments[1]["presentation_ops"].map(
		func(value: Dictionary): return value["kind"]),
		["dialogue_avatar", "stage"],
	)
	assert_false(segments[0].has("stage_ops"))
	assert_false(segments[0].has("stage_operation_lines"))
