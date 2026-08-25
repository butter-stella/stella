extends GutTest
## Typed, channel-neutral composition surface frozen for issue #164.
##
## This file never preloads missing production scripts. Global-class discovery
## makes exact-main fail by assertion for the intended missing capability while
## keeping import and the test script itself valid.


const REQUIRED_CLASSES := [
	"PresentationOperation",
	"StagePresentationOperation",
	"PresentationOperationReceipt",
	"PresentationBatchRequest",
	"PresentationDirector",
]


func _global_class_entry(class_name_value: String) -> Dictionary:
	for entry_value: Variant in ProjectSettings.get_global_class_list():
		var entry: Dictionary = entry_value
		if String(entry.get("class", "")) == class_name_value:
			return entry
	return {}


func _global_class_script(class_name_value: String) -> Script:
	var entry := _global_class_entry(class_name_value)
	if entry.is_empty():
		return null
	var path := String(entry.get("path", ""))
	if path.is_empty() or not ResourceLoader.exists(path, "Script"):
		return null
	return load(path) as Script


func _method_names(script: Script) -> Array[String]:
	var names: Array[String] = []
	if script == null:
		return names
	for method_value: Variant in script.get_script_method_list():
		var method: Dictionary = method_value
		names.append(String(method.get("name", "")))
	return names


func _script_method(script: Script, method_name: String) -> Dictionary:
	if script == null:
		return {}
	for method_value: Variant in script.get_script_method_list():
		var method: Dictionary = method_value
		if String(method.get("name", "")) == method_name:
			return method
	return {}


func _argument_contract(method: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for argument_value: Variant in method.get("args", []):
		var argument: Dictionary = argument_value
		result.append({
			"name": String(argument.get("name", "")),
			"type": int(argument.get("type", TYPE_NIL)),
			"class_name": String(argument.get("class_name", "")),
		})
	return result


func _programmatic_context(command: CommandData) -> ScenarioContext:
	var data := ScenarioData.new()
	data.id = "presentation_batch_handler_contract"
	data.source_path = "res://synthetic/presentation_batch_handler.stla"
	var scene := SceneData.new()
	scene.id = "start"
	scene.commands = [command]
	data.scenes = [scene]
	var context := ScenarioContext.new(data)
	context.bind_runtime_owner({"current": true})
	return context


func _signal_by_name(signal_name: StringName) -> Variant:
	if not SignalBus.has_signal(signal_name):
		return null
	return SignalBus.get(signal_name)


func _assert_no_public_setter(script: Script, field_names: Array[String]) -> void:
	var methods := _method_names(script)
	for field_name: String in field_names:
		assert_does_not_have(methods, "set_%s" % field_name,
			"immutable identity has no public setter: %s" % field_name)


func _runtime_owned_objects_for_script(
	runtime: Node,
	script: Script,
) -> Array[Object]:
	var owned: Array[Object] = []
	if script == null:
		return owned
	for property_value: Variant in runtime.get_property_list():
		var property: Dictionary = property_value
		if int(property.get("type", TYPE_NIL)) != TYPE_OBJECT:
			continue
		var property_name := StringName(property.get("name", &""))
		if property_name.is_empty():
			continue
		var candidate: Variant = runtime.get(property_name)
		if (
			candidate is Object
			and is_instance_valid(candidate)
			and (candidate as Object).get_script() == script
			and candidate not in owned
		):
			owned.append(candidate as Object)
	for child: Node in runtime.get_children():
		if child.get_script() == script and child not in owned:
			owned.append(child)
	return owned


func test_generic_typed_surface_exists_without_stage_specific_aliases() -> void:
	var missing: Array[String] = []
	for required_class: String in REQUIRED_CLASSES:
		if _global_class_script(required_class) == null:
			missing.append(required_class)
	assert_eq(missing, [], "missing issue #164 typed composition surface")
	if not missing.is_empty():
		return

	var base_operation := _global_class_script("PresentationOperation")
	var stage_operation := _global_class_script("StagePresentationOperation")
	assert_same(stage_operation.get_base_script(), base_operation,
		"Stage is the first typed PresentationOperation adapter")
	assert_ne(_global_class_script("PresentationOperationReceipt"), null)
	assert_ne(_global_class_script("PresentationBatchRequest"), null)
	assert_ne(_global_class_script("PresentationDirector"), null)


func test_batch_request_exposes_only_the_frozen_policy_and_outcome_enums() -> void:
	var request_script := _global_class_script("PresentationBatchRequest")
	assert_not_null(request_script, "missing issue #164 PresentationBatchRequest")
	if request_script == null:
		return
	var constants: Dictionary = request_script.get_script_constant_map()
	assert_true(constants.has("Policy"), "typed request owns Policy")
	assert_true(constants.has("Outcome"), "typed request owns Outcome")
	if not constants.has("Policy") or not constants.has("Outcome"):
		return
	var policy: Dictionary = constants["Policy"]
	var outcome: Dictionary = constants["Outcome"]
	var policy_names := policy.keys()
	policy_names.sort()
	var outcome_names := outcome.keys()
	outcome_names.sort()
	assert_eq(policy_names, ["FIRE_AND_FORGET", "JOIN"])
	assert_eq(outcome_names, ["CANCELLED", "COMPLETED", "FAILED"])


func test_stage_operation_payload_is_typed_and_deep_defensive() -> void:
	var stage_script := _global_class_script("StagePresentationOperation")
	assert_not_null(stage_script,
		"missing issue #164 StagePresentationOperation")
	if stage_script == null:
		return
	var payload := {
		"action": "show",
		"id": "typed",
		"properties": {
			"asset": "stage:redraw_source",
			"position": [12.0, 34.0],
		},
		"transition": "fade",
		"duration": 2.0,
	}
	var operation: Object = stage_script.new(payload)
	assert_not_null(operation)
	assert_eq(operation.call("get_kind"), &"stage")
	assert_eq(operation.call("get_channel"), &"stage:typed",
		"named Stage ownership is part of the typed channel")
	var first_payload: Dictionary = operation.call("get_payload")
	assert_eq(first_payload, payload)
	first_payload["id"] = "mutated"
	(first_payload["properties"] as Dictionary)["position"][0] = 999.0
	assert_eq(operation.call("get_payload"), payload,
		"payload getter returns a deep defensive copy")
	var clear_operation: Object = stage_script.new({
		"action": "clear",
		"id": "",
		"properties": {},
		"transition": "cut",
		"duration": 0.0,
	})
	assert_eq(clear_operation.call("get_channel"), &"stage:*",
		"clear is the only wildcard Stage ownership channel")
	_assert_no_public_setter(stage_script,
		["kind", "channel", "payload"])


func test_receipt_is_an_exact_read_only_five_part_identity() -> void:
	var receipt_script := _global_class_script("PresentationOperationReceipt")
	assert_not_null(receipt_script,
		"missing issue #164 PresentationOperationReceipt")
	if receipt_script == null:
		return
	var receipt: Object = receipt_script.new(
		73, 1701, &"stage:typed", 41, 9)
	assert_eq(int(receipt.call("get_batch_id")), 73)
	assert_eq(int(receipt.call("get_presenter_instance_id")), 1701)
	assert_eq(receipt.call("get_channel"), &"stage:typed")
	assert_eq(int(receipt.call("get_token")), 41)
	assert_eq(int(receipt.call("get_generation")), 9)
	_assert_no_public_setter(receipt_script, [
		"batch_id", "presenter_instance_id", "channel", "token", "generation",
	])
	var public_property_names: Array[String] = []
	for property_value: Variant in receipt.get_property_list():
		public_property_names.append(String(
			(property_value as Dictionary).get("name", "")))
	for exact_field: String in [
		"batch_id", "presenter_instance_id", "channel", "token", "generation",
	]:
		assert_does_not_have(public_property_names, exact_field,
			"receipt exposes only defensive getters, never a same-name field")


func test_batch_request_is_defensive_authority_only_and_single_settled() -> void:
	var request_script := _global_class_script("PresentationBatchRequest")
	var stage_script := _global_class_script("StagePresentationOperation")
	var receipt_script := _global_class_script("PresentationOperationReceipt")
	assert_not_null(request_script, "missing PresentationBatchRequest")
	assert_not_null(stage_script, "missing StagePresentationOperation")
	assert_not_null(receipt_script, "missing PresentationOperationReceipt")
	if request_script == null or stage_script == null or receipt_script == null:
		return
	var constants: Dictionary = request_script.get_script_constant_map()
	var policy: Dictionary = constants.get("Policy", {})
	var outcome: Dictionary = constants.get("Outcome", {})
	if policy.is_empty() or outcome.is_empty():
		return
	var operation: Object = stage_script.new({
		"action": "show",
		"id": "request",
		"properties": {"asset": "stage:redraw_source"},
		"transition": "fade",
		"duration": 1.0,
	})
	var authored_operations: Array = [operation]
	var request: Object = request_script.new(policy["JOIN"], authored_operations)
	assert_true(request.has_signal("settled"),
		"BatchRequest exposes one exact terminal notification")
	var settled_events: Array[Dictionary] = []
	if request.has_signal("settled"):
		request.connect("settled", func(batch_id: int, settled_outcome: int) -> void:
			settled_events.append({
				"batch_id": batch_id,
				"outcome": settled_outcome,
			})
		)
	authored_operations.clear()
	assert_eq(int(request.call("get_policy")), int(policy["JOIN"]))
	var first_operations: Array = request.call("get_operations")
	assert_eq(first_operations.size(), 1,
		"constructor and getter both defend the operation container")
	first_operations.clear()
	assert_eq((request.call("get_operations") as Array).size(), 1)
	assert_false(bool(request.call("is_settled")))

	var authority := RefCounted.new()
	var foreign := RefCounted.new()
	assert_false(bool(request.call("_bind_authority", null)))
	assert_true(bool(request.call("_bind_authority", authority)))
	assert_false(bool(request.call("_bind_authority", authority)),
		"authority binds exactly once")
	assert_false(bool(request.call("_bind_authority", foreign)))
	var receipt: Object = receipt_script.new(
		73, 1701, &"stage:request", 41, 9)
	assert_false(bool(request.call("_seal", 73, [receipt], foreign)))
	assert_true(bool(request.call("_seal", 73, [receipt], authority)))
	assert_false(bool(request.call("_seal", 73, [receipt], authority)),
		"request seals exactly once")
	assert_eq(int(request.call("get_batch_id")), 73)
	var first_receipts: Array = request.call("get_receipts")
	assert_eq(first_receipts.size(), 1)
	first_receipts.clear()
	assert_eq((request.call("get_receipts") as Array).size(), 1,
		"receipt container is defensive and its element is immutable")

	assert_false(bool(request.call(
		"_settle", outcome["COMPLETED"], foreign)))
	assert_false(bool(request.call(
		"_settle", outcome["COMPLETED"], null)))
	assert_false(bool(request.call("is_settled")))
	assert_eq(settled_events, [],
		"foreign/null authority cannot emit terminal state")
	assert_true(bool(request.call(
		"_settle", outcome["COMPLETED"], authority)))
	assert_true(bool(request.call("is_settled")))
	assert_eq(int(request.call("get_outcome")), int(outcome["COMPLETED"]))
	assert_eq(settled_events, [{
		"batch_id": 73,
		"outcome": int(outcome["COMPLETED"]),
	}], "first legal settle emits exact batch id/outcome once")
	assert_false(bool(request.call(
		"_settle", outcome["FAILED"], authority)),
		"late settle cannot overwrite the first terminal outcome")
	assert_false(bool(request.call(
		"_settle", outcome["CANCELLED"], foreign)))
	assert_eq(int(request.call("get_outcome")), int(outcome["COMPLETED"]))
	assert_eq(settled_events.size(), 1,
		"late/duplicate settle never emits a second terminal notification")


func test_runtime_owns_exactly_one_generic_director_with_submit() -> void:
	var director_script := _global_class_script("PresentationDirector")
	assert_not_null(director_script, "missing issue #164 PresentationDirector")
	if director_script == null:
		return
	assert_has(_method_names(director_script), "submit",
		"generic Director exposes the frozen submit boundary")
	var runtime := get_tree().root.get_node("StellaRuntime")
	var directors := _runtime_owned_objects_for_script(runtime, director_script)
	assert_eq(directors.size(), 1,
		"StellaRuntime is the single composition root for PresentationDirector")


func test_legacy_raw_stage_facade_remains_void_and_untyped() -> void:
	var runtime := get_tree().root.get_node("StellaRuntime")
	assert_true(runtime.has_method("apply_stage_operations"))
	var method_info: Dictionary = {}
	for method_value: Variant in runtime.get_method_list():
		var candidate: Dictionary = method_value
		if String(candidate.get("name", "")) == "apply_stage_operations":
			method_info = candidate
			break
	assert_false(method_info.is_empty())
	if method_info.is_empty():
		return
	var return_info: Dictionary = method_info.get("return", {})
	assert_eq(int(return_info.get("type", TYPE_NIL)), TYPE_NIL,
		"the old Dictionary facade remains fire-and-forget void")


func test_dialogue_visibility_is_the_second_typed_operation_adapter() -> void:
	var base_operation := _global_class_script("PresentationOperation")
	var visibility_operation := _global_class_script(
		"DialogueVisibilityPresentationOperation")
	assert_not_null(visibility_operation,
		"missing issue #166 typed Dialogue visibility adapter")
	if base_operation == null or visibility_operation == null:
		return
	assert_same(visibility_operation.get_base_script(), base_operation)
	var operation: Object = visibility_operation.new({
		"target": "quick_menu",
		"action": "hide",
		"transition": "fade",
		"duration": 0.25,
	})
	assert_eq(operation.call("get_kind"), &"dialogue_visibility")
	assert_eq(operation.call("get_channel"), &"dialogue:quick_menu")


func test_batch_request_defensively_preserves_mixed_authored_order() -> void:
	var visibility_script := _global_class_script(
		"DialogueVisibilityPresentationOperation")
	assert_not_null(visibility_script,
		"missing issue #166 typed Dialogue visibility adapter")
	if visibility_script == null:
		return
	var stage := StagePresentationOperation.new({
		"action": "show",
		"id": "mixed",
		"properties": {"asset": "stage:redraw_source"},
		"transition": "cut",
		"duration": 0.0,
	})
	var surface: PresentationOperation = visibility_script.new({
		"target": "surface",
		"action": "hide",
		"transition": "fade",
		"duration": 0.25,
	}) as PresentationOperation
	var quick_menu: PresentationOperation = visibility_script.new({
		"target": "quick_menu",
		"action": "show",
		"transition": "cut",
		"duration": 0.0,
	}) as PresentationOperation
	var authored: Array[PresentationOperation] = [stage, surface, quick_menu]
	var request := PresentationBatchRequest.new(
		PresentationBatchRequest.Policy.JOIN, authored)
	authored.clear()
	var operations := request.get_operations()
	assert_eq(operations.map(
		func(operation: PresentationOperation) -> StringName:
			return operation.get_kind()
	), [&"stage", &"dialogue_visibility", &"dialogue_visibility"])
	assert_eq(operations.map(
		func(operation: PresentationOperation) -> StringName:
			return operation.get_channel()
	), [&"stage:mixed", &"dialogue:surface", &"dialogue:quick_menu"])
	operations.clear()
	assert_eq(request.get_operations().size(), 3,
		"mixed operation container remains defensive")


func test_director_accepts_true_empty_visibility_as_positive_zero_receipt_batch() -> void:
	var visibility_script := _global_class_script(
		"DialogueVisibilityPresentationOperation")
	assert_not_null(visibility_script,
		"missing issue #166 typed Dialogue visibility adapter")
	if visibility_script == null:
		return
	var runtime := get_tree().root.get_node("StellaRuntime")
	var director: PresentationDirector = runtime.presentation_director
	assert_not_null(director)
	var snapshot: Dictionary = runtime.presentation_state.capture_snapshot()
	runtime.presentation_state.clear()
	var context := ScenarioContext.new(ScenarioData.new())
	var operation: PresentationOperation = visibility_script.new({
		"target": "surface",
		"action": "hide",
		"transition": "cut",
		"duration": 0.0,
	}) as PresentationOperation
	var operations: Array[PresentationOperation] = [operation]
	var request := director.submit(
		operations,
		PresentationBatchRequest.Policy.JOIN,
		context,
		{
			"source_path": "res://synthetic/empty_visibility.stla",
			"scenario_id": "empty_visibility",
			"line": 3,
		},
	)
	assert_gt(request.get_batch_id(), 0,
		"true empty Presenter completion still crosses the dispatch boundary")
	assert_eq(request.get_receipts(), [])
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(runtime.presentation_state.capture_snapshot().get(
		"dialogue_visibility", {}).get("surface"), false)
	runtime.presentation_state.restore_snapshot(snapshot)


func test_visibility_no_work_respects_live_target_receipt_ownership() -> void:
	var visibility_script := _global_class_script(
		"DialogueVisibilityPresentationOperation")
	assert_not_null(visibility_script)
	if visibility_script == null:
		return
	var runtime := get_tree().root.get_node("StellaRuntime")
	var director: PresentationDirector = runtime.presentation_director
	var snapshot: Dictionary = runtime.presentation_state.capture_snapshot()
	runtime.presentation_state.clear()
	var context := _programmatic_context(CommandData.new())
	var dispatches: Array[Dictionary] = []
	var active_identity := [{}]
	var token := [700]
	var generation := [40]
	var on_visibility := func(operations: Array, _force_cut: bool) -> void:
		var request_id := SignalBus.current_dialogue_visibility_request_id()
		var payload: Dictionary = (operations[0] as PresentationOperation).get_payload()
		var target := String(payload["target"])
		var prior: Dictionary = active_identity[0]
		if not prior.is_empty() and target == prior["target"]:
			SignalBus.dialogue_visibility_transition_terminal.emit(
				31, target, prior["token"],
				prior["request_id"], prior["generation"],
				&"superseded")
		token[0] += 1
		generation[0] += 1
		active_identity[0] = {
			"target": target, "token": token[0], "request_id": request_id,
			"generation": generation[0],
		}
		dispatches.append((active_identity[0] as Dictionary).duplicate(true))
		SignalBus.dialogue_visibility_transition_receipt_started.emit(
			31, target, token[0], request_id, generation[0])
	SignalBus.dialogue_visibility_operations_requested.connect(on_visibility)

	var same_without_owner := director.submit(
		[visibility_script.new({
			"target": "surface", "action": "show",
			"transition": "fade", "duration": 0.25,
		}) as PresentationOperation],
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
		context, {"source_path": "res://synthetic/no_work.stla", "line": 1})
	assert_eq(same_without_owner.get_batch_id(), 0,
		"canonical equality without active ownership remains true no-work")

	var old_request := director.submit(
		[visibility_script.new({
			"target": "surface", "action": "hide",
			"transition": "fade", "duration": 0.25,
		}) as PresentationOperation],
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
		context, {"source_path": "res://synthetic/active.stla", "line": 2})
	assert_gt(old_request.get_batch_id(), 0)
	assert_true(old_request.is_settled(), "FNF settles before its visual receipt")
	assert_eq(old_request.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(dispatches.size(), 1)

	var unrelated_no_work := director.submit(
		[visibility_script.new({
			"target": "quick_menu", "action": "show",
			"transition": "fade", "duration": 0.25,
		}) as PresentationOperation],
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
		context, {"source_path": "res://synthetic/unrelated.stla", "line": 3})
	assert_eq(unrelated_no_work.get_batch_id(), 0,
		"an active surface receipt cannot block quick-menu no-work")

	var replacement := director.submit(
		[visibility_script.new({
			"target": "surface", "action": "hide",
			"transition": "fade", "duration": 0.25,
		}) as PresentationOperation],
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
		context, {"source_path": "res://synthetic/replacement.stla", "line": 4})
	assert_gt(replacement.get_batch_id(), 0,
		"same canonical target with an active receipt must dispatch")
	assert_ne(replacement.get_batch_id(), old_request.get_batch_id())
	assert_eq(dispatches.size(), 2)
	if dispatches.size() == 2:
		assert_ne(dispatches[0]["token"], dispatches[1]["token"])
		assert_ne(dispatches[0]["generation"], dispatches[1]["generation"])
	var replacement_receipts: Array = replacement.get_receipts().duplicate()
	assert_false(replacement_receipts.is_empty(),
		"replacement owns the complete defensive receipt union")
	var synthetic_receipts: Array = replacement_receipts.filter(
		func(receipt_value: Variant) -> bool:
			if not receipt_value is PresentationOperationReceipt:
				return false
			var receipt: PresentationOperationReceipt = receipt_value
			return (
				receipt.get_batch_id() == replacement.get_batch_id()
				and receipt.get_presenter_instance_id() == 31
				and receipt.get_channel() == &"dialogue:surface"
				and receipt.get_token() == active_identity[0]["token"]
				and receipt.get_generation() == active_identity[0]["generation"]
			)
	)
	assert_eq(synthetic_receipts.size(), 1,
		"the defensive union contains the exact synthetic receipt once")
	var quick_menu_before_terminal: Variant = runtime.presentation_state.capture_snapshot().get(
		"dialogue_visibility", {}).get("quick_menu")
	var unrelated_outcome := unrelated_no_work.get_outcome()
	var unrelated_settled := unrelated_no_work.is_settled()
	var seen_receipt_identities: Dictionary = {}
	var finish_records: Array[Dictionary] = []
	for receipt_value: Variant in replacement_receipts:
		assert_true(receipt_value is PresentationOperationReceipt)
		if not receipt_value is PresentationOperationReceipt:
			continue
		var receipt: PresentationOperationReceipt = receipt_value
		var channel := String(receipt.get_channel())
		var target := channel.trim_prefix("dialogue:")
		assert_eq(receipt.get_batch_id(), replacement.get_batch_id())
		assert_gt(receipt.get_presenter_instance_id(), 0)
		assert_eq(channel, "dialogue:surface")
		assert_eq(target, "surface")
		if channel != "dialogue:surface" or target != "surface":
			continue
		assert_gt(receipt.get_token(), 0)
		assert_gt(receipt.get_generation(), 0)
		var identity_key := "%d:%d:%s:%d:%d" % [
			receipt.get_batch_id(), receipt.get_presenter_instance_id(),
			channel, receipt.get_token(), receipt.get_generation(),
		]
		assert_false(seen_receipt_identities.has(identity_key),
			"replacement receipt five-field identity is unique")
		seen_receipt_identities[identity_key] = true
		SignalBus.dialogue_visibility_transition_terminal.emit(
			receipt.get_presenter_instance_id(), target, receipt.get_token(),
			receipt.get_batch_id(), receipt.get_generation(), &"completed")
		finish_records.append({
			"presenter_instance_id": receipt.get_presenter_instance_id(),
			"target": target,
			"token": receipt.get_token(),
			"operation_request_id": receipt.get_batch_id(),
			"generation": receipt.get_generation(),
		})
	assert_false(director._entries.has(replacement.get_batch_id()))
	assert_true(replacement.is_settled())
	assert_eq(replacement.get_outcome(), PresentationBatchRequest.Outcome.COMPLETED)
	assert_eq(runtime.presentation_state.capture_snapshot().get(
		"dialogue_visibility", {}).get("quick_menu"), quick_menu_before_terminal)
	assert_eq(unrelated_no_work.get_outcome(), unrelated_outcome)
	assert_eq(unrelated_no_work.is_settled(), unrelated_settled)
	var replacement_outcome := replacement.get_outcome()
	var replacement_settled := replacement.is_settled()
	var synthetic_owner := (active_identity[0] as Dictionary).duplicate(true)
	SignalBus.dialogue_visibility_transition_receipts_finish_requested.emit(
		finish_records)
	assert_false(director._entries.has(replacement.get_batch_id()),
		"late terminal cannot revive the replacement ledger")
	assert_eq(replacement.get_outcome(), replacement_outcome)
	assert_eq(replacement.is_settled(), replacement_settled)
	assert_eq(active_identity[0], synthetic_owner)
	assert_eq(runtime.presentation_state.capture_snapshot().get(
		"dialogue_visibility", {}).get("quick_menu"), quick_menu_before_terminal)
	assert_eq(unrelated_no_work.get_outcome(), unrelated_outcome)
	assert_eq(unrelated_no_work.is_settled(), unrelated_settled)
	var after_terminal := director.submit(
		[visibility_script.new({
			"target": "surface", "action": "hide",
			"transition": "fade", "duration": 0.25,
		}) as PresentationOperation],
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
		context, {"source_path": "res://synthetic/terminal.stla", "line": 5})
	assert_eq(after_terminal.get_batch_id(), 0,
		"exact terminal restores canonical no-work")
	if SignalBus.dialogue_visibility_operations_requested.is_connected(on_visibility):
		SignalBus.dialogue_visibility_operations_requested.disconnect(on_visibility)
	runtime.presentation_state.restore_snapshot(snapshot)


func test_handler_never_short_circuits_authored_visibility_before_director() -> void:
	var runtime := get_tree().root.get_node("StellaRuntime")
	var handler := PresentationBatchHandler.new(
		runtime.presentation_director, runtime.presentation_state)
	var command := CommandData.new()
	command.type = "presentation_batch"
	command.declared_line = 10
	command.params = {
		"policy": "fire_and_forget",
		"operations": [{
			"kind": "dialogue_visibility",
			"payload": {"target": "surface", "action": "show",
				"transition": "fade", "duration": 0.25},
		}],
		"operation_lines": [11],
	}
	var validation: Dictionary = handler.call("_validate_and_reduce", command)
	assert_true(bool(validation.get("valid", false)))
	assert_false(bool(validation.get("no_work", true)),
		"Handler must pass authored visibility equality to Director ownership preflight")


func test_malformed_dialogue_child_rejects_the_entire_mixed_batch_preallocation() -> void:
	var visibility_script := _global_class_script(
		"DialogueVisibilityPresentationOperation")
	assert_not_null(visibility_script,
		"missing issue #166 typed Dialogue visibility adapter")
	if visibility_script == null:
		return
	var runtime := get_tree().root.get_node("StellaRuntime")
	var before: Dictionary = runtime.presentation_state.capture_snapshot()
	var stage := StagePresentationOperation.new({
		"action": "show",
		"id": "must_not_commit",
		"properties": {"asset": "stage:redraw_source"},
		"transition": "cut",
		"duration": 0.0,
	})
	var malformed: PresentationOperation = visibility_script.new({
		"target": "surface",
		"action": "hide",
		"transition": "fade",
		"duration": NAN,
	}) as PresentationOperation
	var operations: Array[PresentationOperation] = [stage, malformed]
	var request := (runtime.presentation_director as PresentationDirector).submit(
		operations,
		PresentationBatchRequest.Policy.JOIN,
		ScenarioContext.new(ScenarioData.new()),
		{
			"source_path": "res://synthetic/malformed_visibility.stla",
			"scenario_id": "malformed_visibility",
			"line": 29,
		},
	)
	assert_push_error("res://synthetic/malformed_visibility.stla:29")
	assert_true(request.is_settled())
	assert_eq(request.get_outcome(), PresentationBatchRequest.Outcome.FAILED)
	assert_eq(request.get_batch_id(), 0,
		"invalid mixed content fails before request-id allocation")
	assert_eq(request.get_receipts(), [])
	assert_eq(runtime.presentation_state.capture_snapshot(), before,
		"invalid Dialogue content cannot partially commit its Stage sibling")


func test_presentation_batch_handler_exact_api_registration_and_single_runtime_owner() -> void:
	var handler_script := _global_class_script("PresentationBatchHandler")
	assert_not_null(handler_script, "missing issue #166 PresentationBatchHandler")
	if handler_script == null:
		return
	var init_method := _script_method(handler_script, "_init")
	assert_eq(_argument_contract(init_method), [
		{
			"name": "director", "type": TYPE_OBJECT,
			"class_name": "PresentationDirector",
		},
		{
			"name": "presentation_state", "type": TYPE_OBJECT,
			"class_name": "PresentationState",
		},
	])
	assert_eq(init_method.get("default_args", []), [null, null])
	assert_eq(int(init_method.get("return", {}).get("type", TYPE_NIL)), TYPE_NIL,
		"PresentationBatchHandler._init returns void")
	var command_type_method := _script_method(handler_script, "get_command_type")
	assert_false(command_type_method.is_empty())
	if not command_type_method.is_empty():
		assert_eq(int(command_type_method.get("return", {}).get(
			"type", TYPE_NIL)), TYPE_STRING)
	var execute_method := _script_method(handler_script, "execute")
	assert_eq(_argument_contract(execute_method), [
		{"name": "data", "type": TYPE_OBJECT, "class_name": "CommandData"},
		{
			"name": "context", "type": TYPE_OBJECT,
			"class_name": "ScenarioContext",
		},
	])
	assert_eq(int(execute_method.get("return", {}).get("type", TYPE_NIL)),
		TYPE_NIL, "PresentationBatchHandler.execute returns void")
	var runtime := get_tree().root.get_node("StellaRuntime")
	assert_not_null(runtime.engine)
	assert_not_null(runtime.engine.registry)
	if runtime.engine == null or runtime.engine.registry == null:
		return
	assert_true(runtime.engine.registry.has_handler("presentation_batch"))
	var registered: Object = runtime.engine.registry.get_handler(
		"presentation_batch")
	assert_not_null(registered)
	if registered == null:
		return
	assert_same(registered.get_script(), handler_script)
	assert_eq(registered.call("get_command_type"), "presentation_batch")
	var owned_count := 0
	for handler_value: Variant in runtime.engine.registry._handlers.values():
		if handler_value is Object and (handler_value as Object).get_script() == handler_script:
			owned_count += 1
	assert_eq(owned_count, 1,
		"StellaRuntime registers exactly one generic batch handler")


func test_presentation_batch_handler_preflight_is_atomic_source_located_and_current_owned() -> void:
	var handler_script := _global_class_script("PresentationBatchHandler")
	assert_not_null(handler_script, "missing issue #166 PresentationBatchHandler")
	if handler_script == null:
		return
	var runtime := get_tree().root.get_node("StellaRuntime")
	var handler: Object = handler_script.new(
		runtime.presentation_director, runtime.presentation_state)
	var command := CommandData.new()
	command.type = "presentation_batch"
	command.declared_line = 43
	command.params = {
		"policy": "join",
		"operations": [
			{
				"kind": "stage",
				"payload": {
					"action": "show", "id": "must_not_commit",
					"properties": {"asset": "stage:redraw_source"},
					"transition": "cut", "duration": 0.0,
				},
			},
			{
				"kind": "dialogue_visibility",
				"payload": {
					"target": "surface", "action": "hide",
					"transition": "fade", "duration": NAN,
				},
			},
		],
		"operation_lines": [44, 71],
	}
	var context := _programmatic_context(command)
	var before_state: Dictionary = runtime.presentation_state.capture_snapshot()
	var before_entries: Dictionary = runtime.presentation_director._entries.duplicate(true)
	var before_request_id := int(SignalBus._next_stage_operation_request_id)
	var stage_dispatches := [0]
	var visibility_dispatches := [0]
	var generic_tails := [0]
	var receipt_starts := [0]
	var on_stage := func(_operations: Array, _force_cut: bool) -> void:
		stage_dispatches[0] += 1
	var on_visibility := func(_operations: Array, _force_cut: bool) -> void:
		visibility_dispatches[0] += 1
	var on_tail := func(_request_id: int, _delivered: bool) -> void:
		generic_tails[0] += 1
	var on_receipt := func(
		_presenter_id: int,
		_target: String,
		_token: int,
		_request_id: int,
		_generation: int,
	) -> void:
		receipt_starts[0] += 1
	SignalBus.stage_operations_requested.connect(on_stage)
	var visibility_signal: Variant = _signal_by_name(
		&"dialogue_visibility_operations_requested")
	var tail_signal: Variant = _signal_by_name(&"presentation_operation_request_finished")
	var receipt_signal: Variant = _signal_by_name(
		&"dialogue_visibility_transition_receipt_started")
	if visibility_signal is Signal:
		(visibility_signal as Signal).connect(on_visibility)
	if tail_signal is Signal:
		(tail_signal as Signal).connect(on_tail)
	if receipt_signal is Signal:
		(receipt_signal as Signal).connect(on_receipt)
	handler.call("execute", command, context)
	assert_push_error("res://synthetic/presentation_batch_handler.stla:71")
	assert_true(context.is_finished,
		"the current invalid authored command fail-closes its owner")
	assert_eq(runtime.presentation_state.capture_snapshot(), before_state)
	assert_eq(runtime.presentation_director._entries, before_entries)
	assert_eq(int(SignalBus._next_stage_operation_request_id), before_request_id)
	assert_eq(stage_dispatches[0], 0)
	assert_eq(visibility_dispatches[0], 0)
	assert_eq(generic_tails[0], 0)
	assert_eq(receipt_starts[0], 0)
	assert_null(runtime.get_node_or_null("must_not_commit"))
	SignalBus.stage_operations_requested.disconnect(on_stage)
	if visibility_signal is Signal:
		(visibility_signal as Signal).disconnect(on_visibility)
	if tail_signal is Signal:
		(tail_signal as Signal).disconnect(on_tail)
	if receipt_signal is Signal:
		(receipt_signal as Signal).disconnect(on_receipt)

	for lines_value: Variant in [
		[44],
		[44, 0],
		[44, "71"],
		[44, 71, 72],
	]:
		var lines_command := CommandData.new()
		lines_command.type = "presentation_batch"
		lines_command.declared_line = 43
		lines_command.params = command.params.duplicate(true)
		lines_command.params["operation_lines"] = lines_value
		var lines_context := _programmatic_context(lines_command)
		handler.call("execute", lines_command, lines_context)
		assert_push_error("res://synthetic/presentation_batch_handler.stla:43")
		assert_true(lines_context.is_finished, str(lines_value))
	var missing_lines_command := CommandData.new()
	missing_lines_command.type = "presentation_batch"
	missing_lines_command.declared_line = 43
	missing_lines_command.params = command.params.duplicate(true)
	missing_lines_command.params.erase("operation_lines")
	var missing_lines_context := _programmatic_context(missing_lines_command)
	handler.call("execute", missing_lines_command, missing_lines_context)
	assert_push_error("res://synthetic/presentation_batch_handler.stla:43")
	assert_true(missing_lines_context.is_finished)
	assert_eq(runtime.presentation_state.capture_snapshot(), before_state)
	assert_eq(runtime.presentation_director._entries, before_entries)
	assert_eq(int(SignalBus._next_stage_operation_request_id), before_request_id)

	var retired_context := _programmatic_context(command)
	retired_context.bind_runtime_owner({"current": false})
	handler.call("execute", command, retired_context)
	assert_push_error("ScenarioContext is missing, cancelled, or not current")
	assert_false(retired_context.is_finished,
		"a deauthorized retained owner cannot be fail-closed by an old tail")
	var cancelled_context := _programmatic_context(command)
	cancelled_context.request_cancellation()
	var cancelled_finished := cancelled_context.is_finished
	handler.call("execute", command, cancelled_context)
	assert_push_error("ScenarioContext is missing, cancelled, or not current")
	assert_eq(cancelled_context.is_finished, cancelled_finished)
	assert_eq(runtime.presentation_state.capture_snapshot(), before_state)
	assert_eq(runtime.presentation_director._entries, before_entries)
	assert_eq(int(SignalBus._next_stage_operation_request_id), before_request_id)


func test_signal_bus_generic_projection_defers_and_serializes_cross_queue_dispatch() -> void:
	var dispatches: Array[String] = []
	var stage_finishes: Array[String] = []
	var generic_finishes: Array[String] = []
	var stale_mixed_request_id := [0]
	var mixed_request_id := [0]
	var stage_request_id := [0]
	var dialogue_request_id := [0]
	var reentrant_dialogue_request_id := [0]
	var reentrant_enqueued := [false]
	var on_stage := func(_operations: Array, _force_cut: bool) -> void:
		var request_id := SignalBus.current_stage_operation_request_id()
		dispatches.append("stage:%s" % request_id)
		if request_id != stage_request_id[0] or reentrant_enqueued[0]:
			return
		reentrant_enqueued[0] = true
		reentrant_dialogue_request_id[0] = SignalBus.emit_dialogue_visibility_operations([{
			"target": "surface",
			"action": "show",
			"transition": "cut",
			"duration": 0.0,
		}])
	var on_dialogue := func(_operations: Array, _force_cut: bool) -> void:
		dispatches.append("dialogue:%s" % SignalBus.current_dialogue_visibility_request_id())
	var on_stage_tail := func(request_id: int, delivered: bool) -> void:
		stage_finishes.append("%s:%s" % [request_id, delivered])
	var on_generic_tail := func(request_id: int, delivered: bool) -> void:
		generic_finishes.append("%s:%s" % [request_id, delivered])
	SignalBus.stage_operations_requested.connect(on_stage)
	var visibility_signal: Variant = _signal_by_name(
		&"dialogue_visibility_operations_requested")
	var generic_tail_signal: Variant = _signal_by_name(
		&"presentation_operation_request_finished")
	if visibility_signal is Signal:
		(visibility_signal as Signal).connect(on_dialogue)
	SignalBus.stage_operation_request_finished.connect(on_stage_tail)
	if generic_tail_signal is Signal:
		(generic_tail_signal as Signal).connect(on_generic_tail)
	SignalBus.run_presentation_projection(func() -> void:
		stale_mixed_request_id[0] = SignalBus.emit_presentation_operations(
			[{
				"action": "show",
				"id": "stale",
				"properties": {"asset": "stage:redraw_source"},
				"transition": "cut",
				"duration": 0.0,
			}],
			[{
				"target": "surface",
				"action": "hide",
				"transition": "cut",
				"duration": 0.0,
			}],
			false,
		)
		SignalBus.reset_dialogue_visibility_visuals()
		mixed_request_id[0] = SignalBus.emit_presentation_operations(
			[{
				"action": "show",
				"id": "mixed",
				"properties": {"asset": "stage:redraw_source"},
				"transition": "cut",
				"duration": 0.0,
			}],
			[{
				"target": "quick_menu",
				"action": "hide",
				"transition": "cut",
				"duration": 0.0,
			}],
			false,
		)
		stage_request_id[0] = SignalBus.emit_stage_operations([{
			"action": "show",
			"id": "stage_only",
			"properties": {"asset": "stage:redraw_source"},
			"transition": "cut",
			"duration": 0.0,
		}])
		dialogue_request_id[0] = SignalBus.emit_dialogue_visibility_operations([{
			"target": "surface",
			"action": "hide",
			"transition": "cut",
			"duration": 0.0,
		}])
		assert_eq(dispatches, [],
			"generic projection body keeps all queue-backed presentation dispatch deferred")
		assert_eq(stage_finishes, [],
			"stage-only request tails are deferred until the outermost projection exits")
		assert_eq(generic_finishes, [],
			"mixed/dialogue request tails are deferred until the outermost projection exits")
	)
	assert_eq(dispatches, [
		"stage:%s" % stale_mixed_request_id[0],
		"stage:%s" % mixed_request_id[0],
		"dialogue:%s" % mixed_request_id[0],
		"stage:%s" % stage_request_id[0],
		"dialogue:%s" % dialogue_request_id[0],
		"dialogue:%s" % reentrant_dialogue_request_id[0],
	], "outer unified drain preserves enqueue order, skips stale mixed dialogue halves, and appends reentrant work by serial")
	assert_eq(stage_finishes, [
		"%s:true" % stage_request_id[0],
	], "stage-only queue keeps exact-once terminal delivery")
	assert_eq(generic_finishes, [
		"%s:false" % stale_mixed_request_id[0],
		"%s:true" % mixed_request_id[0],
		"%s:true" % dialogue_request_id[0],
		"%s:true" % reentrant_dialogue_request_id[0],
	], "generic queue preserves stale mixed fail-close and keeps transaction-era entries alive")
	SignalBus.stage_operations_requested.disconnect(on_stage)
	if visibility_signal is Signal:
		(visibility_signal as Signal).disconnect(on_dialogue)
	SignalBus.stage_operation_request_finished.disconnect(on_stage_tail)
	if generic_tail_signal is Signal:
		(generic_tail_signal as Signal).disconnect(on_generic_tail)
