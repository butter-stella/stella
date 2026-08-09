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
	assert_eq(parsed["visible_length"], 9)
	assert_eq(parsed["markers"], [{"expression": "sad", "at_char": 8}])
	assert_true(parsed["warnings"].is_empty())


func test_malformed_explicit_avatar_marker_is_reported():
	var parsed := ExpressionTimeline.parse_inline_annotations("A[expr:]B")
	assert_eq(parsed["clean_text"], "A[expr:]B")
	assert_true(parsed["markers"].is_empty())
	assert_eq(parsed["warnings"].size(), 1)
