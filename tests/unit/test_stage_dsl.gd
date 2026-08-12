extends GutTest


func _parse(source: String) -> ScenarioData:
	return DslParser.parse(DslLexer.tokenize(source), "stage_test")


func _has_diagnostic(
	data: ScenarioData,
	level: String,
	message_part: String,
) -> bool:
	for diagnostic in data.diagnostics:
		if (
			diagnostic.get("level") == level
			and message_part in String(diagnostic.get("message", ""))
		):
			return true
	return false


func _has_diagnostic_at_line(
	data: ScenarioData,
	message_part: String,
	line: int,
) -> bool:
	for diagnostic in data.diagnostics:
		if (
			message_part in String(diagnostic.get("message", ""))
			and int(diagnostic.get("line", -1)) == line
		):
			return true
	return false


func test_stage_show_and_update_parse_typed_properties():
	var data := _parse("""@chapter test
@scene start
@stage base show kind=background asset=background:room fit=cover z=-1000
@stage hero show kind=character body=stage:hero_body face=stage:smile x=960 y=120 origin=500,1000 scale=0.75 opacity=0.8 redraw=color_overlay(#2A5C8E40,soft_light) redraw=brightness_contrast(17,-24)
@stage hero update face=stage:sad transition=fade duration=0.3""")
	assert_eq(data.scenes[0].commands.size(), 3)
	var show_command: CommandData = data.scenes[0].commands[1]
	assert_eq(show_command.type, "stage_layer")
	assert_eq(show_command.get_string("action"), "show")
	assert_eq(show_command.get_string("id"), "hero")
	assert_eq(show_command.params["properties"]["origin"], [500.0, 1000.0])
	assert_almost_eq(show_command.params["properties"]["scale"], 0.75, 0.001)
	assert_eq(show_command.params["properties"]["redraw"], [
		{
			"type": "color_overlay",
			"color": "#2a5c8e40",
			"blend": "soft_light",
		},
		{"type": "brightness_contrast", "brightness": 17, "contrast": -24},
	])

	var update_command: CommandData = data.scenes[0].commands[2]
	assert_eq(update_command.get_string("action"), "update")
	assert_eq(update_command.params["properties"], {"face": "stage:sad"})
	assert_eq(update_command.get_string("transition"), "fade")
	assert_almost_eq(update_command.get_float("duration"), 0.3, 0.001)


func test_stage_clear_is_a_command_without_layer_id():
	var data := _parse("""@chapter test
@scene start
@stage clear""")
	var command: CommandData = data.scenes[0].commands[0]
	assert_eq(command.type, "stage_layer")
	assert_eq(command.get_string("action"), "clear")
	assert_eq(command.get_string("id"), "")


func test_stage_property_first_form_keeps_the_show_smart_default():
	var data := _parse("""@chapter test
@scene start
@stage hero asset=stage:hero position=10,20""")
	assert_true(data.diagnostics.is_empty(), str(data.diagnostics))
	assert_eq(data.scenes[0].commands.size(), 1)
	var command: CommandData = data.scenes[0].commands[0]
	assert_eq(command.get_string("action"), "show")
	assert_eq(command.get_string("id"), "hero")
	assert_eq(command.params["properties"]["asset"], "stage:hero")
	assert_eq(command.params["properties"]["position"], [10.0, 20.0])


func test_stage_rejects_invalid_typed_values_and_transition():
	var invalid_properties := [
		["x=abc", "x='abc'"],
		["position=1,bad", "position='1,bad'"],
		["opacity=NaN", "opacity='NaN'"],
		["visible=maybe", "visible='maybe'"],
		["fit=warp", "fit 'warp'"],
		["scale=0", "scale value"],
		["depth_scale=-1", "depth_scale value"],
		["z=99999", "z value"],
		["z=1.5", "z value"],
		["asset=", "asset cannot be empty"],
		["kind=", "kind cannot be empty"],
	]
	for invalid_case in invalid_properties:
		var argument: String = invalid_case[0]
		var message: String = invalid_case[1]
		var data := _parse("""@chapter test
@scene start
@stage hero show face=stage:must_not_apply %s""" % argument)
		assert_true(
			data.scenes[0].commands.is_empty(),
			"one invalid field must reject the complete operation: %s" % argument,
		)
		assert_true(_has_diagnostic_at_line(data, message, 3), argument)


func test_stage_rejects_invalid_timing_and_empty_keys_atomically():
	var invalid_arguments := [
		["transition=warp", "transition 'warp'"],
		["transition=", "transition ''"],
		["duration=-0.1", "finite non-negative"],
		["duration=bad", "finite non-negative"],
		["duration=NaN", "finite non-negative"],
		["duration=INF", "finite non-negative"],
		["=value", "property name cannot be empty"],
	]
	for invalid_case in invalid_arguments:
		var argument: String = invalid_case[0]
		var message: String = invalid_case[1]
		var data := _parse("""@chapter test
@scene start
@stage hero update face=stage:must_not_apply %s""" % argument)
		assert_true(data.scenes[0].commands.is_empty(), argument)
		assert_true(_has_diagnostic_at_line(data, message, 3), argument)


func test_stage_accepts_only_the_documented_canonical_spellings():
	var data := _parse("""@chapter test
@scene start
@stage hero show depth_scale=0.8 rotation=15 asset=none body=none face=none visible=true flip_x=false flip_y=true""")
	assert_true(data.diagnostics.is_empty(), str(data.diagnostics))
	assert_eq(data.scenes[0].commands.size(), 1)
	var properties: Dictionary = data.scenes[0].commands[0].params["properties"]
	assert_almost_eq(properties["depth_scale"], 0.8, 0.001)
	assert_eq(properties["rotation"], 15)
	assert_eq(properties["asset"], "")
	assert_eq(properties["body"], "")
	assert_eq(properties["face"], "")
	assert_true(properties["visible"])
	assert_false(properties["flip_x"])
	assert_true(properties["flip_y"])


func test_stage_rejects_undocumented_property_and_value_aliases():
	var aliases := [
		["depth=0.8", "unknown @stage property 'depth'"],
		["rotation_degrees=15", "unknown @stage property 'rotation_degrees'"],
		["asset=null", "use 'none'"],
		["asset=off", "use 'none'"],
		["body=null", "use 'none'"],
		["body=off", "use 'none'"],
		["face=null", "use 'none'"],
		["face=off", "use 'none'"],
		["visible=yes", "invalid boolean"],
		["visible=on", "invalid boolean"],
		["visible=1", "invalid boolean"],
		["visible=no", "invalid boolean"],
		["visible=off", "invalid boolean"],
		["visible=0", "invalid boolean"],
	]
	for alias_case in aliases:
		var argument: String = alias_case[0]
		var message: String = alias_case[1]
		var data := _parse("""@chapter test
@scene start
@stage hero show kind=character %s""" % argument)
		assert_true(data.scenes[0].commands.is_empty(), argument)
		assert_true(_has_diagnostic_at_line(data, message, 3), argument)


func test_stage_redraw_pipeline_is_ordered_typed_and_canonical():
	var data := _parse("""@chapter test
@scene start
@stage hero show redraw=color_overlay(#112233) redraw=clip(stage:synthetic_mask,-4.5,8) redraw=color_overlay(#44556680,soft_light) redraw=brightness_contrast(37,-12) redraw=grayscale(0.25) redraw=tint(#AABBCC) redraw=blur(2,3) redraw=blur(4,1)
@stage overlay show redraw=clip(background:synthetic_mask,0,0,cover)
@stage hero update redraw=clear""")
	assert_true(data.diagnostics.is_empty(), str(data.diagnostics))
	assert_eq(data.scenes[0].commands.size(), 3)
	var redraw: Array = data.scenes[0].commands[0].params["properties"]["redraw"]
	assert_eq(redraw, [
		{"type": "color_overlay", "color": "#112233ff", "blend": "normal"},
		{
			"type": "clip",
			"asset": "stage:synthetic_mask",
			"offset": [-4.5, 8.0],
			"fit": "native",
		},
		{
			"type": "color_overlay",
			"color": "#44556680",
			"blend": "soft_light",
		},
		{"type": "brightness_contrast", "brightness": 37, "contrast": -12},
		{"type": "grayscale", "amount": 0.25},
		{"type": "tint", "color": "#aabbccff"},
		{"type": "blur", "radius": [2, 3]},
		{"type": "blur", "radius": [4, 1]},
	])
	assert_eq(
		data.scenes[0].commands[1].params["properties"]["redraw"],
		[{
			"type": "clip",
			"asset": "background:synthetic_mask",
			"offset": [0.0, 0.0],
			"fit": "cover",
		}],
	)
	assert_eq(
		data.scenes[0].commands[2].params["properties"]["redraw"],
		[],
	)


func test_stage_rejects_duplicate_clip_effects():
	var redraw_tokens := (
		"redraw=clip(stage:synthetic_mask_a,0,0) "
		+ "redraw=clip(stage:synthetic_mask_b,0,0)"
	)
	var duplicate_data := _parse("""@chapter test
@scene start
@stage hero show %s""" % redraw_tokens)
	assert_true(duplicate_data.scenes[0].commands.is_empty(), redraw_tokens)
	assert_true(
		_has_diagnostic(duplicate_data, "error", "at most one clip"),
		redraw_tokens,
	)


func test_stage_rejects_invalid_redraw_effects_and_clear_mixing():
	var invalid_values := [
		"color_overlay(#2a5c8e40,20)",
		"color_overlay(4280966286)",
		"brightness_contrast(-256,0)",
		"brightness_contrast(0,101)",
		"brightness_contrast(1.5,0)",
		"grayscale(1.1)",
		"tint(red)",
		"blur(1.5,2)",
		"blur(33,0)",
		"clip(,0,0,native)",
		"clip(stage:synthetic_mask,0,0,tile)",
		"unknown_effect(-17,23)",
		"none",
		"off",
	]
	for invalid_value in invalid_values:
		var invalid_data := _parse("""@chapter test
@scene start
@stage hero show redraw=%s""" % invalid_value)
		assert_true(invalid_data.scenes[0].commands.is_empty(), invalid_value)
		assert_true(_has_diagnostic(invalid_data, "error", "redraw"), invalid_value)

	for mixed_values in [
		"redraw=clear redraw=brightness_contrast(0,0)",
		"redraw=brightness_contrast(0,0) redraw=clear",
		"redraw=clear redraw=clear",
	]:
		var mixed_data := _parse("""@chapter test
@scene start
@stage hero update %s""" % mixed_values)
		assert_true(mixed_data.scenes[0].commands.is_empty(), mixed_values)
		assert_true(_has_diagnostic(mixed_data, "error", "cannot be mixed"))


func test_stage_rejects_more_than_maximum_redraw_effects():
	var effects := ""
	for _index in range(StageLayerState.MAX_REDRAW_EFFECTS):
		effects += " redraw=grayscale(0.5)"
	var maximum_data := _parse("""@chapter test
@scene start
@stage hero show%s""" % effects)
	assert_eq(maximum_data.scenes[0].commands.size(), 1)
	assert_eq(
		maximum_data.scenes[0].commands[0].params["properties"]["redraw"].size(),
		StageLayerState.MAX_REDRAW_EFFECTS,
	)

	effects += " redraw=grayscale(0.5)"
	var data := _parse("""@chapter test
@scene start
@stage hero show%s""" % effects)
	assert_true(data.scenes[0].commands.is_empty())
	assert_true(_has_diagnostic(data, "error", "at most %d redraw effects" % StageLayerState.MAX_REDRAW_EFFECTS))


func test_stage_rejects_more_than_maximum_blur_passes():
	var effects := ""
	for _index in range(StageLayerState.MAX_BLUR_PASSES):
		effects += " redraw=blur(1,1)"
	var maximum_data := _parse("""@chapter test
@scene start
@stage hero show%s""" % effects)
	assert_eq(maximum_data.scenes[0].commands.size(), 1)

	effects += " redraw=blur(1,1)"
	var data := _parse("""@chapter test
@scene start
@stage hero show%s""" % effects)
	assert_true(data.scenes[0].commands.is_empty())
	assert_true(_has_diagnostic(
		data,
		"error",
		"at most %d blur effects" % StageLayerState.MAX_BLUR_PASSES,
	))


func test_unknown_directive_reports_an_error_without_a_runtime_command():
	var data := _parse("""@chapter test
@scene start
@teleport hero 10,20
@stage hero show asset=stage:hero""")
	assert_eq(data.scenes[0].commands.size(), 1)
	assert_eq(data.scenes[0].commands[0].type, "stage_layer")
	assert_true(_has_diagnostic(data, "error", "unknown command '@teleport'"))


func test_stage_rejects_unknown_and_action_incompatible_properties():
	var data := _parse("""@chapter test
@scene start
@stage hero show positon=1,2
@stage hero hide opacity=0.5
@stage hero remove face=stage:sad
@stage clear asset=stage:unused""")
	assert_true(data.scenes[0].commands.is_empty())
	assert_true(_has_diagnostic(data, "error", "unknown @stage property 'positon'"))
	assert_true(_has_diagnostic(data, "error", "hide does not accept"))
	assert_true(_has_diagnostic(data, "error", "remove does not accept"))
	assert_true(_has_diagnostic(data, "error", "clear does not accept"))


func test_combine_binds_stage_operations_to_the_next_segment_only():
	var data := _parse("""@chapter test
@scene start
@combine
@stage hero update face=stage:sad transition=fade duration=0.3
sakura「一」 #voice:v1
@stage event show asset=stage:flash z=20
@stage hero update face=stage:happy
sakura「二」 #voice:v2
@end""")
	var segments: Array = data.scenes[0].commands[0].params["segments"]
	assert_eq(segments.size(), 2)
	assert_eq(segments[0]["stage_ops"].size(), 1)
	assert_eq(segments[0]["stage_ops"][0]["id"], "hero")
	assert_eq(segments[1]["stage_ops"].size(), 2)
	assert_eq(segments[1]["stage_ops"][0]["id"], "event")
	assert_eq(segments[1]["stage_ops"][1]["properties"]["face"], "stage:happy")
	assert_eq(
		data.scenes[0].commands.size(),
		1,
		"stage cues inside combine must not execute as standalone commands",
	)


func test_combine_ignores_non_stage_directives_and_keeps_stage_only_schema():
	var data := _parse("""@chapter test
@scene start
@combine
@effect flash white 0.2
@stage hero update face=stage:sad
sakura「一」
@end""")
	var segments: Array = data.scenes[0].commands[0].params["segments"]
	assert_eq(segments.size(), 1)
	assert_false(segments[0].has("expression"))
	assert_eq(segments[0]["stage_ops"].size(), 1)
	assert_true(_has_diagnostic(data, "warning", "only @stage is allowed"))


func test_combine_rejects_monologue_without_rebinding_its_stage_cues():
	var data := _parse("""@chapter test
@scene start
@combine
@stage hero update face=stage:sad
sakura（这条独白不属于 combine。）
sakura「下一段。」
@end""")
	var segments: Array = data.scenes[0].commands[0].params["segments"]
	assert_eq(segments.size(), 1)
	assert_eq(segments[0]["text"], "下一段。")
	assert_true(segments[0]["stage_ops"].is_empty())
	assert_true(_has_diagnostic(data, "warning", "monologue is not allowed"))


func test_combine_stage_cues_keep_compiled_dialogue_profile():
	var data := _parse("""@dialogue_profile novel line_spacing=8
@chapter test
@scene start
@nvl profile=novel
@combine
@stage hero update face=stage:sad
「一」
@end""")
	var command: CommandData = data.scenes[0].commands[0]
	assert_eq(command.get_string("mode"), "nvl")
	assert_eq(command.get_string("presentation_profile_name"), "novel")
	assert_true(command.get_bool("declarative_presentation"))
	assert_eq(command.params["presentation_profile"]["line_spacing"], 8)
	assert_eq(command.params["segments"][0]["stage_ops"].size(), 1)


func test_combine_reports_stage_cue_without_following_segment():
	var data := _parse("""@chapter test
@scene start
@combine
sakura「一」
@stage hero update face=stage:sad
@end""")
	assert_true(_has_diagnostic(data, "warning", "not bound"))


func test_unclosed_combine_reports_source_line_error():
	var data := _parse("""@chapter test
@scene start
@combine
@stage hero show asset=stage:hero
「line」""")
	assert_true(_has_diagnostic(data, "error", "line 3 is missing @end"))


func test_unclosed_combine_cannot_consume_the_next_scene():
	var data := _parse("""@chapter test
@scene first
@combine
@stage stale show asset=stage:stale
「lost」
@scene second
「kept」""")
	assert_true(_has_diagnostic(data, "error", "before the next @scene"))
	assert_eq(data.scenes.size(), 2)
	assert_true(data.scenes[0].commands.is_empty())
	assert_eq(data.scenes[1].commands[0].get_string("text"), "kept")
