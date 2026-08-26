extends GutTest
## Public synthetic contract tests for issue #170.
##
## These tests deliberately discover the optional presenter by resource path
## before loading it.  That keeps the pre-feature baseline importable and makes
## the red result describe the missing public capability instead of a preload
## or test-script parse failure.


const PRESENTER_PATH := \
	"res://addons/stella/presentation/ui/chapter_indicator_presenter.gd"
const SYNTHETIC_SOURCE_PATH := \
	"res://tests/fixtures/scenarios/chapter_indicator/contract.stla"


func _parse(source: String, source_path: String = SYNTHETIC_SOURCE_PATH) -> ScenarioData:
	return DslParser.parse(DslLexer.tokenize(source), "chapter_contract", source_path)


func _chapter_indicator_commands(data: ScenarioData) -> Array:
	var result: Array = []
	for scene_value: Variant in data.scenes:
		var scene: SceneData = scene_value
		for command_value: Variant in scene.commands:
			var command: CommandData = command_value
			if command.type == "chapter_indicator":
				result.append(command)
			elif command.type == "presentation_batch":
				var operations: Array = command.params.get("operations", [])
				var lines: Array = command.params.get("operation_lines", [])
				for index in range(operations.size()):
					var operation: Dictionary = operations[index]
					if String(operation.get("kind", "")) != "chapter_indicator":
						continue
					var lowered := CommandData.new()
					lowered.type = "chapter_indicator"
					lowered.params = (operation.get("payload", {}) as Dictionary).duplicate(true)
					lowered.declared_line = int(lines[index])
					result.append(lowered)
	return result


func _error_diagnostics(data: ScenarioData) -> Array:
	return data.diagnostics.filter(
		func(diagnostic: Dictionary) -> bool:
			return String(diagnostic.get("level", "")) == "error"
	)


func _runtime() -> Node:
	return get_tree().root.get_node("StellaRuntime")


func test_public_surface_is_registered_without_internal_runtime_access() -> void:
	var runtime := _runtime()
	assert_true(runtime.has_method("get_current_chapter_id"),
		"Facade must expose get_current_chapter_id()")
	assert_true(runtime.has_method("get_current_chapter_title"),
		"Facade must expose get_current_chapter_title()")
	assert_true(runtime.has_method("is_chapter_indicator_visible"),
		"Facade must expose authored indicator visibility")
	assert_true(SignalBus.has_signal("current_chapter_changed"),
		"SignalBus must publish resolved chapter identity/title")
	assert_true(ResourceLoader.exists(PRESENTER_PATH, "Script"),
		"the reusable skinnable presenter must exist at its public path")


func test_runtime_composition_registers_chapter_indicator_handler() -> void:
	# This is an explicit composition-root assertion, not a project-facing API
	# example.  Public behavior is covered end-to-end from a real .stla fixture
	# in the integration suite.
	var registry: Variant = _runtime().get("registry")
	assert_not_null(registry, "test setup requires StellaRuntime's registry")
	assert_true(registry != null and registry.has_handler("chapter_indicator"),
		"StellaRuntime must register the authored command handler")


func test_facade_empty_policy_without_an_active_scenario() -> void:
	var runtime := _runtime()
	if not (
		runtime.has_method("get_current_chapter_id")
		and runtime.has_method("get_current_chapter_title")
		and runtime.has_method("is_chapter_indicator_visible")
	):
		assert_true(false, "chapter Facade methods are not implemented")
		return
	assert_eq(String(runtime.call("get_current_chapter_id")), "")
	assert_eq(String(runtime.call("get_current_chapter_title")), "")
	assert_false(bool(runtime.call("is_chapter_indicator_visible")))


func test_dsl_compiles_canonical_show_hide_operations_and_defaults() -> void:
	var data := _parse("""@chapter prologue \"chapter.prologue\"
@scene start
@chapter_indicator show
@chapter_indicator hide transition=fade
@chapter_indicator show transition=fade duration=0.5
@chapter_indicator hide transition=none
@chapter_indicator show transition=fade duration=0.0
""")
	var commands := _chapter_indicator_commands(data)
	assert_eq(_error_diagnostics(data), [],
		"valid indicator operations must not produce parse errors")
	assert_eq(commands.size(), 5,
		"each authored operation must survive into addressable IR")
	if commands.size() != 5:
		return

	assert_eq(commands[0].params, {
		"action": "show", "transition": "cut", "duration": 0.0,
	})
	assert_eq(commands[1].params, {
		"action": "hide", "transition": "fade", "duration": 0.25,
	})
	assert_eq(commands[2].params, {
		"action": "show", "transition": "fade", "duration": 0.5,
	})
	assert_eq(commands[3].params, {
		"action": "hide", "transition": "cut", "duration": 0.0,
	}, "none is an authoring alias and must canonicalize to cut")
	assert_eq(commands[4].params, {
		"action": "show", "transition": "fade", "duration": 0.0,
	}, "an authored zero-duration fade remains a legal fade operation")
	for index in range(commands.size()):
		assert_eq(commands[index].declared_line, index + 3,
			"IR must retain the authored source line")


func test_none_alias_and_explicit_cut_share_a_semantic_fingerprint() -> void:
	var none_data := _parse(
		"@chapter c \"C\"\n@scene start\n"
		+ "@chapter_indicator show transition=none\n")
	var cut_data := _parse(
		"@chapter c \"C\"\n@scene start\n"
		+ "@chapter_indicator show transition=cut\n")
	assert_eq(_error_diagnostics(none_data), [])
	assert_eq(_error_diagnostics(cut_data), [])
	assert_eq(none_data.content_fingerprint, cut_data.content_fingerprint,
		"equivalent alias spelling cannot invalidate save/read identity")


func test_invalid_dsl_operation_is_source_located_and_atomic() -> void:
	var cases := [
		["@chapter_indicator", "action"],
		["@chapter_indicator toggle", "toggle"],
		["@chapter_indicator show fade", "key=value"],
		["@chapter_indicator show easing=smooth", "easing"],
		["@chapter_indicator show transition=warp", "warp"],
		["@chapter_indicator show transition=fade transition=cut", "duplicate"],
		["@chapter_indicator show duration=0.1 duration=0.2", "duplicate"],
		["@chapter_indicator show duration=-0.1", "non-negative"],
		["@chapter_indicator show duration=nan", "finite"],
		["@chapter_indicator show transition=cut duration=0.1", "duration"],
		["@chapter_indicator show transition=none duration=0.1", "duration"],
	]
	for case_value: Variant in cases:
		var case: Array = case_value
		var source := "@chapter c \"C\"\n@scene start\n%s\n@wait click\n" % case[0]
		var data := _parse(source)
		assert_eq(_chapter_indicator_commands(data).size(), 0,
			"invalid operation must not leave partial IR: %s" % case[0])
		var errors := _error_diagnostics(data)
		assert_gt(errors.size(), 0, "invalid operation must diagnose: %s" % case[0])
		if errors.is_empty():
			continue
		var combined := ""
		for diagnostic_value: Variant in errors:
			var diagnostic: Dictionary = diagnostic_value
			combined += String(diagnostic.get("message", "")) + "\n"
			assert_eq(int(diagnostic.get("line", 0)), 3,
				"diagnostic line must point at the rejected operation")
		assert_true(SYNTHETIC_SOURCE_PATH + ":3" in combined,
			"diagnostic must include public source_path:line: %s" % combined)
		assert_true(String(case[1]).to_lower() in combined.to_lower(),
			"diagnostic must identify the bad field/value: %s" % combined)


func test_indicator_legality_at_block_and_scene_boundaries() -> void:
	var boundary_cases := [
		[
			"@chapter c \"C\"\n@chapter_indicator show\n@scene start\n",
			2,
		],
		[
			"@chapter_indicator show\n@chapter c \"C\"\n@scene start\n",
			1,
		],
		[
			"""@chapter c "C"
@scene start
@combine
@chapter_indicator show
narrator「segment」
@end
""",
			4,
		],
	]
	for case_value: Variant in boundary_cases:
		var case: Array = case_value
		var data := _parse(String(case[0]))
		assert_eq(_chapter_indicator_commands(data).size(), 0,
			"illegal placement must not leave executable IR")
		var matched := false
		for diagnostic_value: Variant in _error_diagnostics(data):
			var diagnostic: Dictionary = diagnostic_value
			if (
				int(diagnostic.get("line", 0)) == int(case[1])
				and "chapter_indicator" in String(
					diagnostic.get("message", "")).to_lower()
				and (
					SYNTHETIC_SOURCE_PATH + ":%d" % int(case[1])
				) in String(diagnostic.get("message", ""))
			):
				matched = true
		assert_true(matched,
			"illegal placement must be diagnosed at its authored line")


func test_indicator_invalidates_whole_parallel_block() -> void:
	var data := _parse("""@chapter c "C"
@scene start
@parallel
@set should_not_run = true
@chapter_indicator show
@end
""")
	assert_eq(_chapter_indicator_commands(data).size(), 0)
	var command_types: Array = []
	for command_value: Variant in data.scenes[0].commands:
		command_types.append((command_value as CommandData).type)
	assert_false("parallel" in command_types,
		"one blocking indicator child invalidates the whole parallel block")
	var combined := ""
	for diagnostic_value: Variant in _error_diagnostics(data):
		combined += String((diagnostic_value as Dictionary).get("message", ""))
	assert_true("parallel" in combined.to_lower())
	assert_true(SYNTHETIC_SOURCE_PATH + ":5" in combined)


func test_programmatic_parallel_preflight_rejects_before_any_child_side_effect() -> void:
	var runtime := _runtime()
	var registry: Variant = runtime.get("registry")
	var parallel_handler: Variant = (
		registry.get_handler("parallel") if registry != null else null
	)
	assert_not_null(parallel_handler)
	if parallel_handler == null:
		return
	var data := _parse("@chapter c \"C\"\n@scene start\n")
	var context := ScenarioContext.new(data)
	context.variable_store = VariableStore.new()
	var first := CommandData.new()
	first.type = "set"
	first.params = {"var": "parallel_first_ran", "value": true}
	var blocker := CommandData.new()
	blocker.type = "chapter_indicator"
	blocker.params = {
		"action": "show", "transition": "cut", "duration": 0.0,
	}
	var last := CommandData.new()
	last.type = "set"
	last.params = {"var": "parallel_last_ran", "value": true}
	var wrapper := CommandData.new()
	wrapper.type = "parallel"
	wrapper.params = {"commands": [first, blocker, last]}

	await parallel_handler.execute(wrapper, context)
	assert_push_warning("blocking 'chapter_indicator' child is not allowed")
	assert_eq(context.variable_store.get_var("parallel_first_ran"), null,
		"parallel preflight happens before the harmless first child")
	assert_eq(context.variable_store.get_var("parallel_last_ran"), null,
		"parallel preflight rejects the entire programmatic batch")
	assert_false(bool(context.capture_snapshot().get(
		"chapter_indicator_visible", true)),
		"the blocking child itself is never dispatched")


func test_indicator_is_legal_on_executed_conditional_branches() -> void:
	var data := _parse("""@chapter c "C"
@scene start
@if route_open
@chapter_indicator show
@else
@chapter_indicator hide
@end
""")
	assert_eq(_error_diagnostics(data), [])
	var commands := _chapter_indicator_commands(data)
	assert_eq(commands.size(), 2,
		"both conditional branch operations must survive CFG lowering")
	if commands.size() == 2:
		var actions := [commands[0].get_string("action"), commands[1].get_string("action")]
		actions.sort()
		assert_eq(actions, ["hide", "show"])


func test_context_visibility_defaults_hidden_and_roundtrips_independently() -> void:
	var data := _parse("@chapter c \"C\"\n@scene start\n")
	var context := ScenarioContext.new(data)
	var initial := context.capture_snapshot()
	assert_true(initial.has("chapter_indicator_visible"),
		"visibility is canonical ScenarioContext state")
	assert_false(bool(initial.get("chapter_indicator_visible", true)),
		"a new scenario starts authored-hidden")

	context.restore_snapshot({
		"scene_index": 0,
		"command_index": 0,
		"chapter_indicator_visible": true,
	})
	assert_true(bool(context.capture_snapshot().get(
		"chapter_indicator_visible", false)),
		"visibility must survive snapshot restore")

	context.restore_snapshot({"scene_index": 0, "command_index": 0})
	assert_false(bool(context.capture_snapshot().get(
		"chapter_indicator_visible", true)),
		"legacy snapshots without the field restore hidden")


func test_save_validation_rejects_non_boolean_visibility_atomically() -> void:
	var data := _parse("@chapter c \"C\"\n@scene start\n")
	var context := ScenarioContext.new(data)
	var valid_snapshot := context.capture_snapshot()
	var manager := SaveManager.new()
	assert_true(manager.validate_data_for_scenario({
		"scenario_context": valid_snapshot,
		"presentation_clip_audio_choice": {
			"version": 1, "initialized": true,
			"initial_seed": 17, "state": 17, "last_choices": {},
		},
	}, data), "the synthetic control snapshot must be valid")

	var malformed := valid_snapshot.duplicate(true)
	malformed["chapter_indicator_visible"] = "true"
	assert_false(manager.validate_data_for_scenario({
		"scenario_context": malformed,
		"presentation_clip_audio_choice": {
			"version": 1, "initialized": true,
			"initial_seed": 17, "state": 17, "last_choices": {},
		},
	}, data), "present non-bool visibility must fail preflight")
	assert_eq(context.capture_snapshot(), valid_snapshot,
		"side-effect-free validation cannot partially mutate the live context")


func test_composed_handler_commits_headless_cut_and_fade_without_a_presenter() -> void:
	# Handler-level composition test.  It intentionally inspects the Runtime
	# registry; project-facing callers use the DSL/Facade integration test.
	var runtime := _runtime()
	var registry: Variant = runtime.get("registry")
	var handler: Variant = (
		registry.get_handler("chapter_indicator") if registry != null else null
	)
	assert_not_null(handler,
		"headless semantics require the registered public handler")
	if handler == null:
		return
	var data := _parse("""@chapter c \"C\"
@scene start
@chapter_indicator show transition=fade duration=5.0
@chapter_indicator hide
""")
	var commands := _chapter_indicator_commands(data)
	assert_eq(commands.size(), 2)
	if commands.size() != 2:
		return
	var context := ScenarioContext.new(data)
	await handler.execute(commands[0], context)
	assert_true(bool(context.capture_snapshot().get(
		"chapter_indicator_visible", false)),
		"zero presenters complete even a long authored fade synchronously")
	await handler.execute(commands[1], context)
	assert_false(bool(context.capture_snapshot().get(
		"chapter_indicator_visible", true)),
		"headless cut also commits the canonical authored target")


func test_initial_hidden_same_target_still_validates_presenter_atomically() -> void:
	var runtime := _runtime()
	var registry: Variant = runtime.get("registry")
	var handler: Variant = (
		registry.get_handler("chapter_indicator") if registry != null else null
	)
	assert_not_null(handler)
	assert_true(ResourceLoader.exists(PRESENTER_PATH, "Script"))
	if handler == null or not ResourceLoader.exists(PRESENTER_PATH, "Script"):
		return
	SignalBus.reset_chapter_indicator_presentation()

	var presenter := Control.new()
	presenter.name = "InvalidInitialHiddenSkin"
	presenter.modulate.a = 0.4
	presenter.set_script(load(PRESENTER_PATH))
	var untouched_label := Label.new()
	untouched_label.name = "ProjectOwnedTitle"
	untouched_label.text = "untouched"
	presenter.add_child(untouched_label)
	presenter.set("title_label_path", NodePath("MissingTitle"))
	add_child_autoqfree(presenter)
	await get_tree().process_frame

	var data := _parse("""@chapter c "C"
@scene start
@chapter_indicator hide
""")
	var commands := _chapter_indicator_commands(data)
	assert_eq(commands.size(), 1)
	if commands.size() != 1:
		return
	var context := ScenarioContext.new(data)
	var initial_snapshot := context.capture_snapshot()
	var initial_visible := presenter.visible
	var initial_modulate := presenter.modulate
	var initial_label_text := untouched_label.text
	var validation_count := [0]
	var apply_count := [0]
	var on_validate := func(_request: Variant) -> void:
		validation_count[0] += 1
	var on_apply := func(_request: Variant) -> void:
		apply_count[0] += 1
	SignalBus.chapter_indicator_validate_requested.connect(on_validate)
	SignalBus.chapter_indicator_apply_requested.connect(on_apply)

	await handler.execute(commands[0], context)
	SignalBus.chapter_indicator_validate_requested.disconnect(on_validate)
	SignalBus.chapter_indicator_apply_requested.disconnect(on_apply)
	assert_push_error(SYNTHETIC_SOURCE_PATH + ":3")
	assert_eq(validation_count[0], 1,
		"same-target commands still validate every snapshotted Presenter")
	assert_eq(apply_count[0], 0,
		"a rejected validation cannot enter the apply phase")
	var expected_snapshot := initial_snapshot.duplicate(true)
	expected_snapshot["is_finished"] = true
	assert_eq(context.capture_snapshot(), expected_snapshot,
		"binding rejection may only fail-close the owning Context")
	assert_eq(presenter.visible, initial_visible,
		"same-target validation failure cannot mutate visibility")
	assert_eq(presenter.modulate, initial_modulate,
		"same-target validation failure cannot mutate presentation alpha")
	assert_eq(untouched_label.text, initial_label_text,
		"same-target validation failure cannot write the unresolved binding")


func test_initial_hidden_same_target_is_sync_for_headless_and_valid_presenter() -> void:
	var runtime := _runtime()
	var registry: Variant = runtime.get("registry")
	var handler: Variant = (
		registry.get_handler("chapter_indicator") if registry != null else null
	)
	assert_not_null(handler)
	assert_true(ResourceLoader.exists(PRESENTER_PATH, "Script"))
	if handler == null or not ResourceLoader.exists(PRESENTER_PATH, "Script"):
		return
	SignalBus.reset_chapter_indicator_presentation()
	var data := _parse("""@chapter c "C"
@scene start
@chapter_indicator hide
""")
	var commands := _chapter_indicator_commands(data)
	assert_eq(commands.size(), 1)
	if commands.size() != 1:
		return

	var validation_count := [0]
	var apply_count := [0]
	var on_validate := func(_request: Variant) -> void:
		validation_count[0] += 1
	var on_apply := func(_request: Variant) -> void:
		apply_count[0] += 1
	SignalBus.chapter_indicator_validate_requested.connect(on_validate)
	SignalBus.chapter_indicator_apply_requested.connect(on_apply)
	var headless_context := ScenarioContext.new(data)
	await handler.execute(commands[0], headless_context)
	assert_false(headless_context.is_finished)
	assert_false(headless_context.chapter_indicator_visible)
	assert_false(runtime.get("presentation_director").has_blocking_waiter(
		headless_context), "a headless same-target operation cannot leave a barrier")
	assert_eq(validation_count[0], 1)
	assert_eq(apply_count[0], 1,
		"headless same-target still completes the typed dispatch synchronously")

	var presenter := Control.new()
	presenter.name = "ValidInitialHiddenSkin"
	presenter.set_script(load(PRESENTER_PATH))
	var label := Label.new()
	label.name = "ProjectOwnedTitle"
	label.text = "untouched"
	presenter.add_child(label)
	presenter.set("title_label_path", NodePath("ProjectOwnedTitle"))
	add_child_autoqfree(presenter)
	await get_tree().process_frame
	var initial_modulate := presenter.modulate
	var context := ScenarioContext.new(data)
	await handler.execute(commands[0], context)
	SignalBus.chapter_indicator_validate_requested.disconnect(on_validate)
	SignalBus.chapter_indicator_apply_requested.disconnect(on_apply)
	assert_false(context.is_finished)
	assert_false(context.chapter_indicator_visible)
	assert_false(presenter.visible)
	assert_eq(presenter.modulate, initial_modulate)
	assert_null(presenter.get("_active_tween"),
		"a valid same-target Presenter cannot create a no-work Tween")
	assert_false(runtime.get("presentation_director").has_blocking_waiter(context),
		"a valid no-work Presenter must acknowledge synchronously")
	assert_eq(validation_count[0], 2)
	assert_eq(apply_count[0], 2,
		"the valid Presenter participates in the complete typed dispatch")


func test_composed_handler_rejects_malformed_programmatic_commands() -> void:
	# Parser validation is not a trust boundary: extensions can construct
	# CommandData directly.  This composition test deliberately reaches the
	# registered handler, while keeping all private helper/protocol names out of
	# the contract.
	var runtime := _runtime()
	var registry: Variant = runtime.get("registry")
	var handler: Variant = (
		registry.get_handler("chapter_indicator") if registry != null else null
	)
	assert_not_null(handler,
		"closed-schema validation requires the composed handler")
	if handler == null:
		return
	var data := _parse("@chapter c \"C\"\n@scene start\n")
	var malformed_params: Array[Dictionary] = [
		{},
		{"action": 1, "transition": "cut", "duration": 0.0},
		{"action": "toggle", "transition": "cut", "duration": 0.0},
		{"action": "show", "duration": 0.0},
		{"action": "show", "transition": 1, "duration": 0.0},
		{"action": "show", "transition": "warp", "duration": 0.0},
		{"action": "show", "transition": "cut", "duration": 0},
		{"action": "show", "transition": "cut", "duration": "0.0"},
		{"action": "show", "transition": "cut", "duration": -0.1},
		{"action": "show", "transition": "cut", "duration": NAN},
		{"action": "show", "transition": "cut", "duration": INF},
		{"action": "show", "transition": "cut", "duration": 0.1},
		{
			"action": "show",
			"transition": "cut",
			"duration": 0.0,
			"private_extra": true,
		},
	]
	for params: Dictionary in malformed_params:
		var context := ScenarioContext.new(data)
		var initial_snapshot := context.capture_snapshot()
		var command := CommandData.new()
		command.type = "chapter_indicator"
		command.params = params
		command.declared_line = 7
		await handler.execute(command, context)
		assert_push_error(SYNTHETIC_SOURCE_PATH + ":7")
		var expected_snapshot := initial_snapshot.duplicate(true)
		expected_snapshot["is_finished"] = true
		assert_eq(context.capture_snapshot(), expected_snapshot,
			"malformed runtime input fail-closes only its owning context: %s" % [params])


func test_malformed_runtime_operation_stops_before_the_next_command() -> void:
	var runtime := _runtime()
	var registry: Variant = runtime.get("registry")
	assert_not_null(registry)
	if registry == null or not registry.has_handler("chapter_indicator"):
		assert_true(false, "chapter indicator handler is not composed")
		return
	var data := _parse("""@chapter c "C"
@scene start
@chapter_indicator show
@set sentinel_ran = true
""")
	var commands := _chapter_indicator_commands(data)
	assert_eq(commands.size(), 1)
	if commands.size() != 1:
		return
	var parsed_batch: CommandData = data.scenes[0].commands[0]
	parsed_batch.params["operations"][0]["payload"]["duration"] = "0.0"
	var engine := ScenarioEngine.new()
	engine.registry = registry
	engine.load_scenario(data)
	await engine.run()
	assert_push_error(SYNTHETIC_SOURCE_PATH + ":3")
	assert_true(engine.context.is_finished,
		"the invalid command must stop its exact owning context")
	assert_eq(engine.context.current_command_index, 0,
		"the failed command cursor must not advance")
	assert_eq(engine.context.variable_store.get_var("sentinel_ran"), null,
		"the command after an invalid operation must never execute")


func test_bare_empty_and_localized_title_metadata_policy() -> void:
	var bare := _parse("@chapter prologue\n@scene start\n")
	assert_eq(bare.chapters[0].display_name, "prologue",
		"bare @chapter title remains its stable id")
	var empty := _parse("@chapter silent \"\"\n@scene start\n")
	assert_eq(empty.chapters[0].display_name, "",
		"an explicitly empty title remains non-presentable")
	var keyed := _parse("@chapter keyed \"chapter.synthetic.title\"\n@scene start\n")
	assert_eq(keyed.chapters[0].display_name, "chapter.synthetic.title",
		"quoted title remains the TranslationServer source/key")


func test_same_presenter_binds_two_project_owned_geometries() -> void:
	assert_true(ResourceLoader.exists(PRESENTER_PATH, "Script"),
		"presenter script is missing")
	if not ResourceLoader.exists(PRESENTER_PATH, "Script"):
		return
	var presenter_script: Script = load(PRESENTER_PATH)
	assert_eq(presenter_script.get_global_name(), "ChapterIndicatorPresenter")

	var geometries := [Vector2(378.0, 96.0), Vector2(640.0, 144.0)]
	var presenters: Array = []
	var labels: Array = []
	for geometry: Vector2 in geometries:
		var presenter := Control.new()
		presenter.custom_minimum_size = geometry
		presenter.size = geometry
		presenter.set_script(presenter_script)
		var label := Label.new()
		label.name = "ProjectOwnedTitle"
		presenter.add_child(label)
		presenter.set("title_label_path", NodePath("ProjectOwnedTitle"))
		add_child_autoqfree(presenter)
		presenters.append(presenter)
		labels.append(label)
	await get_tree().process_frame

	for index in range(presenters.size()):
		assert_false(presenters[index].visible,
			"presenter root must start hidden")
		assert_eq(presenters[index].size, geometries[index],
			"Stella must not own project skin geometry")

	SignalBus.emit_signal(
		"current_chapter_changed", "chapter", "Localized chapter")
	for label_value: Variant in labels:
		var label: Label = label_value
		assert_eq(label.text, "Localized chapter",
			"both skins bind the same public title signal")
	for index in range(presenters.size()):
		assert_eq(presenters[index].size, geometries[index],
			"binding cannot rewrite project geometry")
