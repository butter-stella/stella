extends GutTest


class Participant extends Node:
	pass


func _operation(line: int = 7) -> StagePresentationOperation:
	return StagePresentationOperation.new({
		"action": "show",
		"id": "hero",
		"properties": {"asset": "stage:hero"},
		"transition": "mosaic",
		"transition_params": {"cell": 32},
		"duration": 0.5,
	}, {"source_path": "res://synthetic/request.stla", "line": line})


func test_stage_request_snapshots_plan_and_requires_readiness_before_apply_quorum():
	var authority := RefCounted.new()
	var participant := Participant.new()
	add_child_autoqfree(participant)
	var capability := RefCounted.new()
	var current := {participant.get_instance_id(): capability}
	var validator := func(candidate: Object, candidate_capability: Object) -> bool:
		return (
			candidate != null
			and current.get(candidate.get_instance_id()) == candidate_capability)
	var request := StageOperationRequest.new([_operation()], false)
	assert_true(request._bind_authority(authority, validator))
	assert_true(request._snapshot_presenter(participant, capability, authority))
	var plan := {"operation_plans": [{"kind": "mosaic", "cell": 32}]}
	assert_true(request._validate(participant, plan, authority))
	plan["operation_plans"][0]["cell"] = 64
	assert_eq(request.get_plan(participant)["operation_plans"][0]["cell"], 32)
	assert_true(request._seal_validation(41, authority))
	assert_false(request.all_presenters_accepted())
	assert_true(request._accept(participant, authority))
	assert_true(request.all_presenters_accepted())
	assert_false(request.all_presenters_apply_ready())
	assert_false(request.all_presenters_applied())
	assert_false(request._apply(participant, authority))
	assert_true(request._mark_apply_ready(participant, authority))
	assert_true(request.all_presenters_apply_ready())
	assert_false(request.all_presenters_apply_claimed())
	assert_false(request._apply(participant, authority))
	assert_true(request._mark_apply_claimed(participant, authority))
	assert_true(request.all_presenters_apply_claimed())
	assert_true(request._apply(participant, authority))
	assert_true(request.all_presenters_applied())
	request._finish(true, false, authority)
	assert_true(request.is_finished())
	assert_true(request.was_successful())


func test_stage_request_rejection_keeps_exact_operation_source():
	var authority := RefCounted.new()
	var request := StageOperationRequest.new([_operation(19)], false)
	assert_true(request._bind_authority(authority, func(_p, _c): return true))
	assert_true(request._reject(0, "mask is unavailable", authority))
	assert_false(request._seal_validation(9, authority))
	var errors := request.get_validation_errors()
	assert_eq(errors.size(), 1)
	assert_eq(errors[0]["source"]["source_path"], "res://synthetic/request.stla")
	assert_eq(errors[0]["source"]["line"], 19)
	assert_eq(errors[0]["error"], "mask is unavailable")


func test_stage_request_apply_failure_is_source_located_and_single_shot() -> void:
	var authority := RefCounted.new()
	var participant := Participant.new()
	add_child_autoqfree(participant)
	var capability := RefCounted.new()
	var request := StageOperationRequest.new([_operation(23)], false)
	assert_true(request._bind_authority(
		authority, func(candidate: Object, _capability: Object) -> bool:
			return candidate == participant))
	assert_true(request._snapshot_presenter(participant, capability, authority))
	assert_true(request._validate(participant, {}, authority))
	assert_true(request._seal_validation(11, authority))
	assert_true(request._accept(participant, authority))
	assert_true(request._fail_apply(
		participant, 0, "sealed material is unavailable", authority))
	assert_false(request._fail_apply(
		participant, 0, "duplicate", authority))
	assert_false(request.all_presenters_apply_ready())
	assert_false(request._mark_apply_ready(participant, authority))
	assert_false(request._apply(participant, authority))
	var errors := request.get_validation_errors()
	assert_eq(errors.size(), 1)
	assert_eq(errors[0]["source"]["line"], 23)
	assert_eq(errors[0]["error"], "sealed material is unavailable")


func test_stage_request_zero_participant_seal_fails_at_operation_source() -> void:
	var authority := RefCounted.new()
	var request := StageOperationRequest.new([_operation(29)], false)
	assert_true(request._bind_authority(authority, func(_p, _c): return true))
	assert_false(request._seal_validation(12, authority))
	var errors := request.get_validation_errors()
	assert_eq(errors.size(), 1)
	assert_eq(errors[0]["source"]["line"], 29)
	assert_string_contains(errors[0]["error"], "StagePresenter")


func test_stage_request_rejects_stale_capability_after_snapshot():
	var authority := RefCounted.new()
	var participant := Participant.new()
	add_child_autoqfree(participant)
	var capability := RefCounted.new()
	var current_capability: Array[Object] = [capability]
	var request := StageOperationRequest.new([_operation()], false)
	assert_true(request._bind_authority(
		authority,
		func(candidate: Object, candidate_capability: Object) -> bool:
			return (
				candidate == participant
				and candidate_capability == current_capability[0]),
	))
	assert_true(request._snapshot_presenter(participant, capability, authority))
	assert_true(request._validate(participant, {}, authority))
	current_capability[0] = RefCounted.new()
	assert_false(request._seal_validation(3, authority))
	assert_false(request.presenters_are_live())


func test_stage_request_getters_are_defensive():
	var operation := _operation()
	var request := StageOperationRequest.new([operation], true)
	var operations := request.get_operations()
	operations.clear()
	var payloads := request.get_payloads()
	payloads[0]["id"] = "mutated"
	assert_eq(request.get_operations().size(), 1)
	assert_eq(request.get_payloads()[0]["id"], "hero")
	assert_true(request.get_force_cut())
