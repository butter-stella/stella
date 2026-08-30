extends GutTest
## Tests for DslParser — converting tokens into ScenarioData.

const ADVANCE_INDICATOR_TEXTURE_PATH := \
	"res://examples/demo/art/backgrounds/bg_black.png"
const ADVANCE_INDICATOR_SCENE_PATH := "res://addons/stella/scenes/game.tscn"
const AUTO_TIMING_PROFILE_PATH := "res://tests/fixtures/auto_timing_profile.tres"


func _parse(source: String, id: String = "test") -> ScenarioData:
	var tokens = DslLexer.tokenize(source)
	return DslParser.parse(tokens, id)


func _event_modes(events: Array) -> Array[String]:
	var modes: Array[String] = []
	for event in events:
		modes.append(str(event.get("mode", "adv")) if event is Dictionary else str(event))
	return modes


func test_empty_tokens():
	var data = _parse("")
	assert_eq(data.id, "test")
	assert_eq(data.scenes.size(), 0)
	assert_eq(data.source_identity, "")


func test_public_parser_assigns_source_identity_from_authored_path():
	var source_path := "res://extensions/review/../review/route.stla"
	var data := DslParser.parse(
		DslLexer.tokenize('@scene start "Start"'),
		"extension_route",
		source_path,
	)
	assert_eq(
		data.source_identity,
		ScenarioData.make_source_identity(source_path),
	)
	assert_true(data.source_identity.begins_with("stella-source-v1:sha256:"))
	assert_false(data.source_identity.contains("extensions"),
		"public parser identity must not copy the authored path")


func test_single_scene():
	var data = _parse('@scene start "序章"')
	assert_eq(data.scenes.size(), 1)
	assert_eq(data.scenes[0].id, "start")


func test_multiple_scenes():
	var data = _parse("""@scene start
@scene middle
@scene ending""")
	assert_eq(data.scenes.size(), 3)
	assert_eq(data.scenes[0].id, "start")
	assert_eq(data.scenes[1].id, "middle")
	assert_eq(data.scenes[2].id, "ending")


func test_dialogue_basic():
	var data = _parse("""@scene start
sakura「你好。」""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.type, "dialogue")
	assert_eq(cmd.get_string("character"), "sakura")
	assert_eq(cmd.get_string("text"), "你好。")
	assert_true(cmd.get_bool("presentation_from_context"))
	assert_false(cmd.has_param("mode"),
		"parser-produced dialogue presentation comes from the runtime path")


func test_dialogue_with_voice():
	var data = _parse("""@scene start
sakura「你好。」 #voice:sakura_001""")
	var cmd = data.scenes[0].commands[0]
	assert_eq_deep(cmd.params.get("voice_layers"), [{
		"id": "main", "asset": "sakura_001", "character": "sakura",
		"dsp": "", "line": 2,
	}])


func test_dialogue_voice_dsp_selection_is_canonical_and_source_located():
	var data = _parse("""@chapter test
@scene start
sakura「你好。」 #voice:sakura_001 #voice_dsp:remote""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(data.diagnostics, [])
	assert_eq_deep(cmd.params.get("voice_layers"), [{
		"id": "main", "asset": "sakura_001", "character": "sakura",
		"dsp": "remote", "line": 3,
	}])
	var reversed = _parse("""@chapter test
@scene start
sakura「你好。」 #voice_dsp:remote #voice:sakura_001""")
	assert_eq(reversed.diagnostics, [])
	assert_eq_deep(
		reversed.scenes[0].commands[0].params.get("voice_layers"),
		cmd.params.get("voice_layers"))


func test_dialogue_voice_dsp_metadata_fails_closed():
	var cases := [
		["sakura「一。」 #voice:v #voice_dsp:a #voice_dsp:b", "cannot be duplicated"],
		["sakura「二。」 #voice_dsp:a", "requires #voice"],
		["sakura「三。」 #voice:v #unknown:a", "unknown dialogue metadata"],
		["sakura「四。」 #voice:v #voice_dsp:../a", "logical preset id"],
		["sakura「五。」 #voice:v #voice_layer:x(character=a,asset=b)", "cannot be mixed"],
		["sakura「六。」 #voice_layer:x(character=a,asset=b) #voice_dsp:p", "cannot be duplicated or mixed"],
	]
	for case_value in cases:
		var case: Array = case_value
		var data = _parse("@scene start\n%s" % String(case[0]))
		assert_true(_has_diagnostic(data, "error", String(case[1])))
		assert_eq(data.scenes[0].commands.size(), 0,
			"invalid voice DSP metadata cannot lower a dry dialogue")


func test_narration():
	var data = _parse("""@scene start
「窗外下起了雨。」 #voice:narration_001""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.type, "dialogue")
	assert_eq(cmd.get_string("character"), "")
	assert_eq(cmd.get_string("text"), "窗外下起了雨。")
	assert_eq_deep(cmd.params.get("voice_layers"), [{
		"id": "main", "asset": "narration_001", "character": "",
		"dsp": "", "line": 2,
	}])


func test_monologue():
	var data = _parse("""@scene start
sakura（这个人...好奇怪。） #voice:sakura_thought_001""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.type, "dialogue")
	assert_eq(cmd.get_string("character"), "sakura")
	assert_eq(cmd.get_string("text"), "这个人...好奇怪。")
	assert_eq(cmd.get_string("mode"), "monologue")
	assert_eq_deep(cmd.params.get("voice_layers"), [{
		"id": "main", "asset": "sakura_thought_001", "character": "sakura",
		"dsp": "", "line": 2,
	}])


func test_dialogue_voice_layers_lower_in_authored_order_and_fail_closed():
	var data = _parse("""@chapter test
@scene start
ensemble「同时。」 #voice_layer:lead(character=yuma,asset=yum_001,dsp=remote) #voice_layer:reply(character=suguru,asset=sug_002)""")
	assert_eq(data.diagnostics, [])
	assert_eq_deep(data.scenes[0].commands[0].params.get("voice_layers"), [
		{"id": "lead", "asset": "yum_001", "character": "yuma", "dsp": "remote", "line": 3},
		{"id": "reply", "asset": "sug_002", "character": "suguru", "dsp": "", "line": 3},
	])
	var cases := [
		["#voice_layer:lead(character=yuma)", "requires 'asset'"],
		["#voice_layer:lead(character=yuma,asset=a,asset=b)", "duplicates parameter 'asset'"],
		["#voice_layer:lead(character=yuma,asset=a,pan=0)", "unknown parameter 'pan'"],
		["#voice_layer:9lead(character=yuma,asset=a)", "id is not canonical"],
		["#voice_layer:lead(character=yuma,asset=../a)", "asset is not a Stella logical id"],
		["#voice_layer:lead(character=yuma,asset=a) #voice_layer:lead(character=suguru,asset=b)", "duplicate #voice_layer id"],
	]
	for case_value: Variant in cases:
		var case: Array = case_value
		var invalid = _parse("@scene start\nensemble「坏。」 %s" % String(case[0]))
		assert_true(_has_diagnostic(invalid, "error", String(case[1])))
		assert_eq(invalid.scenes[0].commands.size(), 0)


func test_dialogue_profile_parses_nvl_entry_affixes_as_strings():
	var data = _parse("""@dialogue_profile compact entry_prefix="・" entry_separator=""
@dialogue_profile spaced entry_separator=" "
@dialogue_profile lines entry_prefix="" entry_separator="\\n"
@chapter test
@scene start
@nvl profile=compact
「compact」
@nvl profile=spaced
「spaced」
@nvl profile=lines
「lines」""")
	assert_eq(data.diagnostics, [])

	var compact_profile := data.get_dialogue_profile("compact")
	assert_eq(compact_profile.get("entry_prefix"), "・")
	assert_true(compact_profile.has("entry_separator"),
		"an explicitly empty separator must remain distinguishable from an omitted property")
	assert_eq(compact_profile.get("entry_separator"), "")

	var spaced_profile := data.get_dialogue_profile("spaced")
	assert_false(spaced_profile.has("entry_prefix"),
		"entry prefix and separator are independent profile properties")
	assert_eq(spaced_profile.get("entry_separator"), " ")

	var lines_profile := data.get_dialogue_profile("lines")
	assert_true(lines_profile.has("entry_prefix"))
	assert_eq(lines_profile.get("entry_prefix"), "")
	assert_eq(lines_profile.get("entry_separator"), "\n")


func test_dialogue_profile_rejects_invalid_nvl_entry_escape_with_source_line():
	var data = _parse("""@dialogue_profile broken entry_prefix="\\q"
@chapter test
@scene start
@nvl profile=broken
「line」""")
	assert_eq(data.diagnostics.size(), 2)
	assert_eq(data.diagnostics[0]["line"], 1)
	assert_string_contains(str(data.diagnostics[0]["message"]).to_lower(), "escape")
	var profile := data.get_dialogue_profile("broken")
	assert_false(profile.has("entry_prefix"),
		"an invalid string must not be compiled into presentation data")


func test_dialogue_profile_rejects_unterminated_nvl_entry_string_with_source_line():
	var data = _parse("""@dialogue_profile broken entry_separator="unterminated
@chapter test
@scene start
@nvl profile=broken
「line」""")
	assert_eq(data.diagnostics.size(), 2)
	assert_eq(data.diagnostics[0]["line"], 1)
	assert_string_contains(str(data.diagnostics[0]["message"]).to_lower(), "unterminated")
	var profile := data.get_dialogue_profile("broken")
	assert_false(profile.has("entry_separator"),
		"an unterminated string must not be compiled into presentation data")


func test_dialogue_profile_rejects_bbcode_in_nvl_entry_format():
	var data = _parse("""@dialogue_profile broken entry_prefix="[b]・[/b]"
@chapter test
@scene start
@nvl profile=broken
「line」""")
	assert_eq(data.diagnostics.size(), 2)
	assert_eq(data.diagnostics[0]["line"], 1)
	assert_string_contains(str(data.diagnostics[0]["message"]), "BBCode")
	var profile := data.get_dialogue_profile("broken")
	assert_false(profile.has("entry_prefix"),
		"markup would make raw typewriter offsets diverge from visible characters")


func test_dialogue_profile_parses_advance_indicator_fields():
	var data = _parse(("""@dialogue_profile wait \
advance_indicator_texture=\"%s\" advance_indicator_offset=4.5,-2 \
advance_indicator_animation=pulse
@chapter test
@scene start
@adv profile=wait
「line」""") % ADVANCE_INDICATOR_TEXTURE_PATH)
	assert_eq(data.diagnostics, [])
	var profile := data.get_dialogue_profile("wait")
	assert_eq(profile.get("advance_indicator_texture"), ADVANCE_INDICATOR_TEXTURE_PATH)
	assert_eq(profile.get("advance_indicator_offset"), Vector2(4.5, -2.0))
	assert_eq(profile.get("advance_indicator_animation"), "pulse")
	assert_false(profile.has("advance_indicator_scene"))

	var runtime_profile := DialogueModeProfile.from_dictionary(profile)
	assert_true(runtime_profile.has_advance_indicator())
	assert_not_null(runtime_profile.resolve_advance_indicator_texture())
	assert_null(runtime_profile.resolve_advance_indicator_scene())
	assert_true(runtime_profile.advance_indicator_validation_errors().is_empty())


func test_dialogue_profile_parses_typed_auto_timing_profile_with_provenance():
	var source := ("""@dialogue_profile timed auto_timing_profile=\"%s\"
@chapter test
@scene start
@adv profile=timed
「line」""") % AUTO_TIMING_PROFILE_PATH
	var data := DslParser.parse(
		DslLexer.tokenize(source),
		"auto_timing",
		"res://story/auto_timing.stla",
	)
	assert_eq(data.diagnostics, [])
	var profile := data.get_dialogue_profile("timed")
	var provenance := data.get_dialogue_profile_provenance("timed")
	assert_eq(profile.get("auto_timing_profile"), AUTO_TIMING_PROFILE_PATH)
	assert_eq(provenance.get("field_lines", {}).get("auto_timing_profile"), 1)
	var runtime_profile := DialogueModeProfile.from_dictionary(profile, provenance)
	assert_true(runtime_profile.has_auto_timing_profile())
	assert_true(runtime_profile.resolve_auto_timing_profile() is AutoTimingProfile)
	assert_eq(runtime_profile.auto_timing_diagnostic_provenance().get("line"), 1)


func test_dialogue_profile_rejects_wrong_auto_timing_resource_type_atomically():
	var data := _parse(("""@dialogue_profile broken line_spacing=5 \
auto_timing_profile=\"%s\"
@chapter test
@scene start
@adv profile=broken
「line」""") % ADVANCE_INDICATOR_SCENE_PATH)
	assert_true(_has_diagnostic(data, "error", "AutoTimingProfile"))
	assert_true(data.get_dialogue_profile("broken").is_empty())
	assert_true(_has_diagnostic(data, "error", "unknown dialogue profile 'broken'"))


func test_dialogue_profile_keeps_indicator_provenance_out_of_profile_data():
	var source := ("""@dialogue_profile named advance_indicator_scene=\"%s\"
@chapter test
@scene start
@adv profile=named
「line」""") % ADVANCE_INDICATOR_SCENE_PATH
	var data := DslParser.parse(
		DslLexer.tokenize(source),
		"indicator_provenance",
		"res://story/indicator_provenance.stla",
	)
	assert_eq(data.diagnostics, [])
	var profile := data.get_dialogue_profile("named")
	var provenance := data.get_dialogue_profile_provenance("named")
	assert_false(profile.has(DialogueProfileParser.RUNTIME_PROVENANCE_KEY),
		"authoring metadata must remain a runtime sidecar")
	assert_eq(provenance.get("kind"), "stla")
	assert_eq(provenance.get("profile_name"), "named")
	assert_eq(provenance.get("source_path"),
		"res://story/indicator_provenance.stla")
	assert_eq(provenance.get("field_lines", {}).get(
		"advance_indicator_scene"), 1)

	var runtime_profile := DialogueModeProfile.from_dictionary(profile, provenance)
	var diagnostic := runtime_profile.advance_indicator_diagnostic_provenance()
	assert_eq(diagnostic.get("profile_name"), "named")
	assert_eq(diagnostic.get("declaration_line"), 1)
	assert_eq(diagnostic.get("indicator_source"), ADVANCE_INDICATOR_SCENE_PATH)


func test_dialogue_profile_unknown_source_is_not_mislabeled_as_scenario_id():
	var source := ("""@dialogue_profile named advance_indicator_scene=\"%s\"
@chapter test
@scene start
@adv profile=named
「line」""") % ADVANCE_INDICATOR_SCENE_PATH
	var data := DslParser.parse(DslLexer.tokenize(source), "scenario_id_only")
	var runtime_profile := DialogueModeProfile.from_dictionary(
		data.get_dialogue_profile("named"),
		data.get_dialogue_profile_provenance("named"),
	)
	var diagnostic := runtime_profile.advance_indicator_diagnostic_provenance()
	assert_eq(diagnostic.get("profile_source"), "<unknown STLA>")


func test_dialogue_profile_scene_source_resolves_from_stla_path():
	var data = _parse(("""@dialogue_profile wait \
advance_indicator_scene=\"%s\" advance_indicator_animation=bob
@chapter test
@scene start
@overlay profile=wait
「line」""") % ADVANCE_INDICATOR_SCENE_PATH)
	assert_eq(data.diagnostics, [])
	var profile := data.get_dialogue_profile("wait")
	assert_eq(profile.get("advance_indicator_scene"), ADVANCE_INDICATOR_SCENE_PATH)
	assert_eq(profile.get("advance_indicator_animation"), "bob")

	var runtime_profile := DialogueModeProfile.from_dictionary(profile)
	assert_true(runtime_profile.has_advance_indicator())
	assert_not_null(runtime_profile.resolve_advance_indicator_scene())
	assert_null(runtime_profile.resolve_advance_indicator_texture())
	assert_true(runtime_profile.advance_indicator_validation_errors().is_empty())


func test_dialogue_profile_rejects_mutually_exclusive_indicator_sources_atomically():
	var data = _parse(("""@dialogue_profile texture_first \
advance_indicator_texture=\"%s\" advance_indicator_scene=\"%s\"
@dialogue_profile scene_first advance_indicator_scene=\"%s\"
@dialogue_profile scene_first advance_indicator_texture=\"%s\"
@chapter test
@scene start
@adv profile=texture_first
「first」
@adv profile=scene_first
「second」""") % [
		ADVANCE_INDICATOR_TEXTURE_PATH,
		ADVANCE_INDICATOR_SCENE_PATH,
		ADVANCE_INDICATOR_SCENE_PATH,
		ADVANCE_INDICATOR_TEXTURE_PATH,
	])
	assert_true(_has_diagnostic(data, "error", "mutually exclusive"))
	for profile_name in ["texture_first", "scene_first"]:
		assert_true(data.get_dialogue_profile(profile_name).is_empty(),
			"a source conflict rejects the whole Profile independent of order")


func test_dialogue_profile_bad_indicator_source_rejects_profile_atomically():
	var data = _parse(("""@dialogue_profile missing horizontal_alignment=center \
advance_indicator_texture=\"res://missing/indicator.png\"
@dialogue_profile wrong_type line_spacing=7 \
advance_indicator_scene=\"%s\"
@chapter test
@scene start
@adv profile=missing
「missing」
@adv profile=wrong_type
「wrong type」""") % ADVANCE_INDICATOR_TEXTURE_PATH)
	assert_true(_has_diagnostic(data, "error", "does not exist"))
	assert_true(_has_diagnostic(data, "error", "PackedScene"))
	assert_true(data.get_dialogue_profile("missing").is_empty())
	assert_true(data.get_dialogue_profile("wrong_type").is_empty())
	assert_true(_has_diagnostic(data, "error", "unknown dialogue profile 'missing'"))
	assert_true(_has_diagnostic(data, "error", "unknown dialogue profile 'wrong_type'"))


func test_dialogue_profile_rejects_invalid_indicator_fields_atomically():
	var data = _parse(("""@dialogue_profile broken line_spacing=5 \
advance_indicator_texture=\"%s\" advance_indicator_offset=1 \
advance_indicator_animation=spin
@chapter test
@scene start
@adv profile=broken
「line」""") % ADVANCE_INDICATOR_TEXTURE_PATH)
	assert_eq(data.diagnostics.size(), 3)
	assert_true(_has_diagnostic(data, "error", "two comma-separated numbers"))
	assert_true(_has_diagnostic(data, "error", "advance_indicator_animation"))
	assert_true(data.get_dialogue_profile("broken").is_empty())
	assert_true(_has_diagnostic(data, "error", "unknown dialogue profile 'broken'"))


func test_dialogue_profile_rejects_non_project_indicator_paths():
	var data = _parse("""@dialogue_profile relative advance_indicator_texture=\"ui/next.png\"
@dialogue_profile writable advance_indicator_scene=\"user://next.tscn\"
@chapter test
@scene start
@adv profile=relative
「one」
@adv profile=writable
「two」""")
	assert_eq(data.diagnostics.size(), 4)
	assert_eq(data.diagnostics.filter(func(diagnostic):
		return "res:// or uid://" in String(diagnostic.get("message", ""))).size(), 2)
	assert_true(_has_diagnostic(data, "error", "unknown dialogue profile 'relative'"))
	assert_true(_has_diagnostic(data, "error", "unknown dialogue profile 'writable'"))


func test_dialogue_mode_profile_indicator_is_created_only_from_stla_data():
	var profile := DialogueModeProfile.new()
	assert_false(profile.has_advance_indicator())
	assert_eq(profile.get_advance_indicator_offset(), Vector2.ZERO)
	assert_eq(profile.get_advance_indicator_animation(), "none")
	assert_true(profile.advance_indicator_validation_errors().is_empty())

	profile = DialogueModeProfile.from_dictionary({
		"advance_indicator_texture": ADVANCE_INDICATOR_TEXTURE_PATH,
		"advance_indicator_offset": Vector2(3.0, -1.0),
		"advance_indicator_animation": "pulse",
	})
	assert_true(profile.has_advance_indicator())
	assert_not_null(profile.resolve_advance_indicator_texture())
	assert_eq(profile.get_advance_indicator_offset(), Vector2(3.0, -1.0))
	assert_eq(profile.get_advance_indicator_animation(), "pulse")


func test_bg_full_params():
	var data = _parse("""@scene start
@bg bg_school fade 0.8""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.type, "bg")
	assert_eq(cmd.get_string("asset"), "bg_school")
	assert_eq(cmd.get_string("transition"), "fade")
	assert_almost_eq(cmd.get_float("duration"), 0.8, 0.001)


func test_bg_defaults():
	var data = _parse("""@scene start
@bg bg_school""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.get_string("transition"), "fade")
	assert_almost_eq(cmd.get_float("duration"), 0.5, 0.001)


func test_bg_slide_transitions_preserved():
	for dir in ["slide_left", "slide_right", "slide_up", "slide_down"]:
		var data = _parse("@scene start\n@bg bg_cafe %s 0.6" % dir)
		var cmd = data.scenes[0].commands[0]
		assert_eq(cmd.type, "bg")
		assert_eq(cmd.get_string("transition"), dir, "transition %s should pass through" % dir)
		assert_almost_eq(cmd.get_float("duration"), 0.6, 0.001)


func test_jump():
	var data = _parse("""@scene start
@jump ending""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.type, "jump")
	assert_eq(cmd.get_string("target"), "ending")


func test_set_assign():
	var data = _parse("""@scene start
@set talked = true""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.type, "set")
	assert_eq(cmd.get_string("var"), "talked")
	assert_eq(cmd.get_string("value"), "true")
	assert_eq(cmd.get_string("op"), "=")


func test_set_increment():
	var data = _parse("""@scene start
@set score += 5""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.get_string("var"), "score")
	assert_eq(cmd.get_string("op"), "+=")


func test_choice_basic():
	var data = _parse("""@scene start
@choice
  - "你好" -> scene_a
  - "再见" -> scene_b""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.type, "choice")
	var options = cmd.params.get("options", [])
	assert_eq(options.size(), 2)
	assert_eq(options[0]["label"], "你好")
	assert_eq(options[0]["jump"], "scene_a")
	assert_eq(options[1]["label"], "再见")
	assert_eq(options[1]["jump"], "scene_b")


func test_choice_with_prompt():
	var data = _parse("""@scene start
@choice "你该怎么回应？"
  - "你好" -> scene_a""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.get_string("prompt"), "你该怎么回应？")


func test_choice_with_set():
	var data = _parse("""@scene start
@choice
  - "走吧" -> scene_go {affection += 5}""")
	var cmd = data.scenes[0].commands[0]
	var options = cmd.params.get("options", [])
	assert_true(options[0].has("set"))


func test_if_else_end():
	var data = _parse("""@scene start
@if has_key
  sakura「你有钥匙！」
@else
  sakura「没有钥匙...」
@end""")
	# Should generate a condition command + synthetic scenes
	var found_condition = false
	for scene in data.scenes:
		for cmd in scene.commands:
			if cmd.type == "condition":
				found_condition = true
				assert_eq(cmd.get_string("if"), "has_key")
				assert_true(cmd.has_param("then_jump"))
				assert_true(cmd.has_param("else_jump"))
	assert_true(found_condition, "Should have a condition command")


func test_if_without_else():
	var data = _parse("""@scene start
@if has_key
  sakura「你有钥匙！」
@end
sakura「继续...」""")
	var found_condition = false
	for scene in data.scenes:
		for cmd in scene.commands:
			if cmd.type == "condition":
				found_condition = true
	assert_true(found_condition)


func test_nested_if_condition_is_owned_by_the_outer_then_cfg():
	var data := _parse("""@chapter test
@scene start
@if outer
「outer before」
@if inner
「inner then」
@else
「inner else」
@end
「outer after」
@else
「outer else」
@end
「done」""")
	assert_eq(data.diagnostics, [])

	var start := data.get_scene("start")
	assert_not_null(start)
	if start == null:
		return
	assert_eq(start.commands.size(), 1,
		"the author scene must enter the outer condition before any nested condition")
	assert_eq(start.commands[0].type, "condition")
	assert_eq(start.commands[0].get_string("if"), "outer")

	var inner_condition_scene: SceneData = null
	for scene in data.scenes:
		for command in scene.commands:
			if command.type == "condition" and command.get_string("if") == "inner":
				inner_condition_scene = scene
	assert_not_null(inner_condition_scene)
	if inner_condition_scene != null:
		assert_ne(inner_condition_scene.id, "start")
		assert_true(inner_condition_scene.id.begins_with("__if_start_3_then"),
			"the inner condition must only be reachable from the outer true branch")

	var root_cont_id := "__if_start_3_cont"
	assert_eq(data.scenes[-1].id, root_cont_id,
		"the root continuation must be physically last in its compiled CFG")
	for scene_index in range(1, data.scenes.size() - 1):
		var synthetic_scene: SceneData = data.scenes[scene_index]
		assert_true(synthetic_scene.id.begins_with("__"))
		assert_false(synthetic_scene.commands.is_empty(),
			"non-final synthetic scene %s needs an explicit transfer" % synthetic_scene.id)
		if synthetic_scene.commands.is_empty():
			continue
		var terminal: CommandData = synthetic_scene.commands[-1]
		assert_true(terminal.type in ["condition", "jump"],
			"synthetic scene %s must not fall through to a sibling branch"
			% synthetic_scene.id)
		if terminal.type == "jump":
			assert_not_null(data.get_scene(terminal.get_string("target")),
				"synthetic jump target must exist")
		else:
			assert_not_null(data.get_scene(terminal.get_string("then_jump")),
				"synthetic true target must exist")
			assert_not_null(data.get_scene(terminal.get_string("else_jump")),
				"synthetic false target must exist")


func test_multi_elif_branches_join_the_root_if_continuation():
	var data := _parse("""@chapter test
@scene start
@if route == 1
「one」
@elif route == 2
「two」
@elif route == 3
「three」
@else
「four」
@end
「done」""")
	assert_eq(data.diagnostics, [])
	var root_cont_id := "__if_start_3_cont"
	assert_not_null(data.get_scene(root_cont_id))

	var branch_texts := ["one", "two", "three", "four"]
	for branch_text in branch_texts:
		var branch_scene: SceneData = null
		for scene in data.scenes:
			for command in scene.commands:
				if command.type == "dialogue" \
					and command.get_string("text") == branch_text:
					branch_scene = scene
		assert_not_null(branch_scene, "missing branch scene for %s" % branch_text)
		if branch_scene == null:
			continue
		var terminal: CommandData = branch_scene.commands[-1]
		assert_eq(terminal.type, "jump",
			"branch %s must not fall through into another synthetic branch" % branch_text)
		assert_eq(terminal.get_string("target"), root_cont_id,
			"every elif-chain branch must join the root if continuation")


func test_end_command():
	var data = _parse("""@scene start
@end""")
	assert_eq(data.scenes[0].commands.size(), 0)
	assert_true(_has_diagnostic(data, "error", "unmatched @end"))


func test_unmatched_and_misordered_condition_branches_are_diagnostics():
	var unmatched = _parse("""@scene start
@elif score > 1
@else""")
	assert_true(_has_diagnostic(unmatched, "error", "unmatched @elif"))
	assert_true(_has_diagnostic(unmatched, "error", "unmatched @else"))

	var misordered = _parse("""@scene start
@if score > 1
「then」
@else
「else」
@elif score > 2
@else
@end""")
	assert_true(_has_diagnostic(misordered, "error", "@elif cannot appear after @else"))
	assert_true(_has_diagnostic(misordered, "error", "duplicate @else"))


func test_full_poc_scenario():
	var source = """@chapter prologue
@scene start "初次相遇"
@bg bg_school_gate fade 0.8
@stage sakura show kind=character asset=character:sakura/smile position=960,80
sakura「你好，初次见面！」
@choice "你该怎么回应？"
  - "你好！" -> friendly {affection += 5}
  - "……嗯。" -> cold

@scene friendly
@stage sakura update asset=character:sakura/happy
sakura「太好了！」
@jump ending

@scene cold
@stage sakura update asset=character:sakura/sad
sakura「这样啊...」
@jump ending

@scene ending
「（第一天就这样结束了。）」
@stage sakura remove
@bg bg_black fade 1.0"""
	var data = _parse(source, "poc_demo")
	assert_true(data.diagnostics.is_empty())
	assert_eq(data.id, "poc_demo")
	assert_eq(data.scenes.size(), 4)
	assert_eq(data.scenes[0].id, "start")
	assert_eq(data.scenes[1].id, "friendly")
	assert_eq(data.scenes[2].id, "cold")
	assert_eq(data.scenes[3].id, "ending")
	# Start scene should have: bg, stage layer, dialogue, choice
	assert_true(data.scenes[0].commands.size() >= 4)


func test_voice_command():
	var data = _parse("""@scene start
@voice sakura_001""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.type, "voice")
	assert_eq(cmd.get_string("asset"), "sakura_001")


# --- @combine / @end block ---

func test_combine_basic_single_segment():
	var data = _parse("""@scene start
@combine
@stage sakura update asset=character:sakura/sad
sakura「第一句。」 #voice:v1
@end""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.type, "dialogue")
	assert_eq(cmd.get_string("character"), "sakura")
	var segments = cmd.params.get("segments", [])
	assert_eq(segments.size(), 1)
	assert_eq(segments[0]["text"], "第一句。")
	assert_eq(segments[0]["voice_layers"][0]["asset"], "v1")
	assert_eq(segments[0]["presentation_ops"].size(), 1)
	assert_eq(segments[0]["presentation_ops"][0]["kind"], "stage")
	assert_eq(segments[0]["presentation_ops"][0]["payload"]["id"], "sakura")
	assert_eq(segments[0]["presentation_operation_lines"], [3])


func test_combine_multiple_segments():
	var data = _parse("""@scene start
@combine
@stage sakura update asset=character:sakura/sad
sakura「第一句。」 #voice:v1
@stage sakura update asset=character:sakura/surprised
sakura「第二句。」 #voice:v2
@stage sakura update asset=character:sakura/happy
sakura「第三句。」 #voice:v3
@end""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.type, "dialogue")
	assert_eq(cmd.get_string("character"), "sakura")
	var segments = cmd.params.get("segments", [])
	assert_eq(segments.size(), 3)
	assert_eq(segments[0]["text"], "第一句。")
	assert_eq(segments[0]["voice_layers"][0]["asset"], "v1")
	assert_eq(segments[0]["presentation_ops"][0]["payload"]["properties"]["asset"], "character:sakura/sad")
	assert_eq(segments[1]["text"], "第二句。")
	assert_eq(segments[1]["voice_layers"][0]["asset"], "v2")
	assert_eq(segments[1]["presentation_ops"][0]["payload"]["properties"]["asset"], "character:sakura/surprised")
	assert_eq(segments[2]["text"], "第三句。")
	assert_eq(segments[2]["voice_layers"][0]["asset"], "v3")
	assert_eq(segments[2]["presentation_ops"][0]["payload"]["properties"]["asset"], "character:sakura/happy")
	assert_eq(segments[0]["presentation_operation_lines"], [3])
	assert_eq(segments[1]["presentation_operation_lines"], [5])
	assert_eq(segments[2]["presentation_operation_lines"], [7])


func test_combine_segments_select_voice_dsp_independently():
	var data = _parse("""@chapter test
@scene start
@combine
sakura「第一句。」 #voice:v1 #voice_dsp:remote
sakura「第二句。」 #voice:v2 #voice_dsp:memory
sakura「第三句。」 #voice:v3
@end""")
	var segments: Array = data.scenes[0].commands[0].params.get("segments", [])
	assert_eq(data.diagnostics, [])
	assert_eq(segments.size(), 3)
	assert_eq(segments[0]["voice_layers"][0]["dsp"], "remote")
	assert_eq(segments[0]["voice_layers"][0]["line"], 4)
	assert_eq(segments[1]["voice_layers"][0]["dsp"], "memory")
	assert_eq(segments[1]["voice_layers"][0]["line"], 5)
	assert_eq(segments[2]["voice_layers"][0]["dsp"], "")
	assert_eq(segments[2]["voice_layers"][0]["line"], 6)


func test_combine_concatenated_text_for_backlog():
	# Parser should also expose concatenated text for backlog/typewriter
	var data = _parse("""@scene start
@combine
sakura「我本来很开心的...」 #voice:v1
sakura「但是听说下周要期中考...」 #voice:v2
@end""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.get_string("text"),
		"我本来很开心的...但是听说下周要期中考...",
		"combined text should be concatenation of all segments")


func test_combine_segment_without_stage_cue_has_empty_presentation_ops():
	var data = _parse("""@scene start
@combine
sakura「第一句。」 #voice:v1
sakura「第二句。」 #voice:v2
@end""")
	var cmd = data.scenes[0].commands[0]
	var segments = cmd.params.get("segments", [])
	assert_eq(segments.size(), 2)
	assert_true(segments[0]["presentation_ops"].is_empty())
	assert_true(segments[1]["presentation_ops"].is_empty())


func test_combine_only_produces_one_command():
	var data = _parse("""@scene start
@combine
@stage sakura update asset=character:sakura/sad
sakura「一。」 #voice:v1
@stage sakura update asset=character:sakura/happy
sakura「二。」 #voice:v2
@end
sakura「之后的话。」 #voice:v3""")
	# Should have: 1 combine dialogue + 1 normal dialogue = 2 commands
	assert_eq(data.scenes[0].commands.size(), 2)
	assert_eq(data.scenes[0].commands[0].type, "dialogue")
	assert_eq(data.scenes[0].commands[0].params.get("segments", []).size(), 2)
	assert_eq(data.scenes[0].commands[1].type, "dialogue")
	assert_false(data.scenes[0].commands[1].params.has("segments"),
		"normal dialogue should not have segments field")


func test_combine_narration_segments():
	# Narration (no character) should also work
	var data = _parse("""@scene start
@combine
「第一段旁白。」 #voice:n1
「第二段旁白。」 #voice:n2
@end""")
	var cmd = data.scenes[0].commands[0]
	assert_eq(cmd.get_string("character"), "")
	var segments = cmd.params.get("segments", [])
	assert_eq(segments.size(), 2)
	assert_eq(segments[0]["text"], "第一段旁白。")
	assert_eq(segments[1]["text"], "第二段旁白。")


func test_combine_inside_existing_scenario():
	# Should work alongside other commands
	var data = _parse("""@scene start
@bg bg_school
@stage sakura show kind=character asset=character:sakura/smile
sakura「开始。」 #voice:v0
@combine
@stage sakura update asset=character:sakura/sad
sakura「一。」 #voice:v1
@stage sakura update asset=character:sakura/happy
sakura「二。」 #voice:v2
@end
sakura「结束。」 #voice:v3""")
	assert_eq(data.scenes[0].commands.size(), 5)
	assert_eq(data.scenes[0].commands[0].type, "bg")
	assert_eq(data.scenes[0].commands[1].type, "stage_layer")
	assert_eq(data.scenes[0].commands[2].type, "dialogue")
	assert_eq(data.scenes[0].commands[3].type, "dialogue")
	assert_eq(data.scenes[0].commands[3].params.get("segments", []).size(), 2)
	assert_eq(data.scenes[0].commands[4].type, "dialogue")


func test_combine_rejects_effect_with_structured_warning():
	var data = _parse("""@scene start
@combine
@effect flash white 0.2
sakura「第一句。」 #voice:v1
@end""")
	assert_true(
		_has_diagnostic(data, "warning", "only @stage and @dialogue_avatar are allowed inside @combine block; @effect was ignored"),
		"unsupported combine commands must be surfaced through parser diagnostics",
	)
	assert_eq(data.scenes[0].commands.size(), 1)
	assert_eq(data.scenes[0].commands[0].type, "dialogue")


func test_combine_rejects_dialogue_mode_switch_without_mutating_mode():
	var data = _parse("""@dialogue_profile novel horizontal_alignment=center
@scene start
@combine
「第一段。」
@nvl profile=novel
「第二段。」
@end
「之后。」""")
	assert_true(
		_has_diagnostic(data, "warning", "only @stage and @dialogue_avatar are allowed inside @combine block; @nvl was ignored"),
		"dialogue mode switches inside combine must be rejected",
	)
	assert_eq(data.scenes[0].commands.size(), 2)
	var combine_command: CommandData = data.scenes[0].commands[0]
	assert_true(combine_command.get_bool("presentation_from_context"))
	assert_false(combine_command.has_param("mode"))
	assert_false(combine_command.has_param("presentation_profile_name"))
	assert_eq(combine_command.params.get("segments", []).size(), 2)
	var following_command: CommandData = data.scenes[0].commands[1]
	assert_true(following_command.get_bool("presentation_from_context"))
	assert_false(following_command.has_param("mode"))
	assert_false(following_command.has_param("presentation_profile_name"))


func test_nvl_mode_events_preserve_repeated_directives_for_runtime_state():
	var data = _parse("""@chapter test
@scene start
@nvl
「first」
「second」
@nvl
「third」""")
	assert_eq(data.diagnostics, [])
	var commands: Array = data.scenes[0].commands
	assert_eq(commands.size(), 3,
		"mode events must not become position-addressable scenario commands")
	assert_eq(_event_modes(commands[0].dialogue_mode_events_before), ["nvl"])
	assert_eq(commands[1].dialogue_mode_events_before, [])
	assert_eq(_event_modes(commands[2].dialogue_mode_events_before), ["nvl"],
		"a repeated @nvl remains an event so runtime state decides whether it resets")
	for command in commands:
		assert_false(command.has_param("nvl_block_id"),
			"static source block identity must not leak into dialogue commands")


func test_nvl_off_then_on_events_keep_source_order_on_next_real_command():
	var data = _parse("""@chapter test
@scene start
@nvl
「first」
@nvl off
@nvl
「second」""")
	assert_eq(data.diagnostics, [])
	var commands: Array = data.scenes[0].commands
	assert_eq(commands.size(), 2)
	assert_eq(_event_modes(commands[0].dialogue_mode_events_before), ["nvl"])
	assert_eq(_event_modes(commands[1].dialogue_mode_events_before), ["adv", "nvl"],
		"off -> on must replay as two ordered runtime transitions")
	assert_eq(commands[0].dialogue_mode_events_after, [])
	assert_eq(commands[1].dialogue_mode_events_after, [])


func test_nvl_jump_loop_keeps_replayable_events_on_target_and_jump():
	var data = _parse("""@chapter test
@scene page
@nvl
「Entry」
@nvl off
@jump page""")
	assert_eq(data.diagnostics, [])
	var commands: Array = data.scenes[0].commands
	assert_eq(commands.size(), 2,
		"runtime boundaries must not shift the loop's saved command positions")
	assert_eq(commands[0].type, "dialogue")
	assert_eq(_event_modes(commands[0].dialogue_mode_events_before), ["nvl"],
		"every visit to the target command must replay its NVL entry event")
	assert_eq(commands[1].type, "jump")
	assert_eq(_event_modes(commands[1].dialogue_mode_events_before), ["adv"],
		"@nvl off must execute before the jump on every loop iteration")
	assert_eq(data.scenes[0].dialogue_mode_events_on_exit, [])


func test_nvl_mode_events_are_branch_local_across_if_elif_else_join():
	var data = _parse("""@chapter test
@scene start
@nvl
「old block」
@if route == 1
@nvl off
@nvl
「then entry」
@elif route == 2
@nvl off
@nvl
「elif entry」
@else
@nvl off
@nvl
「else entry」
@end
「continuation entry」""")
	assert_eq(data.diagnostics, [])
	var old_entry := _find_dialogue_command(data, "old block")
	var then_entry := _find_dialogue_command(data, "then entry")
	var elif_entry := _find_dialogue_command(data, "elif entry")
	var else_entry := _find_dialogue_command(data, "else entry")
	var continuation := _find_dialogue_command(data, "continuation entry")
	assert_not_null(old_entry)
	assert_not_null(then_entry)
	assert_not_null(elif_entry)
	assert_not_null(else_entry)
	assert_not_null(continuation)
	if (old_entry == null or then_entry == null or elif_entry == null
		or else_entry == null or continuation == null):
		return

	assert_eq(_event_modes(old_entry.dialogue_mode_events_before), ["nvl"])
	assert_eq(_event_modes(then_entry.dialogue_mode_events_before), ["adv", "nvl"])
	assert_eq(_event_modes(elif_entry.dialogue_mode_events_before), ["adv", "nvl"])
	assert_eq(_event_modes(else_entry.dialogue_mode_events_before), ["adv", "nvl"])
	assert_eq(continuation.dialogue_mode_events_before, [],
		"the join must continue whichever runtime branch executed without a static reset")
	for command in [old_entry, then_entry, elif_entry, else_entry, continuation]:
		assert_false(command.has_param("nvl_block_id"))


func test_mode_only_else_uses_false_edge_without_shifting_scenes_or_uids():
	var with_events := _parse("""@chapter test
@scene start
@if flag
@set branch = true
@else
@nvl off
@nvl
@end
@set done = true
@scene later
@set later = true""")
	var without_events := _parse("""@chapter test
@scene start
@if flag
@set branch = true
@else
// legacy empty branch line 1
// legacy empty branch line 2
@end
@set done = true
@scene later
@set later = true""")
	assert_eq(with_events.diagnostics, [])
	assert_eq(without_events.diagnostics, [])

	var with_scene_ids: Array[String] = []
	var without_scene_ids: Array[String] = []
	for scene in with_events.scenes:
		with_scene_ids.append(scene.id)
	for scene in without_events.scenes:
		without_scene_ids.append(scene.id)
	assert_eq(with_scene_ids, without_scene_ids,
		"a mode-only else must not create an addressable synthetic scene")
	assert_eq(with_scene_ids, [
		"start",
		"__if_start_3_then",
		"__if_start_3_cont",
		"later",
	])

	var condition: CommandData = with_events.scenes[0].commands[0]
	assert_eq(condition.type, "condition")
	assert_eq(condition.dialogue_mode_events_on_true_branch, [])
	assert_eq(_event_modes(condition.dialogue_mode_events_on_false_branch), ["adv", "nvl"])
	assert_eq(condition.get_string("else_jump"), "__if_start_3_cont")

	with_events.assign_command_uids()
	without_events.assign_command_uids()
	var with_later := with_events.get_scene("later")
	var without_later := without_events.get_scene("later")
	assert_eq(with_events.get_scene_index("later"),
		without_events.get_scene_index("later"))
	assert_eq(with_later.commands[0].uid, without_later.commands[0].uid,
		"mode-only branch metadata must not shift later command identities")


func test_mode_only_final_else_in_elif_chain_uses_false_edge_sidecar():
	var data := _parse("""@chapter test
@scene start
@if route == 1
@set branch = 1
@elif route == 2
@set branch = 2
@else
@nvl off
@nvl
@end
@set done = true""")
	assert_eq(data.diagnostics, [])
	var elif_condition: CommandData = null
	for scene in data.scenes:
		assert_false(scene.id.begins_with("__elif_") and scene.id.ends_with("_else"),
			"a mode-only final else must not add an elif else scene")
		for command in scene.commands:
			if command.type == "condition" \
				and command.get_string("if") == "route == 2":
				elif_condition = command
	assert_not_null(elif_condition)
	if elif_condition == null:
		return
	assert_eq(_event_modes(elif_condition.dialogue_mode_events_on_false_branch), ["adv", "nvl"])
	assert_eq(elif_condition.get_string("else_jump"), "__if_start_3_cont")


func test_nvl_mode_event_at_scene_tail_runs_on_exit_without_a_real_command():
	var data = _parse("""@chapter test
@scene called_page
@nvl
「Entry」
@nvl off""")
	assert_eq(data.diagnostics, [])
	var scene: SceneData = data.scenes[0]
	assert_eq(scene.commands.size(), 1)
	assert_eq(_event_modes(scene.commands[0].dialogue_mode_events_before), ["nvl"])
	assert_eq(scene.commands[0].dialogue_mode_events_after, [])
	assert_eq(_event_modes(scene.dialogue_mode_events_on_exit), ["adv"],
		"a called scene must leave NVL before ScenarioEngine returns to its caller")


func test_nvl_mode_event_decorates_one_combined_command_without_changing_indices():
	var data = _parse("""@chapter test
@scene start
@nvl
@combine
「first segment」
「second segment」
@end
「next entry」""")
	assert_eq(data.diagnostics, [])
	var commands: Array = data.scenes[0].commands
	assert_eq(commands.size(), 2,
		"a mode event and @combine must still produce exactly two real dialogues")
	assert_eq(commands[0].params.get("segments", []).size(), 2)
	assert_eq(_event_modes(commands[0].dialogue_mode_events_before), ["nvl"])
	assert_eq(commands[1].dialogue_mode_events_before, [])
	assert_false(commands[0].has_param("nvl_block_id"))
	assert_false(commands[1].has_param("nvl_block_id"))


func test_parallel_tail_mode_event_runs_after_the_parallel_wrapper():
	var data = _parse("""@chapter test
@scene start
@parallel
@bg bg_school
@nvl
@end
「after parallel」""")
	assert_eq(data.diagnostics, [])
	var commands: Array = data.scenes[0].commands
	assert_eq(commands.size(), 2)
	assert_eq(commands[0].type, "parallel")
	assert_eq(commands[0].params.get("commands", []).size(), 1)
	assert_eq(commands[0].dialogue_mode_events_before, [])
	assert_eq(_event_modes(commands[0].dialogue_mode_events_after), ["nvl"],
		"a mode event at the nested list tail must run after its parallel work")
	assert_eq(commands[1].type, "dialogue")
	assert_eq(commands[1].dialogue_mode_events_before, [])


# ─── @chapter directive (issue #97) ───

func _find_dialogue_command(data: ScenarioData, text: String) -> CommandData:
	for scene in data.scenes:
		for command in scene.commands:
			if command.type == "dialogue" and command.get_string("text") == text:
				return command
	return null


func _has_diagnostic(data: ScenarioData, level: String, substring: String) -> bool:
	for d in data.diagnostics:
		if d.get("level") == level and substring in str(d.get("message", "")):
			return true
	return false


func test_chapter_creates_chapter_data():
	var data = _parse('@chapter prologue "序章"\n@scene start')
	assert_eq(data.chapters.size(), 1)
	assert_eq(data.chapters[0].id, "prologue")
	assert_eq(data.chapters[0].display_name, "序章")


func test_chapter_without_display_name_falls_back_to_id():
	var data = _parse("@chapter ch1\n@scene start")
	assert_eq(data.chapters.size(), 1)
	assert_eq(data.chapters[0].id, "ch1")
	# Fallback: display name == id when no quoted title
	assert_eq(data.chapters[0].display_name, "ch1")


# ─── @chapter_indicator directive (issue #170) ───

func test_chapter_indicator_parses_canonical_timeline_commands() -> void:
	var data := _parse("""@chapter prologue "Prologue"
@scene start
@chapter_indicator hide
@chapter_indicator show transition=none
@chapter_indicator show transition=fade""")

	assert_eq(data.diagnostics, [])
	assert_eq(data.scenes[0].commands.size(), 3)
	if data.scenes[0].commands.size() != 3:
		return
	var hidden: CommandData = data.scenes[0].commands[0]
	assert_eq(hidden.type, "presentation_batch")
	assert_eq(hidden.params.get("policy"), "join")
	assert_eq(hidden.params.get("operation_lines"), [3])
	assert_eq(hidden.params["operations"][0], {
		"kind": "chapter_indicator",
		"payload": {
		"action": "hide",
		"transition": "cut",
		"duration": 0.0,
		},
	})
	assert_eq(hidden.declared_line, 3)
	assert_eq(data.scenes[0].commands[1].params["operations"][0]["payload"], {
		"action": "show",
		"transition": "cut",
		"duration": 0.0,
	}, "none is accepted authoring syntax but canonicalizes to cut")
	assert_eq(data.scenes[0].commands[2].params["operations"][0]["payload"], {
		"action": "show",
		"transition": "fade",
		"duration": 0.25,
	})


func test_invalid_chapter_indicator_operations_are_rejected_atomically() -> void:
	var invalid_operations := [
		"@chapter_indicator",
		"@chapter_indicator toggle",
		"@chapter_indicator show fade",
		"@chapter_indicator show transition=wipe",
		"@chapter_indicator show transition=cut duration=0.1",
		"@chapter_indicator show duration=-0.1",
		"@chapter_indicator show duration=nan",
		"@chapter_indicator show opacity=0.5",
		"@chapter_indicator show transition=fade transition=cut",
		"@chapter_indicator show duration=0.2 duration=0.3",
	]
	for operation: String in invalid_operations:
		var data := _parse("""@chapter prologue
@scene start
%s""" % operation)
		assert_eq(
			data.scenes[0].commands.size(),
			0,
			"invalid operation must not leave partial CommandData: %s" % operation,
		)
		assert_true(
			_has_diagnostic(data, "error", "chapter_indicator"),
			"invalid operation must retain a source-located diagnostic: %s" % operation,
		)


func test_chapter_groups_following_scenes():
	var data = _parse("""@chapter prologue
@scene a
@scene b
@scene c""")
	assert_eq(data.chapters.size(), 1)
	assert_eq(data.chapters[0].scene_ids.size(), 3)
	assert_eq(data.chapters[0].scene_ids[0], "a")
	assert_eq(data.chapters[0].scene_ids[1], "b")
	assert_eq(data.chapters[0].scene_ids[2], "c")


func test_multiple_chapters_each_get_their_scenes():
	var data = _parse("""@chapter prologue
@scene a
@scene b
@chapter ch1
@scene c
@scene d""")
	assert_eq(data.chapters.size(), 2)
	assert_eq(data.chapters[0].id, "prologue")
	assert_eq(data.chapters[0].scene_ids, ["a", "b"])
	assert_eq(data.chapters[1].id, "ch1")
	assert_eq(data.chapters[1].scene_ids, ["c", "d"])


func test_scene_carries_chapter_id_back_reference():
	var data = _parse("""@chapter prologue
@scene a
@chapter ch1
@scene b""")
	assert_eq(data.scenes.size(), 2)
	assert_eq(data.scenes[0].chapter_id, "prologue")
	assert_eq(data.scenes[1].chapter_id, "ch1")


func test_scene_before_any_chapter_emits_error_diagnostic():
	# Issue #97: 强制规范化 — scene declared before any @chapter is an error
	var data = _parse('@scene orphan\n@chapter ch1\n@scene legit')
	assert_true(_has_diagnostic(data, "error", "before any @chapter"),
		"orphan scene should produce an error diagnostic")
	# Orphan scene is still recorded with empty chapter_id (forgiving parser)
	assert_eq(data.scenes[0].id, "orphan")
	assert_eq(data.scenes[0].chapter_id, "")


func test_empty_chapter_emits_error_diagnostic():
	# Issue #97: 每个 chapter 必须至少包含一个 @scene
	var data = _parse("@chapter empty_ch\n@chapter ch_with_scene\n@scene s")
	assert_true(_has_diagnostic(data, "error", "empty_ch"),
		"empty chapter should produce an error diagnostic naming it")


func test_chapter_inside_if_block_emits_error_diagnostic():
	var data = _parse("""@chapter prologue
@scene start
@if some_flag
@chapter inner
@end""")
	assert_true(_has_diagnostic(data, "error", "@chapter cannot be used inside @if"),
		"chapter inside @if block should produce an error diagnostic")


func test_chapter_at_end_of_file_with_no_scenes_is_empty_chapter_error():
	var data = _parse("@chapter ch1\n@scene s\n@chapter trailing")
	assert_true(_has_diagnostic(data, "error", "trailing"),
		"trailing chapter with no scenes should error")


func test_no_diagnostic_when_well_formed():
	var data = _parse("""@chapter prologue
@scene a
@scene b
@chapter ch1
@scene c""")
	assert_eq(data.diagnostics.size(), 0,
		"well-formed scenario should produce no diagnostics")


# ─── Round 2 fixes (CR feedback) ───

func test_bare_chapter_with_no_id_emits_error_and_skips_append():
	# CR sonnet BLOCKING / opus #5: `@chapter` without an id silently produces
	# a chapter with id="" that downstream code (get_chapter_for_scene) treats
	# as orphan, hiding the bug. Validate at parse time.
	var data = _parse("@chapter\n@scene s")
	assert_true(_has_diagnostic(data, "error", "missing id"),
		"bare @chapter should produce a 'missing id' diagnostic")
	# The chapter must NOT be appended to data.chapters (otherwise ""-id chapter
	# pollutes lookups).
	for ch in data.chapters:
		assert_ne(ch.id, "", "no chapter with empty id should be in data.chapters")


func test_chapter_with_only_quoted_title_emits_error():
	# `@chapter "序章"` has a display name but no bare id → ch.id == "" → same
	# trap as bare @chapter.
	var data = _parse('@chapter "序章"\n@scene s')
	assert_true(_has_diagnostic(data, "error", "missing id"),
		"quoted-only @chapter should produce a 'missing id' diagnostic")


func test_duplicate_chapter_id_emits_error():
	# CR opus #4: silent correctness hazard for PR-C jump-by-id lookup.
	var data = _parse("""@chapter ch
@scene a
@chapter ch
@scene b""")
	assert_true(_has_diagnostic(data, "error", "duplicate"),
		"duplicate chapter id should produce a 'duplicate' diagnostic")
	# Only the FIRST chapter is registered; the duplicate is rejected.
	assert_eq(data.chapters.size(), 1)


func test_chapter_inside_parallel_block_emits_error():
	# CR sonnet should-fix #2: symmetry with @if guard.
	var data = _parse("""@chapter c
@scene s
@parallel
@chapter inner
@end""")
	assert_true(_has_diagnostic(data, "error", "@parallel"),
		"chapter inside @parallel should error")


func test_chapter_inside_combine_block_emits_error():
	var data = _parse("""@chapter c
@scene s
@combine
sakura「a」
@chapter inner
@end""")
	assert_true(_has_diagnostic(data, "error", "@combine"),
		"chapter inside @combine should error")


func test_synthetic_if_scenes_inherit_chapter_id():
	# CR sonnet should-fix #3: __if_*_then / __else / __cont scenes are
	# created during @if expansion. They MUST inherit chapter_id from the
	# enclosing scene's chapter, otherwise PR-C/D's flowchart builder sees
	# them as orphans.
	var data = _parse("""@chapter prologue
@scene start
@if some_flag
sakura「then」
@else
sakura「else」
@end
sakura「after」""")
	for scene in data.scenes:
		if scene.id.begins_with("__if_"):
			assert_eq(scene.chapter_id, "prologue",
				"synthetic scene %s should inherit chapter_id from enclosing chapter" % scene.id)


func test_synthetic_elif_scenes_inherit_chapter_id():
	# Follow-up from PR #100 round 2: __elif_* synthetic scenes (created by
	# _close_elif_into_parent) also need to inherit chapter_id. Round-2 fix
	# set this but lacked dedicated test coverage.
	var data = _parse("""@chapter prologue
@scene start
@if x >= 10
sakura「branch a」
@elif x >= 5
sakura「branch b」
@else
sakura「branch c」
@end
sakura「after」""")
	var saw_elif := false
	for scene in data.scenes:
		if scene.id.begins_with("__elif_"):
			saw_elif = true
			assert_eq(scene.chapter_id, "prologue",
				"synthetic elif scene %s should inherit chapter_id" % scene.id)
	assert_true(saw_elif, "test scenario should produce at least one __elif_* scene")


func test_scene_data_declared_line_set_by_parser():
	# Prep chore for PR-B graph builder: scenes need source-range info so
	# the graph builder can report "scene X on line N" for orphan warnings.
	var data = _parse("""@chapter prologue
@scene a
sakura「one」
@scene b
sakura「two」""")
	assert_eq(data.scenes[0].declared_line, 2)
	assert_eq(data.scenes[1].declared_line, 4)


func test_chapter_data_declared_line_set_by_parser():
	# CR opus #2: empty-chapter diagnostic needs a real line number, requiring
	# the parser to capture declared_line on ChapterData.
	var data = _parse("""@chapter prologue
@scene s

@chapter ch1
@scene s2""")
	assert_eq(data.chapters[0].declared_line, 1)
	assert_eq(data.chapters[1].declared_line, 4)


func test_empty_chapter_diagnostic_includes_real_line_number():
	# Use line >= 1 (was 0 in round 1, breaking author UX).
	var data = _parse("@chapter empty\n@chapter has_scene\n@scene s")
	for d in data.diagnostics:
		if "empty" in d.get("message", ""):
			assert_gt(d.get("line", 0), 0,
				"empty-chapter diagnostic should carry a real line number")


func test_diagnostics_sorted_by_line():
	# CR opus #3: post-parse validation errors arrive after the in-line scan,
	# but should be reordered by line so authors see issues in source order.
	var data = _parse("""@chapter empty
@chapter has_scene
@scene legit
@if x
@chapter inside_if
@end""")
	# Diagnostics should be sorted by line ascending.
	var prev_line = -1
	for d in data.diagnostics:
		var line = int(d.get("line", 0))
		assert_true(line >= prev_line,
			"diagnostics should be sorted by line; saw %d after %d" % [line, prev_line])
		prev_line = line
