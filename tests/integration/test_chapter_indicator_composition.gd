extends GutTest
## Synthetic composed acceptance gate for issue #170.

const SOURCE_PATH := "res://tests/fixtures/scenarios/chapter_indicator/composition.stla"


func _parse(source: String) -> ScenarioData:
	return DslParser.parse(
		DslLexer.tokenize(source), "chapter_composition", SOURCE_PATH)


func _runtime() -> Node:
	return get_tree().root.get_node("StellaRuntime")


func before_each() -> void:
	SignalBus.reset_chapter_indicator_presentation()


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
	var on_stage := func(_operations: Array, _force_cut: bool) -> void:
		var request_id := SignalBus.current_stage_operation_request_id()
		var record := {"request_id": request_id, "token": 11, "generation": 21}
		started.append(record)
		SignalBus.stage_transition_receipt_started.emit(
			970171, "hero", 11, request_id, 21)
	var on_dialogue := func(_operations: Array, _force_cut: bool) -> void:
		var request_id := SignalBus.current_dialogue_visibility_request_id()
		var record := {"request_id": request_id, "token": 12, "generation": 22}
		started.append(record)
		SignalBus.dialogue_visibility_transition_receipt_started.emit(
			970172, "surface", 12, request_id, 22)
	SignalBus.stage_operations_requested.connect(on_stage)
	SignalBus.dialogue_visibility_operations_requested.connect(on_dialogue)
	var operations: Array[PresentationOperation] = [
		StagePresentationOperation.new({
			"action": "show", "id": "hero",
			"properties": {"asset": "stage:redraw_source"},
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
	SignalBus.stage_transition_terminal.emit(
		970171, "hero", 11, started[0]["request_id"], 21, &"completed")
	SignalBus.dialogue_visibility_transition_terminal.emit(
		970172, "surface", 12, started[1]["request_id"], 22, &"completed")
	SignalBus.chapter_indicator_finish_requested.emit(request.get_batch_id())
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_true(context.chapter_indicator_visible)
	assert_true(presenter.visible)
