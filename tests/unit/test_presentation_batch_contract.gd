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
