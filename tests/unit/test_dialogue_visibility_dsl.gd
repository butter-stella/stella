extends GutTest
## Frozen parser/Profile contract for issue #166.
##
## The production classes and parser branches do not exist on the red baseline.
## This file therefore reaches the feature only through existing public parser
## and Resource APIs: failures are contract assertions, never missing preloads.


const SOURCE_PATH := \
	"res://tests/fixtures/scenarios/dialogue/dialogue_visibility_parser.stla"


func _parse(source: String) -> ScenarioData:
	return DslParser.parse(
		DslLexer.tokenize(source),
		"dialogue_visibility_parser_contract",
		SOURCE_PATH,
	)


func _all_commands(data: ScenarioData) -> Array[CommandData]:
	var commands: Array[CommandData] = []
	for scene_value: Variant in data.scenes:
		var scene: SceneData = scene_value
		for command_value: Variant in scene.commands:
			commands.append(command_value as CommandData)
	return commands


func _presentation_batches(data: ScenarioData) -> Array[CommandData]:
	return _all_commands(data).filter(
		func(command: CommandData) -> bool:
			return command.type == "presentation_batch"
	)


func _error_diagnostics(data: ScenarioData) -> Array:
	return data.diagnostics.filter(
		func(diagnostic: Dictionary) -> bool:
			return String(diagnostic.get("level", "")) == "error"
	)


func _has_error_at(data: ScenarioData, line: int, message_part: String = "") -> bool:
	for diagnostic_value: Variant in data.diagnostics:
		var diagnostic: Dictionary = diagnostic_value
		if String(diagnostic.get("level", "")) != "error":
			continue
		if int(diagnostic.get("line", -1)) != line:
			continue
		if not message_part.is_empty() and message_part not in String(
			diagnostic.get("message", "")
		):
			continue
		return String(diagnostic.get("source_path", SOURCE_PATH)) == SOURCE_PATH
	return false


func _assert_single_error_at(
	data: ScenarioData,
	line: int,
	message_part: String,
	label: String,
) -> void:
	var errors := _error_diagnostics(data)
	assert_eq(errors.size(), 1, "%s emits exactly one error" % label)
	if errors.size() != 1:
		return
	var error: Dictionary = errors[0]
	assert_eq(int(error.get("line", -1)), line,
		"%s error stays on its offending child" % label)
	assert_true(message_part in String(error.get("message", "")),
		"%s error names the illegal child" % label)
	assert_eq(String(error.get("source_path", SOURCE_PATH)), SOURCE_PATH,
		"%s error preserves source provenance" % label)


func _sorted_keys(value: Dictionary) -> Array:
	var keys := value.keys()
	keys.sort()
	return keys


func _profile_group_values(value: Variant) -> Array[String]:
	var result: Array[String] = []
	if value is Array or value is PackedStringArray:
		for item: Variant in value:
			result.append(String(item))
	return result


func _property_names(object: Object) -> Array[String]:
	var names: Array[String] = []
	for property_value: Variant in object.get_property_list():
		var property: Dictionary = property_value
		names.append(String(property.get("name", "")))
	return names


func test_standalone_cut_lowers_to_one_join_batch_with_exact_defaults() -> void:
	var data := _parse("""@chapter synthetic
@scene start
@dialogue_visibility surface hide""")
	assert_eq(_error_diagnostics(data), [], str(data.diagnostics))
	var batches := _presentation_batches(data)
	assert_eq(batches.size(), 1,
		"standalone visibility is one addressable presentation batch")
	if batches.size() != 1:
		return
	var batch: CommandData = batches[0]
	assert_eq(batch.declared_line, 3)
	assert_eq(_sorted_keys(batch.params), [
		"operation_lines", "operations", "policy",
	])
	assert_eq(batch.get_string("policy"), "join")
	assert_eq(batch.params["operation_lines"], [3])
	var operations: Array = batch.params["operations"]
	assert_eq(operations.size(), 1)
	if operations.size() != 1:
		return
	assert_eq(_sorted_keys(operations[0]), ["kind", "payload"])
	assert_eq(operations[0]["kind"], "dialogue_visibility")
	assert_eq(operations[0]["payload"], {
		"target": "surface",
		"action": "hide",
		"transition": "cut",
		"duration": 0.0,
	})


func test_standalone_fade_and_quick_menu_defaults_are_canonical() -> void:
	var data := _parse("""@chapter synthetic
@scene start
@dialogue_visibility surface show transition=fade
@dialogue_visibility quick_menu hide transition=fade duration=0.5
@dialogue_visibility quick_menu show transition=cut duration=0""")
	assert_eq(_error_diagnostics(data), [], str(data.diagnostics))
	var batches := _presentation_batches(data)
	assert_eq(batches.size(), 3)
	if batches.size() != 3:
		return
	assert_eq(batches[0].params["operations"][0]["payload"]["duration"], 0.25)
	assert_eq(batches[1].params["operations"][0]["payload"]["duration"], 0.5)
	assert_eq(batches[2].params["operations"][0]["payload"]["duration"], 0.0)
	assert_eq(batches[1].params["operations"][0]["payload"]["target"],
		"quick_menu")


func test_mixed_join_preserves_exact_authored_order_and_source_lines() -> void:
	var data := _parse("""@chapter synthetic
@scene start
@presentation_batch policy=join
  @stage sakura show asset=stage:redraw_source transition=fade duration=0.3
  @dialogue_visibility surface hide transition=fade duration=0.3
  @dialogue_visibility quick_menu hide transition=fade duration=0.3
@end""")
	assert_eq(_error_diagnostics(data), [], str(data.diagnostics))
	var batches := _presentation_batches(data)
	assert_eq(batches.size(), 1)
	if batches.size() != 1:
		return
	var batch: CommandData = batches[0]
	assert_eq(batch.declared_line, 3)
	assert_eq(batch.params["operation_lines"], [4, 5, 6])
	assert_eq(batch.get_string("policy"), "join")
	var operations: Array = batch.params["operations"]
	assert_eq(operations.map(
		func(operation: Dictionary) -> String:
			return String(operation.get("kind", ""))
	), ["stage", "dialogue_visibility", "dialogue_visibility"])
	if operations.size() != 3:
		return
	assert_eq(_sorted_keys(operations[0]["payload"]), [
		"action", "duration", "id", "properties", "transition",
	])
	assert_eq(operations[1]["payload"]["target"], "surface")
	assert_eq(operations[2]["payload"]["target"], "quick_menu")


func test_fire_and_forget_allows_stage_clear_with_visibility_siblings() -> void:
	var data := _parse("""@chapter synthetic
@scene start
@presentation_batch policy=fire_and_forget
  @dialogue_visibility surface show transition=fade duration=0.2
  @stage clear transition=fade duration=0.2
  @dialogue_visibility quick_menu show transition=fade duration=0.2
@end""")
	assert_eq(_error_diagnostics(data), [], str(data.diagnostics))
	var batches := _presentation_batches(data)
	assert_eq(batches.size(), 1)
	if batches.size() == 1:
		assert_eq(batches[0].get_string("policy"), "fire_and_forget")
		assert_eq(batches[0].params["operation_lines"], [4, 5, 6])


func test_stage_batch_remains_stage_only_and_never_becomes_a_mixed_alias() -> void:
	var data := _parse("""@chapter synthetic
@scene start
@stage_batch policy=join
  @stage hero show asset=stage:redraw_source
  @dialogue_visibility surface hide
@end
「recovered tail」""")
	assert_eq(_presentation_batches(data).size(), 0)
	var stage_batches := _all_commands(data).filter(
		func(command: CommandData) -> bool:
			return command.type == "stage_batch"
	)
	assert_eq(stage_batches.size(), 0,
		"legacy @stage_batch must reject a Dialogue visibility child atomically")
	assert_true(_has_error_at(data, 5))
	assert_eq(_all_commands(data).filter(
		func(command: CommandData) -> bool:
			return command.type == "dialogue"
	).size(), 1, "parser recovers at the command following the invalid block")


func test_presentation_batch_is_valid_inside_the_taken_if_branch() -> void:
	var data := _parse("""@chapter synthetic
@scene start
@if route == 1
  @presentation_batch policy=join
    @dialogue_visibility surface hide
  @end
@end""")
	assert_eq(_error_diagnostics(data), [], str(data.diagnostics))
	var batches := _presentation_batches(data)
	assert_eq(batches.size(), 1)
	if batches.size() == 1:
		assert_eq(batches[0].declared_line, 4)
		assert_eq(batches[0].params["operation_lines"], [5])


func test_batch_headers_are_strict_and_fail_closed_at_the_opening_line() -> void:
	var headers := [
		"@presentation_batch",
		"@presentation_batch join",
		"@presentation_batch mode=join",
		"@presentation_batch policy=join policy=join",
		"@presentation_batch policy=JOIN",
		"@presentation_batch policy=Fire_And_Forget",
		"@presentation_batch policy=unknown",
	]
	for header: String in headers:
		var data := _parse("""@chapter synthetic
@scene start
%s
  @dialogue_visibility surface hide
@end""" % header)
		assert_eq(_presentation_batches(data).size(), 0, header)
		assert_eq(_all_commands(data).size(), 0,
			"invalid header cannot leak a visibility child: %s" % header)
		assert_true(_has_error_at(data, 3), header)


func test_standalone_visibility_tokens_and_duration_are_strict() -> void:
	var commands := [
		"@dialogue_visibility Surface hide",
		"@dialogue_visibility surface Hide",
		"@dialogue_visibility panel hide",
		"@dialogue_visibility surface toggle",
		"@dialogue_visibility surface hide transition=Fade",
		"@dialogue_visibility surface hide transition=move",
		"@dialogue_visibility surface hide transition=cut duration=0.1",
		"@dialogue_visibility surface hide transition=fade duration=-1",
		"@dialogue_visibility surface hide transition=fade duration=nan",
		"@dialogue_visibility surface hide transition=fade duration=inf",
		"@dialogue_visibility surface hide duration=1 duration=2",
		"@dialogue_visibility surface hide unknown=true",
		"@dialogue_visibility surface hide extra",
	]
	for authored_command: String in commands:
		var data := _parse("""@chapter synthetic
@scene start
%s""" % authored_command)
		assert_eq(_presentation_batches(data).size(), 0, authored_command)
		assert_true(_has_error_at(data, 3), authored_command)


func test_duplicate_targets_stage_conflicts_and_illegal_children_fail_atomically() -> void:
	var cases: Array[Dictionary] = [
		{
			"label": "duplicate surface",
			"children": "  @dialogue_visibility surface hide\n"
				+ "  @dialogue_visibility surface show",
			"line": 5,
		},
		{
			"label": "duplicate quick menu",
			"children": "  @dialogue_visibility quick_menu hide\n"
				+ "  @dialogue_visibility quick_menu show",
			"line": 5,
		},
		{
			"label": "duplicate Stage layer",
			"children": "  @stage hero show asset=stage:redraw_source\n"
				+ "  @stage hero hide",
			"line": 5,
		},
		{
			"label": "clear conflicts with Stage sibling",
			"children": "  @stage hero show asset=stage:redraw_source\n"
				+ "  @stage clear",
			"line": 5,
		},
		{
			"label": "dialogue child",
			"children": "  「not a presentation operation」",
			"line": 4,
		},
		{
			"label": "nested generic batch",
			"children": "  @presentation_batch policy=join\n"
				+ "    @dialogue_visibility surface hide\n  @end",
			"line": 4,
		},
		{
			"label": "nested stage batch",
			"children": "  @stage_batch policy=join\n"
				+ "    @stage hero show asset=stage:redraw_source\n  @end",
			"line": 4,
		},
		{
			"label": "nested if",
			"children": "  @if flag\n"
				+ "    @dialogue_visibility surface hide\n  @end",
			"line": 4,
		},
		{
			"label": "parallel child",
			"children": "  @parallel\n"
				+ "    @dialogue_visibility surface hide\n  @end",
			"line": 4,
		},
		{
			"label": "combine child",
			"children": "  @combine\n"
				+ "    「valid combined dialogue」\n  @end",
			"line": 4,
		},
		{
			"label": "BGM child",
			"children": "  @bgm bgm_theme",
			"line": 4,
		},
		{
			"label": "SE child",
			"children": "  @se se_select",
			"line": 4,
		},
		{
			"label": "voice child",
			"children": "  @voice voice_line",
			"line": 4,
		},
		{
			"label": "wait child",
			"children": "  @wait 0.1",
			"line": 4,
		},
		{
			"label": "ADV mode child",
			"children": "  @adv",
			"line": 4,
		},
		{
			"label": "NVL mode child",
			"children": "  @nvl",
			"line": 4,
		},
		{
			"label": "overlay mode child",
			"children": "  @overlay",
			"line": 4,
		},
		{
			"label": "chapter indicator child",
			"children": "  @chapter_indicator show",
			"line": 4,
		},
	]
	for case_value: Variant in cases:
		var case: Dictionary = case_value
		var data := _parse("""@chapter synthetic
@scene start
@presentation_batch policy=join
%s
@end""" % String(case["children"]))
		assert_eq(_presentation_batches(data).size(), 0, String(case["label"]))
		assert_eq(_all_commands(data).size(), 0,
			"invalid mixed block is atomic: %s" % case["label"])
		assert_true(_has_error_at(data, int(case["line"])),
			String(case["label"]))
		var purity_token := ""
		if case["label"] == "combine child":
			purity_token = "combine"
		elif case["label"] == "chapter indicator child":
			purity_token = "chapter_indicator"
		if not purity_token.is_empty():
			_assert_single_error_at(data, 4, purity_token,
				"initial %s" % case["label"])

		var recovered := _parse("""@chapter synthetic
@scene broken
@presentation_batch policy=join
%s
@end
@scene recovered
@dialogue_visibility surface show""" % String(case["children"]))
		var broken := recovered.get_scene("broken")
		var recovered_scene := recovered.get_scene("recovered")
		assert_not_null(broken, String(case["label"]))
		assert_not_null(recovered_scene, String(case["label"]))
		if broken != null:
			assert_eq(broken.commands, [],
				"illegal block leaks no child: %s" % case["label"])
		if recovered_scene != null:
			assert_eq(recovered_scene.commands.size(), 1,
				"parser recovers after illegal child: %s" % case["label"])
			if recovered_scene.commands.size() == 1:
				assert_eq(recovered_scene.commands[0].type,
					"presentation_batch")
		if not purity_token.is_empty():
			_assert_single_error_at(recovered, 4, purity_token,
				"recovery %s" % case["label"])
			assert_eq(_presentation_batches(recovered).size(), 1,
				"recovery contains one valid presentation_batch: %s"
				% case["label"])


func test_empty_gap_and_missing_end_errors_recover_without_child_leaks() -> void:
	var empty := _parse("""@chapter synthetic
@scene start
@presentation_batch policy=join
@end""")
	assert_eq(_presentation_batches(empty).size(), 0)
	assert_true(_has_error_at(empty, 3))

	var gap := _parse("""@presentation_batch policy=join
  @dialogue_visibility surface hide
@end
@chapter synthetic
@scene recovered
「tail」""")
	assert_eq(_presentation_batches(gap).size(), 0)
	assert_true(_has_error_at(gap, 1))
	assert_not_null(gap.get_scene("recovered"))

	var missing_end := _parse("""@chapter synthetic
@scene broken
@presentation_batch policy=join
  @dialogue_visibility surface hide
@scene recovered
「tail」""")
	assert_eq(_presentation_batches(missing_end).size(), 0)
	assert_true(_has_error_at(missing_end, 3))
	assert_not_null(missing_end.get_scene("recovered"),
		"missing @end cannot consume the next scene boundary")


func test_profile_ownership_fields_parse_exact_group_lists() -> void:
	var data := _parse("""@dialogue_profile message surface_groups=dialogue_surface,content_alt quick_menu_groups=quick_menu,action_strip
@chapter synthetic
@scene start
@adv profile=message
「profile ownership」""")
	assert_eq(_error_diagnostics(data), [], str(data.diagnostics))
	var profile := data.get_dialogue_profile("message")
	assert_eq(_profile_group_values(profile.get("surface_groups", [])), [
		"dialogue_surface", "content_alt",
	])
	assert_eq(_profile_group_values(profile.get("quick_menu_groups", [])), [
		"quick_menu", "action_strip",
	])
	assert_true(profile.has("surface_groups"))
	assert_true(profile.has("quick_menu_groups"))
	var provenance := data.get_dialogue_profile_provenance("message")
	assert_eq(provenance.get("source_path"), SOURCE_PATH)
	assert_eq(provenance.get("field_lines", {}).get("surface_groups"), 1)
	assert_eq(provenance.get("field_lines", {}).get("quick_menu_groups"), 1)


func test_profile_ownership_defaults_match_resource_fallback() -> void:
	var data := _parse("""@dialogue_profile defaults horizontal_alignment=left
@chapter synthetic
@scene start
@adv profile=defaults
「defaults」""")
	assert_eq(_error_diagnostics(data), [], str(data.diagnostics))
	var profile := data.get_dialogue_profile("defaults")
	assert_eq(_profile_group_values(profile.get("surface_groups", [])), [
		"dialogue_surface",
	])
	assert_eq(_profile_group_values(profile.get("quick_menu_groups", [])), [
		"quick_menu",
	])

	var resource_profile := DialogueModeProfile.new()
	var property_names := _property_names(resource_profile)
	assert_has(property_names, "surface_groups")
	assert_has(property_names, "quick_menu_groups")
	if (
		"surface_groups" in property_names
		and "quick_menu_groups" in property_names
	):
		assert_eq(_profile_group_values(resource_profile.get("surface_groups")), [
			"dialogue_surface",
		])
		assert_eq(_profile_group_values(resource_profile.get("quick_menu_groups")), [
			"quick_menu",
		])


func test_profile_group_grammar_duplicates_and_overlap_fail_atomically() -> void:
	var declarations := [
		"surface_groups=BadName",
		"surface_groups=dialogue-surface",
		"surface_groups=_private",
		"surface_groups=dialogue_surface,dialogue_surface",
		"quick_menu_groups=quick_menu,quick_menu",
		"surface_groups=shared quick_menu_groups=shared",
		"surface_groups=dialogue_surface, quick_menu_groups=quick_menu",
	]
	for fields: String in declarations:
		var data := _parse("""@dialogue_profile broken %s
@chapter synthetic
@scene start
@adv profile=broken
「invalid profile」""" % fields)
		assert_true(data.get_dialogue_profile("broken").is_empty(), fields)
		assert_true(_has_error_at(data, 1), fields)


func test_profile_overlap_across_declarations_blames_the_later_line() -> void:
	var data := _parse("""@dialogue_profile merged surface_groups=dialogue_surface,shared
@dialogue_profile merged quick_menu_groups=quick_menu
@dialogue_profile merged quick_menu_groups=shared
@chapter synthetic
@scene start
@adv profile=merged
「invalid merged profile」""")
	assert_true(data.get_dialogue_profile("merged").is_empty())
	assert_true(_has_error_at(data, 3, "shared"),
		"cross-declaration overlap is owned by the later declaration")
