extends GutTest
## Public synthetic end-to-end red contract for issue #166.
##
## The new classes are resolved through the global-class registry.  The exact
## baseline therefore fails at explicit capability assertions and never at a
## missing preload, parser self-error, or failed resource load.


const RuntimeTestSupport = preload("res://tests/helpers/runtime_test_support.gd")
const DIALOGUE_FIXTURE = preload(
	"res://tests/integration/fixtures/dialogue_visibility_profile.tscn")
const SCENARIO_PATH := \
	"res://tests/fixtures/scenarios/dialogue/dialogue_visibility.stla"
const STAGE_ASSET_ROOT := "res://tests/fixtures/stage/"
const CONFIGURED_TITLE_PROBE := "res://addons/stella/scenes/game.tscn"
const SAVE_SLOT := 166
const REQUIRED_CLASSES := [
	"DialogueVisibilityState",
	"DialogueVisibilityPresentationOperation",
	"PresentationBatchHandler",
]
const REQUIRED_VISIBILITY_SIGNALS := [
	"dialogue_visibility_operations_requested",
	"presentation_operation_request_finished",
	"dialogue_visibility_transition_receipt_started",
	"dialogue_visibility_transition_terminal",
	"dialogue_visibility_transition_receipts_finish_requested",
	"dialogue_visibility_visuals_reset_requested",
	"dialogue_visibility_state_apply_requested",
]

var _runtime: Node
var _dialogue_presenter: Control
var _stage_presenter: StagePresenter
var _dialogue_requests: Array[DialogueRequest] = []
var _stage_dispatches: Array[Dictionary] = []
var _stage_exact_starts: Array[Dictionary] = []
var _submitted_requests: Array[PresentationBatchRequest] = []
var _voice_requests: Array = []
var _visibility_dispatches: Array[Dictionary] = []
var _presentation_tails: Array[Dictionary] = []
var _visibility_exact_starts: Array[Dictionary] = []
var _visibility_terminals: Array[Dictionary] = []
var _visibility_finish_requests: Array = []
var _visibility_state_applies: Array[Dictionary] = []
var _visibility_resets := 0
var _visibility_lifecycle_sequence: Array[String] = []
var _original_stage_assets_path := ""
var _original_title_scene_path := ""


func before_each() -> void:
	_runtime = get_tree().root.get_node("StellaRuntime")
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	_runtime.delete_save(SAVE_SLOT)
	_original_stage_assets_path = _runtime.stage_assets_path
	_original_title_scene_path = _runtime.title_scene_path
	_runtime.stage_assets_path = STAGE_ASSET_ROOT
	_clear_observations()

	# Observe the typed request before scene presenters mutate their local view.
	SignalBus.dialogue_requested.connect(_on_dialogue_requested)
	SignalBus.stage_operations_requested.connect(_on_stage_operations_requested)
	SignalBus.stage_transition_receipt_started.connect(_on_stage_exact_started)
	SignalBus.voice_playback_requested.connect(_on_voice_playback_requested)
	_connect_optional_signal(
		&"dialogue_visibility_operations_requested", _on_visibility_operations)
	_connect_optional_signal(
		&"presentation_operation_request_finished", _on_presentation_tail)
	_connect_optional_signal(
		&"dialogue_visibility_transition_receipt_started",
		_on_visibility_exact_started)
	_connect_optional_signal(
		&"dialogue_visibility_transition_terminal", _on_visibility_terminal)
	_connect_optional_signal(
		&"dialogue_visibility_transition_receipts_finish_requested",
		_on_visibility_finish_requested)
	_connect_optional_signal(
		&"dialogue_visibility_visuals_reset_requested", _on_visibility_reset)
	_connect_optional_signal(
		&"dialogue_visibility_state_apply_requested", _on_visibility_state_apply)

	_dialogue_presenter = DIALOGUE_FIXTURE.instantiate()
	_dialogue_presenter.name = "DialogueVisibilityContractPresenter"
	add_child_autoqfree(_dialogue_presenter)
	_stage_presenter = StagePresenter.new()
	_stage_presenter.name = "DialogueVisibilityStagePresenter"
	add_child_autoqfree(_stage_presenter)
	await get_tree().process_frame
	_dialogue_presenter.set("_char_interval", 0.0)


func after_each() -> void:
	if SignalBus.dialogue_requested.is_connected(_on_dialogue_requested):
		SignalBus.dialogue_requested.disconnect(_on_dialogue_requested)
	if SignalBus.stage_operations_requested.is_connected(
		_on_stage_operations_requested
	):
		SignalBus.stage_operations_requested.disconnect(
			_on_stage_operations_requested)
	if SignalBus.stage_transition_receipt_started.is_connected(
		_on_stage_exact_started
	):
		SignalBus.stage_transition_receipt_started.disconnect(
			_on_stage_exact_started)
	if SignalBus.voice_playback_requested.is_connected(
		_on_voice_playback_requested
	):
		SignalBus.voice_playback_requested.disconnect(
			_on_voice_playback_requested)
	_disconnect_optional_signal(
		&"dialogue_visibility_operations_requested", _on_visibility_operations)
	_disconnect_optional_signal(
		&"presentation_operation_request_finished", _on_presentation_tail)
	_disconnect_optional_signal(
		&"dialogue_visibility_transition_receipt_started",
		_on_visibility_exact_started)
	_disconnect_optional_signal(
		&"dialogue_visibility_transition_terminal", _on_visibility_terminal)
	_disconnect_optional_signal(
		&"dialogue_visibility_transition_receipts_finish_requested",
		_on_visibility_finish_requested)
	_disconnect_optional_signal(
		&"dialogue_visibility_visuals_reset_requested", _on_visibility_reset)
	_disconnect_optional_signal(
		&"dialogue_visibility_state_apply_requested", _on_visibility_state_apply)
	_runtime.stage_assets_path = _original_stage_assets_path
	_runtime.title_scene_path = _original_title_scene_path
	_runtime._navigation_scene_change_override = Callable()
	_runtime.delete_save(SAVE_SLOT)
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())


func _clear_observations() -> void:
	_dialogue_requests.clear()
	_stage_dispatches.clear()
	_stage_exact_starts.clear()
	_submitted_requests.clear()
	_voice_requests.clear()
	_visibility_dispatches.clear()
	_presentation_tails.clear()
	_visibility_exact_starts.clear()
	_visibility_terminals.clear()
	_visibility_finish_requests.clear()
	_visibility_state_applies.clear()
	_visibility_resets = 0
	_visibility_lifecycle_sequence.clear()


func _connect_optional_signal(signal_name: StringName, callback: Callable) -> void:
	if not SignalBus.has_signal(signal_name):
		return
	var bus_signal: Signal = SignalBus.get(signal_name)
	if not bus_signal.is_connected(callback):
		bus_signal.connect(callback)


func _disconnect_optional_signal(signal_name: StringName, callback: Callable) -> void:
	if not SignalBus.has_signal(signal_name):
		return
	var bus_signal: Signal = SignalBus.get(signal_name)
	if bus_signal.is_connected(callback):
		bus_signal.disconnect(callback)


func _on_dialogue_requested(request: DialogueRequest) -> void:
	_dialogue_requests.append(request)


func _on_stage_operations_requested(
	operations: Array,
	force_cut: bool,
) -> void:
	var request_id := SignalBus.current_stage_operation_request_id()
	var entry: Dictionary = _director()._entries.get(request_id, {})
	var request: PresentationBatchRequest = entry.get("request")
	if request != null and request not in _submitted_requests:
		_submitted_requests.append(request)
	_stage_dispatches.append({
		"request_id": request_id,
		"operations": operations.duplicate(true),
		"force_cut": force_cut,
		"dialogue_count": _dialogue_requests.size(),
		"visibility": _visibility_snapshot(),
	})


func _on_stage_exact_started(
	presenter_instance_id: int,
	layer_id: String,
	token: int,
	request_id: int,
	generation: int,
) -> void:
	_stage_exact_starts.append({
		"presenter_instance_id": presenter_instance_id,
		"layer_id": layer_id,
		"token": token,
		"operation_request_id": request_id,
		"generation": generation,
	})


func _on_voice_playback_requested(request: Variant) -> void:
	_voice_requests.append(request)


func _on_visibility_operations(operations: Array, force_cut: bool) -> void:
	_visibility_dispatches.append({
		"operations": operations.duplicate(true),
		"force_cut": force_cut,
		"dialogue_count": _dialogue_requests.size(),
		"visibility": _visibility_snapshot(),
	})


func _on_presentation_tail(request_id: int, delivered: bool) -> void:
	_presentation_tails.append({"request_id": request_id, "delivered": delivered})


func _on_visibility_exact_started(
	presenter_instance_id: int,
	target: String,
	token: int,
	operation_request_id: int,
	generation: int,
) -> void:
	_visibility_exact_starts.append({
		"presenter_instance_id": presenter_instance_id,
		"target": target,
		"token": token,
		"operation_request_id": operation_request_id,
		"generation": generation,
	})


func _on_visibility_terminal(
	presenter_instance_id: int,
	target: String,
	token: int,
	operation_request_id: int,
	generation: int,
	outcome: StringName,
) -> void:
	_visibility_terminals.append({
		"presenter_instance_id": presenter_instance_id,
		"target": target,
		"token": token,
		"operation_request_id": operation_request_id,
		"generation": generation,
		"outcome": outcome,
	})


func _on_visibility_finish_requested(transitions: Array) -> void:
	_visibility_finish_requests.append(transitions.duplicate(true))


func _on_visibility_reset() -> void:
	_visibility_resets += 1
	_visibility_lifecycle_sequence.append("reset")


func _on_visibility_state_apply(
	visibility: Dictionary,
	content: Dictionary,
	runtime_binding: Dictionary,
) -> void:
	_visibility_lifecycle_sequence.append("apply")
	_visibility_state_applies.append({
		"visibility": visibility.duplicate(true),
		"content": content.duplicate(true),
		"runtime_binding": runtime_binding.duplicate(true),
	})


func _wait_until(predicate: Callable, max_frames: int = 180) -> bool:
	for _frame in range(max_frames):
		if bool(predicate.call()):
			return true
		await get_tree().process_frame
	return bool(predicate.call())


func _global_class_script(class_name_value: String) -> Script:
	for entry_value: Variant in ProjectSettings.get_global_class_list():
		var entry: Dictionary = entry_value
		if String(entry.get("class", "")) != class_name_value:
			continue
		var path := String(entry.get("path", ""))
		if not path.is_empty() and ResourceLoader.exists(path, "Script"):
			return load(path) as Script
	return null


func _director() -> PresentationDirector:
	return _runtime.presentation_director as PresentationDirector


func _require_contract() -> bool:
	var missing: Array[String] = []
	for required_class: String in REQUIRED_CLASSES:
		if _global_class_script(required_class) == null:
			missing.append(required_class)
	for signal_name: String in REQUIRED_VISIBILITY_SIGNALS:
		if not SignalBus.has_signal(signal_name):
			missing.append("SignalBus.%s" % signal_name)
	if (
		_runtime.engine == null
		or _runtime.engine.registry == null
		or not _runtime.engine.registry.has_handler("presentation_batch")
	):
		missing.append("registered presentation_batch CommandHandler")
	var snapshot: Dictionary = _runtime.presentation_state.capture_snapshot()
	if not snapshot.has("dialogue_visibility"):
		missing.append("PresentationState.dialogue_visibility")
	if not snapshot.has("dialogue_content"):
		missing.append("PresentationState.dialogue_content")
	assert_eq(missing, [], "missing issue #166 runtime composition surface")
	if not missing.is_empty():
		return false

	# Probe the parser before opening the checked-in fixture.  This guarantees
	# that a red baseline stops on a capability assertion, not parser push_error.
	var probe := DslParser.parse(DslLexer.tokenize("""@chapter probe
@scene start
@presentation_batch policy=join
  @dialogue_visibility surface hide
@end"""), "dialogue_visibility_probe", "res://synthetic/probe.stla")
	var commands: Array[CommandData] = []
	for scene_value: Variant in probe.scenes:
		var scene: SceneData = scene_value
		for command_value: Variant in scene.commands:
			var command: CommandData = command_value
			if command.type == "presentation_batch":
				commands.append(command)
	var errors := probe.diagnostics.filter(func(diagnostic: Dictionary) -> bool:
		return String(diagnostic.get("level", "")) == "error")
	var compiled := commands.size() == 1 and errors.is_empty()
	if compiled:
		var keys := commands[0].params.keys()
		keys.sort()
		compiled = keys == ["operation_lines", "operations", "policy"]
	assert_true(compiled,
		"@presentation_batch must compile exactly before lifecycle execution")
	return compiled


func _start_scene(scene_id: String) -> bool:
	var prepared: bool = _runtime._prepare_scenario(SCENARIO_PATH)
	assert_true(prepared, "public synthetic #166 fixture parses")
	if not prepared:
		return false
	var selected: bool = _runtime.engine.context.set_scene(scene_id)
	assert_true(selected, "fixture scene exists: %s" % scene_id)
	if not selected:
		return false
	_runtime._last_scenario_path = SCENARIO_PATH
	_runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	_runtime.engine.run()
	return true


func _wait_for_dialogues(count: int) -> bool:
	return await _wait_until(func() -> bool:
		return (
			_dialogue_requests.size() >= count
			and not bool(_dialogue_presenter.get("_is_typing"))
		))


func _advance_dialogue(index: int) -> bool:
	if index < 0 or index >= _dialogue_requests.size():
		return false
	return _dialogue_requests[index].advance()


func _latest_request(policy: int = -1) -> PresentationBatchRequest:
	var latest_id := -1
	var latest: PresentationBatchRequest
	for request_id_value: Variant in _director()._entries:
		var request_id := int(request_id_value)
		var entry: Dictionary = _director()._entries[request_id_value]
		var request: PresentationBatchRequest = entry.get("request")
		if request == null:
			continue
		if policy >= 0 and request.get_policy() != policy:
			continue
		if request_id > latest_id:
			latest_id = request_id
			latest = request
	return latest


func _receipt_channels(request: PresentationBatchRequest) -> Array[String]:
	var channels: Array[String] = []
	if request == null:
		return channels
	for receipt_value: Variant in request.get_receipts():
		var receipt: PresentationOperationReceipt = receipt_value
		channels.append(String(receipt.get_channel()))
	return channels


func _receipt_record(receipt: PresentationOperationReceipt) -> Dictionary:
	var channel := String(receipt.get_channel())
	return {
		"presenter_instance_id": receipt.get_presenter_instance_id(),
		"target": channel.trim_prefix("dialogue:"),
		"token": receipt.get_token(),
		"operation_request_id": receipt.get_batch_id(),
		"generation": receipt.get_generation(),
	}


func _emit_visibility_terminal(
	receipt: PresentationOperationReceipt,
	outcome: StringName = &"completed",
) -> void:
	var record := _receipt_record(receipt)
	(SignalBus.get("dialogue_visibility_transition_terminal") as Signal).emit(
		record["presenter_instance_id"],
		record["target"],
		record["token"],
		record["operation_request_id"],
		record["generation"],
		outcome,
	)


func _emit_visibility_finish(receipt: PresentationOperationReceipt) -> void:
	(SignalBus.get(
		"dialogue_visibility_transition_receipts_finish_requested") as Signal
	).emit([_receipt_record(receipt)])


func _visibility_visual_snapshot() -> Array:
	var result: Array = []
	for target: StringName in [&"dialogue_surface", &"quick_menu"]:
		for node: CanvasItem in _owned_group_nodes(target):
			result.append([
				node.get_instance_id(), node.visible,
				node.modulate.a, node.self_modulate.a,
			])
	return result


func _assert_exact_finish_record(record: Dictionary) -> void:
	var keys := record.keys()
	keys.sort()
	assert_eq(keys, [
		"generation", "operation_request_id", "presenter_instance_id",
		"target", "token",
	])
	assert_true(record.get("presenter_instance_id") is int)
	assert_gt(int(record.get("presenter_instance_id", 0)), 0)
	assert_true(record.get("target") is String)
	assert_has(["surface", "quick_menu"], String(record.get("target", "")))
	for field: String in ["token", "operation_request_id", "generation"]:
		assert_true(record.get(field) is int, "finish identity type: %s" % field)
		assert_gt(int(record.get(field, 0)), 0, "finish identity: %s" % field)


func _assert_no_visibility_visual_work() -> void:
	var active_work: Variant = _dialogue_presenter.get(
		"_dialogue_visibility_active")
	assert_true(active_work is Dictionary)
	if not active_work is Dictionary:
		return
	assert_true((active_work as Dictionary).is_empty(),
		"no active visibility receipt/token authority remains")


func _visibility_snapshot() -> Dictionary:
	return _runtime.presentation_state.capture_snapshot().get(
		"dialogue_visibility", {}).duplicate(true)


func _content_snapshot() -> Dictionary:
	return _runtime.presentation_state.capture_snapshot().get(
		"dialogue_content", {}).duplicate(true)


func _read_save_with_lifecycle_diagnostics(
	slot_id: int,
	scenario_data: ScenarioData,
) -> Variant:
	var raw_saved: Variant = _runtime.save_manager.read_save_data(slot_id)
	assert_true(raw_saved is Dictionary,
		"raw save read without ScenarioData must succeed before scoped validation")
	if not raw_saved is Dictionary:
		return raw_saved
	var saved: Variant = _runtime.save_manager.read_save_data(
		slot_id, scenario_data)
	if saved != null:
		return saved
	var raw_dictionary: Dictionary = raw_saved
	var base_snapshot := {
		"scenario_context": raw_dictionary.get("scenario_context", {}),
	}
	assert_false(
		_runtime.save_manager.validate_data_for_scenario(
			raw_dictionary, scenario_data),
		"scenario-aware save validation must reject before read_save_data returns null",
	)
	assert_true(
		_runtime.save_manager.validate_data_for_scenario(
			base_snapshot,
			scenario_data,
		),
		"save family localization: scenario_context base snapshot stays valid",
	)
	for family_key: String in [
		"variable_store",
		"presentation_state",
		"read_flags",
		"unlocks",
		"flowchart_visited",
		"flowchart_state",
	]:
		if not raw_dictionary.has(family_key):
			continue
		var reduced_snapshot := base_snapshot.duplicate(true)
		reduced_snapshot[family_key] = raw_dictionary[family_key]
		assert_true(
			_runtime.save_manager.validate_data_for_scenario(
				reduced_snapshot,
				scenario_data,
			),
			"save family localization: %s snapshot stays valid"
			% family_key,
		)
	if raw_dictionary.has("timestamp"):
		var timestamp_snapshot := base_snapshot.duplicate(true)
		timestamp_snapshot["timestamp"] = raw_dictionary["timestamp"]
		assert_true(
			_runtime.save_manager.validate_data_for_scenario(
				timestamp_snapshot,
				scenario_data,
			),
			"save family localization: timestamp snapshot stays valid",
		)
	return saved


func _contains_forbidden_transient(value: Variant) -> bool:
	var forbidden := [
		"operation", "receipt", "token", "generation", "tween", "barrier",
		"progress", "activation", "runtime_binding",
	]
	if value is Dictionary:
		for key_value: Variant in (value as Dictionary).keys():
			var key := String(key_value).to_lower()
			for fragment: String in forbidden:
				if fragment in key:
					return true
			if _contains_forbidden_transient((value as Dictionary)[key_value]):
				return true
	if value is Array:
		for child: Variant in value:
			if _contains_forbidden_transient(child):
				return true
	return false


func _unhandled_push_warnings() -> Array:
	return get_errors().filter(func(error: GutTrackedError) -> bool:
		return error.is_push_warning() and not error.handled)


func _dialogue_binding_warnings() -> Array:
	return _unhandled_push_warnings().filter(
		func(warning: GutTrackedError) -> bool:
			var text := "%s %s" % [warning.code, warning.rationale]
			return "DialoguePresenter runtime binding:" in text
	)


func _assert_and_consume_warning_identity(
	warning: GutTrackedError,
	identity_parts: Array[String],
) -> void:
	var text := "%s %s" % [String(warning.code), String(warning.rationale)]
	for part: String in identity_parts:
		assert_true(part in text, "warning provenance includes '%s': %s" % [
			part, text,
		])
	warning.handled = true


func _owned_group_nodes(group_name: StringName) -> Array[CanvasItem]:
	var result: Array[CanvasItem] = []
	for node_value: Variant in get_tree().get_nodes_in_group(group_name):
		if (
			node_value is CanvasItem
			and _dialogue_presenter.is_ancestor_of(node_value as Node)
		):
			result.append(node_value as CanvasItem)
	return result


func _all_owned_visible(group_name: StringName) -> bool:
	var nodes := _owned_group_nodes(group_name)
	if nodes.is_empty():
		return false
	for node: CanvasItem in nodes:
		if not node.visible:
			return false
	return true


func _all_owned_hidden(group_name: StringName) -> bool:
	var nodes := _owned_group_nodes(group_name)
	if nodes.is_empty():
		return false
	for node: CanvasItem in nodes:
		if node.visible:
			return false
	return true


func _typed_operations(values: Array) -> Array[PresentationOperation]:
	var result: Array[PresentationOperation] = []
	for value: Variant in values:
		if value is PresentationOperation:
			result.append(value)
	return result


func _visibility_operation(
	target: String,
	action: String,
	transition: String = "fade",
	duration: float = 10.0,
) -> PresentationOperation:
	var script := _global_class_script(
		"DialogueVisibilityPresentationOperation")
	if script == null:
		return null
	var operation: Variant = script.new({
		"target": target,
		"action": action,
		"transition": transition,
		"duration": duration,
	})
	return operation as PresentationOperation


func _submit_visibility(
	target: String,
	action: String,
	policy: PresentationBatchRequest.Policy,
) -> PresentationBatchRequest:
	var operation := _visibility_operation(target, action)
	if operation == null:
		return null
	return _director().submit(
		_typed_operations([operation]),
		policy,
		_runtime.engine.context,
		{
			"scenario_id": "dialogue_visibility_programmatic",
			"source_path": "res://synthetic/dialogue_visibility.stla",
			"line": 17,
		},
	)


func _assert_stable_adv_content(content: Dictionary) -> void:
	assert_true(bool(content.get("active", false)))
	assert_eq(content.get("mode"), "adv")
	assert_eq(content.get("profile_name"), "message")
	assert_true(bool(content.get("declarative_presentation", false)))
	assert_eq(content.get("character"), "sakura")
	assert_eq(content.get("avatar_expression"), "happy")
	assert_eq(content.get("segments"), [{
		"text": "Owned ADV[expr:happy] content survives a hidden surface.",
	}])
	assert_eq(content.get("nvl_entries"), [])


func test_a_standalone_join_preserves_dialogue_ownership_and_group_independence() -> void:
	if not _require_contract() or not _start_scene("standalone_join"):
		return
	assert_true(await _wait_for_dialogues(1))
	var activation := _dialogue_requests[0].get_activation()
	var original_segments := _dialogue_requests[0].get_segments()
	_assert_stable_adv_content(_content_snapshot())
	assert_true(_all_owned_visible(&"dialogue_surface"))
	assert_true(_all_owned_visible(&"quick_menu"))
	assert_true(_advance_dialogue(0))
	assert_true(await _wait_until(func() -> bool:
		return _latest_request(PresentationBatchRequest.Policy.JOIN) != null))
	var request := _latest_request(PresentationBatchRequest.Policy.JOIN)
	assert_eq(_receipt_channels(request), ["dialogue:surface"])
	assert_false(request.is_settled())
	assert_eq(_visibility_snapshot(), {
		"surface": false, "quick_menu": true,
	})
	_assert_stable_adv_content(_content_snapshot())
	assert_eq(_dialogue_presenter.get("_dialogue_segments"), original_segments)
	assert_eq(activation.get_outcome(), DialogueActivation.Outcome.ADVANCED)
	assert_true(_dialogue_presenter.visible,
		"authored hide never toggles the DialoguePresenter root")
	assert_true((_dialogue_presenter.get_node("UnrelatedHUD") as CanvasItem).visible)
	_runtime.auto_play.is_active = true
	await get_tree().process_frame
	assert_eq(_dialogue_requests.size(), 1, "Auto does not finish a JOIN")
	SignalBus.emit_advance_requested()
	assert_true(await _wait_for_dialogues(2))
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(_visibility_snapshot(), {
		"surface": false, "quick_menu": true,
	})
	assert_true(_all_owned_hidden(&"dialogue_surface"))
	assert_true(_all_owned_visible(&"quick_menu"))
	assert_eq(_visibility_finish_requests.size(), 1)
	if _visibility_finish_requests.size() == 1:
		assert_eq((_visibility_finish_requests[0] as Array).size(), 1)
		if (_visibility_finish_requests[0] as Array).size() == 1:
			_assert_exact_finish_record(_visibility_finish_requests[0][0])
	assert_true(_dialogue_requests[1].get_activation().is_pending(),
		"the finishing advance cannot cross into the following Dialogue")


func test_b_mixed_join_seals_authored_stage_and_dialogue_receipt_union() -> void:
	if not _require_contract() or not _start_scene("mixed_join"):
		return
	assert_true(await _wait_for_dialogues(1))
	assert_true(_advance_dialogue(0))
	assert_true(await _wait_until(func() -> bool:
		var request := _latest_request(PresentationBatchRequest.Policy.JOIN)
		return request != null and request.get_receipts().size() == 3))
	var request := _latest_request(PresentationBatchRequest.Policy.JOIN)
	assert_eq(_receipt_channels(request), [
		"stage:mixed", "dialogue:surface", "dialogue:quick_menu",
	], "mixed receipt union preserves authored dispatch order")
	assert_eq(_runtime.presentation_state.stage_layers.keys(), ["mixed"])
	assert_eq(_visibility_snapshot(), {
		"surface": false, "quick_menu": false,
	})
	assert_eq(_stage_dispatches.size(), 1)
	if _stage_dispatches.size() == 1:
		assert_eq(int(_stage_dispatches[0]["dialogue_count"]), 1)
		assert_false(bool(_stage_dispatches[0]["force_cut"]))
	assert_eq(_visibility_dispatches.size(), 1)
	assert_eq(_stage_exact_starts.size(), 1)
	assert_eq(_visibility_exact_starts.size(), 2)
	assert_eq(_presentation_tails, [{
		"request_id": request.get_batch_id(), "delivered": true,
	}], "generic request-finished tail seals the complete mixed receipt union once")
	var tail_count := _presentation_tails.size()
	SignalBus.emit_advance_requested()
	assert_true(await _wait_for_dialogues(2))
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_false(_director()._entries.has(request.get_batch_id()))
	assert_eq(_presentation_tails.size(), tail_count,
		"terminal completion cannot republish the dispatch tail")
	assert_true(_all_owned_hidden(&"dialogue_surface"))
	assert_true(_all_owned_hidden(&"quick_menu"))
	assert_not_null(_stage_presenter.get_layer_node("mixed"))


func test_c_sealed_fnf_releases_dialogue_and_backlog_without_claiming_advance() -> void:
	if not _require_contract() or not _start_scene("fire_and_forget"):
		return
	assert_true(await _wait_for_dialogues(1))
	assert_true(_advance_dialogue(0))
	assert_true(await _wait_for_dialogues(2))
	var request := _latest_request(PresentationBatchRequest.Policy.FIRE_AND_FORGET)
	assert_not_null(request)
	if request == null:
		return
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(_receipt_channels(request), ["dialogue:surface"])
	assert_true(_dialogue_requests[1].get_activation().is_pending(),
		"FNF releases to the next exact Dialogue activation")
	var canonical_before: Dictionary = _runtime.presentation_state.capture_snapshot()
	var request_count := _dialogue_requests.size()
	_runtime.show_backlog()
	await get_tree().process_frame
	_runtime.close_overlay()
	await get_tree().process_frame
	assert_eq(_runtime.presentation_state.capture_snapshot(), canonical_before,
		"backlog overlay cannot mutate canonical content or gates")
	assert_eq(_dialogue_requests.size(), request_count,
		"closing backlog cannot replay Dialogue")
	var tail_count := _presentation_tails.size()
	var settlement := request.get_outcome()
	var live_request := _dialogue_requests[1]
	var live_activation := live_request.get_activation()
	assert_true(
		_advance_dialogue(1),
		"the exact active DialogueRequest owns the post-FNF advance",
	)
	await get_tree().process_frame
	assert_false(live_activation.is_pending(),
		"ordinary advance remains owned by the live Dialogue, not FNF")
	if _dialogue_requests.size() > request_count:
		assert_not_same(_dialogue_requests[request_count], live_request)
		assert_not_same(
			_dialogue_requests[request_count].get_activation(),
			live_activation,
		)
	assert_eq(_presentation_tails.size(), tail_count,
		"advancing Dialogue cannot replay the generic presentation tail")
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), settlement)
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)


func test_d_same_channel_supersession_rejects_the_old_visibility_generation() -> void:
	if not _require_contract() or not _start_scene("standalone_join"):
		return
	assert_true(await _wait_for_dialogues(1))
	var old_request := _submit_visibility(
		"surface", "hide", PresentationBatchRequest.Policy.FIRE_AND_FORGET)
	assert_not_null(old_request)
	if old_request == null:
		return
	assert_gt(old_request.get_batch_id(), 0)
	assert_true(old_request.is_settled())
	assert_eq(old_request.get_outcome(),
		PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(old_request.get_receipts().size(), 1)
	var old_receipt: PresentationOperationReceipt = old_request.get_receipts()[0]
	var old_late_settlements: Array = []
	old_request.settled.connect(func(batch_id: int, outcome: int) -> void:
		old_late_settlements.append([batch_id, outcome]))
	var winner := _submit_visibility(
		"surface", "show", PresentationBatchRequest.Policy.JOIN)
	assert_not_null(winner)
	if winner == null:
		return
	assert_gt(winner.get_batch_id(), old_request.get_batch_id())
	assert_eq(winner.get_receipts().size(), 1)
	var winning_receipt: PresentationOperationReceipt = winner.get_receipts()[0]
	assert_eq(winning_receipt.get_channel(), old_receipt.get_channel())
	assert_ne(winning_receipt.get_generation(), old_receipt.get_generation())
	assert_ne(winning_receipt.get_token(), old_receipt.get_token())
	assert_false(_director()._entries.has(old_request.get_batch_id()),
		"the superseded FNF remains released and relinquishes terminal ownership")
	assert_true(_director()._entries.has(winner.get_batch_id()))
	var old_settlements := [old_request.get_outcome(), old_request.is_settled()]
	var winner_settled := winner.is_settled()
	var dialogue_count := _dialogue_requests.size()
	var tail_count := _presentation_tails.size()
	var visual_before := _visibility_visual_snapshot()
	_emit_visibility_terminal(old_receipt)
	_emit_visibility_finish(old_receipt)
	await get_tree().process_frame
	assert_eq([old_request.get_outcome(), old_request.is_settled()], old_settlements)
	assert_eq(winner.is_settled(), winner_settled)
	assert_true(_director()._entries.has(winner.get_batch_id()))
	assert_eq(_dialogue_requests.size(), dialogue_count)
	assert_eq(_presentation_tails.size(), tail_count)
	assert_eq(_visibility_visual_snapshot(), visual_before,
		"old exact terminal/finish cannot cut the winning generation")
	assert_eq(old_late_settlements, [],
		"an already settled FNF never emits a second settlement")
	SignalBus.emit_advance_requested()
	assert_true(await _wait_until(winner.is_settled))
	assert_eq(winner.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(_visibility_snapshot().get("surface"), true)
	var winner_terminal := [winner.get_outcome(), winner.is_settled()]
	var completed_visual := _visibility_visual_snapshot()
	_emit_visibility_terminal(old_receipt)
	_emit_visibility_finish(old_receipt)
	await get_tree().process_frame
	assert_eq([winner.get_outcome(), winner.is_settled()], winner_terminal)
	assert_eq(_visibility_visual_snapshot(), completed_visual)
	assert_eq(_dialogue_requests.size(), dialogue_count)
	assert_eq(old_late_settlements, [])
	assert_true(_dialogue_requests[0].get_activation().is_pending(),
		"batch completion cannot consume the pre-existing Dialogue owner")


func test_e_persistent_and_dispatch_edge_skip_cut_exact_mixed_owner_once() -> void:
	if not _require_contract() or not _start_scene("skip_boundary"):
		return
	assert_true(await _wait_for_dialogues(1))
	var original_skip_only_read := bool(_runtime.get_setting("skip_only_read"))
	_runtime.set_setting("skip_only_read", false)
	_runtime.skip_controller.is_active = true
	assert_true(await _wait_until(func() -> bool:
		return _submitted_requests.size() == 1 and _dialogue_requests.size() >= 2
	))
	_runtime.set_setting("skip_only_read", original_skip_only_read)
	assert_eq(_submitted_requests.size(), 1)
	if _submitted_requests.size() == 1:
		var cut_request := _submitted_requests[0]
		assert_gt(cut_request.get_batch_id(), 0)
		assert_eq(cut_request.get_receipts(), [])
		assert_true(cut_request.is_settled())
		assert_eq(cut_request.get_outcome(),
			PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(_stage_exact_starts, [],
		"persistent Skip cuts Stage and Dialogue before receipt allocation")
	assert_eq(_stage_dispatches.size(), 1)
	if _stage_dispatches.size() == 1:
		assert_true(bool(_stage_dispatches[0]["force_cut"]))
	assert_true(_stage_presenter._layer_tweens.is_empty())
	assert_eq(_visibility_snapshot(), {
		"surface": false, "quick_menu": false,
	})
	assert_true(_dialogue_requests[1].get_activation().is_pending())

	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	_runtime.stage_assets_path = STAGE_ASSET_ROOT
	_clear_observations()
	var edge_once := [false]
	var preseal := [{}]
	var edge_request := [null]
	var settlements: Array = []
	var on_first_stage_receipt := func(
		_presenter_id: int,
		_layer_id: String,
		_token: int,
		request_id: int,
		_generation: int,
	) -> void:
		if edge_once[0]:
			return
		edge_once[0] = true
		var entry: Dictionary = _director()._entries.get(request_id, {})
		edge_request[0] = entry.get("request")
		preseal[0] = {
			"sealed": bool(entry.get("sealed", true)),
			"settled": (
				edge_request[0] == null
				or (edge_request[0] as PresentationBatchRequest).is_settled()
			),
		}
		if edge_request[0] != null:
			(edge_request[0] as PresentationBatchRequest).settled.connect(func(
				batch_id: int,
				outcome: int,
			) -> void: settlements.append([batch_id, outcome]), CONNECT_ONE_SHOT)
		SignalBus.emit_advance_requested()
		_runtime.skip_controller.is_active = true
	SignalBus.stage_transition_receipt_started.connect(
		on_first_stage_receipt, CONNECT_ONE_SHOT)
	assert_true(_start_scene("skip_boundary"))
	assert_true(await _wait_for_dialogues(1))
	assert_true(_advance_dialogue(0))
	assert_true(await _wait_for_dialogues(2))
	assert_eq(preseal[0], {"sealed": false, "settled": false})
	assert_not_null(edge_request[0])
	if edge_request[0] != null:
		var request: PresentationBatchRequest = edge_request[0]
		assert_eq(_receipt_channels(request), [
			"stage:skipped", "dialogue:surface", "dialogue:quick_menu",
		])
		assert_true(request.is_settled())
		assert_eq(request.get_outcome(),
			PresentationBatchRequest.Outcome.COMPLETED)
		assert_eq(settlements, [[
			request.get_batch_id(), PresentationBatchRequest.Outcome.COMPLETED,
		]])
		assert_false(_director()._entries.has(request.get_batch_id()))
	assert_true(_dialogue_requests[1].get_activation().is_pending(),
		"preseal ordinary advance cannot replay across the dispatch tail")
	var dialogue_count := _dialogue_requests.size()
	_director().on_skip_active_changed(true)
	await get_tree().process_frame
	assert_eq(_dialogue_requests.size(), dialogue_count,
		"late duplicate Skip cannot advance the next Dialogue")


func test_f_adv_mid_visibility_save_load_restores_stable_content_without_side_effects() -> void:
	if not _require_contract() or not _start_scene("adv_save"):
		return
	assert_true(await _wait_for_dialogues(1))
	assert_true(_advance_dialogue(0))
	assert_true(await _wait_until(func() -> bool:
		return _latest_request(PresentationBatchRequest.Policy.JOIN) != null))
	var old_request := _latest_request(PresentationBatchRequest.Policy.JOIN)
	var old_context: ScenarioContext = _runtime.engine.context
	var voice_count := _voice_requests.size()
	var backlog_count: int = _runtime.backlog_manager.get_entries().size()
	_runtime.save(SAVE_SLOT)
	var saved: Variant = _read_save_with_lifecycle_diagnostics(
		SAVE_SLOT, old_context.scenario_data)
	assert_true(saved is Dictionary)
	if not saved is Dictionary:
		return
	var saved_presentation: Dictionary = saved.get("presentation_state", {})
	assert_eq(saved_presentation.get("dialogue_visibility"), {
		"surface": false, "quick_menu": true,
	})
	var saved_content: Dictionary = saved_presentation.get(
		"dialogue_content", {})
	assert_eq(saved_content.get("profile_name"), "message")
	assert_eq(saved_content.get("avatar_expression"), "happy")
	assert_eq(saved_content.get("segments"), [{
		"text": "Stable ADV[expr:happy] save projection.",
	}])
	assert_eq(old_context.current_command().type, "presentation_batch")
	var stage_count := _stage_dispatches.size()
	var accepted: bool = await _runtime.continue_from_save(SAVE_SLOT)
	assert_true(accepted)
	assert_true(await _wait_until(func() -> bool:
		return (
			_runtime.engine.context != old_context
			and _dialogue_requests.size() >= 2
		)))
	assert_true(old_request.is_settled())
	assert_eq(old_request.get_outcome(),
		PresentationBatchRequest.Outcome.CANCELLED)
	assert_eq(_visibility_snapshot().get("surface"), false)
	assert_eq(_voice_requests.size(), voice_count,
		"visual-only restore never replays voice")
	assert_eq(_runtime.backlog_manager.get_entries().size(), backlog_count,
		"load clears retired history and creates only the authored tail entry")
	assert_true(_dialogue_requests[-1].get_activation().is_pending())
	assert_eq(_stage_dispatches.size(), stage_count,
		"Dialogue visual restore cannot replay a Stage operation")


func test_f_mid_fnf_save_load_uses_canonical_checkpoint_and_same_cursor_no_work() -> void:
	if not _require_contract():
		return
	var receipt_checkpoint: Array[Dictionary] = []
	var on_receipt_started := func(
		_presenter_instance_id: int,
		_target: String,
		_token: int,
		operation_request_id: int,
		_generation: int,
	) -> void:
		var entry: Dictionary = _director()._entries.get(
			operation_request_id, {})
		var request: PresentationBatchRequest = entry.get("request")
		receipt_checkpoint.append({
			"request": request,
			"sealed": bool(entry.get("sealed", true)),
			"settled": request == null or request.is_settled(),
			"cursor_type": _runtime.engine.context.current_command().type,
			"visibility": _visibility_snapshot(),
		})
		_runtime.save(SAVE_SLOT)
	var receipt_signal: Signal = SignalBus.get(
		"dialogue_visibility_transition_receipt_started")
	receipt_signal.connect(on_receipt_started, CONNECT_ONE_SHOT)
	assert_true(_start_scene("fnf_save"))
	assert_true(await _wait_for_dialogues(1))
	var voice_count := _voice_requests.size()
	var backlog_count: int = _runtime.backlog_manager.get_entries().size()
	assert_true(_advance_dialogue(0))
	assert_true(await _wait_for_dialogues(2))
	assert_eq(receipt_checkpoint.size(), 1,
		"save is captured synchronously from the first visibility receipt")
	if receipt_checkpoint.size() != 1:
		return
	var old_request: PresentationBatchRequest = receipt_checkpoint[0]["request"]
	assert_not_null(old_request)
	assert_false(bool(receipt_checkpoint[0]["sealed"]))
	assert_false(bool(receipt_checkpoint[0]["settled"]))
	assert_eq(receipt_checkpoint[0]["cursor_type"], "presentation_batch")
	assert_eq(receipt_checkpoint[0]["visibility"], {
		"surface": false, "quick_menu": true,
	})
	assert_true(old_request.is_settled())
	assert_eq(old_request.get_outcome(),
		PresentationBatchRequest.Outcome.COMPLETED)
	var stage_count := _stage_dispatches.size()
	var read_flags_before: Dictionary = _runtime.read_flags.capture_snapshot()
	var initial_receipts := _visibility_exact_starts.size()
	var initial_dispatches := _visibility_dispatches.size()
	var token_serial_before_load := int(
		_dialogue_presenter.get("_dialogue_visibility_token_serial"))
	var saved: Variant = _read_save_with_lifecycle_diagnostics(
		SAVE_SLOT, _runtime.engine.context.scenario_data)
	assert_true(saved is Dictionary)
	if not saved is Dictionary:
		return
	assert_eq(saved.get("presentation_state", {}).get("dialogue_visibility"), {
		"surface": false, "quick_menu": true,
	})
	assert_eq(saved.get("presentation_state", {}).get(
		"dialogue_content", {}).get("segments"), [{
		"text": "Stable FNF ADV[expr:happy] save projection.",
	}])
	assert_false(_contains_forbidden_transient(saved),
		"save contains stable canonical projection only")
	var expected_fnf_tail := [{
		"request_id": old_request.get_batch_id(),
		"delivered": true,
	}]
	assert_eq(_presentation_tails, expected_fnf_tail,
		"sealed FNF emits its generic dispatch tail exactly once")
	var initial_resets := _visibility_resets
	var initial_sequence_size := _visibility_lifecycle_sequence.size()
	var request_id_before_load := int(SignalBus._next_stage_operation_request_id)
	var dialogue_count := _dialogue_requests.size()
	var old_context: ScenarioContext = _runtime.engine.context
	assert_true(await _runtime.continue_from_save(SAVE_SLOT))
	assert_true(await _wait_until(func() -> bool:
		return (
			_runtime.engine.context != old_context
			and _dialogue_requests.size() > dialogue_count
			and not bool(_dialogue_presenter.get("_is_typing"))
		)))
	assert_true(old_request.is_settled())
	assert_eq(old_request.get_outcome(),
		PresentationBatchRequest.Outcome.COMPLETED,
		"late lifecycle cancellation cannot revoke a sealed FNF release")
	assert_eq(_visibility_snapshot(), {"surface": false, "quick_menu": true})
	assert_gt(_visibility_state_applies.size(), 0,
		"load restores content and gates through one visual-only cut")
	assert_gt(_visibility_resets, initial_resets,
		"load hard-resets old visibility ownership before restore")
	var load_sequence := _visibility_lifecycle_sequence.slice(
		initial_sequence_size)
	assert_has(load_sequence, "reset")
	assert_has(load_sequence, "apply")
	assert_lt(load_sequence.find("reset"), load_sequence.find("apply"),
		"winning restore invalidates old generations before visual-only apply")
	assert_eq(_visibility_exact_starts.size(), initial_receipts,
		"same-cursor satisfied FNF allocates no new receipt/token/tween")
	assert_eq(_visibility_dispatches.size(), initial_dispatches,
		"same-cursor satisfied FNF allocates no new visibility dispatch")
	assert_eq(int(SignalBus._next_stage_operation_request_id),
		request_id_before_load,
		"same-cursor satisfied FNF is preallocation no-work")
	assert_eq(int(_dialogue_presenter.get("_dialogue_visibility_token_serial")),
		token_serial_before_load,
		"same-cursor satisfied FNF preserves monotonic visibility serial")
	_assert_no_visibility_visual_work()
	assert_eq(_presentation_tails, expected_fnf_tail,
		"same-cursor preallocation no-work cannot omit or duplicate the FNF tail")
	assert_eq(_voice_requests.size(), voice_count)
	assert_eq(_stage_dispatches.size(), stage_count)
	assert_eq(_runtime.backlog_manager.get_entries().size(), backlog_count)
	assert_eq(_runtime.read_flags.capture_snapshot(), read_flags_before,
		"visual-only load and same-cursor no-work add no read mark")
	var new_dialogue_segments := _dialogue_requests.slice(dialogue_count).map(
		func(request: DialogueRequest) -> Array:
			return request.get_segments()
	)
	assert_eq(new_dialogue_segments, [[{
		"text": "FNF save tail.",
		"voice": "",
		"stage_ops": [],
	}]], "load fresh-dispatches the authored tail exactly once")
	assert_true(_dialogue_requests[-1].get_activation().is_pending())


func test_g_nvl_mid_visibility_save_load_rebuilds_ordered_page_once() -> void:
	if not _require_contract() or not _start_scene("nvl_save"):
		return
	assert_true(await _wait_for_dialogues(1))
	assert_true(_advance_dialogue(0))
	assert_true(await _wait_for_dialogues(2))
	assert_true(_advance_dialogue(1))
	assert_true(await _wait_until(func() -> bool:
		return _latest_request(PresentationBatchRequest.Policy.JOIN) != null))
	var old_context: ScenarioContext = _runtime.engine.context
	var old_request := _latest_request(PresentationBatchRequest.Policy.JOIN)
	var voice_count := _voice_requests.size()
	_runtime.save(SAVE_SLOT)
	var saved: Variant = _read_save_with_lifecycle_diagnostics(
		SAVE_SLOT, old_context.scenario_data)
	assert_true(saved is Dictionary)
	if not saved is Dictionary:
		return
	var content: Dictionary = saved.get(
		"presentation_state", {}).get("dialogue_content", {})
	assert_eq(content.get("mode"), "nvl")
	assert_eq(content.get("profile_name"), "novel_second")
	assert_eq(content.get("avatar_expression"), "smile")
	var entries: Array = content.get("nvl_entries", [])
	assert_eq(entries.size(), 2)
	if entries.size() == 2:
		assert_eq(entries.map(func(entry: Dictionary) -> String:
			return String(entry.get("profile_name", ""))), [
			"novel_first", "novel_second",
		])
		assert_eq(entries.map(func(entry: Dictionary) -> String:
			return String((entry.get("segments", []) as Array)[0].get(
				"text", ""))), [
			"First NVL entry.", "Second NVL[expr:smile] entry.",
		])
	assert_true(await _runtime.continue_from_save(SAVE_SLOT))
	assert_true(await _wait_until(func() -> bool:
		return (
			_runtime.engine.context != old_context
			and _dialogue_requests.size() >= 3
			and not bool(_dialogue_presenter.get("_is_typing"))
		)))
	assert_true(old_request.is_settled())
	assert_eq(old_request.get_outcome(),
		PresentationBatchRequest.Outcome.CANCELLED)
	var rendered := String(_dialogue_presenter.get("_nvl_render_source"))
	assert_eq(rendered.count("First NVL entry."), 1)
	assert_eq(rendered.count("Second NVL"), 1)
	assert_eq(rendered.count("NVL load tail."), 1)
	assert_eq(_voice_requests.size(), voice_count)
	assert_eq(_visibility_snapshot().get("surface"), false)


func test_h_rollback_visual_cut_restores_content_and_gates_before_fresh_dispatch() -> void:
	if not _require_contract() or not _start_scene("adv_save"):
		return
	assert_true(await _wait_for_dialogues(1))
	assert_true(_advance_dialogue(0))
	assert_true(await _wait_until(func() -> bool:
		return _latest_request(PresentationBatchRequest.Policy.JOIN) != null))
	var old_context: ScenarioContext = _runtime.engine.context
	var old_request := _latest_request(PresentationBatchRequest.Policy.JOIN)
	var snapshot: Dictionary = _runtime._capture_rollback_snapshot()
	var stable_content: Dictionary = snapshot.get(
		"presentation_state", {}).get("dialogue_content", {}).duplicate(true)
	var checkpoint_index: int = _runtime.backlog_manager.get_entries().size()
	_runtime.backlog_manager.add_entry(
		"dialogue visibility checkpoint", [], 166,
		func() -> Dictionary: return snapshot.duplicate(true),
	)
	assert_eq(_runtime.backlog_manager.get_entries().size(), checkpoint_index + 1)
	var checkpoint_entry: Dictionary = _runtime.backlog_manager.get_entry(
		checkpoint_index)
	assert_eq(int(checkpoint_entry.get("command_uid", -1)), 166)
	assert_eq(
		checkpoint_entry.get("snapshot", {}),
		snapshot,
	)
	var voice_count := _voice_requests.size()
	assert_true(_runtime.jump_from_backlog(checkpoint_index))
	assert_true(await _wait_until(func() -> bool:
		return (
			_runtime.engine.context != old_context
			and _dialogue_requests.size() >= 2
		)))
	assert_eq(_visibility_snapshot(), {
		"surface": false, "quick_menu": true,
	})
	assert_eq(stable_content.get("segments"), [{
		"text": "Stable ADV[expr:happy] save projection.",
	}], "rollback captured the stable Dialogue before replacing its owner")
	assert_eq(_content_snapshot().get("segments"), [{
		"text": "ADV load tail.",
	}], "fresh dispatch advances once after the retained visual cut")
	assert_true(old_request.is_settled())
	assert_eq(old_request.get_outcome(),
		PresentationBatchRequest.Outcome.CANCELLED)
	assert_eq(_voice_requests.size(), voice_count)
	assert_true(_dialogue_requests[-1].get_activation().is_pending())


func test_h_retained_visual_apply_is_a_side_effect_free_content_and_gate_cut() -> void:
	if not _require_contract():
		return
	var prepared: bool = _runtime._prepare_scenario(SCENARIO_PATH)
	assert_true(prepared)
	if not prepared:
		return
	var context: ScenarioContext = _runtime.engine.context
	assert_true(context.set_scene("adv_save"))
	context.current_dialogue_mode = "adv"
	context.current_dialogue_profile_name = "message"
	context.current_dialogue_uses_declarative_presentation = true
	var stable_content := {
		"version": 1,
		"active": true,
		"mode": "adv",
		"profile_name": "message",
		"declarative_presentation": true,
		"character": "sakura",
		"segments": [{
			"text": "Stable ADV[expr:happy] save projection.",
		}],
		"avatar_expression": "happy",
		"nvl_entries": [],
	}
	_runtime.presentation_state.restore_snapshot({
		"bg": "",
		"stage_layers": {},
		"bgm": "",
		"dialogue_visibility": {
			"surface": false, "quick_menu": true,
		},
		"dialogue_content": stable_content,
	})
	SignalBus.hide_dialogue.emit()
	var dialogue_count := _dialogue_requests.size()
	var voice_count := _voice_requests.size()
	var backlog_count: int = _runtime.backlog_manager.get_entries().size()
	var stage_count := _stage_dispatches.size()
	assert_true(_runtime._apply_retained_presentation(context))
	assert_eq(_runtime.presentation_state.capture_snapshot().get(
		"dialogue_content"), stable_content)
	assert_eq(_dialogue_presenter.get("_current_character"), "sakura")
	assert_eq(_dialogue_presenter.get("_current_avatar_expression"), "happy")
	var avatar_view := _dialogue_presenter.get_node(
		"AvatarContainer/AvatarTexture") as TextureRect
	assert_not_null(avatar_view.texture)
	assert_true(avatar_view.texture is AtlasTexture)
	if avatar_view.texture is AtlasTexture:
		var atlas := (avatar_view.texture as AtlasTexture).atlas
		assert_not_null(atlas)
		if atlas != null:
			assert_true(atlas.resource_path.ends_with("sakura/happy.png"),
				"visual-only restore resolves the final authored avatar expression")
	assert_eq(_dialogue_presenter.get("_dialogue_voice_character"), "")
	assert_eq(_dialogue_presenter.get("_current_voice"), "")
	assert_eq(_dialogue_presenter.get("_current_voice_character"), "")
	assert_false(bool(_dialogue_presenter.get("_voice_playing")))
	assert_eq(int(_dialogue_presenter.get("_active_voice_token")), -1)
	assert_false(bool(_dialogue_presenter.get("_playback_queue_active")))
	assert_eq(int(_dialogue_presenter.get("_playback_owner_dialogue_gen")), -1)
	assert_eq(int(_dialogue_presenter.get("_playback_voice_token")), -1)
	assert_eq(float(_dialogue_presenter.get("_playback_total_duration")), 0.0)
	assert_eq(float(_dialogue_presenter.get("_playback_played_duration")), 0.0)
	assert_eq(_dialogue_presenter.get("_playback_segment_durations"), [])
	assert_eq(_dialogue_presenter.get("_stage_transition_records"), {})
	assert_eq(_dialogue_presenter.get("_finalization_transition_records"), {})
	assert_eq(_dialogue_presenter.get("_stage_operation_request_owners"), {})
	assert_eq(_dialogue_presenter.get("_stage_operation_request_results"), {})
	assert_eq(int(_dialogue_presenter.get("_next_stage_segment_index")), 0)
	assert_false(bool(_dialogue_presenter.get("_finalization_pending")))
	assert_false(bool(_dialogue_presenter.get("_finalization_in_progress")))
	assert_eq(_dialogue_presenter.get("_queued_voice_replay_request"), {})
	assert_eq(_dialogue_presenter.get("_dialogue_segments"), [{
		"text": "Stable ADV[expr:happy] save projection.",
	}])
	assert_eq(_dialogue_presenter.get("_current_mode"), "adv")
	assert_null(_dialogue_presenter.get("_current_dialogue_activation"))
	assert_eq(_dialogue_requests.size(), dialogue_count)
	assert_eq(_voice_requests.size(), voice_count)
	assert_eq(_runtime.backlog_manager.get_entries().size(), backlog_count)
	assert_eq(_stage_dispatches.size(), stage_count)
	assert_true(_director()._entries.is_empty(),
		"visual-only restore allocates no presentation receipt or barrier")
	assert_eq(_visibility_exact_starts, [],
		"visual-only restore allocates no visibility receipt/token/tween")
	_assert_no_visibility_visual_work()
	assert_true(_dialogue_presenter.visible)
	assert_true(_all_owned_hidden(&"dialogue_surface"))
	assert_true(_all_owned_visible(&"quick_menu"))
	var indicator: Variant = _dialogue_presenter.get("_advance_indicator")
	assert_true(indicator == null or not bool((indicator as CanvasItem).visible),
		"visual-only cut leaves the advance indicator unarmed")


func test_h_nvl_visual_cut_restores_each_entry_with_its_own_profile() -> void:
	if not _require_contract():
		return
	var prepared: bool = _runtime._prepare_scenario(SCENARIO_PATH)
	assert_true(prepared)
	if not prepared:
		return
	var context: ScenarioContext = _runtime.engine.context
	assert_true(context.set_scene("nvl_save"))
	context.current_dialogue_mode = "nvl"
	context.current_dialogue_profile_name = "novel_second"
	context.current_dialogue_uses_declarative_presentation = true
	context.nvl_page_entries = [
		{
			"profile_name": "novel_first", "character": "sakura",
			"segments": [{"text": "First entry"}],
		},
		{
			"profile_name": "novel_second", "character": "senpai",
			"segments": [{"text": "Second entry"}],
		},
	]
	var content := {
		"version": 1, "active": true, "mode": "nvl",
		"profile_name": "novel_second", "declarative_presentation": true,
		"character": "senpai", "segments": [{"text": "Second entry"}],
		"avatar_expression": "", "nvl_entries": context.nvl_page_entries,
	}
	_runtime.presentation_state.restore_snapshot({
		"bg": "", "stage_layers": {}, "bgm": "",
		"dialogue_visibility": {"surface": true, "quick_menu": true},
		"dialogue_content": content,
	})
	assert_true(_runtime._apply_retained_presentation(context))
	assert_eq(_dialogue_presenter.get("_nvl_render_source"),
		"A%s：First entry~B%s：Second entry" % ["sakura", "senpai"],
		"each restored NVL entry uses its authored Profile affixes")
	assert_eq(_dialogue_presenter.get("_dialogue_voice_character"), "")
	assert_eq(_dialogue_presenter.get("_current_voice"), "")
	assert_false(bool(_dialogue_presenter.get("_playback_queue_active")))
	assert_null(_dialogue_presenter.get("_current_dialogue_activation"))
	assert_eq(_visibility_exact_starts, [])
	assert_true(_director()._entries.is_empty())
	_assert_no_visibility_visual_work()


func test_i_rejected_navigation_restores_retained_projection_and_fresh_dispatches() -> void:
	if not _require_contract() or not _start_scene("standalone_join"):
		return
	assert_true(await _wait_for_dialogues(1))
	assert_true(_advance_dialogue(0))
	assert_true(await _wait_until(func() -> bool:
		return _latest_request(PresentationBatchRequest.Policy.JOIN) != null))
	var retained_context: ScenarioContext = _runtime.engine.context
	var retained_index := retained_context.current_command_index
	var old_request := _latest_request(PresentationBatchRequest.Policy.JOIN)
	var retained_content := _content_snapshot()
	var retained_visibility := _visibility_snapshot()
	_runtime.title_scene_path = CONFIGURED_TITLE_PROBE
	_runtime._navigation_scene_change_override = \
		func(_scene: PackedScene) -> int: return ERR_CANT_CREATE
	_runtime.return_to_title()
	assert_true(await _wait_until(func() -> bool:
		var fresh := _latest_request(PresentationBatchRequest.Policy.JOIN)
		return fresh != null and fresh.get_batch_id() != old_request.get_batch_id()))
	assert_push_error("failed to request the configured title scene")
	assert_push_error("failed to enter the configured title scene; falling back")
	assert_push_error("failed to request the built-in title scene")
	assert_push_error("failed to enter the built-in title scene")
	var fresh := _latest_request(PresentationBatchRequest.Policy.JOIN)
	assert_not_null(fresh)
	if fresh == null:
		return
	assert_same(_runtime.engine.context, retained_context)
	assert_false(retained_context.is_finished)
	assert_eq(retained_context.current_command_index, retained_index)
	assert_true(old_request.is_settled())
	assert_eq(old_request.get_outcome(),
		PresentationBatchRequest.Outcome.CANCELLED)
	assert_ne(fresh.get_batch_id(), old_request.get_batch_id())
	assert_eq(_content_snapshot(), retained_content)
	assert_eq(_visibility_snapshot(), retained_visibility)
	assert_true(_director().has_blocking_waiter(retained_context),
		"generic lifecycle blocker owns Dialogue visibility JOIN")
	SignalBus.emit_advance_requested()
	assert_true(await _wait_for_dialogues(2))
	assert_true(fresh.is_settled())
	assert_true(_dialogue_requests[-1].get_activation().is_pending())


func test_j_missing_groups_warn_once_with_exact_provenance_and_bind_nothing() -> void:
	if not _require_contract() or not _start_scene("missing_binding"):
		return
	assert_true(await _wait_for_dialogues(1))
	var unrelated := _dialogue_presenter.get_node("UnrelatedHUD") as CanvasItem
	var overlap := _dialogue_presenter.get_node("OverlapProbe") as CanvasItem
	assert_true(unrelated.visible)
	assert_true(overlap.visible)
	assert_true(_advance_dialogue(0))
	assert_true(await _wait_for_dialogues(2))
	assert_eq(_visibility_snapshot().get("surface"), false,
		"canonical gate updates even when it owns no runtime participant")
	assert_true(_all_owned_visible(&"dialogue_surface"),
		"missing authored groups do not fall back to the default surface")
	assert_true(_all_owned_visible(&"quick_menu"),
		"missing authored groups do not fall back to the default quick menu")
	assert_true(unrelated.visible)
	assert_true(overlap.visible)
	assert_eq(_visibility_dispatches.size(), 1)
	if _visibility_dispatches.size() == 1:
		var operations: Array = _visibility_dispatches[0]["operations"]
		assert_eq(operations.size(), 1)
		assert_true(operations.size() == 1 and operations[0] is Object,
			"runtime binding travels on the typed operation authority")
		if operations.size() == 1 and operations[0] is Object:
			var binding: Dictionary = operations[0].call("get_runtime_binding")
			assert_eq(binding.get("current", {}).get("surface_groups"), [
				"missing_surface",
			])
			assert_eq(binding.get("current", {}).get("quick_menu_groups"), [
				"missing_quick",
			])
			assert_eq(binding.get("current", {}).get("profile_name"), "missing_groups")
			assert_eq(binding.get("current", {}).get("provenance", {}).get(
				"source_path"), SCENARIO_PATH)
	var presenter_binding: Dictionary = _dialogue_presenter.get(
		"_dialogue_visibility_binding")
	assert_eq(presenter_binding.get("current", {}).get("surface_groups"), [])
	assert_eq(presenter_binding.get("current", {}).get("quick_menu_groups"), [])
	var live_activation := _dialogue_requests[-1].get_activation()
	SignalBus.hide_dialogue.emit()
	await get_tree().process_frame
	assert_false(live_activation.is_pending())
	assert_null(_dialogue_presenter.get("_current_dialogue_activation"))
	assert_true(_runtime._apply_retained_presentation(_runtime.engine.context))
	assert_true(_runtime._apply_retained_presentation(_runtime.engine.context))
	var warnings := _dialogue_binding_warnings()
	assert_eq(warnings.size(), 2,
		"missing surface and quick-menu participants warn exactly once each")
	if warnings.size() == 2:
		var expected := [
			["profile=missing_groups", "source=%s" % SCENARIO_PATH,
				"field=surface_groups", "line=6", "group=missing_surface",
				"failure_kind=missing"],
			["profile=missing_groups", "source=%s" % SCENARIO_PATH,
				"field=quick_menu_groups", "line=6", "group=missing_quick",
				"failure_kind=missing"],
		]
		for identity_value: Variant in expected:
			var identity: Array[String] = []
			for part_value: Variant in identity_value:
				identity.append(String(part_value))
			var matching := warnings.filter(func(warning: GutTrackedError) -> bool:
				var text := "%s %s" % [warning.code, warning.rationale]
				return identity.all(func(part: String) -> bool: return part in text))
			assert_eq(matching.size(), 1,
				"warning dedup identity includes all six provenance fields")
			if matching.size() == 1:
				_assert_and_consume_warning_identity(matching[0], identity)


func test_j_overlap_warns_once_and_only_overlap_uses_default_fallback() -> void:
	if not _require_contract() or not _start_scene("overlap_binding"):
		return
	assert_true(await _wait_for_dialogues(1))
	var unrelated := _dialogue_presenter.get_node("UnrelatedHUD") as CanvasItem
	var overlap := _dialogue_presenter.get_node("OverlapProbe") as CanvasItem
	assert_true(unrelated.visible)
	assert_true(overlap.visible)
	assert_true(_advance_dialogue(0))
	assert_true(await _wait_for_dialogues(2))
	assert_true(_all_owned_visible(&"dialogue_surface"))
	assert_true(_all_owned_hidden(&"quick_menu"),
		"overlap rejection alone may bind the declared default quick menu")
	assert_true(overlap.visible,
		"the authored overlapping member is never partially retained")
	assert_true(unrelated.visible)
	assert_eq(_visibility_snapshot().get("quick_menu"), false)
	assert_eq(_visibility_dispatches.size(), 1)
	if _visibility_dispatches.size() == 1:
		var operations: Array = _visibility_dispatches[0]["operations"]
		assert_true(operations.size() == 1 and operations[0] is Object)
		if operations.size() == 1 and operations[0] is Object:
			var binding: Dictionary = operations[0].call("get_runtime_binding")
			assert_eq(binding.get("current", {}).get("surface_groups"), [
				"overlap_surface",
			])
			assert_eq(binding.get("current", {}).get("quick_menu_groups"), [
				"overlap_quick",
			])
			assert_eq(binding.get("current", {}).get("provenance", {}).get(
				"source_path"), SCENARIO_PATH)
	var presenter_binding: Dictionary = _dialogue_presenter.get(
		"_dialogue_visibility_binding")
	assert_eq(presenter_binding.get("current", {}).get("surface_groups"), [
		"dialogue_surface",
	])
	assert_eq(presenter_binding.get("current", {}).get("quick_menu_groups"), [
		"quick_menu",
		])
	var live_activation := _dialogue_requests[-1].get_activation()
	SignalBus.hide_dialogue.emit()
	await get_tree().process_frame
	assert_false(live_activation.is_pending())
	assert_null(_dialogue_presenter.get("_current_dialogue_activation"))
	assert_true(_runtime._apply_retained_presentation(_runtime.engine.context))
	var warnings := _dialogue_binding_warnings()
	assert_eq(warnings.size(), 1, "normalized overlap warns exactly once")
	if warnings.size() == 1:
		_assert_and_consume_warning_identity(warnings[0], [
			"profile=overlapping", "source=%s" % SCENARIO_PATH,
			"field=surface_groups", "line=7", "group=overlap_surface",
			"field=quick_menu_groups", "line=7", "group=overlap_quick",
			"failure_kind=overlap",
		])


func test_j_overlapping_default_groups_fail_to_empty_without_recursive_fallback() -> void:
	if not _require_contract():
		return
	var toolbar := _dialogue_presenter.get_node("Toolbar") as CanvasItem
	toolbar.add_to_group("dialogue_surface")
	assert_true(_start_scene("overlap_binding"))
	assert_true(await _wait_for_dialogues(1))
	assert_true(_advance_dialogue(0))
	assert_true(await _wait_for_dialogues(2))
	assert_eq(_visibility_snapshot().get("quick_menu"), false)
	assert_true(toolbar.visible,
		"an overlapping default binding becomes empty, never partially owned")
	assert_true((_dialogue_presenter.get_node("DialogueBg") as CanvasItem).visible)
	assert_true((_dialogue_presenter.get_node("OverlapProbe") as CanvasItem).visible)
	assert_true((_dialogue_presenter.get_node("UnrelatedHUD") as CanvasItem).visible)
	if not _visibility_dispatches.is_empty():
		var operations: Array = _visibility_dispatches[-1]["operations"]
		assert_true(operations.size() == 1 and operations[0] is Object)
		if operations.size() == 1 and operations[0] is Object:
			var binding: Dictionary = operations[0].call("get_runtime_binding")
			assert_eq(binding.get("current", {}).get("surface_groups"), [
				"overlap_surface",
			])
			assert_eq(binding.get("current", {}).get("quick_menu_groups"), [
				"overlap_quick",
			])
		var presenter_binding: Dictionary = _dialogue_presenter.get(
			"_dialogue_visibility_binding")
		assert_eq(presenter_binding.get("current", {}).get("surface_groups"), [])
		assert_eq(presenter_binding.get("current", {}).get("quick_menu_groups"), [])
	toolbar.remove_from_group("dialogue_surface")
	for warning: GutTrackedError in _unhandled_push_warnings():
		warning.handled = true


func test_j_hard_reset_cancels_old_generations_and_clears_projection() -> void:
	if not _require_contract() or not _start_scene("mixed_join"):
		return
	assert_true(await _wait_for_dialogues(1))
	var activation := _dialogue_requests[0].get_activation()
	assert_true(_advance_dialogue(0))
	assert_true(await _wait_until(func() -> bool:
		return _latest_request(PresentationBatchRequest.Policy.JOIN) != null))
	var request := _latest_request(PresentationBatchRequest.Policy.JOIN)
	var old_receipts := request.get_receipts()
	var settlements: Array = []
	request.settled.connect(func(batch_id: int, outcome: int) -> void:
		settlements.append([batch_id, outcome]))
	var navigation := int(_runtime.get("_navigation_generation"))
	var context: ScenarioContext = _runtime.engine.context
	assert_true(_runtime._reset_presentation(navigation, context))
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(),
		PresentationBatchRequest.Outcome.CANCELLED)
	assert_eq(activation.get_outcome(), DialogueActivation.Outcome.ADVANCED)
	assert_eq(_visibility_snapshot(), {
		"surface": true, "quick_menu": true,
	})
	assert_eq(_content_snapshot(), {
		"version": 1,
		"active": false,
		"mode": "adv",
		"profile_name": "",
		"declarative_presentation": false,
		"character": "",
		"segments": [],
		"avatar_expression": "",
		"nvl_entries": [],
	})
	assert_null(_dialogue_presenter.get("_current_dialogue_activation"))
	assert_eq(_dialogue_presenter.get("_nvl_render_source"), "")
	assert_false(_dialogue_presenter.visible)
	assert_false(_director().has_blocking_waiter(context))
	assert_gt(old_receipts.size(), 0,
		"the cancellation test must retire allocated exact identities")
	var reset_snapshot: Dictionary = _runtime.presentation_state.capture_snapshot()
	var reset_visual := _visibility_visual_snapshot()
	var dialogue_count := _dialogue_requests.size()
	var tail_count := _presentation_tails.size()
	var settlement := [request.get_outcome(), request.is_settled()]
	for receipt_value: Variant in old_receipts:
		var receipt: PresentationOperationReceipt = receipt_value
		if String(receipt.get_channel()).begins_with("dialogue:"):
			_emit_visibility_terminal(receipt)
			_emit_visibility_finish(receipt)
	await get_tree().process_frame
	assert_eq([request.get_outcome(), request.is_settled()], settlement)
	assert_eq(_runtime.presentation_state.capture_snapshot(), reset_snapshot)
	assert_eq(_visibility_visual_snapshot(), reset_visual)
	assert_eq(_dialogue_requests.size(), dialogue_count)
	assert_eq(_presentation_tails.size(), tail_count)
	assert_false(_director()._entries.has(request.get_batch_id()))
	assert_eq(settlements, [[
		request.get_batch_id(), PresentationBatchRequest.Outcome.CANCELLED,
	]], "hard reset settles the retired request exactly once")


func test_j_accepted_title_replacement_clears_old_content_and_visibility_owner() -> void:
	if not _require_contract() or not _start_scene("mixed_join"):
		return
	assert_true(await _wait_for_dialogues(1))
	assert_true(_advance_dialogue(0))
	assert_true(await _wait_until(func() -> bool:
		return _latest_request(PresentationBatchRequest.Policy.JOIN) != null))
	var old_context: ScenarioContext = _runtime.engine.context
	var old_request := _latest_request(PresentationBatchRequest.Policy.JOIN)
	var old_receipts := old_request.get_receipts()
	var settlements: Array = []
	old_request.settled.connect(func(batch_id: int, outcome: int) -> void:
		settlements.append([batch_id, outcome]))
	_runtime.title_scene_path = CONFIGURED_TITLE_PROBE
	_runtime._navigation_scene_change_override = \
		func(_scene: PackedScene) -> int: return OK
	_runtime.return_to_title()
	assert_true(await _wait_until(func() -> bool:
		return int(_runtime._navigation_scene_slot_active_serial) > 0))
	var navigation_serial := int(_runtime._navigation_scene_slot_active_serial)

	_dialogue_presenter.free()
	_dialogue_presenter = DIALOGUE_FIXTURE.instantiate()
	_dialogue_presenter.name = "DialogueVisibilityReplacementPresenter"
	add_child_autoqfree(_dialogue_presenter)
	await get_tree().process_frame
	_dialogue_presenter.set("_char_interval", 0.0)
	_runtime._settle_navigation_scene_slot(navigation_serial, true)
	assert_true(await _wait_until(func() -> bool:
		return (
			_runtime.engine.context != old_context
			and String(_runtime._navigation_kind).is_empty()
		)))
	assert_false(old_context.is_runtime_owner_current())
	assert_true(old_request.is_settled())
	assert_eq(old_request.get_outcome(),
		PresentationBatchRequest.Outcome.CANCELLED)
	assert_false(_director()._entries.has(old_request.get_batch_id()))
	assert_eq(_visibility_snapshot(), {
		"surface": true, "quick_menu": true,
	})
	assert_eq(_content_snapshot().get("active"), false)
	assert_null(_dialogue_presenter.get("_current_dialogue_activation"))
	assert_false(_dialogue_presenter.visible)
	assert_eq(_dialogue_requests.size(), 1,
		"accepted replacement cannot publish an old Dialogue tail")
	var replacement_id := _dialogue_presenter.get_instance_id()
	var replacement_snapshot: Dictionary = _runtime.presentation_state.capture_snapshot()
	var replacement_visual := _visibility_visual_snapshot()
	var tail_count := _presentation_tails.size()
	var settlement := [old_request.get_outcome(), old_request.is_settled()]
	for receipt_value: Variant in old_receipts:
		var receipt: PresentationOperationReceipt = receipt_value
		if String(receipt.get_channel()).begins_with("dialogue:"):
			_emit_visibility_terminal(receipt)
			_emit_visibility_finish(receipt)
	await get_tree().process_frame
	assert_eq(_dialogue_presenter.get_instance_id(), replacement_id)
	assert_eq(_runtime.presentation_state.capture_snapshot(), replacement_snapshot)
	assert_eq(_visibility_visual_snapshot(), replacement_visual)
	assert_eq([old_request.get_outcome(), old_request.is_settled()], settlement)
	assert_eq(_presentation_tails.size(), tail_count)
	assert_eq(_dialogue_requests.size(), 1)
	assert_eq(settlements, [[
		old_request.get_batch_id(), PresentationBatchRequest.Outcome.CANCELLED,
	]], "accepted replacement settles the old owner exactly once")
