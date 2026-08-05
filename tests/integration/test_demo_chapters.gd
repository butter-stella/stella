extends GutTest
## Integration smoke test for the demo's @chapter structure.
## Runs the full tokenize → parse → diagnostics-surface pipeline against the
## actual demo.stla, asserting the chapters parse out as expected. Catches
## drift between demo and parser, and validates that issue #97 PR-A's
## chapter-grouping behavior survives a real production scenario.


const DEMO_PATH = "res://examples/demo/scenarios/demo.stla"


func _parse_demo() -> ScenarioData:
	var file = FileAccess.open(DEMO_PATH, FileAccess.READ)
	assert_not_null(file, "demo.stla should exist at " + DEMO_PATH)
	var source = file.get_as_text()
	file.close()
	var tokens = DslLexer.tokenize(source)
	return DslParser.parse(tokens, "demo")


func test_demo_parses_with_no_diagnostics():
	# After PR-A, the demo MUST be well-formed (no parser errors / warnings).
	var data = _parse_demo()
	if data.diagnostics.size() > 0:
		var msgs = []
		for d in data.diagnostics:
			msgs.append("[%s line %d] %s" % [d.get("level"), d.get("line"), d.get("message")])
		fail_test("demo.stla parsed with diagnostics:\n  " + "\n  ".join(msgs))


func test_demo_has_expected_chapters():
	var data = _parse_demo()
	var expected_ids = [
		"prologue",
		"campus_tour",
		"cafe_chapter",
		"alone_chapter",
		"ending_chapter",
	]
	assert_eq(data.chapters.size(), expected_ids.size(),
		"demo should declare %d chapters" % expected_ids.size())
	for i in range(expected_ids.size()):
		if i < data.chapters.size():
			assert_eq(data.chapters[i].id, expected_ids[i],
				"chapter index %d should be '%s'" % [i, expected_ids[i]])


func test_demo_campus_tour_owns_internal_scenes():
	# campus_tour groups tour + praise_senpai + thank_senpai (the latter two
	# are "internal" scenes that won't appear on the player flowchart).
	var data = _parse_demo()
	var ch = data.get_chapter("campus_tour")
	assert_not_null(ch, "campus_tour chapter should exist")
	assert_true(ch.scene_ids.has("tour"))
	assert_true(ch.scene_ids.has("praise_senpai"))
	assert_true(ch.scene_ids.has("thank_senpai"))


func test_demo_every_scene_has_chapter_id():
	# Issue #97: 强制规范化 — no orphan scenes in production demo.
	var data = _parse_demo()
	for scene in data.scenes:
		# Skip synthetic @if scenes — they get chapter_id from a different
		# code path covered by parser unit tests.
		if scene.id.begins_with("__if_"):
			continue
		assert_ne(scene.chapter_id, "",
			"scene '%s' should have a non-empty chapter_id" % scene.id)


func test_demo_cafe_flash_is_a_real_command_before_combined_dialogue():
	var data = _parse_demo()
	var cafe = data.get_scene("cafe")
	assert_not_null(cafe, "demo should contain the cafe scene")
	if cafe == null:
		return

	var flash_index := -1
	var combine_index := -1
	for i in range(cafe.commands.size()):
		var cmd: CommandData = cafe.commands[i]
		if cmd.type == "effect" and cmd.get_string("effect_type") == "flash":
			flash_index = i
			assert_eq(cmd.get_string("color"), "white")
			assert_almost_eq(cmd.get_float("duration"), 0.18, 0.001)
		elif cmd.type == "dialogue" and cmd.params.get("segments", []).size() > 1:
			combine_index = i

	assert_gte(flash_index, 0, "demo flash must survive parsing")
	assert_gte(combine_index, 0, "demo should contain the combined dialogue")
	assert_lt(flash_index, combine_index, "flash should play when the combined line begins")
