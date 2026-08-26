extends GutTest
## Public canonical DSL and JSON-safe state contract for issue #179.

const SOURCE_PATH := "res://tests/fixtures/scenarios/movie_contract.stla"


func _parse(body: String) -> ScenarioData:
	return DslParser.parse(
		DslLexer.tokenize("@chapter movie\n@scene start\n" + body),
		"movie_contract",
		SOURCE_PATH,
	)


func _commands(data: ScenarioData) -> Array[CommandData]:
	var result: Array[CommandData] = []
	for scene_value: Variant in data.scenes:
		for command_value: Variant in (scene_value as SceneData).commands:
			result.append(command_value as CommandData)
	return result


func _errors(data: ScenarioData) -> Array:
	return data.diagnostics.filter(
		func(value: Dictionary) -> bool:
			return String(value.get("level", "")) == "error")


func test_short_movie_is_one_canonical_join_batch() -> void:
	var data := _parse("@movie intro\n")
	assert_eq(_errors(data), [], str(data.diagnostics))
	var commands := _commands(data)
	assert_eq(commands.size(), 1)
	if commands.size() != 1:
		return
	assert_eq(commands[0].type, "presentation_batch")
	assert_eq(commands[0].declared_line, 3)
	assert_eq(commands[0].params, {
		"policy": "join",
		"operations": [{
			"kind": "movie",
			"payload": {
				"action": "play",
				"asset": "intro",
				"loop": false,
				"skippable": true,
			},
		}],
		"operation_lines": [3],
	})


func test_stop_and_only_product_options_lower_without_action_noise() -> void:
	var data := _parse(
		"@movie stop\n"
		+ "@movie op skippable=false\n"
		+ "@movie attract loop=true policy=fire_and_forget\n")
	assert_eq(_errors(data), [], str(data.diagnostics))
	var commands := _commands(data)
	assert_eq(commands.size(), 3)
	if commands.size() != 3:
		return
	assert_eq(commands[0].params["operations"][0]["payload"], {
		"action": "stop", "asset": "", "loop": false, "skippable": true,
	})
	assert_eq(commands[1].params["operations"][0]["payload"], {
		"action": "play", "asset": "op", "loop": false, "skippable": false,
	})
	assert_eq(commands[2].params["policy"], "fire_and_forget")
	assert_true(commands[2].params["operations"][0]["payload"]["loop"])


func test_batch_child_inherits_policy_and_preserves_authored_order() -> void:
	var data := _parse("""@presentation_batch policy=fire_and_forget
  @stage screen show asset=stage:redraw_source transition=cut
  @movie ui/eyecatch loop=true skippable=false
@end
""")
	assert_eq(_errors(data), [], str(data.diagnostics))
	var commands := _commands(data)
	assert_eq(commands.size(), 1)
	if commands.size() != 1:
		return
	assert_eq(commands[0].params["operation_lines"], [4, 5])
	assert_eq(commands[0].params["operations"].map(
		func(operation: Dictionary) -> String:
			return String(operation["kind"])), ["stage", "movie"])
	assert_eq(commands[0].params["operations"][1]["payload"], {
		"action": "play",
		"asset": "ui/eyecatch",
		"loop": true,
		"skippable": false,
	})


func test_illegal_or_ambiguous_authoring_fails_at_exact_source_line() -> void:
	for authored: String in [
		"@movie",
		"@movie play intro",
		"@movie ../intro",
		"@movie intro loop=yes",
		"@movie intro loop=false loop=true",
		"@movie intro volume=0.5",
		"@movie intro loop=true",
		"@movie stop loop=false",
	]:
		var data := _parse(authored + "\n")
		assert_eq(_commands(data).size(), 0, authored)
		assert_eq(_errors(data).size(), 1, authored)
		if _errors(data).size() == 1:
			assert_eq(int(_errors(data)[0].get("line", 0)), 3, authored)
			assert_true("%s:3" % SOURCE_PATH in String(
				_errors(data)[0].get("message", "")), authored)

	var child_policy := _parse("""@presentation_batch policy=join
  @movie intro policy=fire_and_forget
@end
""")
	assert_eq(_commands(child_policy).size(), 0)
	assert_eq(_errors(child_policy).size(), 1)
	assert_eq(int(_errors(child_policy)[0].get("line", 0)), 4)


func test_typed_operation_and_snapshot_are_exact_and_defensive() -> void:
	var payload := {
		"action": "play", "asset": "op/main", "loop": false, "skippable": true,
	}
	var operation := MoviePresentationOperation.new(
		payload, {"source_path": SOURCE_PATH, "line": 7})
	assert_eq(operation.get_kind(), &"movie")
	assert_eq(operation.get_channel(), &"movie:main")
	assert_eq(operation.get_payload(), payload)
	payload["asset"] = "mutated"
	assert_eq(operation.get_payload()["asset"], "op/main")

	var state := MovieChannelState.state_for_play(
		"op/main", true, false, 2.0, 5.25)
	assert_eq(state, {
		"asset": "op/main",
		"length": 2.0,
		"loop": true,
		"position": 1.25,
		"skippable": false,
		"status": "playing",
	})
	assert_true(MovieChannelState.validate_snapshot_state(state, false))
	assert_false(MovieChannelState.validate_snapshot_state(
		state.merged({"position": 2.0}, true), false))
	assert_false(MovieChannelState.validate_snapshot_state(
		state.merged({"position": NAN}, true), false))
	assert_false(MovieChannelState.validate_snapshot_state(
		state.merged({"extra": true}, true), false))
