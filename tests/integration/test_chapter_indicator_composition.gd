extends GutTest
## Synthetic composed acceptance gate for issue #170.

const SOURCE_PATH := "res://tests/fixtures/scenarios/chapter_indicator/composition.stla"
const STAGE_ASSET_ROOT := "res://tests/fixtures/stage/"

var _stage_runtime: Node
var _stage_presenter: StagePresenter
var _original_stage_assets_path := ""


func _parse(source: String) -> ScenarioData:
	return DslParser.parse(
		DslLexer.tokenize(source), "chapter_composition", SOURCE_PATH)


func _runtime() -> Node:
	return get_tree().root.get_node("StellaRuntime")


func before_each() -> void:
	SignalBus.reset_chapter_indicator_presentation()
	_stage_runtime = get_tree().root.get_node("StellaRuntime")
	_original_stage_assets_path = _stage_runtime.stage_assets_path
	_stage_runtime.stage_assets_path = STAGE_ASSET_ROOT
	_stage_presenter = StagePresenter.new()
	_stage_presenter.name = "ChapterCompositionStagePresenter"
	add_child_autoqfree(_stage_presenter)
	await get_tree().process_frame


func after_each() -> void:
	_stage_runtime.stage_assets_path = _original_stage_assets_path


func _make_presenter(valid_binding: bool = true) -> Control:
	var presenter := Control.new()
	presenter.name = "SyntheticChapterCompositionSkin"
	presenter.set_script(load(
		"res://addons/stella/presentation/ui/chapter_indicator_presenter.gd"))
	if valid_binding:
		var label := Label.new()
		label.name = "Title"
		presenter.add_child(label)
		presenter.set("title_label_path", NodePath("Title"))
	add_child_autoqfree(presenter)
	return presenter


func _stage_show(layer_id: String) -> StagePresentationOperation:
	return StagePresentationOperation.new({
		"action": "show", "id": layer_id,
		"properties": {"asset": "stage:redraw_source"},
		"transition_params": {},
		"transition": "cut", "duration": 0.0,
	}, {"source_path": SOURCE_PATH, "line": 40})


func _chapter_operation(
	action: String,
	transition: String = "fade",
	duration: float = 10.0,
	line: int = 41,
) -> ChapterIndicatorPresentationOperation:
	return ChapterIndicatorPresentationOperation.new({
		"action": action, "transition": transition, "duration": duration,
	}, {"source_path": SOURCE_PATH, "line": line})


func _chapter_receipt_for(
	request: PresentationBatchRequest,
	presenter: Control,
) -> PresentationOperationReceipt:
	for receipt_value: Variant in request.get_receipts():
		var receipt := receipt_value as PresentationOperationReceipt
		if (
			receipt != null
			and receipt.get_channel() == &"chapter:indicator"
			and receipt.get_presenter_instance_id() == presenter.get_instance_id()
		):
			return receipt
	return null


func test_source_located_chapter_preflight_rejects_before_first_child_apply() -> void:
	var presenter := _make_presenter(false)
	await get_tree().process_frame
	var data := _parse("""@chapter c "C"
@scene start
@presentation_batch policy=join
  @stage hero show asset=stage:redraw_source transition=cut
  @chapter_indicator hide
  @dialogue_visibility hide
@end""")
	assert_eq(data.diagnostics, [])
	var stage_applies := [0]
	var dialogue_applies := [0]
	var on_stage := func(_operations: Array, _force_cut: bool) -> void:
		stage_applies[0] += 1
	var on_dialogue := func(_operations: Array, _force_cut: bool) -> void:
		dialogue_applies[0] += 1
	SignalBus.stage_operations_requested.connect(on_stage)
	SignalBus.dialogue_visibility_operations_requested.connect(on_dialogue)
	var context := ScenarioContext.new(data)
	var handler: Variant = _runtime().registry.get_handler("presentation_batch")
	await handler.execute(data.scenes[0].commands[0], context)
	SignalBus.stage_operations_requested.disconnect(on_stage)
	SignalBus.dialogue_visibility_operations_requested.disconnect(on_dialogue)
	assert_push_error(SOURCE_PATH + ":5")
	assert_true(context.is_finished)
	assert_eq(stage_applies[0], 0,
		"all participant preflight must finish before the first Stage apply")
	assert_eq(dialogue_applies[0], 0)
	assert_false(context.chapter_indicator_visible)
	assert_false(presenter.visible)


func test_contextual_stage_preflight_reports_each_child_source_line() -> void:
	var runtime := _runtime()
	var snapshot: Dictionary = runtime.presentation_state.capture_snapshot()
	var handler: Variant = runtime.registry.get_handler("presentation_batch")
	for authored_stage: String in [
		"@stage pr182_missing_update update position=10,20 transition=cut",
		"@stage pr182_missing_hide hide transition=cut",
	]:
		var data := _parse("""@chapter c "C"
@scene start
@presentation_batch policy=join
  %s
  @chapter_indicator hide
@end""" % authored_stage)
		assert_eq(data.diagnostics, [])
		var layer_id := (
			"pr182_missing_update"
			if authored_stage.contains(" update ")
			else "pr182_missing_hide"
		)
		runtime.presentation_state.stage_layers.erase(layer_id)
		var context := ScenarioContext.new(data)
		await handler.execute(data.scenes[0].commands[0], context)
		assert_push_error(SOURCE_PATH + ":4")
		assert_true(context.is_finished)
		assert_false(runtime.presentation_state.stage_layers.has(layer_id))
	runtime.presentation_state.restore_snapshot(snapshot)


func test_preapply_chapter_rejection_does_not_project_or_retire_prior_owners() -> void:
	var presenter := _make_presenter(false)
	await get_tree().process_frame
	SignalBus.emit_current_chapter_changed("c", "C", func() -> bool: return true)
	var state := PresentationState.new()
	state.connect_signals()
	var director := PresentationDirector.new(state, func() -> bool: return false)
	var context := ScenarioContext.new(ScenarioData.new())
	var active_stage_tween := [null]
	var active_dialogue_tween := [null]
	var projection_counts := {
		"stage_reset": 0,
		"stage_state": 0,
		"dialogue_target_state": 0,
		"chapter_state": 0,
	}
	var on_stage := func(operations: Array, _force_cut: bool) -> void:
		for payload_value: Variant in operations:
			var payload: Dictionary = payload_value
			if String(payload.get("id", "")) != "preflight_prior_stage":
				continue
			var request_id := SignalBus.current_stage_operation_request_id()
			active_stage_tween[0] = create_tween()
			(active_stage_tween[0] as Tween).tween_interval(30.0)
			SignalBus.stage_transition_receipt_started.emit(
				8101, "preflight_prior_stage", 1, request_id, 1)
	var on_visibility := func(operations: Array, _force_cut: bool) -> void:
		for operation_value: Variant in operations:
			var operation := operation_value as PresentationOperation
			if (
				operation == null
				or operation.get_channel() != &"dialogue:surface"
			):
				continue
			var request_id := SignalBus.current_dialogue_visibility_request_id()
			active_dialogue_tween[0] = create_tween()
			(active_dialogue_tween[0] as Tween).tween_interval(30.0)
			SignalBus.dialogue_visibility_transition_receipt_started.emit(
				8102, "surface", 1, request_id, 1)
	var on_stage_reset := func() -> void:
		projection_counts["stage_reset"] += 1
		if active_stage_tween[0] is Tween:
			(active_stage_tween[0] as Tween).kill()
	var on_stage_state := func(_layers: Dictionary) -> void:
		projection_counts["stage_state"] += 1
	var on_dialogue_target_state := func(
		_visibility: Dictionary, _targets: Array,
	) -> void:
		projection_counts["dialogue_target_state"] += 1
		if active_dialogue_tween[0] is Tween:
			(active_dialogue_tween[0] as Tween).kill()
	var on_chapter_state := func(_visible: bool, _generation: int) -> void:
		projection_counts["chapter_state"] += 1
	SignalBus.stage_operations_requested.connect(on_stage)
	SignalBus.dialogue_visibility_operations_requested.connect(on_visibility)
	SignalBus.stage_visuals_reset_requested.connect(on_stage_reset)
	SignalBus.stage_state_apply_requested.connect(on_stage_state)
	SignalBus.dialogue_visibility_targets_state_apply_requested.connect(
		on_dialogue_target_state)
	SignalBus.chapter_indicator_state_apply_requested.connect(on_chapter_state)
	var prior_request := director.submit([
		StagePresentationOperation.new({
			"action": "show", "id": "preflight_prior_stage",
			"properties": {"asset": "stage:redraw_source"},
			"transition_params": {},
			"transition": "fade", "duration": 30.0,
		}, {"source_path": SOURCE_PATH, "line": 82}),
		DialogueVisibilityPresentationOperation.new({
			"target": "surface", "action": "hide",
			"transition": "fade", "duration": 30.0,
		}, {}, {"source_path": SOURCE_PATH, "line": 83}),
	], PresentationBatchRequest.Policy.FIRE_AND_FORGET, context,
	{"source_path": SOURCE_PATH, "line": 81})
	assert_eq(prior_request.get_outcome(),
		PresentationBatchRequest.Outcome.COMPLETED)
	assert_true(active_stage_tween[0] is Tween)
	assert_true(active_dialogue_tween[0] is Tween)
	var prior_stage := state.stage_layers.duplicate(true)
	var prior_visibility := state.dialogue_visibility.duplicate(true)
	var rejected_request := director.submit([
		_stage_show("preflight_never_applied"),
		DialogueVisibilityPresentationOperation.new({
			"target": "quick_menu", "action": "hide",
			"transition": "cut", "duration": 0.0,
		}, {}, {"source_path": SOURCE_PATH, "line": 86}),
		_chapter_operation("show", "cut", 0.0, 87),
	], PresentationBatchRequest.Policy.JOIN, context,
	{"source_path": SOURCE_PATH, "line": 84})
	assert_push_error(SOURCE_PATH + ":87")
	assert_eq(rejected_request.get_outcome(),
		PresentationBatchRequest.Outcome.FAILED)
	assert_eq(projection_counts, {
		"stage_reset": 0,
		"stage_state": 0,
		"dialogue_target_state": 0,
		"chapter_state": 0,
	}, "a mutation-free participant rejection emits no rollback projection")
	assert_eq(state.stage_layers, prior_stage)
	assert_eq(state.dialogue_visibility, prior_visibility)
	assert_true((active_stage_tween[0] as Tween).is_valid())
	assert_true((active_stage_tween[0] as Tween).is_running())
	assert_true((active_dialogue_tween[0] as Tween).is_valid())
	assert_true((active_dialogue_tween[0] as Tween).is_running())
	SignalBus.stage_operations_requested.disconnect(on_stage)
	SignalBus.dialogue_visibility_operations_requested.disconnect(on_visibility)
	SignalBus.stage_visuals_reset_requested.disconnect(on_stage_reset)
	SignalBus.stage_state_apply_requested.disconnect(on_stage_state)
	SignalBus.dialogue_visibility_targets_state_apply_requested.disconnect(
		on_dialogue_target_state)
	SignalBus.chapter_indicator_state_apply_requested.disconnect(on_chapter_state)
	(active_stage_tween[0] as Tween).kill()
	(active_dialogue_tween[0] as Tween).kill()
	director.cancel_all()
	state.disconnect_signals()
	SignalBus.reset_stage_visuals()
	SignalBus.reset_dialogue_visibility_visuals()


func test_mixed_dispatch_preserves_authored_cross_kind_order() -> void:
	var presenter := _make_presenter(true)
	await get_tree().process_frame
	SignalBus.emit_current_chapter_changed("c", "C", func() -> bool: return true)
	var data := _parse("""@chapter c "C"
@scene start
@presentation_batch policy=join
  @dialogue_visibility surface hide
  @chapter_indicator show
  @stage hero show asset=stage:redraw_source transition=cut
  @dialogue_visibility quick_menu hide
@end""")
	var order: Array[String] = []
	var on_stage := func(_operations: Array, _force_cut: bool) -> void:
		order.append("stage")
	var on_dialogue := func(operations: Array, _force_cut: bool) -> void:
		var operation: PresentationOperation = operations[0]
		order.append("dialogue:%s" % operation.get_payload()["target"])
	var on_chapter := func(_request: Variant) -> void:
		order.append("chapter")
	SignalBus.stage_operations_requested.connect(on_stage)
	SignalBus.dialogue_visibility_operations_requested.connect(on_dialogue)
	SignalBus.chapter_indicator_apply_requested.connect(on_chapter)
	var context := ScenarioContext.new(data)
	var handler: Variant = _runtime().registry.get_handler("presentation_batch")
	await handler.execute(data.scenes[0].commands[0], context)
	SignalBus.stage_operations_requested.disconnect(on_stage)
	SignalBus.dialogue_visibility_operations_requested.disconnect(on_dialogue)
	SignalBus.chapter_indicator_apply_requested.disconnect(on_chapter)
	assert_eq(order, [
		"dialogue:surface", "chapter", "stage", "dialogue:quick_menu",
	])
	assert_true(context.chapter_indicator_visible)
	assert_true(presenter.visible)


func test_stage_and_chapter_failure_cut_projects_the_complete_previous_state() -> void:
	var presenter := _make_presenter(true)
	await get_tree().process_frame
	SignalBus.emit_current_chapter_changed("c", "C", func() -> bool: return true)
	var state := PresentationState.new()
	state.connect_signals()
	var director := PresentationDirector.new(state, func() -> bool: return false)
	var context := ScenarioContext.new(ScenarioData.new())
	var projected_stage := [{}]
	var authored_dispatches := [0]
	var cut_projections := [0]
	var on_stage := func(operations: Array, _force_cut: bool) -> void:
		authored_dispatches[0] += 1
		projected_stage[0] = StageLayerState.reduce(
			projected_stage[0], operations, false)
	var on_stage_projection := func(layers: Dictionary) -> void:
		cut_projections[0] += 1
		projected_stage[0] = layers.duplicate(true)
	SignalBus.stage_operations_requested.connect(on_stage)
	SignalBus.stage_state_apply_requested.connect(on_stage_projection)
	var request := director.submit([
		_stage_show("rollback_hero"),
		_chapter_operation("show", "fade", 10.0, 42),
	], PresentationBatchRequest.Policy.JOIN, context,
	{"source_path": SOURCE_PATH, "line": 39})
	var receipt := _chapter_receipt_for(request, presenter)
	assert_not_null(receipt)
	if receipt != null:
		SignalBus.chapter_indicator_transition_terminal.emit(
			receipt.get_presenter_instance_id(), receipt.get_token(),
			receipt.get_batch_id(), receipt.get_generation(), &"cancelled")
	assert_push_error(SOURCE_PATH + ":42")
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_eq(state.stage_layers, {})
	assert_eq(projected_stage[0], {},
		"current-owner failure cut-projects the canonical rollback to Stage")
	assert_eq(authored_dispatches[0], 1)
	assert_eq(cut_projections[0], 1,
		"rollback uses the typed Stage projection boundary exactly once")
	assert_false(context.chapter_indicator_visible)
	assert_false(presenter.visible)
	SignalBus.stage_operations_requested.disconnect(on_stage)
	SignalBus.stage_state_apply_requested.disconnect(on_stage_projection)
	state.disconnect_signals()


func test_other_domain_reset_rolls_back_only_the_applied_stage_prefix() -> void:
	var presenter := _make_presenter(true)
	await get_tree().process_frame
	SignalBus.emit_current_chapter_changed("c", "C", func() -> bool: return true)
	var state := PresentationState.new()
	state.connect_signals()
	var director := PresentationDirector.new(state, func() -> bool: return false)
	var context := ScenarioContext.new(ScenarioData.new())
	var projected_stage := [{}]
	var stage_dispatches := [0]
	var stage_projections := [0]
	var chapter_resets := [0]
	var chapter_applies := [0]
	var on_stage := func(operations: Array, _force_cut: bool) -> void:
		stage_dispatches[0] += 1
		projected_stage[0] = StageLayerState.reduce(
			projected_stage[0], operations, false)
		SignalBus.reset_chapter_indicator_presentation()
	var on_stage_projection := func(layers: Dictionary) -> void:
		stage_projections[0] += 1
		projected_stage[0] = layers.duplicate(true)
	var on_chapter_reset := func(_generation: int) -> void:
		chapter_resets[0] += 1
	var on_chapter_apply := func(_visible: bool, _generation: int) -> void:
		chapter_applies[0] += 1
	SignalBus.stage_operations_requested.connect(on_stage)
	SignalBus.stage_state_apply_requested.connect(on_stage_projection)
	SignalBus.chapter_indicator_reset_requested.connect(on_chapter_reset)
	SignalBus.chapter_indicator_state_apply_requested.connect(on_chapter_apply)
	var request := director.submit([
		_stage_show("partial_prefix_hero"),
		_chapter_operation("show", "fade", 10.0, 47),
	], PresentationBatchRequest.Policy.JOIN, context,
	{"source_path": SOURCE_PATH, "line": 44})
	assert_push_error(SOURCE_PATH + ":47")
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.FAILED,
		"a current applied domain makes the atomically interrupted batch fail")
	assert_eq(stage_dispatches[0], 1)
	assert_eq(state.stage_layers, {})
	assert_eq(projected_stage[0], {})
	assert_eq(stage_projections[0], 1,
		"the still-current applied Stage prefix is cut-restored exactly once")
	assert_eq(chapter_resets[0], 1)
	assert_eq(chapter_applies[0], 0,
		"rollback cannot overwrite the newer chapter reset generation")
	assert_false(context.chapter_indicator_visible)
	assert_false(presenter.visible)
	SignalBus.stage_operations_requested.disconnect(on_stage)
	SignalBus.stage_state_apply_requested.disconnect(on_stage_projection)
	SignalBus.chapter_indicator_reset_requested.disconnect(on_chapter_reset)
	SignalBus.chapter_indicator_state_apply_requested.disconnect(on_chapter_apply)
	state.disconnect_signals()


func test_newer_stage_reset_during_rollback_retires_the_remaining_tail() -> void:
	var presenter := _make_presenter(true)
	await get_tree().process_frame
	SignalBus.emit_current_chapter_changed("c", "C", func() -> bool: return true)
	var state := PresentationState.new()
	state.connect_signals()
	var director := PresentationDirector.new(state, func() -> bool: return false)
	var context := ScenarioContext.new(ScenarioData.new())
	var stage_reset_epochs: Array[int] = []
	var stage_projections := [0]
	var dialogue_projections := [0]
	var chapter_projections := [0]
	var nested_reset_fired := [false]
	var on_stage_reset := func() -> void:
		stage_reset_epochs.append(SignalBus.current_stage_reset_epoch())
	var on_stage_projection := func(_layers: Dictionary) -> void:
		stage_projections[0] += 1
		if not nested_reset_fired[0]:
			nested_reset_fired[0] = true
			SignalBus.reset_stage_visuals()
	var on_dialogue_projection := func(
		_visibility: Dictionary, _targets: Array,
	) -> void:
		dialogue_projections[0] += 1
	var on_chapter_projection := func(
		_visible: bool, _generation: int,
	) -> void:
		chapter_projections[0] += 1
	SignalBus.stage_visuals_reset_requested.connect(on_stage_reset)
	SignalBus.stage_state_apply_requested.connect(on_stage_projection)
	SignalBus.dialogue_visibility_targets_state_apply_requested.connect(
		on_dialogue_projection)
	SignalBus.chapter_indicator_state_apply_requested.connect(
		on_chapter_projection)
	var initial_stage_epoch := SignalBus.current_stage_operation_epoch()
	var request := director.submit([
		_stage_show("nested_reset_owner"),
		DialogueVisibilityPresentationOperation.new({
			"target": "surface", "action": "hide",
			"transition": "cut", "duration": 0.0,
		}, {}, {"source_path": SOURCE_PATH, "line": 49}),
		_chapter_operation("show", "fade", 10.0, 50),
	], PresentationBatchRequest.Policy.JOIN, context,
	{"source_path": SOURCE_PATH, "line": 46})
	var receipt := _chapter_receipt_for(request, presenter)
	assert_not_null(receipt)
	if receipt != null:
		SignalBus.chapter_indicator_transition_terminal.emit(
			receipt.get_presenter_instance_id(), receipt.get_token(),
			receipt.get_batch_id(), receipt.get_generation(), &"cancelled")
	assert_push_error(SOURCE_PATH + ":50")
	assert_true(nested_reset_fired[0])
	assert_eq(stage_reset_epochs, [initial_stage_epoch + 1, initial_stage_epoch + 2],
		"the Director suppresses only its own rollback reset identity")
	assert_eq(SignalBus.current_stage_operation_epoch(), initial_stage_epoch + 2)
	assert_eq(stage_projections[0], 1,
		"the newer bare reset invalidates the outer state-apply tail")
	assert_eq(dialogue_projections[0], 0,
		"retired rollback cannot resume with a dialogue projection")
	assert_eq(chapter_projections[0], 0,
		"retired rollback cannot resume with a chapter projection")
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.CANCELLED)
	assert_false(director.has_blocking_waiter(context))
	assert_eq(state.stage_layers, {})
	assert_false(bool(state.dialogue_visibility.get("surface", true)),
		"the newer Stage-only boundary does not authorize stale dialogue rollback")
	assert_true(context.chapter_indicator_visible,
		"the newer Stage-only boundary does not authorize stale chapter rollback")
	SignalBus.stage_visuals_reset_requested.disconnect(on_stage_reset)
	SignalBus.stage_state_apply_requested.disconnect(on_stage_projection)
	SignalBus.dialogue_visibility_targets_state_apply_requested.disconnect(
		on_dialogue_projection)
	SignalBus.chapter_indicator_state_apply_requested.disconnect(
		on_chapter_projection)
	state.disconnect_signals()


func test_dialogue_and_chapter_failure_cut_projects_the_previous_gate() -> void:
	var presenter := _make_presenter(true)
	await get_tree().process_frame
	SignalBus.emit_current_chapter_changed("c", "C", func() -> bool: return true)
	var state := PresentationState.new()
	state.connect_signals()
	var director := PresentationDirector.new(state, func() -> bool: return false)
	var context := ScenarioContext.new(ScenarioData.new())
	var projected_visibility := [DialogueVisibilityState.default_state()]
	var target_projections := [0]
	var on_visibility := func(operations: Array, _force_cut: bool) -> void:
		var payloads: Array = []
		for operation_value: Variant in operations:
			payloads.append(
				(operation_value as PresentationOperation).get_payload())
		projected_visibility[0] = DialogueVisibilityState.reduce(
			projected_visibility[0], payloads, false)
	var on_target_projection := func(
		visibility: Dictionary, targets: Array,
	) -> void:
		target_projections[0] += 1
		for target_value: Variant in targets:
			var target := String(target_value)
			projected_visibility[0][target] = bool(visibility.get(target, true))
	SignalBus.dialogue_visibility_operations_requested.connect(on_visibility)
	var target_projection_signal: Signal = (
		SignalBus.dialogue_visibility_targets_state_apply_requested)
	target_projection_signal.connect(on_target_projection)
	var request := director.submit([
		DialogueVisibilityPresentationOperation.new({
			"target": "surface", "action": "hide",
			"transition": "cut", "duration": 0.0,
		}, {}, {"source_path": SOURCE_PATH, "line": 51}),
		_chapter_operation("show", "fade", 10.0, 52),
	], PresentationBatchRequest.Policy.JOIN, context,
	{"source_path": SOURCE_PATH, "line": 49})
	var receipt := _chapter_receipt_for(request, presenter)
	assert_not_null(receipt)
	if receipt != null:
		SignalBus.chapter_indicator_transition_terminal.emit(
			receipt.get_presenter_instance_id(), receipt.get_token(),
			receipt.get_batch_id(), receipt.get_generation(), &"cancelled")
	assert_push_error(SOURCE_PATH + ":52")
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_eq(state.dialogue_visibility,
		DialogueVisibilityState.default_state())
	assert_eq(projected_visibility[0], DialogueVisibilityState.default_state(),
		"current-owner failure cut-projects the previous dialogue gate")
	assert_eq(target_projections[0], 1)
	assert_false(context.chapter_indicator_visible)
	SignalBus.dialogue_visibility_operations_requested.disconnect(on_visibility)
	target_projection_signal.disconnect(on_target_projection)
	state.disconnect_signals()


func test_old_failed_terminal_cannot_rollback_a_fresh_composed_owner() -> void:
	var presenter := _make_presenter(true)
	await get_tree().process_frame
	SignalBus.emit_current_chapter_changed("c", "C", func() -> bool: return true)
	var state := PresentationState.new()
	state.connect_signals()
	var director := PresentationDirector.new(state, func() -> bool: return false)
	var context := ScenarioContext.new(ScenarioData.new())
	var projected_stage := [{}]
	var cut_projections := [0]
	var on_stage := func(operations: Array, _force_cut: bool) -> void:
		projected_stage[0] = StageLayerState.reduce(
			projected_stage[0], operations, false)
	var on_stage_projection := func(layers: Dictionary) -> void:
		cut_projections[0] += 1
		projected_stage[0] = layers.duplicate(true)
	SignalBus.stage_operations_requested.connect(on_stage)
	SignalBus.stage_state_apply_requested.connect(on_stage_projection)
	var old_request := director.submit([
		_stage_show("old_owner"),
		_chapter_operation("show", "fade", 10.0, 62),
	], PresentationBatchRequest.Policy.JOIN, context,
	{"source_path": SOURCE_PATH, "line": 59})
	var old_receipt := _chapter_receipt_for(old_request, presenter)
	assert_not_null(old_receipt)
	var fresh_request := director.submit([
		_stage_show("fresh_owner"),
		_chapter_operation("show", "cut", 0.0, 67),
	], PresentationBatchRequest.Policy.JOIN, context,
	{"source_path": SOURCE_PATH, "line": 64})
	assert_push_error(SOURCE_PATH + ":62")
	assert_eq(old_request.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_eq(fresh_request.get_outcome(),
		PresentationBatchRequest.Outcome.COMPLETED)
	var expected_stage := state.stage_layers.duplicate(true)
	var expected_projection := (projected_stage[0] as Dictionary).duplicate(true)
	if old_receipt != null:
		SignalBus.chapter_indicator_transition_terminal.emit(
			old_receipt.get_presenter_instance_id(), old_receipt.get_token(),
			old_receipt.get_batch_id(), old_receipt.get_generation(), &"cancelled")
	assert_eq(state.stage_layers, expected_stage)
	assert_eq(projected_stage[0], expected_projection,
		"duplicate stale terminal cannot cut-project over the fresh owner")
	assert_true(projected_stage[0].has("old_owner"))
	assert_true(projected_stage[0].has("fresh_owner"))
	assert_eq(cut_projections[0], 0)
	assert_true(context.chapter_indicator_visible)
	assert_true(presenter.visible)
	SignalBus.stage_operations_requested.disconnect(on_stage)
	SignalBus.stage_state_apply_requested.disconnect(on_stage_projection)
	state.disconnect_signals()


func test_stage_rollback_does_not_cancel_a_fresh_chapter_only_owner() -> void:
	var presenter := _make_presenter(true)
	await get_tree().process_frame
	SignalBus.emit_current_chapter_changed("c", "C", func() -> bool: return true)
	SignalBus.apply_chapter_indicator_state(true)
	var state := PresentationState.new()
	state.connect_signals()
	var director := PresentationDirector.new(state, func() -> bool: return false)
	var context := ScenarioContext.new(ScenarioData.new())
	context.chapter_indicator_visible = true
	var projected_stage := [{}]
	var cut_projections := [0]
	var on_stage := func(operations: Array, _force_cut: bool) -> void:
		projected_stage[0] = StageLayerState.reduce(
			projected_stage[0], operations, false)
	var on_stage_projection := func(layers: Dictionary) -> void:
		cut_projections[0] += 1
		projected_stage[0] = layers.duplicate(true)
	SignalBus.stage_operations_requested.connect(on_stage)
	SignalBus.stage_state_apply_requested.connect(on_stage_projection)
	var old_request := director.submit([
		_stage_show("old_cross_domain_owner"),
		_chapter_operation("hide", "fade", 10.0, 72),
	], PresentationBatchRequest.Policy.JOIN, context,
	{"source_path": SOURCE_PATH, "line": 69})
	assert_not_null(_chapter_receipt_for(old_request, presenter))
	var fresh_request := director.submit([
		_chapter_operation("show", "cut", 0.0, 77),
	], PresentationBatchRequest.Policy.JOIN, context,
	{"source_path": SOURCE_PATH, "line": 76})
	assert_push_error(SOURCE_PATH + ":72")
	assert_eq(old_request.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_eq(state.stage_layers, {})
	assert_eq(projected_stage[0], {})
	assert_eq(cut_projections[0], 1,
		"the old request still owns and cut-restores its Stage domain")
	assert_eq(fresh_request.get_outcome(),
		PresentationBatchRequest.Outcome.COMPLETED,
		"an unrelated Stage rollback epoch cannot invalidate chapter-only delivery")
	assert_true(context.chapter_indicator_visible)
	assert_true(presenter.visible)
	SignalBus.stage_operations_requested.disconnect(on_stage)
	SignalBus.stage_state_apply_requested.disconnect(on_stage_projection)
	state.disconnect_signals()


func test_old_chapter_terminal_cannot_settle_fresh_director_owner() -> void:
	var state := PresentationState.new()
	var director := PresentationDirector.new(state, func() -> bool: return false)
	var context := ScenarioContext.new(ScenarioData.new())
	var receipt_serial := [0]
	var receipts: Array[Dictionary] = []
	var on_apply := func(request: Variant) -> void:
		receipt_serial[0] += 1
		var receipt := {
			"request_id": request.get_request_id(),
			"token": receipt_serial[0],
			"generation": receipt_serial[0],
		}
		receipts.append(receipt)
		SignalBus.chapter_indicator_transition_receipt_started.emit(
			970170, receipt["token"], receipt["request_id"], receipt["generation"])
	SignalBus.chapter_indicator_apply_requested.connect(on_apply)
	var operation := ChapterIndicatorPresentationOperation.new({
		"action": "show", "transition": "fade", "duration": 10.0,
	}, {"source_path": SOURCE_PATH, "line": 9})
	var old_request := director.submit(
		[operation], PresentationBatchRequest.Policy.JOIN, context,
		{"source_path": SOURCE_PATH, "line": 9})
	director.cancel_all()
	var fresh_request := director.submit(
		[operation], PresentationBatchRequest.Policy.JOIN, context,
		{"source_path": SOURCE_PATH, "line": 10})
	SignalBus.chapter_indicator_apply_requested.disconnect(on_apply)
	assert_true(old_request.is_settled())
	assert_false(fresh_request.is_settled())
	var old_receipt: Dictionary = receipts[0]
	SignalBus.chapter_indicator_transition_terminal.emit(
		970170, old_receipt["token"], old_receipt["request_id"],
		old_receipt["generation"], &"completed")
	assert_false(fresh_request.is_settled(),
		"retired exact owner callbacks cannot satisfy a fresh receipt")
	var fresh_receipt: Dictionary = receipts[1]
	SignalBus.chapter_indicator_transition_terminal.emit(
		970170, fresh_receipt["token"], fresh_receipt["request_id"],
		fresh_receipt["generation"], &"completed")
	assert_true(fresh_request.is_settled())
	assert_eq(
		fresh_request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)


func test_composed_join_seals_and_acknowledges_three_channels() -> void:
	var presenter := _make_presenter(true)
	await get_tree().process_frame
	SignalBus.emit_current_chapter_changed("c", "C", func() -> bool: return true)
	var state := PresentationState.new()
	var director := PresentationDirector.new(state, func() -> bool: return false)
	var context := ScenarioContext.new(ScenarioData.new())
	var started: Array[Dictionary] = []
	var stage_exact: Dictionary = {}
	var stage_raw_notifications := [0]
	var on_stage := func(_operations: Array, _force_cut: bool) -> void:
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
			or layer_id != "hero"
		):
			return
		stage_exact.assign({
			"presenter_instance_id": presenter_instance_id,
			"layer_id": layer_id,
			"token": token,
			"operation_request_id": operation_request_id,
			"generation": generation,
		})
	var on_dialogue := func(_operations: Array, _force_cut: bool) -> void:
		var request_id := SignalBus.current_dialogue_visibility_request_id()
		var record := {"request_id": request_id, "token": 12, "generation": 22}
		started.append(record)
		SignalBus.dialogue_visibility_transition_receipt_started.emit(
			970172, "surface", 12, request_id, 22)
	SignalBus.stage_operations_requested.connect(on_stage)
	SignalBus.stage_transition_receipt_started.connect(on_stage_receipt)
	SignalBus.dialogue_visibility_operations_requested.connect(on_dialogue)
	var operations: Array[PresentationOperation] = [
		StagePresentationOperation.new({
			"action": "show", "id": "hero",
			"properties": {"asset": "stage:redraw_source"},
			"transition_params": {},
			"transition": "fade", "duration": 10.0,
		}),
		ChapterIndicatorPresentationOperation.new({
			"action": "show", "transition": "fade", "duration": 10.0,
		}),
		DialogueVisibilityPresentationOperation.new({
			"target": "surface", "action": "hide",
			"transition": "fade", "duration": 10.0,
		}),
	]
	var request := director.submit(
		operations, PresentationBatchRequest.Policy.JOIN, context,
		{"source_path": SOURCE_PATH, "line": 20})
	SignalBus.stage_operations_requested.disconnect(on_stage)
	SignalBus.stage_transition_receipt_started.disconnect(on_stage_receipt)
	SignalBus.dialogue_visibility_operations_requested.disconnect(on_dialogue)
	assert_false(request.is_settled())
	var channels: Array[String] = []
	var chapter_presenter_receipt_found := false
	for receipt_value: Variant in request.get_receipts():
		var receipt := receipt_value as PresentationOperationReceipt
		channels.append(String(receipt.get_channel()))
		if (
			receipt.get_channel() == &"chapter:indicator"
			and receipt.get_presenter_instance_id() == presenter.get_instance_id()
		):
			chapter_presenter_receipt_found = true
	assert_eq(channels.count("stage:hero"), 1)
	assert_gte(channels.count("chapter:indicator"), 1)
	assert_eq(channels.count("dialogue:surface"), 1)
	assert_true(chapter_presenter_receipt_found,
		"the composed receipt union includes the exact synthetic participant")
	assert_eq(stage_raw_notifications[0], 1)
	assert_eq(stage_exact.size(), 5)
	if stage_exact.size() == 5:
		SignalBus.stage_transition_receipts_finish_requested.emit(
			[stage_exact.duplicate(true)])
	SignalBus.dialogue_visibility_transition_terminal.emit(
		970172, "surface", 12, started[0]["request_id"], 22, &"completed")
	SignalBus.chapter_indicator_finish_requested.emit(request.get_batch_id())
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_true(context.chapter_indicator_visible)
	assert_true(presenter.visible)
