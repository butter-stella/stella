extends GutTest
## Integration smoke test for the demo's @chapter structure.
## Runs the full tokenize → parse → diagnostics-surface pipeline against the
## actual demo.stla, asserting the chapters parse out as expected. Catches
## drift between demo and parser, and validates that issue #97 PR-A's
## chapter-grouping behavior survives a real production scenario.


const DEMO_PATH = "res://examples/demo/scenarios/demo.stla"
const DIALOGUE_VISIBILITY_REFERENCE_PATH = \
	"res://examples/demo/scenarios/dialogue_visibility.stla"
const DIALOGUE_CLEAR_REFERENCE_PATH = \
	"res://examples/demo/scenarios/dialogue_clear.stla"
const LOOP_SE_REFERENCE_PATH = "res://examples/demo/scenarios/loop_se.stla"
const BGM_REFERENCE_PATH = "res://examples/demo/scenarios/bgm_lifecycle.stla"
const BGM_RESOURCE_PATH = "res://examples/demo/audio/bgm/synthetic_bgm.tres"
const BGM_STEM_RESOURCE_PATH = \
	"res://examples/demo/audio/bgm/synthetic_bgm_stems.tres"


func _parse_demo() -> ScenarioData:
	var file = FileAccess.open(DEMO_PATH, FileAccess.READ)
	assert_not_null(file, "demo.stla should exist at " + DEMO_PATH)
	var source = file.get_as_text()
	file.close()
	var tokens = DslLexer.tokenize(source)
	return DslParser.parse(tokens, "demo")


func _profile_groups(value: Variant) -> Array[String]:
	var result: Array[String] = []
	if value is Array or value is PackedStringArray:
		for item: Variant in value:
			result.append(String(item))
	return result


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


func test_dialogue_visibility_public_reference_parses_without_private_content() -> void:
	assert_true(FileAccess.file_exists(DIALOGUE_VISIBILITY_REFERENCE_PATH),
		"issue #166 publishes one redistributable reference scenario")
	if not FileAccess.file_exists(DIALOGUE_VISIBILITY_REFERENCE_PATH):
		return
	var file := FileAccess.open(
		DIALOGUE_VISIBILITY_REFERENCE_PATH, FileAccess.READ)
	assert_not_null(file)
	if file == null:
		return
	var source := file.get_as_text()
	file.close()
	var data := DslParser.parse(
		DslLexer.tokenize(source),
		"dialogue_visibility_demo",
		DIALOGUE_VISIBILITY_REFERENCE_PATH,
	)
	assert_eq(data.diagnostics, [], str(data.diagnostics))
	assert_not_null(data.get_chapter("dialogue_visibility_demo"))
	var scene := data.get_scene("dialogue_visibility_start")
	assert_not_null(scene)
	assert_true("@presentation_batch" in source)
	assert_true("@dialogue_visibility hide" in source)
	assert_true("@dialogue_visibility show" in source)
	assert_true("@dialogue_visibility quick_menu" in source)
	assert_false("@dialogue_visibility surface" in source,
		"public surface examples use the shortest canonical spelling")
	var message := data.get_dialogue_profile("message")
	var novel := data.get_dialogue_profile("novel")
	assert_eq(_profile_groups(message.get("surface_groups", [])), [
		"dialogue_surface",
	])
	assert_eq(_profile_groups(message.get("quick_menu_groups", [])), [
		"quick_menu",
	])
	assert_eq(_profile_groups(novel.get("surface_groups", [])), [
		"dialogue_surface",
	])
	assert_eq(_profile_groups(novel.get("quick_menu_groups", [])), [
		"quick_menu",
	])
	if scene == null:
		return
	var batches: Array[CommandData] = []
	for command_value: Variant in scene.commands:
		var command: CommandData = command_value
		if command.type == "presentation_batch":
			batches.append(command)
	assert_eq(batches.size(), 6,
		"public reference compiles six exact generic batches")
	if batches.size() != 6:
		return
	assert_eq(batches.map(func(batch: CommandData) -> int:
		return batch.declared_line), [14, 22, 27, 28, 31, 35])
	assert_eq(batches.map(func(batch: CommandData) -> Array:
		return batch.params.get("operation_lines", [])), [
		[15, 16, 17, 18], [23, 24], [27], [28], [32], [36, 37],
	])
	assert_eq(batches.map(func(batch: CommandData) -> String:
		return batch.get_string("policy")), [
		"join", "join", "join", "join", "join", "join",
	])
	assert_eq(batches.map(func(batch: CommandData) -> Array:
		return (batch.params.get("operations", []) as Array).map(
			func(operation: Dictionary) -> String:
				return String(operation.get("kind", ""))
		)), [
		["dialogue_visibility", "chapter_indicator",
			"dialogue_visibility", "stage"],
		["dialogue_visibility", "dialogue_visibility"],
		["dialogue_visibility"],
		["dialogue_visibility"],
		["dialogue_visibility"],
		["dialogue_visibility", "stage"],
	])
	var first_chapter: Dictionary = batches[0].params["operations"][1]["payload"]
	assert_eq(first_chapter, {
		"action": "show", "transition": "fade", "duration": 0.3,
	})
	var expected_visibility := [
		["surface", "hide", "fade", 0.3],
		["quick_menu", "hide", "fade", 0.3],
		["surface", "show", "fade", 0.2],
		["quick_menu", "show", "fade", 0.2],
		["surface", "hide", "fade", 0.2],
		["surface", "show", "fade", 0.2],
		["quick_menu", "hide", "fade", 0.2],
		["quick_menu", "show", "fade", 0.2],
	]
	var actual_visibility: Array = []
	for batch: CommandData in batches:
		for operation_value: Variant in batch.params["operations"]:
			var operation: Dictionary = operation_value
			if String(operation.get("kind", "")) != "dialogue_visibility":
				continue
			var payload: Dictionary = operation.get("payload", {})
			actual_visibility.append([
				payload.get("target"), payload.get("action"),
				payload.get("transition"), payload.get("duration"),
			])
	assert_eq(actual_visibility, expected_visibility)
	var first_stage: Dictionary = batches[0].params["operations"][3]["payload"]
	assert_eq(first_stage.get("action"), "update")
	assert_eq(first_stage.get("transition"), "move")
	assert_eq(first_stage.get("duration"), 0.3)
	var clear_stage: Dictionary = batches[5].params["operations"][1]["payload"]
	assert_eq(clear_stage.get("action"), "clear")
	assert_eq(clear_stage.get("transition"), "fade")
	assert_eq(clear_stage.get("duration"), 0.2)


func test_dialogue_clear_public_reference_uses_only_short_canonical_syntax() -> void:
	assert_true(FileAccess.file_exists(DIALOGUE_CLEAR_REFERENCE_PATH),
		"issue #169 publishes one redistributable reference scenario")
	if not FileAccess.file_exists(DIALOGUE_CLEAR_REFERENCE_PATH):
		return
	var file := FileAccess.open(DIALOGUE_CLEAR_REFERENCE_PATH, FileAccess.READ)
	assert_not_null(file)
	if file == null:
		return
	var source := file.get_as_text()
	file.close()
	var data := DslParser.parse(
		DslLexer.tokenize(source),
		"dialogue_clear_demo",
		DIALOGUE_CLEAR_REFERENCE_PATH,
	)
	assert_eq(data.diagnostics, [], str(data.diagnostics))
	assert_not_null(data.get_chapter("dialogue_clear_demo"))
	assert_not_null(data.get_scene("dialogue_clear_start"))
	assert_true("@dialogue_clear\n" in source)
	assert_true("  @dialogue_clear\n" in source)
	assert_false("@dialogue_clear " in source,
		"dialogue clear has no redundant options or compatibility grammar")
	var clear_children := 0
	for scene_value: Variant in data.scenes:
		for command_value: Variant in (scene_value as SceneData).commands:
			var command: CommandData = command_value
			if command.type != "presentation_batch":
				continue
			for operation_value: Variant in command.params.get("operations", []):
				if String((operation_value as Dictionary).get("kind", "")) == "dialogue_clear":
					clear_children += 1
					assert_eq(
						(operation_value as Dictionary).get("payload"),
						{"scope": "page"},
					)
	assert_eq(clear_children, 2,
		"standalone and mixed forms compile through one canonical child")


func test_loop_se_public_reference_uses_canonical_named_channels() -> void:
	assert_true(FileAccess.file_exists(LOOP_SE_REFERENCE_PATH),
		"issue #167 publishes one redistributable reference scenario")
	if not FileAccess.file_exists(LOOP_SE_REFERENCE_PATH):
		return
	var file := FileAccess.open(LOOP_SE_REFERENCE_PATH, FileAccess.READ)
	assert_not_null(file)
	if file == null:
		return
	var source := file.get_as_text()
	file.close()
	var data := DslParser.parse(
		DslLexer.tokenize(source),
		"loop_se_demo",
		LOOP_SE_REFERENCE_PATH,
	)
	assert_eq(data.diagnostics, [], str(data.diagnostics))
	assert_not_null(data.get_chapter("loop_se_demo"))
	var scene := data.get_scene("loop_se_start")
	assert_not_null(scene)
	if scene == null:
		return
	var batches: Array[CommandData] = []
	for command_value: Variant in scene.commands:
		var command: CommandData = command_value
		if command.type == "presentation_batch":
			batches.append(command)
	assert_eq(batches.size(), 4)
	if batches.size() != 4:
		return
	assert_eq(batches.map(func(batch: CommandData) -> String:
		return batch.get_string("policy")), [
		"fire_and_forget", "fire_and_forget", "fire_and_forget", "join",
	])
	assert_eq(batches.map(func(batch: CommandData) -> Array:
		return batch.params.get("operation_lines", [])), [[6], [7], [11], [16, 17]])
	var first_payload: Dictionary = batches[0].params["operations"][0]["payload"]
	var detail_payload: Dictionary = batches[1].params["operations"][0]["payload"]
	var volume_payload: Dictionary = batches[2].params["operations"][0]["payload"]
	assert_eq(first_payload.get("channel"), "ambience")
	assert_eq(first_payload.get("asset"), "se_select")
	assert_eq(detail_payload.get("channel"), "detail")
	assert_eq(detail_payload.get("asset"), "se_cancel")
	assert_eq(volume_payload.get("channel"), "ambience")
	assert_eq(volume_payload.get("asset"), "se_select")
	assert_eq(volume_payload.get("volume"), 0.08)
	var stop_channels: Array[String] = []
	for operation_value: Variant in batches[3].params["operations"]:
		var payload: Dictionary = (operation_value as Dictionary)["payload"]
		assert_eq(payload.get("action"), "stop")
		stop_channels.append(String(payload.get("channel", "")))
	assert_eq(stop_channels, ["ambience", "detail"])


func test_bgm_public_reference_uses_canonical_lifecycle_and_cues() -> void:
	assert_true(FileAccess.file_exists(BGM_REFERENCE_PATH),
		"issue #168 publishes one redistributable reference scenario")
	assert_true(ResourceLoader.exists(BGM_RESOURCE_PATH))
	assert_true(ResourceLoader.exists(BGM_STEM_RESOURCE_PATH))
	if not FileAccess.file_exists(BGM_REFERENCE_PATH):
		return
	var file := FileAccess.open(BGM_REFERENCE_PATH, FileAccess.READ)
	assert_not_null(file)
	if file == null:
		return
	var source := file.get_as_text()
	file.close()
	var data := DslParser.parse(
		DslLexer.tokenize(source), "bgm_lifecycle_demo", BGM_REFERENCE_PATH)
	assert_eq(data.diagnostics, [], str(data.diagnostics))
	var scene := data.get_scene("bgm_lifecycle_start")
	assert_not_null(scene)
	if scene == null:
		return
	var batches: Array[CommandData] = []
	for command_value: Variant in scene.commands:
		var command: CommandData = command_value
		if command.type == "presentation_batch":
			batches.append(command)
	assert_eq(batches.size(), 7)
	if batches.size() != 7:
		return
	assert_eq(batches.map(func(batch: CommandData) -> String:
		return batch.get_string("policy")), [
		"fire_and_forget", "join", "fire_and_forget", "join",
		"fire_and_forget", "join", "join",
	])
	assert_eq(batches.map(func(batch: CommandData) -> Array:
		return (batch.params.get("operations", []) as Array).map(
			func(operation: Dictionary) -> String:
				return String(operation.get("kind", "")))), [
		["bgm"], ["bgm"], ["bgm"], ["bgm", "stage"], ["bgm"],
		["bgm"], ["bgm", "stage"],
	])
	var first: Dictionary = batches[0].params["operations"][0]["payload"]
	assert_eq(first.get("action"), "play")
	assert_eq(first.get("asset"), "synthetic_bgm")
	assert_eq(first.get("cue"), "opening")
	assert_eq(first.get("fade_duration"), 0.2)
	var track := ResourceLoader.load(BGM_RESOURCE_PATH) as BgmTrackDefinition
	assert_not_null(track)
	if track != null:
		assert_gt(track.stream.get_length(), 0.0)
		assert_eq(track.cues.map(func(cue: BgmCueDefinition) -> String:
			return cue.cue_name), ["opening", "bridge", "finale"])
	var stems := ResourceLoader.load(
		BGM_STEM_RESOURCE_PATH) as BgmTrackDefinition
	assert_not_null(stems)
	if stems != null:
		assert_null(stems.stream)
		assert_eq(stems.stems.map(func(stem: BgmStemDefinition) -> String:
			return stem.stem_name), ["rhythm", "harmony"])
		assert_eq(batches[5].params["operations"][0]["payload"]["action"], "mix")
