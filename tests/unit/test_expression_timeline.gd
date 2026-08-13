extends GutTest
## Tests for ExpressionTimeline — voice/text-driven expression switching.


func test_extract_inline_expressions():
	var et = ExpressionTimeline.new()
	var result = et.extract_from_text("我本来很开心的...[expr:surprised]但是...[expr:cry]呜呜...")

	assert_eq(result["clean_text"], "我本来很开心的...但是...呜呜...")
	assert_eq(result["markers"].size(), 2)
	assert_eq(result["markers"][0]["expression"], "surprised")
	assert_eq(result["markers"][0]["at_char"], 10)
	assert_eq(result["markers"][1]["expression"], "cry")
	assert_eq(result["markers"][1]["at_char"], 15)


func test_no_inline_expressions():
	var et = ExpressionTimeline.new()
	var result = et.extract_from_text("普通的对话文本。")

	assert_eq(result["clean_text"], "普通的对话文本。")
	assert_eq(result["markers"].size(), 0)


func test_single_expression():
	var et = ExpressionTimeline.new()
	var result = et.extract_from_text("你好...[expr:sad]再见。")

	assert_eq(result["clean_text"], "你好...再见。")
	assert_eq(result["markers"].size(), 1)
	assert_eq(result["markers"][0]["expression"], "sad")
	assert_eq(result["markers"][0]["at_char"], 5)


func test_expression_at_start():
	var et = ExpressionTimeline.new()
	var result = et.extract_from_text("[expr:angry]我生气了！")

	assert_eq(result["clean_text"], "我生气了！")
	assert_eq(result["markers"][0]["expression"], "angry")
	assert_eq(result["markers"][0]["at_char"], 0)


func test_get_expression_at_char():
	var et = ExpressionTimeline.new()
	et.markers = [
		{"expression": "smile", "at_char": 0},
		{"expression": "surprised", "at_char": 10},
		{"expression": "cry", "at_char": 20},
	]

	assert_eq(et.get_expression_at_char(0), "smile")
	assert_eq(et.get_expression_at_char(5), "smile")
	assert_eq(et.get_expression_at_char(10), "surprised")
	assert_eq(et.get_expression_at_char(15), "surprised")
	assert_eq(et.get_expression_at_char(20), "cry")
	assert_eq(et.get_expression_at_char(30), "cry")


func test_get_expression_at_char_empty():
	var et = ExpressionTimeline.new()
	assert_eq(et.get_expression_at_char(5), "")


func test_get_expression_at_char_before_first():
	var et = ExpressionTimeline.new()
	et.markers = [{"expression": "smile", "at_char": 5}]
	assert_eq(et.get_expression_at_char(3), "")


func test_invalid_effect_is_visible_and_does_not_parse_nested_avatar_marker():
	var parsed := ExpressionTimeline.parse_inline_annotations(
		"a{wait:[expr:sad]}b{speed:fast}c"
	)
	assert_eq(parsed["clean_text"], "a{wait:[expr:sad]}b{speed:fast}c")
	assert_true(parsed["markers"].is_empty())
	assert_true(parsed["effects"].is_empty())
	assert_eq(parsed["warnings"].size(), 2)


func test_explicit_avatar_marker_does_not_consume_literal_brackets():
	var parsed := ExpressionTimeline.parse_inline_annotations(
		"[b]A[/b][expr:sad]B"
	)
	assert_eq(parsed["clean_text"], "[b]A[/b]B")
	assert_eq(parsed["visible_text"], "[b]A[/b]B")
	assert_eq(parsed["visible_length"], 2)
	assert_eq(parsed["markers"], [{
		"expression": "sad",
		"at_char": 1,
		"source_offset": 8,
	}])
	assert_true(parsed["warnings"].is_empty())


func test_legacy_bare_avatar_marker_is_literal_text() -> void:
	var parsed := ExpressionTimeline.parse_inline_annotations("A[happy]B")

	assert_eq(parsed["clean_text"], "A[happy]B")
	assert_true(parsed["markers"].is_empty())
	assert_true(parsed["warnings"].is_empty())


func test_malformed_explicit_avatar_marker_is_reported():
	var parsed := ExpressionTimeline.parse_inline_annotations("A[expr:]B")
	assert_eq(parsed["clean_text"], "A[expr:]B")
	assert_true(parsed["markers"].is_empty())
	assert_eq(parsed["warnings"].size(), 1)


func test_builtin_bbcode_survives_expression_extraction():
	var result := ExpressionTimeline.new().extract_from_text(
		"[indent]A[/indent][ul]B[/ul][right]C[/right][expr:happy]D")

	assert_eq(
		result["clean_text"],
		"[indent]A[/indent][ul]B[/ul][right]C[/right]D",
	)
	assert_eq(result["markers"].size(), 1)
	assert_eq(result["markers"][0]["expression"], "happy")


func test_registered_custom_effect_distinguishes_options_from_literal_main_value():
	var registered_effect_names := {"custom": true}
	var result := ExpressionTimeline.new().extract_from_text(
		"[custom]A[/custom]"
		+ "[custom=2]B[/custom]"
		+ "[custom amp=2]C[/custom]"
		+ "[unknown]D[unknown amp=2]E[/unknown]"
		+ "[expr:happy]F",
		registered_effect_names,
	)

	assert_eq(
		result["clean_text"],
		"[custom]A[/custom]"
			+ "[custom=2]B[/custom]"
			+ "[custom amp=2]C[/custom]"
			+ "[unknown]D[unknown amp=2]E[/unknown]F",
		"registered effects and literal unknown tags survive explicit expression extraction",
	)
	assert_eq(result["markers"].size(), 1)
	assert_eq(result["markers"][0]["expression"], "happy")
	assert_true(ExpressionTimeline.is_godot_bbcode_tag(
		"custom", registered_effect_names))
	assert_false(ExpressionTimeline.is_godot_bbcode_tag(
		"custom=2", registered_effect_names))
	assert_true(ExpressionTimeline.is_registered_effect_main_value_literal(
		"custom=2", registered_effect_names))
	assert_true(ExpressionTimeline.is_godot_bbcode_tag(
		"custom amp=2", registered_effect_names))
	assert_false(ExpressionTimeline.is_godot_bbcode_tag(
		"customized", registered_effect_names))
	assert_false(ExpressionTimeline.is_godot_bbcode_tag(
		"unknown", registered_effect_names))


func test_godot_46_bbcode_opening_tag_recognition_is_exact():
	assert_true(ExpressionTimeline.is_godot_bbcode_tag("right"))
	assert_false(ExpressionTimeline.is_godot_bbcode_tag("right bogus"),
		"Godot does not recognize option blocks on [right]")
	assert_true(ExpressionTimeline.is_godot_bbcode_tag("p align=right"))
	assert_true(ExpressionTimeline.is_godot_bbcode_tag("ol type=I"))
	assert_false(ExpressionTimeline.is_godot_bbcode_tag("ol type=z"))
	# Godot 4.6 itself uses broad begins_with checks for these tags.
	assert_true(ExpressionTimeline.is_godot_bbcode_tag("hrbogus"))
	assert_true(ExpressionTimeline.is_godot_bbcode_tag("imgbogus"))
	assert_true(ExpressionTimeline.is_godot_bbcode_tag("dropcapbogus"))
	assert_false(ExpressionTimeline.is_godot_bbcode_tag("fontbogus"),
		"Godot only accepts font= or a font option block")
	var invalid_font := ExpressionTimeline.new().extract_from_text(
		"[fontbogus]A[/font][expr:happy]B")
	assert_eq(invalid_font["clean_text"], "[fontbogus]A[/font]B")
	assert_eq(invalid_font["markers"].size(), 1)
	assert_eq(invalid_font["markers"][0]["expression"], "happy")


func test_bbcode_bracket_search_matches_godot_46_quote_rules():
	var quoted := "[p note='a]b' align=right]"
	assert_eq(
		ExpressionTimeline.find_unquoted_closing_bracket(quoted, 1),
		quoted.length() - 1,
		"] inside a quoted option is data",
	)
	# Godot 4.6's _find_unquoted does not give backslash special meaning. The
	# quote after the slash closes the value, so the following ] ends the tag.
	var backslash_quote := "[p note=\"a\\\"]b\" align=right]"
	assert_eq(
		ExpressionTimeline.find_unquoted_closing_bracket(backslash_quote, 1),
		backslash_quote.find("]"),
		"backslash-escaped quotes intentionally follow Godot's raw quote toggle",
	)
