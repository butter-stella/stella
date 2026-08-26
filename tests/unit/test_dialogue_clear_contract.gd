extends GutTest
## Public synthetic contract for issue #169.  Missing production capability is
## discovered through global-class/method introspection so the baseline fails
## by an intentional assertion rather than by a preload or parser error.


const REQUIRED_CLASSES := [
	"DialogueClearPresentationOperation",
	"PresentationBatchHandler",
]
const STAGE_ASSET_ROOT := "res://tests/fixtures/stage/"

var _stage_runtime: Node
var _stage_presenter: StagePresenter
var _original_stage_assets_path := ""


func before_each() -> void:
	_stage_runtime = get_tree().root.get_node("StellaRuntime")
	_original_stage_assets_path = _stage_runtime.stage_assets_path
	_stage_runtime.stage_assets_path = STAGE_ASSET_ROOT
	_stage_presenter = StagePresenter.new()
	_stage_presenter.name = "DialogueClearContractStagePresenter"
	add_child_autoqfree(_stage_presenter)
	await get_tree().process_frame


func after_each() -> void:
	_stage_runtime.stage_assets_path = _original_stage_assets_path


func _global_class_script(class_name_value: String) -> Script:
	for entry_value: Variant in ProjectSettings.get_global_class_list():
		var entry: Dictionary = entry_value
		if String(entry.get("class", "")) != class_name_value:
			continue
		var path := String(entry.get("path", ""))
		if not path.is_empty() and ResourceLoader.exists(path, "Script"):
			return load(path) as Script
	return null


func _method_names(value: Object) -> Array[String]:
	var names: Array[String] = []
	for method_value: Variant in value.get_method_list():
		names.append(String((method_value as Dictionary).get("name", "")))
	return names


func _parse(source: String, path: String = "res://synthetic/dialogue_clear.stla") -> ScenarioData:
	return DslParser.parse(DslLexer.tokenize(source), "dialogue_clear", path)


func _errors(data: ScenarioData) -> Array:
	return data.diagnostics.filter(func(diagnostic: Dictionary) -> bool:
		return String(diagnostic.get("level", "")) == "error")


func _commands(data: ScenarioData) -> Array[CommandData]:
	var result: Array[CommandData] = []
	for scene_value: Variant in data.scenes:
		var scene: SceneData = scene_value
		for command_value: Variant in scene.commands:
			result.append(command_value as CommandData)
	return result


func _nvl_context() -> ScenarioContext:
	var data := ScenarioData.new()
	data.id = "dialogue_clear_context"
	data.source_path = "res://synthetic/dialogue_clear_context.stla"
	var context := ScenarioContext.new(data)
	context.current_dialogue_mode = "nvl"
	context.current_dialogue_profile_name = "novel"
	context.current_dialogue_uses_declarative_presentation = true
	context.adv_dialogue_profile_name = "message"
	context.adv_dialogue_uses_declarative_presentation = true
	context.nvl_page_epoch = 7
	context.nvl_page_entries = [{
		"command_uid": 11,
		"scene_index": 0,
		"command_index": 0,
		"profile_name": "novel",
		"character": "narrator",
		"segments": [{"text": "retained in backlog only", "voice_layers": []}],
	}]
	return context


func test_issue_169_typed_surface_and_exact_signals_exist() -> void:
	var missing: Array[String] = []
	for required_class: String in REQUIRED_CLASSES:
		if _global_class_script(required_class) == null:
			missing.append(required_class)
	for signal_name: StringName in [
		&"dialogue_clear_validate_requested",
		&"dialogue_clear_accept_requested",
		&"dialogue_clear_apply_requested",
	]:
		if not SignalBus.has_signal(signal_name):
			missing.append("SignalBus.%s" % signal_name)
	assert_eq(missing, [], "missing issue #169 typed clear surface")


func test_short_standalone_syntax_lowers_to_one_canonical_join_child() -> void:
	var data := _parse("""@chapter demo
@scene start
@dialogue_clear
""")
	var commands := _commands(data)
	assert_eq(_errors(data), [])
	assert_eq(commands.size(), 1)
	if commands.size() != 1:
		return
	var command := commands[0]
	assert_eq(command.type, "presentation_batch")
	assert_eq(command.declared_line, 3)
	assert_eq(command.params, {
		"policy": "join",
		"operations": [{
			"kind": "dialogue_clear",
			"payload": {"scope": "page"},
		}],
		"operation_lines": [3],
	})


func test_clear_rejects_every_argument_with_source_location_and_no_command() -> void:
	for suffix: String in ["page", "scope=page", "transition=cut", "now"]:
		var source_path := "res://synthetic/invalid_clear_%s.stla" % suffix.replace("=", "_")
		var data := _parse("""@chapter demo
@scene start
@dialogue_clear %s
""" % suffix, source_path)
		assert_eq(_commands(data), [], "invalid clear does not partially compile")
		assert_eq(_errors(data).size(), 1)
		if _errors(data).size() == 1:
			assert_string_contains(
				String(_errors(data)[0].get("message", "")),
				"%s:3" % source_path,
			)


func test_mixed_batch_preserves_clear_visibility_order_and_rejects_duplicate_clear() -> void:
	var clear_then_hide := _parse("""@chapter demo
@scene start
@presentation_batch policy=join
  @dialogue_clear
  @dialogue_visibility hide
@end
""")
	var first_commands := _commands(clear_then_hide)
	assert_eq(_errors(clear_then_hide), [])
	assert_eq(first_commands.size(), 1)
	if first_commands.size() == 1:
		assert_eq(first_commands[0].params.get("operations"), [{
			"kind": "dialogue_clear",
			"payload": {"scope": "page"},
		}, {
			"kind": "dialogue_visibility",
			"payload": {
				"target": "surface",
				"action": "hide",
				"transition": "cut",
				"duration": 0.0,
			},
		}])

	var hide_then_clear := _parse("""@chapter demo
@scene start
@presentation_batch policy=join
  @dialogue_visibility hide
  @dialogue_clear
@end
""")
	var second_commands := _commands(hide_then_clear)
	assert_eq(_errors(hide_then_clear), [])
	assert_eq(second_commands.size(), 1)
	if second_commands.size() == 1:
		assert_eq(
			String((second_commands[0].params.get("operations") as Array)[0].get("kind")),
			"dialogue_visibility",
		)
		assert_eq(
			String((second_commands[0].params.get("operations") as Array)[1].get("kind")),
			"dialogue_clear",
		)

	var duplicate := _parse("""@chapter demo
@scene start
@presentation_batch policy=join
  @dialogue_clear
  @dialogue_clear
@end
""")
	assert_eq(_commands(duplicate), [])
	assert_eq(_errors(duplicate).size(), 1)
	if _errors(duplicate).size() == 1:
		assert_string_contains(
			String(_errors(duplicate)[0].get("message", "")),
			"res://synthetic/dialogue_clear.stla:5",
		)


func test_context_clear_is_page_scoped_and_preserves_mode_and_profiles() -> void:
	var context := _nvl_context()
	var methods := _method_names(context)
	assert_has(methods, "clear_dialogue_page", "ScenarioContext owns canonical page clear")
	if "clear_dialogue_page" not in methods:
		return
	context.call("clear_dialogue_page")
	assert_eq(context.current_dialogue_mode, "nvl")
	assert_eq(context.current_dialogue_profile_name, "novel")
	assert_true(context.current_dialogue_uses_declarative_presentation)
	assert_eq(context.adv_dialogue_profile_name, "message")
	assert_true(context.adv_dialogue_uses_declarative_presentation)
	assert_eq(context.nvl_page_entries, [])
	assert_eq(context.nvl_page_epoch, 8,
		"cleared NVL content starts the following line on a fresh page key")


func test_cleared_snapshot_is_explicit_and_retains_selected_presentation() -> void:
	var state := PresentationState.new()
	var context := _nvl_context()
	var methods := _method_names(state)
	assert_has(methods, "commit_dialogue_clear", "PresentationState owns cleared state")
	if "commit_dialogue_clear" not in methods:
		return
	state.call("commit_dialogue_clear", context)
	var content: Dictionary = state.capture_snapshot().get("dialogue_content", {})
	assert_eq(content, {
		"version": 2,
		"active": true,
		"cleared": true,
		"mode": "nvl",
		"profile_name": "novel",
		"declarative_presentation": true,
		"character": "",
		"segments": [],
		"avatar_expression": "",
		"nvl_entries": [],
	})
	assert_true(PresentationState._validate_dialogue_content(content, false))


func test_clear_does_not_mutate_durable_backlog() -> void:
	var backlog := BacklogManager.new()
	backlog.add_entry("narrator", [{
		"text": "durable line",
		"voice_layers": [{"id": "main", "asset": "voice_001", "character": "", "dsp": "", "line": 0}],
	}], 1)
	var before := backlog.get_entries()
	var context := _nvl_context()
	if "clear_dialogue_page" not in _method_names(context):
		pending("ScenarioContext.clear_dialogue_page is not implemented yet")
		return
	context.call("clear_dialogue_page")
	assert_eq(backlog.get_entries(), before)


func test_clear_is_positive_headless_work_and_does_not_claim_independent_stage_owner() -> void:
	var state := PresentationState.new()
	state.connect_signals()
	var director := PresentationDirector.new(state, func() -> bool: return false)
	var context := _nvl_context()
	context.current_dialogue_profile_name = ""
	context.current_dialogue_uses_declarative_presentation = false
	state.dialogue_content = {
		"version": 2,
		"active": true,
		"cleared": false,
		"mode": "nvl",
		"profile_name": "",
		"declarative_presentation": false,
		"character": "narrator",
		"segments": [{"text": "live page"}],
		"avatar_expression": "",
		"nvl_entries": [{
			"profile_name": "",
			"character": "narrator",
			"segments": [{"text": "live page"}],
		}],
	}
	var stage_receipt: Dictionary = {}
	var stage_raw_notifications := [0]
	var on_stage := func(operations: Array, _force_cut: bool) -> void:
		for payload_value: Variant in operations:
			var payload: Dictionary = payload_value
			if String(payload.get("id", "")) != "independent":
				continue
			stage_raw_notifications[0] += 1
	var on_stage_receipt := func(
		presenter_instance_id: int,
		layer_id: String,
		token: int,
		operation_request_id: int,
		generation: int,
	) -> void:
		if (
			presenter_instance_id != _stage_presenter.get_instance_id()
			or layer_id != "independent"
		):
			return
		stage_receipt.assign({
			"presenter_instance_id": presenter_instance_id,
			"layer_id": layer_id,
			"token": token,
			"operation_request_id": operation_request_id,
			"generation": generation,
		})
	SignalBus.stage_operations_requested.connect(on_stage)
	SignalBus.stage_transition_receipt_started.connect(on_stage_receipt)
	var stage_operations: Array[PresentationOperation] = [
		StagePresentationOperation.new({
			"action": "show",
			"id": "independent",
			"properties": {"asset": "stage:redraw_source"},
			"transition_params": {},
			"transition": "fade",
			"duration": 10.0,
		}),
	]
	var stage_request := director.submit(
		stage_operations,
		PresentationBatchRequest.Policy.JOIN,
		context,
		{"source_path": "res://synthetic/independent_stage.stla", "line": 4},
	)
	assert_false(stage_request.is_settled())
	var clear_operations: Array[PresentationOperation] = [
		DialogueClearPresentationOperation.new(
			{"scope": "page"},
			PresentationState.cleared_dialogue_content(context),
			{},
			{"source_path": "res://synthetic/dialogue_clear.stla", "line": 7},
		),
	]
	var clear_request := director.submit(
		clear_operations,
		PresentationBatchRequest.Policy.JOIN,
		context,
		{"source_path": "res://synthetic/dialogue_clear.stla", "line": 7},
	)
	assert_true(clear_request.is_settled(),
		"an empty clear remains positive work without a transition receipt")
	assert_eq(clear_request.get_outcome(),
		PresentationBatchRequest.Outcome.COMPLETED)
	assert_gt(clear_request.get_batch_id(), 0)
	assert_eq(clear_request.get_receipts(), [])
	assert_false(stage_request.is_settled(),
		"dialogue-content clear never finishes an independent Stage JOIN")
	assert_true(state.stage_layers.has("independent"))
	assert_true(bool(state.dialogue_content.get("cleared", false)))
	assert_eq(context.nvl_page_epoch, 8)
	assert_eq(context.nvl_page_entries, [])
	assert_eq(stage_raw_notifications[0], 1)
	assert_eq(stage_receipt.size(), 5)
	if stage_receipt.size() == 5:
		SignalBus.stage_transition_receipts_finish_requested.emit(
			[stage_receipt.duplicate(true)])
	assert_true(stage_request.is_settled())
	SignalBus.stage_transition_receipt_started.disconnect(on_stage_receipt)
	SignalBus.stage_operations_requested.disconnect(on_stage)
	state.disconnect_signals()


func test_mixed_failure_rolls_back_cleared_content_page_and_stage_atomically() -> void:
	var state := PresentationState.new()
	state.connect_signals()
	var director := PresentationDirector.new(state, func() -> bool: return false)
	var context := _nvl_context()
	context.current_dialogue_profile_name = ""
	context.current_dialogue_uses_declarative_presentation = false
	var previous_content := {
		"version": 2,
		"active": true,
		"cleared": false,
		"mode": "nvl",
		"profile_name": "",
		"declarative_presentation": false,
		"character": "narrator",
		"segments": [{"text": "rollback page"}],
		"avatar_expression": "",
		"nvl_entries": [{
			"profile_name": "",
			"character": "narrator",
			"segments": [{"text": "rollback page"}],
		}],
	}
	state.dialogue_content = previous_content.duplicate(true)
	var previous_page := context.capture_dialogue_page_state()
	var stage_identity: Array[int] = []
	var on_stage := func(operations: Array, _force_cut: bool) -> void:
		for payload_value: Variant in operations:
			if String((payload_value as Dictionary).get("id", "")) != "rollback":
				continue
			var request_id := SignalBus.current_stage_operation_request_id()
			stage_identity.assign([920169, 2, request_id, 1])
			SignalBus.stage_transition_receipt_started.emit(
				920169, "rollback", 2, request_id, 1)
	SignalBus.stage_operations_requested.connect(on_stage)
	var operations: Array[PresentationOperation] = [
		DialogueClearPresentationOperation.new(
			{"scope": "page"},
			PresentationState.cleared_dialogue_content(context),
			{},
		),
		StagePresentationOperation.new({
			"action": "show",
			"id": "rollback",
			"properties": {"asset": "stage:redraw_source"},
			"transition_params": {},
			"transition": "fade",
			"duration": 10.0,
		}),
	]
	var request := director.submit(
		operations,
		PresentationBatchRequest.Policy.JOIN,
		context,
		{"source_path": "res://synthetic/atomic_clear.stla", "line": 5},
	)
	assert_false(request.is_settled())
	assert_true(bool(state.dialogue_content.get("cleared", false)))
	assert_eq(context.nvl_page_entries, [])
	assert_true(state.stage_layers.has("rollback"))
	assert_eq(stage_identity.size(), 4)
	if stage_identity.size() == 4:
		SignalBus.stage_transition_terminal.emit(
			stage_identity[0], "rollback", stage_identity[1],
			stage_identity[2], stage_identity[3], &"cancelled")
	assert_push_error(
		"[res://synthetic/atomic_clear.stla:5] PresentationDirector: "
		+ "a sealed presentation participant failed or was superseded")
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_eq(state.dialogue_content, previous_content)
	assert_eq(context.capture_dialogue_page_state(), previous_page)
	assert_eq(state.stage_layers, {})
	SignalBus.stage_operations_requested.disconnect(on_stage)
	state.disconnect_signals()


func test_reversible_navigation_restores_preclear_page_before_replay() -> void:
	var state := PresentationState.new()
	state.connect_signals()
	var director := PresentationDirector.new(state, func() -> bool: return false)
	var context := _nvl_context()
	context.current_dialogue_profile_name = ""
	context.current_dialogue_uses_declarative_presentation = false
	var previous_content := {
		"version": 2,
		"active": true,
		"cleared": false,
		"mode": "nvl",
		"profile_name": "",
		"declarative_presentation": false,
		"character": "narrator",
		"segments": [{"text": "retained page"}],
		"avatar_expression": "",
		"nvl_entries": [{
			"profile_name": "",
			"character": "narrator",
			"segments": [{"text": "retained page"}],
		}],
	}
	state.dialogue_content = previous_content.duplicate(true)
	var previous_page := context.capture_dialogue_page_state()
	var projected_contents: Array[Dictionary] = []
	var on_content_projection := func(
		content: Dictionary,
		_runtime_binding: Dictionary,
	) -> void:
		projected_contents.append(content.duplicate(true))
	SignalBus.dialogue_content_state_apply_requested.connect(
		on_content_projection)
	var on_stage := func(operations: Array, _force_cut: bool) -> void:
		for payload_value: Variant in operations:
			if String((payload_value as Dictionary).get("id", "")) != "replay":
				continue
			SignalBus.stage_transition_receipt_started.emit(
				930169,
				"replay",
				3,
				SignalBus.current_stage_operation_request_id(),
				1,
			)
	SignalBus.stage_operations_requested.connect(on_stage)
	var operations: Array[PresentationOperation] = [
		DialogueClearPresentationOperation.new(
			{"scope": "page"},
			PresentationState.cleared_dialogue_content(context),
			{},
		),
		StagePresentationOperation.new({
			"action": "show",
			"id": "replay",
			"properties": {"asset": "stage:redraw_source"},
			"transition_params": {},
			"transition": "fade",
			"duration": 10.0,
		}),
	]
	var request := director.submit(
		operations,
		PresentationBatchRequest.Policy.JOIN,
		context,
		{"source_path": "res://synthetic/replay_clear.stla", "line": 6},
	)
	assert_false(request.is_settled())
	assert_true(bool(state.dialogue_content.get("cleared", false)))
	assert_true(director.cancel_blocking_waiters(context, true))
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.CANCELLED)
	assert_eq(state.dialogue_content, previous_content)
	assert_eq(context.capture_dialogue_page_state(), previous_page)
	assert_eq(state.stage_layers, {})
	assert_eq(projected_contents, [previous_content])
	SignalBus.stage_operations_requested.disconnect(on_stage)
	SignalBus.dialogue_content_state_apply_requested.disconnect(
		on_content_projection)
	state.disconnect_signals()
