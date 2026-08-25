extends GutTest
## Focused ownership regressions kept outside the frozen public #170 package.
##
## These tests intentionally exercise internal capability and dispatch seams
## whose observable contract is otherwise covered by the public synthetic
## suite. They protect same-object capability rotation and two synchronous
## signal-tail races that require real built-in presenters.


const RuntimeTestSupport = preload("res://tests/helpers/runtime_test_support.gd")
const ChapterIndicatorRequest = preload(
	"res://addons/stella/core/data/chapter_indicator_request.gd")
const ChapterIndicatorPresenterScript = preload(
	"res://addons/stella/presentation/ui/chapter_indicator_presenter.gd")
const TRANSITION_PATH := (
	"res://tests/fixtures/scenarios/chapter_indicator/transition.stla")
const MIDFADE_PATH := (
	"res://tests/fixtures/scenarios/chapter_indicator/midfade.stla")
const CONFIGURED_TITLE_PROBE := "res://addons/stella/scenes/game.tscn"

var _runtime: Node
var _dialogue_requests: Array[DialogueRequest] = []
var _owned_nodes: Array[Node] = []


func before_each() -> void:
	_runtime = get_tree().root.get_node("StellaRuntime")
	_runtime._navigation_scene_change_override = Callable()
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	_dialogue_requests.clear()
	_owned_nodes.clear()


func after_each() -> void:
	_runtime._navigation_scene_change_override = Callable()
	await RuntimeTestSupport.reset_for_test(_runtime, get_tree())
	await _release_owned_nodes()
	_dialogue_requests.clear()


func _add_owned_node(node: Node) -> void:
	_owned_nodes.append(node)
	add_child_autoqfree(node)


func _release_owned_nodes() -> void:
	for node: Node in _owned_nodes:
		if not is_instance_valid(node):
			continue
		if node.is_inside_tree():
			var exited: Signal = node.tree_exited
			if not node.is_queued_for_deletion():
				node.queue_free()
			await exited
		elif is_instance_valid(node):
			node.free()
	_owned_nodes.clear()
	await get_tree().process_frame


func _wait_until(predicate: Callable, max_frames: int = 120) -> bool:
	for _frame in range(max_frames):
		if bool(predicate.call()):
			return true
		await get_tree().process_frame
	return bool(predicate.call())


func _record_navigation_scene_receipt(
	serial: int,
	label: String,
	results: Array[Dictionary],
) -> void:
	var succeeded: bool = await _runtime._await_navigation_scene_receipt(serial)
	results.append({"label": label, "success": succeeded})


func _record_receipt_then_open_next(
	serial: int,
	results: Array[Dictionary],
	next_serial: Array[int],
) -> void:
	var succeeded: bool = await _runtime._await_navigation_scene_receipt(serial)
	results.append({"label": "reentrant", "success": succeeded})
	next_serial[0] = _runtime._open_navigation_scene_slot(
		17301,
		"res://synthetic_reentrant_receipt.tscn",
	)


func _make_presenter(name: String) -> Control:
	var presenter := Control.new()
	presenter.name = name
	presenter.set_script(ChapterIndicatorPresenterScript)
	var label := Label.new()
	label.name = "Title"
	presenter.add_child(label)
	presenter.set("title_label_path", NodePath("Title"))
	_add_owned_node(presenter)
	return presenter


func test_rotated_capability_cannot_ack_an_old_request_snapshot() -> void:
	var presenter := Node.new()
	_add_owned_node(presenter)
	var authority := RefCounted.new()
	var old_capability := RefCounted.new()
	var new_capability := RefCounted.new()
	var request := ChapterIndicatorRequest.new(
		true, "fade", 1.0, {"path": "synthetic", "line": 1})
	var is_current := func(candidate: Object, capability: Object) -> bool:
		return (
			candidate == presenter
			and capability in [old_capability, new_capability]
		)

	assert_true(request._bind_authority(authority, is_current))
	assert_true(request._snapshot_presenter(
		presenter, old_capability, authority))
	assert_true(request._validate(presenter, authority))
	assert_true(request._seal_validation(170, authority))
	assert_true(request._accept(presenter, authority))
	assert_true(request._has_accepted_identity(
		presenter, old_capability, authority))
	assert_false(request._has_accepted_identity(
		presenter, new_capability, authority),
		"the request-scoped capability is part of the exact ack identity")


func test_run_suspension_token_is_single_use_compare_and_swap() -> void:
	var engine := ScenarioEngine.new()
	engine.load_scenario(_build_wait_then_dialogue_scenario())
	var retained_context := engine.context
	var suspension := engine.suspend_current_run()
	assert_not_null(suspension)
	assert_true(engine.resume_suspended_run(suspension))
	assert_false(engine.resume_suspended_run(suspension),
		"one suspension capability can resume at most once")

	var invalidated := engine.suspend_current_run()
	engine.invalidate_current_run()
	assert_false(engine.resume_suspended_run(invalidated),
		"a nested run-generation mutation defeats the suspension CAS")
	assert_same(engine.context, retained_context)


func test_nested_deferred_failure_transfers_and_resumes_the_base_waiter() -> void:
	var requests: Array[DialogueRequest] = []
	var on_dialogue := func(request: DialogueRequest) -> void:
		requests.append(request)
	SignalBus.dialogue_requested.connect(on_dialogue)
	_runtime.engine.load_scenario(_build_wait_then_dialogue_scenario())
	var retained_context: ScenarioContext = _runtime.engine.context
	_runtime.engine.run()
	var nested_observation := [{}]
	var inside_reset := [false]
	var on_reset := func(_epoch: int) -> void:
		if inside_reset[0]:
			return
		inside_reset[0] = true
		var base_suspension = _runtime._navigation_run_suspension
		var nested_navigation: int = _runtime._begin_navigation(
			"nested_deferred_failure", true)
		nested_observation[0] = {
			"transferred": (
				_runtime._navigation_run_suspension == base_suspension),
			"generation": nested_navigation,
		}
		# Model a fully preflighted deferred destination that fails before it
		# submits a SceneTree request (for example, unavailable title fallback).
		_runtime._finish_navigation(nested_navigation)
		inside_reset[0] = false
	SignalBus.chapter_indicator_reset_requested.connect(on_reset)

	var outer_navigation: int = _runtime._begin_navigation(
		"outer_deferred", true)
	assert_false(_runtime._acquire_navigation_runtime_ownership(
		outer_navigation, true, true),
		"the nested navigation supersedes the outer reset owner")
	SignalBus.chapter_indicator_reset_requested.disconnect(on_reset)
	assert_true(bool(nested_observation[0].get("transferred", false)),
		"nested deferred ownership adopts the original opaque suspension")
	assert_same(_runtime.engine.context, retained_context)
	assert_eq(retained_context.current_command_index, 0)

	SignalBus.emit_advance_requested()
	assert_true(await _wait_until(func() -> bool: return requests.size() == 1),
		"the rejected nested navigation resumes the original click waiter")
	assert_eq(retained_context.current_command_index, 1)
	_runtime.engine.cancel_current_run()
	SignalBus.dialogue_requested.disconnect(on_dialogue)


func test_pre_scene_handoff_reset_makes_presenter_exit_inert() -> void:
	var presenter := _make_presenter("SceneOwnedTransitionSkin")
	await get_tree().process_frame
	var requests: Array[DialogueRequest] = []
	var on_dialogue := func(request: DialogueRequest) -> void:
		requests.append(request)
	SignalBus.dialogue_requested.connect(on_dialogue)
	_runtime.start_scenario(MIDFADE_PATH)
	assert_true(await _wait_until(
		func() -> bool:
			return (
				presenter.get("_active_request_id") != 0
				and bool(_runtime.call("is_chapter_indicator_visible"))
			),
	))
	var retained_context: ScenarioContext = _runtime.engine.context
	var navigation: int = _runtime._begin_navigation(
		"accepted_scene_handoff_probe", true)
	assert_true(_runtime._acquire_navigation_runtime_ownership(
		navigation, true, true))
	# This is the synchronous _exit_tree edge of change_scene_to_packed(). The
	# request was already cancelled and the run already lost its generation.
	presenter.free()
	assert_eq(retained_context.current_command_index, 0)
	assert_eq(retained_context.variable_store.get_var(
		"retired_transition_tail_ran"), null)
	assert_eq(requests.size(), 0,
		"scene-owned Presenter exit cannot dispatch the following dialogue")
	_runtime._discard_navigation_run_suspension(navigation)
	_runtime.engine.cancel_current_run()
	_runtime._finish_navigation(navigation)
	SignalBus.dialogue_requested.disconnect(on_dialogue)


func test_nested_deferred_failure_fresh_runs_a_cancelled_indicator_cursor() -> void:
	var presenter := _make_presenter("NestedRecoveryTransitionSkin")
	await get_tree().process_frame
	var requests: Array[DialogueRequest] = []
	var on_dialogue := func(request: DialogueRequest) -> void:
		requests.append(request)
	SignalBus.dialogue_requested.connect(on_dialogue)
	_runtime.start_scenario(MIDFADE_PATH)
	assert_true(await _wait_until(
		func() -> bool:
			return (
				presenter.get("_active_request_id") != 0
				and bool(_runtime.call("is_chapter_indicator_visible"))
			),
	))
	var retained_context: ScenarioContext = _runtime.engine.context
	var nested_observation := [{}]
	var inside_reset := [false]
	var on_reset := func(_epoch: int) -> void:
		if inside_reset[0]:
			return
		inside_reset[0] = true
		var base_suspension = _runtime._navigation_run_suspension
		var nested_navigation: int = _runtime._begin_navigation(
			"nested_indicator_failure", true)
		nested_observation[0] = {
			"transferred": (
				_runtime._navigation_run_suspension == base_suspension),
			"cancelled_waiter": (
				_runtime._navigation_blocking_presentation_waiter_cancelled),
		}
		_runtime._finish_navigation(nested_navigation)
		inside_reset[0] = false
	SignalBus.chapter_indicator_reset_requested.connect(on_reset)

	var outer_navigation: int = _runtime._begin_navigation(
		"outer_indicator_navigation", true)
	assert_false(_runtime._acquire_navigation_runtime_ownership(
		outer_navigation, true, true))
	SignalBus.chapter_indicator_reset_requested.disconnect(on_reset)
	assert_true(bool(nested_observation[0].get("transferred", false)))
	assert_true(bool(nested_observation[0].get("cancelled_waiter", false)),
		"the sticky pre-emit flag reaches the nested recovery owner")
	assert_same(_runtime.engine.context, retained_context)
	assert_true(await _wait_until(func() -> bool: return requests.size() == 1),
		"a cancelled indicator waiter is freshly dispatched at the same cursor")
	assert_eq(retained_context.variable_store.get_var(
		"retired_transition_tail_ran"), "true",
		"the fresh no-op transition, not the stale coroutine, reaches the sentinel")
	assert_true(requests[0].get_activation().is_pending())
	_runtime.engine.cancel_current_run()
	SignalBus.dialogue_requested.disconnect(on_dialogue)


func test_accepted_slot_waits_for_exact_scene_changed_before_fresh_run() -> void:
	var requests: Array[DialogueRequest] = []
	var on_dialogue := func(request: DialogueRequest) -> void:
		requests.append(request)
	SignalBus.dialogue_requested.connect(on_dialogue)
	_runtime.engine.load_scenario(_build_wait_then_dialogue_scenario())
	var retained_context: ScenarioContext = _runtime.engine.context
	_runtime.engine.run()

	var first_navigation: int = _runtime._begin_navigation(
		"accepted_receipt_owner", true)
	assert_true(_runtime._acquire_navigation_runtime_ownership(
		first_navigation, true, true))
	var slot_serial: int = _runtime._open_navigation_scene_slot(
		first_navigation, "res://synthetic_destination_ready.tscn")
	assert_gt(slot_serial, 0)
	assert_true(_runtime._accept_navigation_scene_slot(slot_serial))
	assert_false(retained_context.is_runtime_owner_current(),
		"an accepted handoff keeps the retained execution session retired")

	var latest_navigation: int = _runtime._begin_navigation(
		"latest_failure_during_destination_ready", true)
	_runtime._finish_navigation(latest_navigation)
	await get_tree().process_frame
	assert_eq(requests.size(), 0,
		"matching current_scene path cannot settle an accepted slot before signal")
	assert_eq(_runtime._navigation_scene_slot_active_serial, slot_serial)

	# Model only the central observer's raw scene_changed callback. It marks the
	# exact receipt settled before waking latest recovery, which fresh-dispatches
	# the same click command in the destination scene.
	_runtime._on_navigation_scene_changed()
	assert_eq(_runtime._navigation_scene_slot_active_serial, 0)
	assert_true(retained_context.is_runtime_owner_current())
	assert_eq(retained_context.current_command_index, 0)
	SignalBus.emit_advance_requested()
	assert_true(await _wait_until(func() -> bool: return requests.size() == 1))
	assert_eq(retained_context.current_command_index, 1)
	_runtime.engine.cancel_current_run()
	SignalBus.dialogue_requested.disconnect(on_dialogue)


func test_three_settled_scene_receipts_leave_no_retained_result_state() -> void:
	_runtime._navigation_scene_slot_results.clear()
	var serials: Array[int] = []
	for index in range(3):
		var serial: int = _runtime._open_navigation_scene_slot(
			17000 + index,
			"res://synthetic_receipt_%d.tscn" % index,
		)
		assert_gt(serial, 0)
		serials.append(serial)
		assert_true(_runtime._abort_navigation_scene_slot(serial))
		assert_false(await _runtime._await_navigation_scene_receipt(serial))

	for serial: int in serials:
		assert_false(_runtime._navigation_scene_slot_results.has(serial),
			"a fully awaited receipt cannot retain its serial forever")
	assert_true(_runtime._navigation_scene_slot_results.is_empty(),
		"serial receipt bookkeeping must stay bounded across navigation")


func test_shared_scene_receipt_wakes_every_waiter_before_cleanup() -> void:
	_runtime._navigation_scene_slot_results.clear()
	var serial: int = _runtime._open_navigation_scene_slot(
		17100,
		"res://synthetic_shared_receipt.tscn",
	)
	assert_gt(serial, 0)
	if serial <= 0:
		return
	var results: Array[Dictionary] = []
	_record_navigation_scene_receipt(serial, "creator", results)
	_record_navigation_scene_receipt(serial, "superseder", results)
	assert_eq(results.size(), 0,
		"both consumers must wait for the exact unsettled receipt")
	assert_true(_runtime._abort_navigation_scene_slot(serial))
	assert_true(await _wait_until(func() -> bool: return results.size() == 2),
		"cleanup cannot erase the receipt before every registered waiter wakes")
	results.sort_custom(
		func(left: Dictionary, right: Dictionary) -> bool:
			return String(left["label"]) < String(right["label"])
	)
	assert_eq(results, [
		{"label": "creator", "success": false},
		{"label": "superseder", "success": false},
	])
	await get_tree().process_frame
	assert_false(_runtime._navigation_scene_slot_results.has(serial),
		"the last waiter releases the exact settled receipt")


func test_unknown_and_expired_scene_receipts_fail_without_stranding() -> void:
	_runtime._navigation_scene_slot_results.clear()
	var unknown_serial: int = (
		int(_runtime._navigation_scene_slot_serial_counter) + 1000)
	var results: Array[Dictionary] = []
	_record_navigation_scene_receipt(unknown_serial, "unknown", results)
	assert_true(await _wait_until(func() -> bool: return results.size() == 1, 2),
		"an unknown serial must fail instead of becoming an unowned waiter")
	if results.is_empty():
		# Release the intentionally exposed legacy waiter so the red test cannot
		# leak a coroutine into later cases.
		_runtime._navigation_scene_slot_results[unknown_serial] = false
		_runtime._navigation_scene_slot_settled.emit()
		await get_tree().process_frame
	_runtime._navigation_scene_slot_results.erase(unknown_serial)
	assert_eq(results, [{"label": "unknown", "success": false}])

	var serial: int = _runtime._open_navigation_scene_slot(
		17200,
		"res://synthetic_expired_receipt.tscn",
	)
	assert_gt(serial, 0)
	assert_true(_runtime._abort_navigation_scene_slot(serial))
	assert_false(await _runtime._await_navigation_scene_receipt(serial))
	await get_tree().process_frame
	assert_false(_runtime._navigation_scene_slot_results.has(serial))
	results.clear()
	_record_navigation_scene_receipt(serial, "expired", results)
	assert_true(await _wait_until(func() -> bool: return results.size() == 1, 2),
		"a consumed serial must fail instead of reopening a waiter")
	if results.is_empty():
		_runtime._navigation_scene_slot_results[serial] = false
		_runtime._navigation_scene_slot_settled.emit()
		await get_tree().process_frame
	_runtime._navigation_scene_slot_results.erase(serial)
	assert_eq(results, [{"label": "expired", "success": false}])


func test_successful_receipt_can_settle_before_its_creator_reads_once() -> void:
	_runtime._navigation_scene_slot_results.clear()
	var serial: int = _runtime._open_navigation_scene_slot(
		17300,
		"res://synthetic_successful_receipt.tscn",
	)
	assert_gt(serial, 0)
	if serial <= 0:
		return
	_runtime._settle_navigation_scene_slot(serial, true)
	assert_true(_runtime._navigation_scene_slot_results.has(serial),
		"settlement retains the unique creator reservation until its late read")
	assert_true(await _runtime._await_navigation_scene_receipt(serial, true))
	assert_false(_runtime._navigation_scene_slot_results.has(serial),
		"the creator's exact read releases the last settled reservation")
	assert_false(await _runtime._await_navigation_scene_receipt(serial, true),
		"the consumed creator reservation cannot reopen an expired result")


func test_old_receipt_cleanup_cannot_erase_a_reentrant_new_serial() -> void:
	_runtime._navigation_scene_slot_results.clear()
	var old_serial: int = _runtime._open_navigation_scene_slot(
		17300,
		"res://synthetic_old_receipt.tscn",
	)
	assert_gt(old_serial, 0)
	if old_serial <= 0:
		return
	var results: Array[Dictionary] = []
	var next_serial: Array[int] = [0]
	_record_receipt_then_open_next(old_serial, results, next_serial)
	_record_navigation_scene_receipt(old_serial, "other", results)
	assert_true(_runtime._abort_navigation_scene_slot(old_serial))
	assert_true(await _wait_until(func() -> bool: return results.size() == 2))
	assert_gt(next_serial[0], old_serial,
		"a waiter may synchronously reserve the next exact scene slot")
	assert_false(_runtime._navigation_scene_slot_results.has(old_serial),
		"all old consumers release only the old settled record")
	assert_true(_runtime._navigation_scene_slot_results.has(next_serial[0]),
		"old cleanup cannot erase the reentrantly opened serial")
	results.sort_custom(
		func(left: Dictionary, right: Dictionary) -> bool:
			return String(left["label"]) < String(right["label"])
	)
	assert_eq(results, [
		{"label": "other", "success": false},
		{"label": "reentrant", "success": false},
	])
	assert_true(_runtime._abort_navigation_scene_slot(next_serial[0]))
	assert_true(_runtime._navigation_scene_slot_results.is_empty())


func test_rejected_candidate_retry_keeps_one_paused_execution_session() -> void:
	var requests: Array[DialogueRequest] = []
	var on_dialogue := func(request: DialogueRequest) -> void:
		requests.append(request)
	SignalBus.dialogue_requested.connect(on_dialogue)
	_runtime.engine.load_scenario(_build_wait_then_dialogue_scenario())
	var retained_context: ScenarioContext = _runtime.engine.context
	_runtime.engine.run()
	var navigation: int = _runtime._begin_navigation(
		"configured_then_builtin_title", true)
	assert_true(_runtime._acquire_navigation_runtime_ownership(
		navigation, true, true))
	var suspension = _runtime._navigation_run_suspension
	assert_not_null(suspension)

	var configured_serial: int = _runtime._open_navigation_scene_slot(
		navigation, "res://synthetic_configured_title.tscn")
	assert_true(_runtime._abort_navigation_scene_slot(configured_serial))
	assert_same(_runtime._navigation_run_suspension, suspension)
	assert_false(retained_context.is_runtime_owner_current())
	assert_eq(retained_context.current_command_index, 0)
	assert_eq(requests.size(), 0,
		"the first candidate rejection cannot resume or fresh-run between retries")

	var fallback_serial: int = _runtime._open_navigation_scene_slot(
		navigation, "res://synthetic_builtin_title.tscn")
	assert_true(_runtime._abort_navigation_scene_slot(fallback_serial))
	assert_same(_runtime._navigation_run_suspension, suspension)
	_runtime._finish_navigation(navigation)
	assert_true(retained_context.is_runtime_owner_current())
	SignalBus.emit_advance_requested()
	assert_true(await _wait_until(func() -> bool: return requests.size() == 1))
	assert_eq(retained_context.current_command_index, 1)
	_runtime.engine.cancel_current_run()
	SignalBus.dialogue_requested.disconnect(on_dialogue)


func test_finished_context_slot_failure_restores_cut_without_lifecycle_replay() -> void:
	var presenter := _make_presenter("FinishedContextSkin")
	await get_tree().process_frame
	var data := ScenarioData.new()
	data.id = "already_finished_context"
	var scene := SceneData.new()
	scene.id = "end"
	scene.chapter_id = "finished"
	var chapter := ChapterData.new()
	chapter.id = "finished"
	chapter.display_name = "Finished"
	chapter.scene_ids = ["end"]
	data.scenes = [scene]
	data.chapters = [chapter]
	_runtime.engine.load_scenario(data)
	var retained_context: ScenarioContext = _runtime.engine.context
	retained_context.is_finished = true
	retained_context.chapter_indicator_visible = true
	assert_true(_runtime._apply_chapter_presentation(retained_context))
	assert_true(presenter.visible)
	var started := [0]
	var ended := [0]
	var on_started := func(_id: String) -> void: started[0] += 1
	var on_ended := func(_id: String) -> void: ended[0] += 1
	_runtime.engine.scenario_started.connect(on_started)
	_runtime.engine.scenario_ended.connect(on_ended)

	var first_navigation: int = _runtime._begin_navigation(
		"finished_accepted_owner", true)
	assert_true(_runtime._acquire_navigation_runtime_ownership(
		first_navigation, true, true))
	assert_false(presenter.visible)
	var slot_serial: int = _runtime._open_navigation_scene_slot(
		first_navigation, "res://synthetic_finished_destination.tscn")
	assert_true(_runtime._accept_navigation_scene_slot(slot_serial))
	var latest_navigation: int = _runtime._begin_navigation(
		"finished_latest_failure", true)
	_runtime._finish_navigation(latest_navigation)
	_runtime._on_navigation_scene_changed()

	assert_true(presenter.visible,
		"finished retained state is restored as a cut after exact slot settlement")
	assert_eq(started[0], 0)
	assert_eq(ended[0], 0,
		"finished retained Context never re-emits scenario lifecycle")
	_runtime.engine.scenario_started.disconnect(on_started)
	_runtime.engine.scenario_ended.disconnect(on_ended)
	_runtime.engine.cancel_current_run()


func test_reset_replacement_retires_return_transaction_before_any_submit() -> void:
	_runtime.engine.load_scenario(_build_wait_then_dialogue_scenario())
	_runtime.engine.run()
	var fresh_context := [null]
	var on_reset := func(_epoch: int) -> void:
		fresh_context[0] = _install_fresh_wait_owner("reset_replacement")
	SignalBus.chapter_indicator_reset_requested.connect(
		on_reset, CONNECT_ONE_SHOT)
	var submissions := [0]
	_runtime._navigation_scene_change_override = func(_scene: PackedScene) -> int:
		submissions[0] += 1
		return ERR_CANT_CREATE
	_runtime.title_scene_path = CONFIGURED_TITLE_PROBE

	_runtime.return_to_title()
	assert_true(await _wait_until(
		func() -> bool: return fresh_context[0] != null))
	await get_tree().process_frame

	assert_eq(submissions[0], 0,
		"reset-time Context replacement prevents configured and fallback submits")
	assert_same(_runtime.engine.context, fresh_context[0])
	assert_eq(_runtime._navigation_kind, "")
	assert_false(_runtime._return_to_title_pending)
	_runtime.engine.cancel_current_run()


func test_retire_replacement_preserves_fresh_owner_and_suppresses_fallback() -> void:
	_runtime.engine.load_scenario(_build_wait_then_dialogue_scenario())
	var retained_context: ScenarioContext = _runtime.engine.context
	_runtime.engine.run()
	var fresh_context := [null]
	var on_session_retired := func() -> void:
		fresh_context[0] = _install_fresh_wait_owner("retire_replacement")
	retained_context.cancellation_requested.connect(
		on_session_retired, CONNECT_ONE_SHOT)
	var submissions := [0]
	_runtime._navigation_scene_change_override = func(_scene: PackedScene) -> int:
		submissions[0] += 1
		return OK
	_runtime.title_scene_path = CONFIGURED_TITLE_PROBE

	_runtime.return_to_title()
	assert_true(await _wait_until(
		func() -> bool: return fresh_context[0] != null))
	assert_eq(submissions[0], 1,
		"an accepted configured candidate is not retried as built-in fallback")
	assert_gt(_runtime._navigation_scene_slot_active_serial, 0,
		"the accepted SceneTree receipt remains central-observer owned")
	assert_same(_runtime.engine.context, fresh_context[0])
	assert_eq(_runtime._navigation_kind, "")
	assert_false(_runtime._return_to_title_pending)

	_runtime._on_navigation_scene_changed()
	await get_tree().process_frame
	assert_eq(submissions[0], 1)
	assert_same(_runtime.engine.context, fresh_context[0],
		"settling the old receipt cannot cancel the direct replacement")
	var probe_navigation: int = _runtime._begin_navigation(
		"post_replacement_probe", true)
	_runtime._finish_navigation(probe_navigation)
	assert_eq(_runtime._navigation_kind, "",
		"the anonymous retirement leaves later navigation usable")
	_runtime.engine.cancel_current_run()


func test_destination_ready_replacement_survives_receipt_tail() -> void:
	_runtime.engine.load_scenario(_build_wait_then_dialogue_scenario())
	_runtime.engine.run()
	var submissions := [0]
	_runtime._navigation_scene_change_override = func(_scene: PackedScene) -> int:
		submissions[0] += 1
		return OK
	_runtime.title_scene_path = CONFIGURED_TITLE_PROBE
	_runtime.return_to_title()
	assert_true(await _wait_until(
		func() -> bool:
			return (
				submissions[0] == 1
				and _runtime._navigation_scene_slot_accepted
			),
	))

	# This is the semantic portion of a destination root's _ready(): the new
	# scene installs and starts its own Context before raw scene_changed settles
	# the older receipt.
	var fresh_context := _install_fresh_wait_owner("destination_ready_owner")
	_runtime._on_navigation_scene_changed()
	await get_tree().process_frame

	assert_eq(submissions[0], 1,
		"receipt-time owner loss cannot fall through to built-in fallback")
	assert_same(_runtime.engine.context, fresh_context)
	assert_eq(_runtime._navigation_kind, "")
	assert_false(_runtime._return_to_title_pending)
	_runtime.engine.cancel_current_run()


func test_accepted_token_failure_retires_transaction_without_fallback() -> void:
	_runtime.engine.load_scenario(_build_wait_then_dialogue_scenario())
	var retained_context: ScenarioContext = _runtime.engine.context
	_runtime.engine.run()
	var submissions := [0]
	_runtime._navigation_scene_change_override = func(_scene: PackedScene) -> int:
		submissions[0] += 1
		# Defeat the exact suspension CAS while retaining the same Context. The
		# SceneTree request is nevertheless accepted, so this is an owner-loss
		# terminal rather than permission to try the built-in candidate.
		_runtime.engine.invalidate_current_run()
		return OK
	_runtime.title_scene_path = CONFIGURED_TITLE_PROBE

	_runtime.return_to_title()
	assert_true(await _wait_until(
		func() -> bool:
			return (
				submissions[0] == 1
				and _runtime._navigation_scene_slot_accepted
			),
	))
	assert_same(_runtime.engine.context, retained_context)
	assert_eq(_runtime._navigation_kind, "")
	assert_false(_runtime._return_to_title_pending)
	_runtime._on_navigation_scene_changed()
	await get_tree().process_frame
	assert_eq(submissions[0], 1,
		"an accepted token failure cannot become configured fallback")
	assert_same(_runtime.engine.context, retained_context)
	_runtime.engine.cancel_current_run()


func test_configured_reject_then_builtin_accept_is_one_atomic_navigation() -> void:
	var requests: Array[DialogueRequest] = []
	var on_dialogue := func(request: DialogueRequest) -> void:
		requests.append(request)
	SignalBus.dialogue_requested.connect(on_dialogue)
	_runtime.engine.load_scenario(_build_wait_then_dialogue_scenario())
	var retained_context: ScenarioContext = _runtime.engine.context
	_runtime.engine.run()
	_runtime.game_state.current_state = GameStateMachine.State.PLAYING
	var submissions := [0]
	var owner_during_fallback := [true]
	_runtime._navigation_scene_change_override = func(scene: PackedScene) -> int:
		submissions[0] += 1
		if submissions[0] == 1:
			return ERR_CANT_CREATE
		owner_during_fallback[0] = retained_context.is_runtime_owner_current()
		return get_tree().change_scene_to_packed(scene)
	_runtime.title_scene_path = CONFIGURED_TITLE_PROBE

	_runtime.return_to_title()
	assert_true(await _wait_until(
		func() -> bool:
			return (
				submissions[0] == 2
				and not _runtime._return_to_title_pending
			),
	))
	assert_push_error("failed to request the configured title scene")
	assert_push_error("falling back to the built-in title scene")

	assert_eq(submissions[0], 2)
	assert_false(owner_during_fallback[0],
		"the old execution stays paused across the configured candidate reject")
	assert_eq(requests.size(), 0,
		"no intermediate resume or fresh dispatch may run between candidates")
	assert_null(_runtime.engine.context)
	assert_eq(_runtime.game_state.current_state,
		GameStateMachine.State.TITLE)
	assert_eq(_runtime._navigation_kind, "")
	SignalBus.dialogue_requested.disconnect(on_dialogue)


func test_inherited_slot_owner_loss_blocks_the_second_scene_submit() -> void:
	_runtime.engine.load_scenario(_build_wait_then_dialogue_scenario())
	var retained_context: ScenarioContext = _runtime.engine.context
	_runtime.engine.run()
	var first_navigation: int = _runtime._begin_navigation(
		"first_accepted_owner", true)
	assert_true(_runtime._acquire_navigation_runtime_ownership(
		first_navigation, true, true))
	var first_slot: int = _runtime._open_navigation_scene_slot(
		first_navigation, "res://synthetic_first_destination.tscn")
	assert_true(_runtime._accept_navigation_scene_slot(first_slot))
	assert_false(retained_context.is_runtime_owner_current())

	var latest_navigation: int = _runtime._begin_navigation(
		"inherited_waiting_owner", true)
	var result := [true]
	var run_latest := func() -> void:
		result[0] = await _runtime._enter_scene_and_confirm(
			{
				"scene": load("res://addons/stella/scenes/title.tscn"),
				"path": "res://addons/stella/scenes/title.tscn",
			},
			latest_navigation,
			"inherited probe",
		)
	run_latest.call()
	await get_tree().process_frame
	var submissions := [0]
	_runtime._navigation_scene_change_override = func(_scene: PackedScene) -> int:
		submissions[0] += 1
		return ERR_CANT_CREATE
	var fresh_context := _install_fresh_wait_owner("inherited_ready_owner")
	_runtime._on_navigation_scene_changed()
	assert_true(await _wait_until(
		func() -> bool: return not _runtime._owns_navigation(latest_navigation)))

	assert_false(result[0])
	assert_eq(submissions[0], 0,
		"an inherited retired capability cannot adopt the replacement Context")
	assert_same(_runtime.engine.context, fresh_context)
	assert_eq(_runtime._navigation_kind, "")
	_runtime.engine.cancel_current_run()


func test_accepted_choice_backlog_restore_waits_for_new_scene_presenter() -> void:
	_runtime.game_state.current_state = GameStateMachine.State.PLAYING
	var old_game: Node = load("res://addons/stella/scenes/game.tscn").instantiate()
	_add_owned_node(old_game)
	await get_tree().process_frame
	var choice_shows := [0]
	var dialogue_requests: Array[DialogueRequest] = []
	var rollback_result := [false]
	var on_choice_show := func(_prompt: String, _options: Array) -> void:
		choice_shows[0] += 1
	var on_dialogue := func(request: DialogueRequest) -> void:
		dialogue_requests.append(request)
	SignalBus.choice_show.connect(on_choice_show)
	SignalBus.dialogue_requested.connect(on_dialogue)

	_runtime.engine.load_scenario(_build_choice_then_dialogue_scenario())
	var retained_context: ScenarioContext = _runtime.engine.context
	var snapshot: Dictionary = _runtime._capture_rollback_snapshot()
	(snapshot["scenario_context"] as Dictionary)["command_index"] = 1
	_runtime.backlog_manager.add_entry(
		"n",
		[],
		170,
		func() -> Dictionary: return snapshot.duplicate(true),
	)
	_runtime.engine.run()
	assert_true(await _wait_until(func() -> bool: return choice_shows[0] == 1))
	var on_choice_hide := func() -> void:
		rollback_result[0] = _runtime.jump_from_backlog(0)
	SignalBus.choice_hide.connect(on_choice_hide, CONNECT_ONE_SHOT)

	var navigation: int = _runtime._begin_navigation(
		"choice_scene_handoff", true)
	assert_true(_runtime._acquire_navigation_runtime_ownership(
		navigation, true, true))
	var slot_serial: int = _runtime._open_navigation_scene_slot(
		navigation, "res://synthetic_choice_destination.tscn")
	assert_true(_runtime._accept_navigation_scene_slot(slot_serial))
	assert_true(rollback_result[0],
		"choice-hide accepts the backlog facade synchronously")
	assert_same(_runtime.engine.context, retained_context)
	assert_eq(dialogue_requests.size(), 0,
		"rollback cannot publish SHOW into the outgoing scene")

	old_game.queue_free()
	await get_tree().process_frame
	var new_game: Node = load("res://addons/stella/scenes/game.tscn").instantiate()
	_add_owned_node(new_game)
	await get_tree().process_frame
	var new_dialogue: Control = new_game.get_node("UILayer/DialoguePanel")
	new_dialogue._char_interval = 0.0
	assert_eq(dialogue_requests.size(), 0,
		"the accepted backlog continuation still waits for exact scene_changed")

	_runtime._on_navigation_scene_changed()
	assert_true(await _wait_until(
		func() -> bool: return dialogue_requests.size() == 1))
	assert_ne(_runtime.engine.context, retained_context)
	assert_eq(_runtime.engine.context.current_command_index, 1)
	assert_true(dialogue_requests[0].get_activation().is_pending())
	assert_same(new_dialogue.get("_current_dialogue_activation"),
		dialogue_requests[0].get_activation(),
		"the destination Presenter, not the removed owner, accepts restored SHOW")

	_runtime.engine.cancel_current_run()
	SignalBus.choice_show.disconnect(on_choice_show)
	SignalBus.dialogue_requested.disconnect(on_dialogue)


func test_accepted_choice_rollback_superseded_by_latest_failure_recovers_once() -> void:
	_runtime.game_state.current_state = GameStateMachine.State.PLAYING
	var old_game: Node = load("res://addons/stella/scenes/game.tscn").instantiate()
	_add_owned_node(old_game)
	await get_tree().process_frame
	var choice_shows := [0]
	var dialogue_requests: Array[DialogueRequest] = []
	var scenario_starts := [0]
	var rollback_result := [false]
	var on_choice_show := func(_prompt: String, _options: Array) -> void:
		choice_shows[0] += 1
	var on_dialogue := func(request: DialogueRequest) -> void:
		dialogue_requests.append(request)
	var on_started := func(_scenario_id: String) -> void:
		scenario_starts[0] += 1
	SignalBus.choice_show.connect(on_choice_show)
	SignalBus.dialogue_requested.connect(on_dialogue)
	_runtime.engine.scenario_started.connect(on_started)

	_runtime.engine.load_scenario(_build_choice_then_dialogue_scenario())
	var retained_context: ScenarioContext = _runtime.engine.context
	var snapshot: Dictionary = _runtime._capture_rollback_snapshot()
	(snapshot["scenario_context"] as Dictionary)["command_index"] = 1
	_runtime.backlog_manager.add_entry(
		"n",
		[],
		171,
		func() -> Dictionary: return snapshot.duplicate(true),
	)
	_runtime.engine.run()
	assert_true(await _wait_until(func() -> bool: return choice_shows[0] == 1))
	var on_choice_hide := func() -> void:
		rollback_result[0] = _runtime.jump_from_backlog(0)
	SignalBus.choice_hide.connect(on_choice_hide, CONNECT_ONE_SHOT)

	var first_navigation: int = _runtime._begin_navigation(
		"accepted_choice_owner", true)
	assert_true(_runtime._acquire_navigation_runtime_ownership(
		first_navigation, true, true))
	var slot_serial: int = _runtime._open_navigation_scene_slot(
		first_navigation, "res://synthetic_choice_latest_destination.tscn")
	assert_true(_runtime._accept_navigation_scene_slot(slot_serial))
	assert_true(rollback_result[0])
	var latest_navigation: int = _runtime._begin_navigation(
		"latest_failure_after_rollback", true)
	_runtime._finish_navigation(latest_navigation)
	assert_eq(dialogue_requests.size(), 0)
	assert_eq(choice_shows[0], 1)

	old_game.queue_free()
	await get_tree().process_frame
	var new_game: Node = load("res://addons/stella/scenes/game.tscn").instantiate()
	_add_owned_node(new_game)
	await get_tree().process_frame
	_runtime._on_navigation_scene_changed()
	assert_true(await _wait_until(func() -> bool: return choice_shows[0] == 2))

	assert_same(_runtime.engine.context, retained_context,
		"the stale rollback tail cannot install its snapshot Context")
	assert_eq(retained_context.current_command_index, 0)
	assert_eq(scenario_starts[0], 2,
		"latest failure fresh-runs the retired Context exactly once")
	assert_eq(dialogue_requests.size(), 0)
	SignalBus.choice_selected.emit("old")
	assert_true(await _wait_until(
		func() -> bool: return dialogue_requests.size() == 1))
	assert_eq(retained_context.variable_store.get_var("selection_count"), 1,
		"the retired choice waiter cannot apply the fresh selection twice")
	assert_true(dialogue_requests[0].get_activation().is_pending())

	_runtime.engine.cancel_current_run()
	SignalBus.choice_show.disconnect(on_choice_show)
	SignalBus.dialogue_requested.disconnect(on_dialogue)
	_runtime.engine.scenario_started.disconnect(on_started)


func test_real_dialogue_scene_exit_cannot_poison_fresh_slot_recovery() -> void:
	_runtime.game_state.current_state = GameStateMachine.State.PLAYING
	var old_game: Node = load("res://addons/stella/scenes/game.tscn").instantiate()
	_add_owned_node(old_game)
	await get_tree().process_frame
	var old_dialogue: Control = old_game.get_node("UILayer/DialoguePanel")
	old_dialogue._char_interval = 0.02
	var requests: Array[DialogueRequest] = []
	var starts := [0]
	var on_dialogue := func(request: DialogueRequest) -> void:
		requests.append(request)
	var on_started := func(_scenario_id: String) -> void:
		starts[0] += 1
	SignalBus.dialogue_requested.connect(on_dialogue)
	_runtime.engine.scenario_started.connect(on_started)
	_runtime.engine.load_scenario(_build_two_dialogue_scenario())
	var retained_context: ScenarioContext = _runtime.engine.context
	_runtime.engine.run()
	assert_true(await _wait_until(func() -> bool: return requests.size() == 1))
	var old_activation: DialogueActivation = requests[0].get_activation()
	var old_dialogue_generation: int = int(old_dialogue.get("_dialogue_gen"))
	assert_true(old_activation.is_pending())

	var first_navigation: int = _runtime._begin_navigation(
		"real_dialogue_handoff", true)
	assert_true(_runtime._acquire_navigation_runtime_ownership(
		first_navigation, true, true))
	var slot_serial: int = _runtime._open_navigation_scene_slot(
		first_navigation, "res://synthetic_dialogue_destination.tscn")
	assert_true(_runtime._accept_navigation_scene_slot(slot_serial))
	assert_false(old_activation.is_pending())
	assert_false(retained_context.is_finished,
		"retiring the exact execution session makes Presenter abort tails inert")
	assert_eq(retained_context.current_command_index, 0)

	var latest_navigation: int = _runtime._begin_navigation(
		"real_dialogue_latest_failure", true)
	_runtime._finish_navigation(latest_navigation)
	var old_game_exited: Signal = old_game.tree_exited
	old_game.queue_free()
	await old_game_exited
	assert_gt(int(old_dialogue.get("_dialogue_gen")), old_dialogue_generation)
	assert_eq((old_dialogue.get("_dialogue_timer_waiters") as Dictionary).size(), 0)
	assert_eq((old_dialogue.get("_voice_event_waiters") as Dictionary).size(), 0)
	assert_eq((old_dialogue.get("_next_frame_waiters") as Dictionary).size(), 0)
	assert_eq((old_dialogue.get("_queued_dialogue_requests") as Array).size(), 0)
	assert_eq((old_dialogue.get("_deferred_lifecycle_boundary") as Dictionary).size(), 0)
	assert_false(retained_context.is_finished)
	assert_eq(retained_context.current_command_index, 0)
	var new_game: Node = load("res://addons/stella/scenes/game.tscn").instantiate()
	_add_owned_node(new_game)
	await get_tree().process_frame
	var new_dialogue: Control = new_game.get_node("UILayer/DialoguePanel")
	new_dialogue._char_interval = 0.0
	_runtime._on_navigation_scene_changed()
	assert_true(await _wait_until(func() -> bool: return requests.size() == 2))

	assert_same(_runtime.engine.context, retained_context)
	assert_false(retained_context.is_finished)
	assert_eq(retained_context.current_command_index, 0)
	assert_eq(starts[0], 2,
		"the retired dialogue cursor is freshly dispatched exactly once")
	assert_true(requests[1].get_activation().is_pending())
	assert_same(new_dialogue.get("_current_dialogue_activation"),
		requests[1].get_activation())
	var replacement_activation: DialogueActivation = requests[1].get_activation()
	_runtime.engine.cancel_current_run()
	SignalBus.hide_dialogue.emit()
	assert_false(replacement_activation.is_pending())
	assert_null(new_dialogue.get("_current_dialogue_activation"))
	assert_false(new_dialogue.get("_is_typing"))
	assert_true((new_dialogue.get("_next_frame_waiters") as Dictionary).is_empty(),
		"hard hide synchronously retires the accepted SHOW frame authority")
	requests.clear()
	old_activation = null
	replacement_activation = null
	SignalBus.dialogue_requested.disconnect(on_dialogue)
	_runtime.engine.scenario_started.disconnect(on_started)


func test_begin_navigation_cancellation_reentry_keeps_nested_generation_latest() -> void:
	_runtime.engine.load_scenario(_build_wait_then_dialogue_scenario())
	_runtime.engine.run()
	var paused_navigation: int = _runtime._begin_navigation(
		"paused_pre_submit", true)
	assert_true(_runtime._acquire_navigation_runtime_ownership(
		paused_navigation, false, true))
	var nested_navigation := [0]
	var on_session_retired := func() -> void:
		nested_navigation[0] = _runtime._begin_navigation(
			"nested_latest_from_session_retire", true)
	_runtime.engine.context.cancellation_requested.connect(
		on_session_retired, CONNECT_ONE_SHOT)

	var stale_outer: int = _runtime._begin_navigation(
		"outer_discarding_owner", false)
	assert_gt(nested_navigation[0], stale_outer)
	assert_eq(_runtime._navigation_generation, nested_navigation[0])
	assert_eq(_runtime._navigation_kind,
		"nested_latest_from_session_retire")
	assert_eq(_runtime._navigation_run_suspension_generation,
		nested_navigation[0],
		"the stale discard tail cannot erase the nested capability record")
	_runtime._finish_navigation(nested_navigation[0])
	_runtime.engine.cancel_current_run()


func test_resumable_recovery_restores_owner_before_metadata_callback_advance() -> void:
	var requests: Array[DialogueRequest] = []
	var on_dialogue := func(request: DialogueRequest) -> void:
		requests.append(request)
	SignalBus.dialogue_requested.connect(on_dialogue)
	_runtime.engine.load_scenario(_build_wait_then_dialogue_scenario())
	var retained_context: ScenarioContext = _runtime.engine.context
	_runtime.engine.run()
	var navigation: int = _runtime._begin_navigation(
		"sync_rejection_resume_order", true)
	assert_true(_runtime._acquire_navigation_runtime_ownership(
		navigation, true, true))
	var advanced := [false]
	var on_metadata := func(_chapter_id: String, _title: String) -> void:
		if advanced[0]:
			return
		advanced[0] = true
		SignalBus.emit_advance_requested()
	SignalBus.current_chapter_changed.connect(on_metadata)

	_runtime._finish_navigation(navigation)
	SignalBus.current_chapter_changed.disconnect(on_metadata)
	assert_true(advanced[0])
	assert_true(await _wait_until(func() -> bool: return requests.size() == 1))
	assert_eq(retained_context.current_command_index, 1)
	assert_eq(_runtime._navigation_kind, "",
		"legitimate same-owner cursor progress finishes recovery without error")
	_runtime.engine.cancel_current_run()
	SignalBus.dialogue_requested.disconnect(on_dialogue)


func test_reentrant_cut_projection_cannot_be_overwritten_by_old_fade_tail() -> void:
	var presenter := _make_presenter("ReentrantFadeSkin")
	await get_tree().process_frame
	assert_true(SignalBus.emit_current_chapter_changed(
		"fresh", "Fresh", func() -> bool: return true))
	var reentered := [false]
	var on_visibility_changed := func() -> void:
		if presenter.visible and not reentered[0]:
			reentered[0] = true
			SignalBus.apply_chapter_indicator_state(true)
	presenter.visibility_changed.connect(on_visibility_changed)

	var data := DslParser.parse(DslLexer.tokenize(
		"@chapter fresh \"Fresh\"\n@scene start\n"
		+ "@chapter_indicator show transition=fade duration=5.0\n"),
		"synthetic_reentrant_fade", "synthetic_reentrant_fade.stla")
	var context := ScenarioContext.new(data)
	var handler: Variant = _runtime.registry.get_handler("presentation_batch")
	await handler.execute(data.scenes[0].commands[0], context)

	assert_true(reentered[0])
	assert_true(context.is_finished,
		"the fresh cut projection retires the superseded fade request")
	assert_true(presenter.visible)
	assert_almost_eq(presenter.modulate.a, 1.0, 0.0001,
		"the old show-fade tail cannot restore alpha zero after the fresh cut")
	assert_null(presenter.get("_active_tween"),
		"the stale fade tail cannot install a tween after reentrant retirement")


func test_skip_activation_tail_cannot_touch_the_fresh_real_dialogue_owner() -> void:
	_runtime.game_state.current_state = GameStateMachine.State.PLAYING
	var game: Node = load("res://addons/stella/scenes/game.tscn").instantiate()
	_add_owned_node(game)
	await get_tree().process_frame
	var dialogue: Control = game.get_node("UILayer/DialoguePanel")
	var indicator: Control = game.get_node("UILayer/ChapterIndicator")
	dialogue._char_interval = 0.0
	var observed_at_show := [{}]
	var on_dialogue := func(request: DialogueRequest) -> void:
		_dialogue_requests.append(request)
		if observed_at_show[0].is_empty():
			observed_at_show[0] = {
				"pending": request.get_activation().is_pending(),
				"typing": dialogue._is_typing,
				"ready": dialogue._dialogue_ready,
				"skip_active": _runtime.skip_controller.is_active,
			}
			# Cleanup happens only after the real Presenter has accepted SHOW. The
			# snapshot above proves Skip intent survived the indicator completion.
			_runtime.skip_controller.stop()
	SignalBus.dialogue_requested.connect(on_dialogue)

	_runtime.start_scenario(TRANSITION_PATH)
	assert_true(await _wait_until(
		func() -> bool:
			return (
				indicator.get("_active_request_id") != 0
				and bool(_runtime.call("is_chapter_indicator_visible"))
			),
	))
	_runtime.skip_controller.is_active = true
	assert_true(_runtime.skip_controller.is_active)
	assert_eq(_dialogue_requests.size(), 0,
		"the outer active_changed signal tail cannot synchronously install dialogue")
	assert_ne(indicator.get("_active_request_id"), 0,
		"transition completion is deferred until the activation tail returns")

	assert_true(await _wait_until(
		func() -> bool: return not observed_at_show[0].is_empty()))
	assert_eq(_dialogue_requests.size(), 1)
	assert_true(bool(observed_at_show[0].get("skip_active", false)),
		"Skip intent remains active when the fresh dialogue is admitted")
	assert_true(bool(observed_at_show[0].get("pending", false)))
	assert_true(bool(observed_at_show[0].get("typing", false)),
		"the same activation cannot snap the fresh real typewriter")
	assert_false(bool(observed_at_show[0].get("ready", true)))
	assert_true(_dialogue_requests[0].get_activation().is_pending(),
		"the same activation cannot advance the following command owner")
	SignalBus.dialogue_requested.disconnect(on_dialogue)
	_runtime.engine.cancel_current_run()


func test_zero_significand_gross_exponent_is_canonical_zero_duration() -> void:
	var source := (
		"@chapter exponent \"Exponent\"\n"
		+ "@scene start\n"
		+ "@chapter_indicator show transition=fade duration=0e999\n"
	)
	var data := DslParser.parse(
		DslLexer.tokenize(source), "zero_exponent", "zero_exponent.stla")
	var errors := data.diagnostics.filter(
		func(diagnostic: Dictionary) -> bool:
			return String(diagnostic.get("level", "")) == "error")
	assert_eq(errors, [])
	assert_eq(data.scenes.size(), 1)
	if data.scenes.is_empty() or data.scenes[0].commands.is_empty():
		return
	var command: CommandData = data.scenes[0].commands[0]
	assert_eq(command.type, "presentation_batch")
	assert_eq(
		command.params["operations"][0]["payload"].get("duration"), 0.0)


func _build_wait_then_dialogue_scenario() -> ScenarioData:
	var data := ScenarioData.new()
	data.id = "chapter_indicator_suspension_probe"
	var scene := SceneData.new()
	scene.id = "start"
	var wait := CommandData.new()
	wait.type = "wait"
	wait.params = {"mode": "click"}
	var dialogue := CommandData.new()
	dialogue.type = "dialogue"
	dialogue.params = {"character": "n", "text": "resumed"}
	scene.commands = [wait, dialogue]
	data.scenes = [scene]
	return data


func _build_choice_then_dialogue_scenario() -> ScenarioData:
	var data := ScenarioData.new()
	data.id = "chapter_indicator_choice_receipt_probe"
	var scene := SceneData.new()
	scene.id = "start"
	var choice := CommandData.new()
	choice.type = "choice"
	choice.params = {
		"prompt": "Retired owner",
		"options": [{
			"id": "old",
			"label": "Old",
			"set": {"selection_count": "+ 1"},
		}],
	}
	var dialogue := CommandData.new()
	dialogue.type = "dialogue"
	dialogue.params = {"character": "n", "text": "restored in destination"}
	scene.commands = [choice, dialogue]
	data.scenes = [scene]
	return data


func _build_two_dialogue_scenario() -> ScenarioData:
	var data := ScenarioData.new()
	data.id = "chapter_indicator_real_dialogue_handoff"
	var scene := SceneData.new()
	scene.id = "start"
	for text: String in ["retained dialogue", "must remain next"]:
		var dialogue := CommandData.new()
		dialogue.type = "dialogue"
		dialogue.params = {"character": "n", "text": text}
		scene.commands.append(dialogue)
	data.scenes = [scene]
	return data


func _install_fresh_wait_owner(id: String) -> ScenarioContext:
	var data := _build_wait_then_dialogue_scenario()
	data.id = id
	data.assign_command_uids()
	var context := ScenarioContext.new(data)
	context.variable_store = VariableStore.new()
	_runtime.engine.replace_context(context)
	_runtime.engine.run()
	return context
