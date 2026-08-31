## Runtime-owned generic composition authority for typed presentation batches.
##
## The Director registers ownership before synchronous SignalBus delivery,
## seals the exact receipt set at the serialized dispatch tail, and settles a
## JOIN only from terminal acknowledgements for that sealed set.
class_name PresentationDirector extends RefCounted

const EXACT_STAGE_OPERATION_KEYS := [
	"action", "duration", "id", "properties", "transition", "transition_params",
]
const EXACT_DIALOGUE_VISIBILITY_KEYS := [
	"action", "duration", "target", "transition",
]
const EXACT_DIALOGUE_CLEAR_KEYS := ["scope"]
const EXACT_DIALOGUE_AVATAR_KEYS := [
	"action", "duration", "properties", "transition",
]
const EXACT_CHAPTER_INDICATOR_KEYS := [
	"action", "duration", "transition",
]
const EXACT_LOOP_SE_KEYS := [
	"action", "asset", "channel", "fade_duration", "resume_position", "volume",
]
const EXACT_BGM_KEYS := [
	"action", "asset", "cue", "fade_duration", "marker", "resume_position",
	"stem_mix", "volume",
]
const EXACT_PRESENTATION_CLIP_KEYS := ["asset"]
const EXACT_MOVIE_KEYS := ["action", "asset", "loop", "skippable"]

var _authority := RefCounted.new()
var _reservation_authority := RefCounted.new()
var _presentation_state: PresentationState
var _skip_active: Callable
var _cancel_skip_after_clip_claim: Callable
var _skip_activation_claimed_by_clip: bool = false
var _skip_activation_claimed_by_movie: bool = false
var _entries: Dictionary = {}
var _pending_request_reservations: Dictionary = {}
var _external_blockers: Dictionary = {}
var _generation: int = 1
var _dialogue_visibility_reset_allows_next_apply: bool = false
var _retired_presentation_projection_lifecycle_id: int = 0
var _latest_stage_owner_request_id: int = 0
var _latest_dialogue_owner_request_ids: Dictionary = {}
var _latest_dialogue_content_owner_request_id: int = 0
var _latest_dialogue_avatar_owner_request_id: int = 0
var _latest_chapter_owner_request_id: int = 0
var _latest_loop_se_owner_request_ids: Dictionary = {}
var _latest_bgm_owner_request_id: int = 0
var _latest_presentation_clip_owner_request_id: int = 0
var _latest_movie_owner_request_id: int = 0
var _rollback_stage_reset_epoch: int = 0
var _rollback_movie_reset_epoch: int = 0


func _init(
	presentation_state: PresentationState = null,
	skip_active: Callable = Callable(),
	cancel_skip_after_clip_claim: Callable = Callable(),
) -> void:
	_presentation_state = presentation_state
	_skip_active = skip_active
	_cancel_skip_after_clip_claim = cancel_skip_after_clip_claim
	SignalBus.stage_transition_receipt_started.connect(
		_on_stage_transition_receipt_started)
	SignalBus.stage_operation_request_finished.connect(
		_on_stage_operation_request_finished)
	SignalBus.stage_transition_terminal.connect(_on_stage_transition_terminal)
	if SignalBus.has_signal(&"dialogue_visibility_transition_receipt_started"):
		(SignalBus.get(&"dialogue_visibility_transition_receipt_started") as Signal).connect(
			_on_dialogue_visibility_transition_receipt_started
		)
	if SignalBus.has_signal(&"presentation_operation_request_finished"):
		(SignalBus.get(&"presentation_operation_request_finished") as Signal).connect(
			_on_presentation_operation_request_finished
		)
	SignalBus.presentation_projection_lifecycle_finished.connect(
		_on_presentation_projection_lifecycle_finished
	)
	if SignalBus.has_signal(&"dialogue_visibility_transition_terminal"):
		(SignalBus.get(&"dialogue_visibility_transition_terminal") as Signal).connect(
			_on_dialogue_visibility_transition_terminal
		)
	SignalBus.dialogue_avatar_transition_receipt_started.connect(
		_on_dialogue_avatar_transition_receipt_started)
	SignalBus.dialogue_avatar_transition_terminal.connect(
		_on_dialogue_avatar_transition_terminal)
	SignalBus.chapter_indicator_transition_receipt_started.connect(
		_on_chapter_indicator_transition_receipt_started)
	SignalBus.chapter_indicator_transition_terminal.connect(
		_on_chapter_indicator_transition_terminal)
	SignalBus.loop_se_transition_receipt_started.connect(
		_on_loop_se_transition_receipt_started)
	SignalBus.loop_se_transition_terminal.connect(
		_on_loop_se_transition_terminal)
	SignalBus.loop_se_projection_reset_requested.connect(
		_on_loop_se_projection_reset_requested)
	SignalBus.bgm_transition_receipt_started.connect(
		_on_bgm_transition_receipt_started)
	SignalBus.bgm_transition_terminal.connect(_on_bgm_transition_terminal)
	SignalBus.bgm_projection_reset_requested.connect(
		_on_bgm_projection_reset_requested)
	SignalBus.presentation_clip_transition_receipt_started.connect(
		_on_presentation_clip_transition_receipt_started)
	SignalBus.presentation_clip_transition_terminal.connect(
		_on_presentation_clip_transition_terminal)
	SignalBus.presentation_clip_projection_reset_requested.connect(
		_on_presentation_clip_projection_reset_requested)
	SignalBus.movie_transition_receipt_started.connect(
		_on_movie_transition_receipt_started)
	SignalBus.movie_transition_terminal.connect(_on_movie_transition_terminal)
	SignalBus.movie_projection_reset_requested.connect(
		_on_movie_projection_reset_requested)
	if SignalBus.has_signal(&"dialogue_visibility_visuals_reset_requested"):
		(SignalBus.get(&"dialogue_visibility_visuals_reset_requested") as Signal).connect(
			_on_dialogue_visibility_visuals_reset_requested
		)
	if SignalBus.has_signal(&"dialogue_visibility_state_apply_requested"):
		(SignalBus.get(&"dialogue_visibility_state_apply_requested") as Signal).connect(
			_on_dialogue_visibility_state_apply_requested
		)
	SignalBus.advance_requested.connect(_on_advance_requested)
	SignalBus.stage_visuals_reset_requested.connect(
		_on_stage_visuals_reset_requested)
	SignalBus.engine_abort_requested.connect(_on_engine_abort_requested)


func submit(
	operations: Array[PresentationOperation],
	policy: PresentationBatchRequest.Policy,
	context: ScenarioContext,
	source: Dictionary,
	explicit_force_cut: bool = false,
	reservation: PresentationRequestReservation = null,
	on_dispatch_started: Callable = Callable(),
) -> PresentationBatchRequest:
	var authored: Array = []
	for operation: PresentationOperation in operations:
		authored.append(operation)
	var request := PresentationBatchRequest.new(policy, authored)
	request._bind_authority(_authority)
	var request_id := 0
	if reservation != null:
		request_id = _consume_request_reservation(reservation)
		if request_id <= 0:
			_report_submit_error(
				_diagnostic_source(source),
				"presentation request reservation is not active and owned by this Director",
			)
			request._settle(PresentationBatchRequest.Outcome.FAILED, _authority)
			return request
	if not _context_accepts_submission(context):
		_report_submit_error(
			_diagnostic_source(source),
			"ScenarioContext is missing, cancelled, or not current",
		)
		request._settle(PresentationBatchRequest.Outcome.FAILED, _authority)
		return request
	var preflight := _preflight_operations(operations, policy, context)
	if not bool(preflight.get("valid", false)):
		_report_submit_error(
			_diagnostic_source(
				preflight.get("source", source) as Dictionary),
			String(preflight.get("error", "invalid presentation batch")),
		)
		request._settle(PresentationBatchRequest.Outcome.FAILED, _authority)
		return request
	if bool(preflight.get("no_work", false)):
		var authored_targets: Array = preflight.get("dialogue_targets", [])
		var has_target_owner := false
		for target_value: Variant in authored_targets:
			if _has_active_dialogue_visibility_owner(String(target_value)):
				has_target_owner = true
				break
		if not has_target_owner:
			request._settle(PresentationBatchRequest.Outcome.COMPLETED, _authority)
			return request

	if request_id <= 0:
		request_id = SignalBus.reserve_stage_operation_request_id()
	var entry := {
		"request_id": request_id,
		"request": request,
		"context": context,
		"source": _diagnostic_source(source),
		"previous_stage_layers": (
			preflight["before_state"] as Dictionary).duplicate(true),
		"previous_dialogue_visibility": (
			preflight["before_visibility"] as Dictionary).duplicate(true),
		"previous_dialogue_content": (
			preflight["before_dialogue_content"] as Dictionary).duplicate(true),
		"previous_dialogue_avatar": (
			preflight["before_dialogue_avatar"] as Dictionary).duplicate(true),
		"previous_dialogue_page": (
			preflight["before_dialogue_page"] as Dictionary).duplicate(true),
		"target_dialogue_content": (
			preflight["target_dialogue_content"] as Dictionary).duplicate(true),
		"dialogue_runtime_binding": (
			preflight["dialogue_runtime_binding"] as Dictionary).duplicate(true),
		"has_dialogue_clear": bool(preflight["has_dialogue_clear"]),
		"has_dialogue_avatar": bool(preflight["has_dialogue_avatar"]),
		"dialogue_clear_source": (
			preflight.get("dialogue_clear_source", {}) as Dictionary).duplicate(true),
		"dialogue_avatar_source": (
			preflight.get("dialogue_avatar_source", {}) as Dictionary).duplicate(true),
		"previous_chapter_indicator_visible": bool(
			preflight["before_chapter_indicator_visible"]),
		"previous_loop_se_channels": (
			preflight["before_loop_se_channels"] as Dictionary).duplicate(true),
		"target_loop_se_channels": (
			preflight["target_loop_se_channels"] as Dictionary).duplicate(true),
		"previous_bgm": (
			preflight["before_bgm"] as Dictionary).duplicate(true),
		"previous_movie": (
			preflight["before_movie"] as Dictionary).duplicate(true),
		"target_chapter_indicator_visible": bool(
			preflight["target_chapter_indicator_visible"]),
		"has_chapter_indicator": bool(preflight["has_chapter_indicator"]),
		"has_stage_operations": bool(preflight["has_stage_operations"]),
		"has_loop_se_operations": bool(preflight["has_loop_se_operations"]),
		"has_bgm_operation": bool(preflight["has_bgm_operation"]),
		"has_presentation_clip": bool(preflight["has_presentation_clip"]),
		"has_movie_operation": bool(preflight["has_movie_operation"]),
		"presentation_clip_source": (
			preflight.get("presentation_clip_source", {}) as Dictionary).duplicate(true),
		"chapter_indicator_source": (
			preflight["chapter_indicator_source"] as Dictionary).duplicate(true),
		"chapter_indicator_epoch": SignalBus.current_chapter_indicator_epoch(),
		"loop_se_epoch": SignalBus.current_loop_se_epoch(),
		"bgm_epoch": SignalBus.current_bgm_epoch(),
		"presentation_clip_epoch": SignalBus.current_presentation_clip_epoch(),
		"movie_epoch": SignalBus.current_movie_epoch(),
		"stage_epoch": SignalBus.current_stage_operation_epoch(),
		"dialogue_visibility_epoch": (
			SignalBus.current_dialogue_visibility_epoch()),
		"dialogue_avatar_epoch": SignalBus.current_dialogue_avatar_epoch(),
		"policy": policy,
		"receipts": [],
		"receipt_keys": {},
		"receipt_invalid": false,
		"terminal_keys": {},
		"sealed": false,
		"generation": _generation,
		"accept_advance_serial": SignalBus.current_advance_dispatch_serial(),
		"context_cancel": Callable(),
		"dialogue_targets": (preflight.get("dialogue_targets", []) as Array).duplicate(),
		"loop_se_channels": (preflight.get("loop_se_channels", []) as Array).duplicate(),
		"loop_se_sources": (
			preflight.get("loop_se_sources", {}) as Dictionary).duplicate(true),
		"bgm_source": (
			preflight.get("bgm_source", {}) as Dictionary).duplicate(true),
		"movie_source": (
			preflight.get("movie_source", {}) as Dictionary).duplicate(true),
		"stage_source": (
			preflight.get("stage_source", {}) as Dictionary).duplicate(true),
		"applied_stage": false,
		"applied_dialogue_targets": {},
		"applied_dialogue_content": false,
		"applied_dialogue_avatar": false,
		"applied_chapter": false,
		"applied_loop_se_channels": {},
		"applied_bgm": false,
		"applied_presentation_clip": false,
		"applied_movie": false,
	}
	_entries[request_id] = entry
	if context != null:
		var on_context_cancel := func() -> void:
			_cancel_entry(request_id, PresentationBatchRequest.Outcome.CANCELLED)
		entry["context_cancel"] = on_context_cancel
		context.cancellation_requested.connect(on_context_cancel, CONNECT_ONE_SHOT)

	var force_cut := explicit_force_cut or _is_skip_active()
	var on_apply_started := func(channels: Array) -> void:
		_on_presentation_operation_apply_started(request_id, channels)
	SignalBus.emit_presentation_operations(
		operations,
		force_cut,
		request_id,
		on_apply_started,
		on_dispatch_started,
	)
	# Persistent Skip is part of typed clip dispatch intent, but an
	# unskippable FNF projection remains modal after the command settles. Consume
	# that pre-existing intent at the newly published owner so content behind it
	# cannot observe the same state as a second Skip edge.
	if (
		force_cut
		and _is_skip_active()
		and _entries.has(request_id)
		and _entry_owns_movie(_entries[request_id])
		and SignalBus.claim_active_movie_input(request_id, &"skip")
	):
		return request
	if (
		force_cut
		and _is_skip_active()
		and _entries.has(request_id)
		and _entry_owns_presentation_clip(_entries[request_id])
		and SignalBus.claim_active_presentation_clip_input(request_id)
		and _cancel_skip_after_clip_claim.is_valid()
	):
		_cancel_skip_after_clip_claim.call()
	return request


## Reserve a globally monotonic id without exposing admission as a bare int.
## The returned capability must be consumed exactly once by submit or explicitly
## abandoned by its owner before local validation returns.
func reserve_request() -> PresentationRequestReservation:
	var reservation := PresentationRequestReservation.new()
	var request_id := SignalBus.reserve_stage_operation_request_id()
	if not reservation._bind(request_id, _reservation_authority):
		return null
	_pending_request_reservations[reservation.get_instance_id()] = {
		"reservation": reservation,
		"request_id": request_id,
	}
	return reservation


func abandon_request_reservation(
	reservation: PresentationRequestReservation,
) -> bool:
	if not _reservation_is_pending(reservation):
		return false
	var reservation_key := reservation.get_instance_id()
	if not reservation._retire(_reservation_authority, false):
		return false
	_pending_request_reservations.erase(reservation_key)
	return true


func _consume_request_reservation(
	reservation: PresentationRequestReservation,
) -> int:
	if not _reservation_is_pending(reservation):
		return 0
	var reservation_key := reservation.get_instance_id()
	var request_id := reservation.get_request_id()
	if _entries.has(request_id) or SignalBus.is_stage_operation_request_active(request_id):
		reservation._retire(_reservation_authority, true)
		_pending_request_reservations.erase(reservation_key)
		return 0
	if not reservation._consume(_reservation_authority):
		return 0
	_pending_request_reservations.erase(reservation_key)
	return request_id


func _reservation_is_pending(
	reservation: PresentationRequestReservation,
) -> bool:
	if reservation == null or not reservation.is_active():
		return false
	var record: Dictionary = _pending_request_reservations.get(
		reservation.get_instance_id(), {})
	return (
		not record.is_empty()
		and record.get("reservation") == reservation
		and int(record.get("request_id", 0)) == reservation.get_request_id()
	)


func _cancel_pending_request_reservations() -> void:
	var reservations := _pending_request_reservations.values()
	_pending_request_reservations.clear()
	for record_value: Variant in reservations:
		if not record_value is Dictionary:
			continue
		var reservation: PresentationRequestReservation = (
			(record_value as Dictionary).get("reservation"))
		if reservation != null:
			reservation._retire(_reservation_authority, true)


func has_blocking_waiter(context: ScenarioContext = null) -> bool:
	for request_id_value: Variant in _entries:
		var entry: Dictionary = _entries[request_id_value]
		var request: PresentationBatchRequest = entry["request"]
		if (
			int(entry["policy"]) == PresentationBatchRequest.Policy.JOIN
			and not request.is_settled()
			and (context == null or entry["context"] == context)
		):
			return true
	if context == null:
		return not _external_blockers.is_empty()
	return _external_blockers.has(context.get_instance_id())


## Cancel generic blocking work before a lifecycle reset. Reversible scene
## navigation may restore a Stage JOIN's pre-command canonical state so a
## rejected handoff can fresh-dispatch the retained cursor exactly once.
func cancel_blocking_waiters(
	context: ScenarioContext = null,
	restore_for_replay: bool = false,
) -> bool:
	var entry_snapshot: Dictionary = {}
	var blocker_snapshot: Dictionary = {}
	var had_blocking_waiter := false
	var restore_state: Dictionary = {}
	var restore_visibility: Dictionary = {}
	var restore_dialogue_content: Dictionary = {}
	var restore_dialogue_page: Dictionary = {}
	var restore_dialogue_binding: Dictionary = {}
	var restore_dialogue_avatar: Dictionary = {}
	var has_stage_restore := false
	var has_visibility_restore := false
	var has_dialogue_content_restore := false
	var has_dialogue_avatar_restore := false
	var restore_chapter_indicator_visible := false
	var has_chapter_indicator_restore := false
	var restore_loop_se := (
		_presentation_state.loop_se_channels.duplicate(true)
		if _presentation_state != null
		else {}
	)
	var restore_loop_se_targets: Array[String] = []
	var restore_bgm: Dictionary = {}
	var has_bgm_restore := false
	var restore_movie: Dictionary = {}
	var has_movie_restore := false
	var restore_movie_request_id := 0
	for request_id_value: Variant in _entries.keys():
		var request_id := int(request_id_value)
		var entry: Dictionary = _entries[request_id]
		if context != null and entry.get("context") != context:
			continue
		entry_snapshot[request_id] = entry
		var request: PresentationBatchRequest = entry["request"]
		if (
			int(entry["policy"]) == PresentationBatchRequest.Policy.JOIN
			and not request.is_settled()
		):
			had_blocking_waiter = true
			if restore_for_replay and not has_stage_restore:
				var previous: Variant = entry.get("previous_stage_layers", {})
				if previous is Dictionary:
					restore_state = (previous as Dictionary).duplicate(true)
					has_stage_restore = true
			if restore_for_replay and not has_visibility_restore:
				var previous_visibility: Variant = entry.get(
					"previous_dialogue_visibility",
					{},
				)
				if previous_visibility is Dictionary:
					restore_visibility = (
						previous_visibility as Dictionary
					).duplicate(true)
					has_visibility_restore = true
			if (
				restore_for_replay
				and not has_dialogue_content_restore
				and _entry_owns_dialogue_content(entry)
			):
				restore_dialogue_content = (
					entry.get("previous_dialogue_content", {}) as Dictionary
				).duplicate(true)
				restore_dialogue_page = (
					entry.get("previous_dialogue_page", {}) as Dictionary
				).duplicate(true)
				restore_dialogue_binding = (
					entry.get("dialogue_runtime_binding", {}) as Dictionary
				).duplicate(true)
				has_dialogue_content_restore = true
			if (
				restore_for_replay
				and not has_dialogue_avatar_restore
				and bool(entry.get("has_dialogue_avatar", false))
			):
				restore_dialogue_avatar = (
					entry.get("previous_dialogue_avatar", {}) as Dictionary
				).duplicate(true)
				has_dialogue_avatar_restore = true
			if (
				restore_for_replay
				and not has_chapter_indicator_restore
				and bool(entry.get("has_chapter_indicator", false))
			):
				restore_chapter_indicator_visible = bool(
					entry.get("previous_chapter_indicator_visible", false))
				has_chapter_indicator_restore = true
			if restore_for_replay:
				var previous_loop_se: Dictionary = entry.get(
					"previous_loop_se_channels", {})
				for channel_id: String in _entry_owned_loop_se_channels(entry):
					if previous_loop_se.has(channel_id):
						restore_loop_se[channel_id] = (
							previous_loop_se[channel_id] as Dictionary).duplicate(true)
					else:
						restore_loop_se.erase(channel_id)
					if channel_id not in restore_loop_se_targets:
						restore_loop_se_targets.append(channel_id)
				if not has_bgm_restore and _entry_owns_bgm(entry):
					restore_bgm = (
						entry.get("previous_bgm", {}) as Dictionary).duplicate(true)
					has_bgm_restore = true
				if not has_movie_restore and _entry_owns_movie(entry):
					restore_movie = (
						entry.get("previous_movie", {}) as Dictionary).duplicate(true)
					has_movie_restore = true
					restore_movie_request_id = request_id

	var context_ids: Array = (
		_external_blockers.keys().duplicate()
		if context == null
		else [context.get_instance_id()]
	)
	for context_id: Variant in context_ids:
		var blockers: Array = _external_blockers.get(context_id, [])
		if blockers.is_empty():
			continue
		blocker_snapshot[context_id] = blockers.duplicate()
		had_blocking_waiter = true

	# Retire the complete old lifecycle before any request settlement or external
	# blocker callback can synchronously install a winning replacement.
	_generation += 1
	for request_id_value: Variant in entry_snapshot:
		_entries.erase(int(request_id_value))
	for context_id: Variant in blocker_snapshot:
		_external_blockers.erase(context_id)
	for entry_value: Variant in entry_snapshot.values():
		_disconnect_entry_context(entry_value)
	if (
		restore_for_replay
		and _presentation_state != null
	):
		if has_stage_restore:
			_presentation_state.stage_layers = restore_state.duplicate(true)
		if has_visibility_restore:
			_presentation_state.dialogue_visibility = restore_visibility.duplicate(
				true
			)
		if has_dialogue_content_restore:
			_presentation_state.dialogue_content = (
				restore_dialogue_content.duplicate(true))
		if has_dialogue_avatar_restore:
			_presentation_state.dialogue_avatar = (
				restore_dialogue_avatar.duplicate(true))
		if not restore_loop_se_targets.is_empty():
			_presentation_state.loop_se_channels = restore_loop_se.duplicate(true)
		if has_bgm_restore:
			_presentation_state.current_bgm = restore_bgm.duplicate(true)
		if has_movie_restore:
			_presentation_state.current_movie = restore_movie.duplicate(true)
	if (
		restore_for_replay
		and has_chapter_indicator_restore
		and context != null
		and context.is_runtime_owner_current()
	):
		context.chapter_indicator_visible = restore_chapter_indicator_visible
	if (
		restore_for_replay
		and has_dialogue_content_restore
		and context != null
		and context.is_runtime_owner_current()
	):
		context.restore_dialogue_page_state(restore_dialogue_page)
		SignalBus.apply_dialogue_content_state(
			restore_dialogue_content, restore_dialogue_binding)
	if restore_for_replay and has_dialogue_avatar_restore:
		SignalBus.reset_and_apply_dialogue_avatar_state(restore_dialogue_avatar)
	if restore_for_replay and not restore_loop_se_targets.is_empty():
		SignalBus.apply_loop_se_targets_state(
			restore_loop_se, restore_loop_se_targets)
	if restore_for_replay and has_bgm_restore:
		SignalBus.reset_and_apply_bgm_state(restore_bgm)
	if restore_for_replay and has_movie_restore:
		if SignalBus.prepare_movie_rollback_state(
			restore_movie_request_id, restore_movie):
			if _presentation_state != null:
				_presentation_state.current_movie = restore_movie.duplicate(true)
			var expected_movie_reset_epoch := SignalBus.current_movie_epoch() + 1
			_rollback_movie_reset_epoch = expected_movie_reset_epoch
			var restored_movie := SignalBus.reset_and_apply_movie_rollback_state(
				restore_movie_request_id, restore_movie)
			if _rollback_movie_reset_epoch == expected_movie_reset_epoch:
				_rollback_movie_reset_epoch = 0
			if restored_movie:
				_adopt_rolled_back_movie(
					restore_movie,
					context,
					(entry_snapshot.get(restore_movie_request_id, {}) as Dictionary).get(
						"movie_source", {}),
				)
			else:
				push_error(
					"PresentationDirector: sealed replay movie rollback apply failed")
		else:
			push_error(
				"PresentationDirector: sealed replay movie rollback plan is unavailable")

	for request_id_value: Variant in entry_snapshot:
		_cancel_detached_entry(
			int(request_id_value),
			entry_snapshot[request_id_value],
			PresentationBatchRequest.Outcome.CANCELLED,
		)
		_release_entry_movie_rollback(entry_snapshot[request_id_value])
	for context_id: Variant in blocker_snapshot:
		for blocker_value: Variant in blocker_snapshot[context_id]:
			var blocker: Dictionary = blocker_value
			var cancel: Callable = blocker.get("cancel", Callable())
			if cancel.is_valid():
				cancel.call()
	return had_blocking_waiter


func cancel_all() -> void:
	var entry_snapshot := _entries.duplicate()
	var blocker_snapshot := _external_blockers.duplicate(true)
	_generation += 1
	_cancel_pending_request_reservations()
	_entries.clear()
	_external_blockers.clear()
	for entry_value: Variant in entry_snapshot.values():
		_disconnect_entry_context(entry_value)
	for request_id_value: Variant in entry_snapshot:
		_cancel_detached_entry(
			int(request_id_value),
			entry_snapshot[request_id_value],
			PresentationBatchRequest.Outcome.CANCELLED,
		)
		_release_entry_movie_rollback(entry_snapshot[request_id_value])
	for context_id: Variant in blocker_snapshot:
		for blocker_value: Variant in (
			blocker_snapshot.get(context_id, []) as Array
		):
			var cancel: Callable = (blocker_value as Dictionary).get(
				"cancel", Callable())
			if cancel.is_valid():
				cancel.call()


func _register_blocking_waiter(
	context: ScenarioContext,
	owner: Object,
	cancel: Callable,
) -> bool:
	if (
		not _context_accepts_submission(context)
		or owner == null
		or not cancel.is_valid()
	):
		return false
	var context_id := context.get_instance_id()
	var blockers: Array = _external_blockers.get(context_id, [])
	for blocker_value: Variant in blockers:
		if (blocker_value as Dictionary).get("owner") == owner:
			return false
	blockers.append({"owner": owner, "cancel": cancel})
	_external_blockers[context_id] = blockers
	return true


func _unregister_blocking_waiter(
	context: ScenarioContext,
	owner: Object,
) -> bool:
	if context == null or owner == null:
		return false
	var context_id := context.get_instance_id()
	var blockers: Array = _external_blockers.get(context_id, [])
	for index in range(blockers.size()):
		if (blockers[index] as Dictionary).get("owner") != owner:
			continue
		blockers.remove_at(index)
		if blockers.is_empty():
			_external_blockers.erase(context_id)
		else:
			_external_blockers[context_id] = blockers
		return true
	return false


func _preflight_operations(
	operations: Array[PresentationOperation],
	policy: PresentationBatchRequest.Policy,
	context: ScenarioContext,
) -> Dictionary:
	if policy not in [
		PresentationBatchRequest.Policy.JOIN,
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
	]:
		return {"valid": false, "error": "unsupported batch policy"}
	if operations.is_empty():
		return {"valid": false, "error": "operations must not be empty"}
	if _presentation_state == null:
		return {"valid": false, "error": "PresentationState is unavailable"}
	var stage_payloads: Array = []
	var stage_typed_operations: Array[StagePresentationOperation] = []
	var visibility_payloads: Array = []
	var visibility_canonical_payloads: Array = []
	var dialogue_avatar_payloads: Array = []
	var saw_dialogue_clear := false
	var saw_dialogue_avatar := false
	var target_dialogue_content: Dictionary = {}
	var dialogue_runtime_binding: Dictionary = {}
	var dialogue_clear_source: Dictionary = {}
	var dialogue_avatar_source: Dictionary = {}
	var loop_se_payloads: Array = []
	var bgm_payloads: Array = []
	var seen_layers := {}
	var seen_targets := {}
	var seen_loop_se_channels := {}
	var saw_bgm := false
	var saw_presentation_clip := false
	var presentation_clip_source: Dictionary = {}
	var saw_movie := false
	var movie_source: Dictionary = {}
	var stage_source: Dictionary = {}
	var saw_clear := false
	var saw_visibility := false
	var saw_chapter_indicator := false
	var chapter_indicator_source: Dictionary = {}
	var loop_se_sources: Dictionary = {}
	var bgm_source: Dictionary = {}
	var stage_run_open := false
	var target_chapter_indicator_visible := context.chapter_indicator_visible
	var before_loop_se_channels := LoopSeChannelState.with_positions(
		_presentation_state.loop_se_channels,
		SignalBus.capture_loop_se_positions(),
	)
	var loop_se_simulated := before_loop_se_channels.duplicate(true)
	var before_bgm := SignalBus.capture_bgm_state(
		_presentation_state.current_bgm)
	var before_movie := SignalBus.capture_movie_state()
	var before_dialogue_avatar := _presentation_state.dialogue_avatar.duplicate(true)
	var simulated_dialogue_avatar := before_dialogue_avatar.duplicate(true)
	for operation: PresentationOperation in operations:
		var payload := operation.get_payload() if operation != null else {}
		var payload_keys := payload.keys()
		payload_keys.sort()
		if operation is StagePresentationOperation:
			if stage_source.is_empty():
				stage_source = operation.get_source()
			if not stage_run_open:
				seen_layers.clear()
			stage_run_open = true
			if payload_keys != EXACT_STAGE_OPERATION_KEYS:
				return _preflight_failure(
					"stage payload must use the canonical six-field schema",
					operation,
				)
			if (
				not payload["action"] is String
				or not payload["id"] is String
				or not payload["properties"] is Dictionary
				or not payload["transition"] is String
				or not payload["transition_params"] is Dictionary
				or not (
					payload["duration"] is int
					or payload["duration"] is float
				)
			):
				return _preflight_failure(
					"stage payload has invalid types", operation)
			var action := String(payload.get("action", ""))
			var raw_layer_id := String(payload.get("id", ""))
			var layer_id := raw_layer_id.strip_edges()
			var expected_channel := (
				"stage:*" if action == "clear" else "stage:%s" % layer_id
			)
			if (
				operation == null
				or raw_layer_id != layer_id
				or String(operation.get_channel()) != expected_channel
			):
				return _preflight_failure(
					"invalid typed Stage ownership", operation)
			if (
				action not in StageLayerState.VALID_ACTIONS
				or not StageLayerState.validate_operation(payload, false)
			):
				return _preflight_failure(
					"stage payload is not canonical", operation)
			if action == "clear":
				if saw_clear or not stage_payloads.is_empty():
					return _preflight_failure(
						"clear must be the only Stage operation", operation)
				saw_clear = true
			elif layer_id == "*" or saw_clear or seen_layers.has(layer_id):
				return _preflight_failure(
					"duplicate or invalid Stage channel '%s'" % layer_id,
					operation,
				)
			else:
				seen_layers[layer_id] = true
			stage_payloads.append(payload.duplicate(true))
			stage_typed_operations.append(operation)
		elif operation is DialogueVisibilityPresentationOperation:
			stage_run_open = false
			if payload_keys != EXACT_DIALOGUE_VISIBILITY_KEYS:
				return _preflight_failure(
					"dialogue visibility payload must use the canonical four-field schema",
					operation,
				)
			var target := String(payload.get("target", "")).strip_edges()
			if (
				String(operation.get_channel()) != "dialogue:%s" % target
				or not DialogueVisibilityState.validate_operation(payload, false)
			):
				return _preflight_failure(
					"invalid typed dialogue visibility ownership", operation)
			if seen_targets.has(target):
				return _preflight_failure(
					"duplicate dialogue visibility channel '%s'" % target,
					operation,
				)
			seen_targets[target] = true
			saw_visibility = true
			visibility_canonical_payloads.append(payload.duplicate(true))
			visibility_payloads.append(operation)
		elif operation is DialogueClearPresentationOperation:
			stage_run_open = false
			if (
				saw_dialogue_clear
				or payload_keys != EXACT_DIALOGUE_CLEAR_KEYS
				or payload.get("scope", null) != "page"
				or String(operation.get_channel()) != "dialogue:content"
			):
				return _preflight_failure(
					"invalid or duplicate typed dialogue clear ownership",
					operation,
				)
			target_dialogue_content = operation.get_target_content()
			dialogue_runtime_binding = operation.get_runtime_binding()
			if (
				not PresentationState._validate_dialogue_content(
					target_dialogue_content, false)
				or not bool(target_dialogue_content.get("active", false))
				or not bool(target_dialogue_content.get("cleared", false))
				or not PresentationState.dialogue_content_profiles_exist(
					target_dialogue_content, context.scenario_data)
			):
				return _preflight_failure(
					"dialogue clear target content is not canonical", operation)
			saw_dialogue_clear = true
			dialogue_clear_source = operation.get_source()
		elif operation is DialogueAvatarPresentationOperation:
			stage_run_open = false
			if payload_keys != EXACT_DIALOGUE_AVATAR_KEYS:
				return _preflight_failure(
					"dialogue avatar payload must use the canonical four-field schema",
					operation,
				)
			if (
				String(operation.get_channel()) != "dialogue:avatar"
				or not DialogueAvatarState.validate_operation(payload, false)
				or operation.get_before_state() != simulated_dialogue_avatar
				or not DialogueAvatarState.operation_is_supported(
					simulated_dialogue_avatar, payload)
			):
				return _preflight_failure(
					"invalid typed dialogue avatar ownership or lifecycle",
					operation,
				)
			var avatar_target := DialogueAvatarState.reduce(
				simulated_dialogue_avatar, [payload], false)
			if operation.get_target_state() != avatar_target:
				return _preflight_failure(
					"dialogue avatar target does not match canonical reduction",
					operation,
				)
			simulated_dialogue_avatar = avatar_target
			dialogue_avatar_payloads.append(payload.duplicate(true))
			dialogue_avatar_source = operation.get_source()
			saw_dialogue_avatar = true
		elif operation is ChapterIndicatorPresentationOperation:
			stage_run_open = false
			if payload_keys != EXACT_CHAPTER_INDICATOR_KEYS:
				return _preflight_failure(
					"chapter indicator payload must use the canonical three-field schema",
					operation,
				)
			if (
				saw_chapter_indicator
				or String(operation.get_channel()) != "chapter:indicator"
				or String(payload.get("action", "")) not in ["show", "hide"]
				or String(payload.get("transition", "")) not in ["cut", "fade"]
				or not payload.get("duration", null) is float
				or not is_finite(float(payload.get("duration", -1.0)))
				or float(payload.get("duration", -1.0)) < 0.0
				or (
					String(payload.get("transition", "")) == "cut"
					and float(payload.get("duration", -1.0)) != 0.0
				)
			):
				return _preflight_failure(
					"invalid typed chapter indicator ownership", operation)
			saw_chapter_indicator = true
			chapter_indicator_source = operation.get_source()
			target_chapter_indicator_visible = (
				String(payload.get("action", "")) == "show")
		elif operation is LoopSePresentationOperation:
			stage_run_open = false
			if payload_keys != EXACT_LOOP_SE_KEYS:
				return _preflight_failure(
					"loop-SE payload must use the canonical six-field schema",
					operation,
				)
			var channel_id := String(payload.get("channel", ""))
			if (
				String(operation.get_channel()) != "loop_se:%s" % channel_id
				or not LoopSeChannelState.validate_operation(payload, false)
			):
				return _preflight_failure(
					"invalid typed loop-SE ownership", operation)
			if seen_loop_se_channels.has(channel_id):
				return _preflight_failure(
					"duplicate loop-SE channel '%s'" % channel_id, operation)
			seen_loop_se_channels[channel_id] = true
			loop_se_sources[channel_id] = operation.get_source()
			loop_se_simulated = LoopSeChannelState.reduce(
				loop_se_simulated, [payload], false)
			loop_se_payloads.append(payload.duplicate(true))
		elif operation is BgmPresentationOperation:
			stage_run_open = false
			if payload_keys != EXACT_BGM_KEYS:
				return _preflight_failure(
					"BGM payload must use the canonical eight-field schema",
					operation,
				)
			if (
				saw_bgm
				or String(operation.get_channel()) != "bgm:main"
				or not BgmChannelState.validate_operation(payload, false)
			):
				return _preflight_failure(
					"invalid or duplicate typed BGM ownership", operation)
			if not BgmChannelState.operation_is_supported(before_bgm, payload):
				return _preflight_failure(
					"BGM lifecycle action requires an active track", operation)
			saw_bgm = true
			bgm_source = operation.get_source()
			bgm_payloads.append(payload.duplicate(true))
		elif operation is PresentationClipPresentationOperation:
			stage_run_open = false
			if (
				saw_presentation_clip
				or operations.size() != 1
				or payload_keys != EXACT_PRESENTATION_CLIP_KEYS
				or not payload.get("asset", null) is String
				or not PresentationClipDefinition.is_logical_id(
					String(payload.get("asset", "")))
				or String(operation.get_channel())
					!= "clip:%s" % String(payload.get("asset", ""))
			):
				return _preflight_failure(
					"presentation clip must be the only operation in its batch",
					operation,
				)
			saw_presentation_clip = true
			presentation_clip_source = operation.get_source()
		elif operation is MoviePresentationOperation:
			stage_run_open = false
			if (
				saw_movie
				or payload_keys != EXACT_MOVIE_KEYS
				or String(operation.get_channel()) != "movie:main"
				or not MovieChannelState.validate_operation(payload, false)
				or (
					policy == PresentationBatchRequest.Policy.JOIN
					and bool(payload.get("loop", false))
				)
			):
				return _preflight_failure(
					"invalid or duplicate typed movie ownership/lifecycle",
					operation,
				)
			saw_movie = true
			movie_source = operation.get_source()
		else:
			stage_run_open = false
			return _preflight_failure(
				"unsupported presentation operation kind", operation)

	var before_state := _presentation_state.stage_layers.duplicate(true)
	var before_visibility := _presentation_state.dialogue_visibility.duplicate(true)
	var before_dialogue_content := _presentation_state.dialogue_content.duplicate(true)
	var before_dialogue_page := context.capture_dialogue_page_state()
	var simulated := before_state.duplicate(true)
	for stage_index in range(stage_payloads.size()):
		var payload: Dictionary = stage_payloads[stage_index]
		var action := String(payload["action"])
		var layer_id := String(payload["id"])
		if action in ["update", "hide"] and not simulated.has(layer_id):
			return _preflight_failure(
				"cannot %s unknown layer '%s'" % [action, layer_id],
				stage_typed_operations[stage_index],
			)
		simulated = StageLayerState.reduce(simulated, [payload], false)
	var target_visibility := DialogueVisibilityState.reduce(
		before_visibility,
		visibility_canonical_payloads,
		false,
	)
	return {
		"valid": true,
		"payloads": {
			"stage": stage_payloads,
			"dialogue_visibility": visibility_payloads,
			"dialogue_avatar": dialogue_avatar_payloads,
		},
		"before_state": before_state,
		"before_visibility": before_visibility,
		"before_dialogue_content": before_dialogue_content,
		"before_dialogue_avatar": before_dialogue_avatar,
		"before_dialogue_page": before_dialogue_page,
		"target_dialogue_content": target_dialogue_content,
		"dialogue_runtime_binding": dialogue_runtime_binding,
		"has_dialogue_clear": saw_dialogue_clear,
		"has_dialogue_avatar": saw_dialogue_avatar,
		"dialogue_clear_source": dialogue_clear_source,
		"dialogue_avatar_source": dialogue_avatar_source,
		"before_chapter_indicator_visible": context.chapter_indicator_visible,
		"before_loop_se_channels": before_loop_se_channels,
		"before_bgm": before_bgm,
		"before_movie": before_movie,
		"target_state": simulated,
		"target_visibility": target_visibility,
		"target_dialogue_avatar": simulated_dialogue_avatar,
		"target_chapter_indicator_visible": target_chapter_indicator_visible,
		"target_loop_se_channels": loop_se_simulated,
		"has_chapter_indicator": saw_chapter_indicator,
		"has_stage_operations": not stage_payloads.is_empty(),
		"has_loop_se_operations": not loop_se_payloads.is_empty(),
		"has_bgm_operation": saw_bgm,
		"has_presentation_clip": saw_presentation_clip,
		"has_movie_operation": saw_movie,
		"chapter_indicator_source": chapter_indicator_source,
		"loop_se_sources": loop_se_sources,
		"bgm_source": bgm_source,
		"presentation_clip_source": presentation_clip_source,
		"movie_source": movie_source,
		"stage_source": stage_source,
		"dialogue_targets": seen_targets.keys(),
		"loop_se_channels": seen_loop_se_channels.keys(),
		"no_work": (
			stage_payloads.is_empty()
			and simulated == before_state
			and target_visibility == before_visibility
			and loop_se_payloads.is_empty()
			and bgm_payloads.is_empty()
			and not saw_clear
			and not saw_dialogue_clear
			and not saw_dialogue_avatar
			and not saw_chapter_indicator
			and not saw_presentation_clip
			and not saw_movie
		),
	}


func _preflight_failure(
	error: String,
	operation: PresentationOperation = null,
) -> Dictionary:
	var result := {"valid": false, "error": error}
	if operation != null:
		var operation_source := operation.get_source()
		if not operation_source.is_empty():
			result["source"] = operation_source
	return result


func _has_active_dialogue_visibility_owner(target: String) -> bool:
	for request_id_value: Variant in _entries:
		var entry: Dictionary = _entries[request_id_value]
		if int(entry.get("generation", -1)) != _generation:
			continue
		if target not in (entry.get("dialogue_targets", []) as Array):
			continue
		var terminal_keys: Dictionary = entry.get("terminal_keys", {})
		if not bool(entry.get("sealed", false)):
			return true
		for receipt_value: Variant in entry.get("receipts", []):
			if not receipt_value is PresentationOperationReceipt:
				continue
			var receipt: PresentationOperationReceipt = receipt_value
			if (
				String(receipt.get_channel()) == "dialogue:%s" % target
				and not terminal_keys.has(_receipt_key(receipt))
			):
				return true
	return false


func _diagnostic_source(source: Dictionary) -> Dictionary:
	return {
		"source_path": String(source.get("source_path", "")),
		"scenario_id": String(source.get("scenario_id", "")),
		"line": int(source.get("line", 0)),
	}


func _report_submit_error(source: Dictionary, message: String) -> void:
	var source_path := String(source.get("source_path", "")).strip_edges()
	var scenario_id := String(source.get("scenario_id", "")).strip_edges()
	var label := source_path if not source_path.is_empty() else scenario_id
	var line := int(source.get("line", 0))
	if not label.is_empty() and line > 0:
		label = "%s:%d" % [label, line]
	elif label.is_empty() and line > 0:
		label = "line %d" % line
	elif label.is_empty():
		label = "runtime"
	push_error("[%s] PresentationDirector: %s" % [label, message])


func _on_stage_transition_receipt_started(
	presenter_instance_id: int,
	layer_id: String,
	token: int,
	operation_request_id: int,
	generation: int,
) -> void:
	var entry: Dictionary = _entries.get(operation_request_id, {})
	if (
		entry.is_empty()
		or bool(entry.get("sealed", false))
		or int(entry.get("generation", -1)) != _generation
	):
		return
	if (
		presenter_instance_id <= 0
		or layer_id != layer_id.strip_edges()
		or layer_id.is_empty()
		or layer_id == "*"
		or token <= 0
		or generation <= 0
	):
		entry["receipt_invalid"] = true
		return
	var channel := StringName("stage:%s" % layer_id)
	var receipt := PresentationOperationReceipt.new(
		operation_request_id,
		presenter_instance_id,
		channel,
		token,
		generation,
	)
	var key := _receipt_key(receipt)
	if (entry["receipt_keys"] as Dictionary).has(key):
		return
	(entry["receipt_keys"] as Dictionary)[key] = true
	(entry["receipts"] as Array).append(receipt)


func _on_stage_operation_request_finished(
	request_id: int,
	delivered: bool,
) -> void:
	_on_generic_request_finished(request_id, delivered)


func _on_presentation_operation_request_finished(
	request_id: int,
	delivered: bool,
) -> void:
	_on_generic_request_finished(request_id, delivered)


func _on_generic_request_finished(
	request_id: int,
	delivered: bool,
) -> void:
	var entry: Dictionary = _entries.get(request_id, {})
	if entry.is_empty() or bool(entry.get("sealed", false)):
		return
	var request: PresentationBatchRequest = entry["request"]
	var receipts: Array = entry["receipts"]
	var context: ScenarioContext = entry.get("context")
	if delivered and (context == null or not context.is_runtime_owner_current()):
		delivered = false
	if not delivered:
		if not _seal_entry(request_id, entry):
			if (
				context != null
				and context.is_runtime_owner_current()
				and _entry_owns_any_rollback_domain(entry)
			):
				entry["settling_failure"] = true
				_rollback_entry(entry)
				_report_entry_participant_failure(entry)
			request._settle(PresentationBatchRequest.Outcome.FAILED, _authority)
		else:
			entry["sealed"] = true
			var owns_applied_domain := _entry_owns_any_rollback_domain(entry)
			if (
				context != null
				and context.is_runtime_owner_current()
				and (
					owns_applied_domain
					or _entry_dispatch_epochs_are_current(entry)
				)
			):
				if owns_applied_domain:
					entry["settling_failure"] = true
					_rollback_entry(entry)
					_report_entry_participant_failure(entry)
				request._settle(
					PresentationBatchRequest.Outcome.FAILED, _authority)
			else:
				request._settle(
					PresentationBatchRequest.Outcome.CANCELLED, _authority)
		_cleanup_entry(request_id)
		return
	if not _seal_entry(request_id, entry):
		if (
			context != null
			and context.is_runtime_owner_current()
			and _entry_owns_any_rollback_domain(entry)
		):
			entry["settling_failure"] = true
			_rollback_entry(entry)
			_report_entry_participant_failure(entry)
		request._settle(
			PresentationBatchRequest.Outcome.FAILED, _authority)
		_cleanup_entry(request_id)
		return
	entry["sealed"] = true
	if bool(entry.get("has_dialogue_clear", false)):
		context.clear_dialogue_page()
		if _presentation_state != null:
			_presentation_state.dialogue_content = (
				entry.get("target_dialogue_content", {}) as Dictionary
			).duplicate(true)
	if bool(entry.get("has_chapter_indicator", false)):
		var target_visible := bool(
			entry.get("target_chapter_indicator_visible", false))
		context.chapter_indicator_visible = target_visible
		SignalBus.commit_chapter_indicator_projection(target_visible)
	# Rollback ends at the successful whole-batch commit point. A FNF movie entry
	# can then remain as modal ownership for an arbitrarily long (or looping)
	# stream, so it must not pin the superseded stream's sealed rollback plan.
	_release_entry_movie_rollback(entry)
	if int(entry["policy"]) == PresentationBatchRequest.Policy.FIRE_AND_FORGET:
		request._settle(PresentationBatchRequest.Outcome.COMPLETED, _authority)
	if receipts.is_empty():
		request._settle(PresentationBatchRequest.Outcome.COMPLETED, _authority)
		_cleanup_entry(request_id)
		return
	if (
		int(entry["policy"]) == PresentationBatchRequest.Policy.JOIN
		and _is_skip_active()
	):
		_finish_join(request_id)
	_evaluate_terminal_state(request_id)


func _on_stage_transition_terminal(
	presenter_instance_id: int,
	layer_id: String,
	token: int,
	operation_request_id: int,
	generation: int,
	outcome: StringName,
) -> void:
	if outcome not in [&"completed", &"superseded", &"cancelled"]:
		return
	var entry: Dictionary = _entries.get(operation_request_id, {})
	if (
		entry.is_empty()
		or int(entry.get("generation", -1)) != _generation
	):
		return
	var key := _receipt_key_parts(
		operation_request_id,
		presenter_instance_id,
		StringName("stage:%s" % layer_id),
		token,
		generation,
	)
	if (
		not (entry["receipt_keys"] as Dictionary).has(key)
		or (entry["terminal_keys"] as Dictionary).has(key)
	):
		return
	(entry["terminal_keys"] as Dictionary)[key] = outcome
	if not bool(entry.get("sealed", false)):
		return
	_evaluate_terminal_state(operation_request_id)


func _on_dialogue_visibility_transition_receipt_started(
	presenter_instance_id: int,
	target: String,
	token: int,
	operation_request_id: int,
	generation: int,
) -> void:
	var entry: Dictionary = _entries.get(operation_request_id, {})
	if (
		entry.is_empty()
		or bool(entry.get("sealed", false))
		or int(entry.get("generation", -1)) != _generation
	):
		return
	if (
		presenter_instance_id <= 0
		or target != target.strip_edges()
		or target.is_empty()
		or token <= 0
		or generation <= 0
	):
		entry["receipt_invalid"] = true
		return
	var receipt := PresentationOperationReceipt.new(
		operation_request_id,
		presenter_instance_id,
		StringName("dialogue:%s" % target),
		token,
		generation,
	)
	var key := _receipt_key(receipt)
	if (entry["receipt_keys"] as Dictionary).has(key):
		return
	(entry["receipt_keys"] as Dictionary)[key] = true
	(entry["receipts"] as Array).append(receipt)


func _on_dialogue_visibility_transition_terminal(
	presenter_instance_id: int,
	target: String,
	token: int,
	operation_request_id: int,
	generation: int,
	outcome: StringName,
) -> void:
	if outcome not in [&"completed", &"superseded", &"cancelled"]:
		return
	var entry: Dictionary = _entries.get(operation_request_id, {})
	if entry.is_empty() or int(entry.get("generation", -1)) != _generation:
		return
	var key := _receipt_key_parts(
		operation_request_id,
		presenter_instance_id,
		StringName("dialogue:%s" % target),
		token,
		generation,
	)
	if (
		not (entry["receipt_keys"] as Dictionary).has(key)
		or (entry["terminal_keys"] as Dictionary).has(key)
	):
		return
	(entry["terminal_keys"] as Dictionary)[key] = outcome
	if not bool(entry.get("sealed", false)):
		return
	_evaluate_terminal_state(operation_request_id)


func _on_dialogue_avatar_transition_receipt_started(
	presenter_instance_id: int,
	token: int,
	operation_request_id: int,
	generation: int,
) -> void:
	var entry: Dictionary = _entries.get(operation_request_id, {})
	if (
		entry.is_empty()
		or bool(entry.get("sealed", false))
		or int(entry.get("generation", -1)) != _generation
	):
		return
	if presenter_instance_id <= 0 or token <= 0 or generation <= 0:
		entry["receipt_invalid"] = true
		return
	var receipt := PresentationOperationReceipt.new(
		operation_request_id,
		presenter_instance_id,
		&"dialogue:avatar",
		token,
		generation,
	)
	var key := _receipt_key(receipt)
	if (entry["receipt_keys"] as Dictionary).has(key):
		return
	(entry["receipt_keys"] as Dictionary)[key] = true
	(entry["receipts"] as Array).append(receipt)


func _on_dialogue_avatar_transition_terminal(
	presenter_instance_id: int,
	token: int,
	operation_request_id: int,
	generation: int,
	outcome: StringName,
) -> void:
	if outcome not in [&"completed", &"superseded", &"cancelled"]:
		return
	var entry: Dictionary = _entries.get(operation_request_id, {})
	if entry.is_empty() or int(entry.get("generation", -1)) != _generation:
		return
	var key := _receipt_key_parts(
		operation_request_id,
		presenter_instance_id,
		&"dialogue:avatar",
		token,
		generation,
	)
	if (
		not (entry["receipt_keys"] as Dictionary).has(key)
		or (entry["terminal_keys"] as Dictionary).has(key)
	):
		return
	(entry["terminal_keys"] as Dictionary)[key] = outcome
	if bool(entry.get("sealed", false)):
		_evaluate_terminal_state(operation_request_id)


func _on_chapter_indicator_transition_receipt_started(
	presenter_instance_id: int,
	token: int,
	operation_request_id: int,
	generation: int,
) -> void:
	var entry: Dictionary = _entries.get(operation_request_id, {})
	if (
		entry.is_empty()
		or bool(entry.get("sealed", false))
		or int(entry.get("generation", -1)) != _generation
		or presenter_instance_id <= 0
		or token <= 0
		or generation <= 0
	):
		if not entry.is_empty():
			entry["receipt_invalid"] = true
		return
	var receipt := PresentationOperationReceipt.new(
		operation_request_id,
		presenter_instance_id,
		&"chapter:indicator",
		token,
		generation,
	)
	var key := _receipt_key(receipt)
	if (entry["receipt_keys"] as Dictionary).has(key):
		return
	(entry["receipt_keys"] as Dictionary)[key] = true
	(entry["receipts"] as Array).append(receipt)


func _on_loop_se_transition_receipt_started(
	presenter_instance_id: int,
	channel_id: String,
	token: int,
	operation_request_id: int,
	generation: int,
) -> void:
	var entry: Dictionary = _entries.get(operation_request_id, {})
	if (
		entry.is_empty()
		or bool(entry.get("sealed", false))
		or int(entry.get("generation", -1)) != _generation
	):
		return
	if (
		presenter_instance_id <= 0
		or not LoopSeChannelState.is_valid_channel_id(channel_id)
		or token <= 0
		or generation <= 0
	):
		entry["receipt_invalid"] = true
		return
	var receipt := PresentationOperationReceipt.new(
		operation_request_id,
		presenter_instance_id,
		StringName("loop_se:%s" % channel_id),
		token,
		generation,
	)
	var key := _receipt_key(receipt)
	if (entry["receipt_keys"] as Dictionary).has(key):
		return
	(entry["receipt_keys"] as Dictionary)[key] = true
	(entry["receipts"] as Array).append(receipt)


func _on_bgm_transition_receipt_started(
	presenter_instance_id: int,
	token: int,
	operation_request_id: int,
	generation: int,
) -> void:
	var entry: Dictionary = _entries.get(operation_request_id, {})
	if (
		entry.is_empty()
		or bool(entry.get("sealed", false))
		or int(entry.get("generation", -1)) != _generation
	):
		return
	if presenter_instance_id <= 0 or token <= 0 or generation <= 0:
		entry["receipt_invalid"] = true
		return
	var receipt := PresentationOperationReceipt.new(
		operation_request_id,
		presenter_instance_id,
		&"bgm:main",
		token,
		generation,
	)
	var key := _receipt_key(receipt)
	if (entry["receipt_keys"] as Dictionary).has(key):
		return
	(entry["receipt_keys"] as Dictionary)[key] = true
	(entry["receipts"] as Array).append(receipt)


func _on_presentation_clip_transition_receipt_started(
	presenter_instance_id: int,
	token: int,
	operation_request_id: int,
	generation: int,
) -> void:
	var entry: Dictionary = _entries.get(operation_request_id, {})
	if (
		entry.is_empty()
		or bool(entry.get("sealed", false))
		or int(entry.get("generation", -1)) != _generation
	):
		return
	if presenter_instance_id <= 0 or token <= 0 or generation <= 0:
		entry["receipt_invalid"] = true
		return
	var receipt := PresentationOperationReceipt.new(
		operation_request_id,
		presenter_instance_id,
		&"clip:main",
		token,
		generation,
	)
	var key := _receipt_key(receipt)
	if (entry["receipt_keys"] as Dictionary).has(key):
		return
	(entry["receipt_keys"] as Dictionary)[key] = true
	(entry["receipts"] as Array).append(receipt)


func _on_movie_transition_receipt_started(
	presenter_instance_id: int,
	token: int,
	operation_request_id: int,
	generation: int,
) -> void:
	var entry: Dictionary = _entries.get(operation_request_id, {})
	if (
		entry.is_empty()
		or bool(entry.get("sealed", false))
		or int(entry.get("generation", -1)) != _generation
	):
		return
	if presenter_instance_id <= 0 or token <= 0 or generation <= 0:
		entry["receipt_invalid"] = true
		return
	var receipt := PresentationOperationReceipt.new(
		operation_request_id,
		presenter_instance_id,
		&"movie:main",
		token,
		generation,
	)
	var key := _receipt_key(receipt)
	if (entry["receipt_keys"] as Dictionary).has(key):
		return
	(entry["receipt_keys"] as Dictionary)[key] = true
	(entry["receipts"] as Array).append(receipt)


func _on_presentation_operation_apply_started(
	request_id: int,
	channels: Array,
) -> void:
	var entry: Dictionary = _entries.get(request_id, {})
	if (
		entry.is_empty()
		or bool(entry.get("sealed", false))
		or int(entry.get("generation", -1)) != _generation
	):
		return
	for channel_value: Variant in channels:
		var channel := String(channel_value)
		if channel.begins_with("stage:"):
			entry["applied_stage"] = true
			_latest_stage_owner_request_id = request_id
		elif channel.begins_with("dialogue:"):
			var target := channel.trim_prefix("dialogue:")
			if target in ["surface", "quick_menu"]:
				(entry["applied_dialogue_targets"] as Dictionary)[target] = true
				_latest_dialogue_owner_request_ids[target] = request_id
			elif target == "content":
				entry["applied_dialogue_content"] = true
				_latest_dialogue_content_owner_request_id = request_id
			elif target == "avatar":
				entry["applied_dialogue_avatar"] = true
				_latest_dialogue_avatar_owner_request_id = request_id
		elif channel == "chapter:indicator":
			entry["applied_chapter"] = true
			_latest_chapter_owner_request_id = request_id
		elif channel.begins_with("loop_se:"):
			var channel_id := channel.trim_prefix("loop_se:")
			if LoopSeChannelState.is_valid_channel_id(channel_id):
				(entry["applied_loop_se_channels"] as Dictionary)[channel_id] = true
				_latest_loop_se_owner_request_ids[channel_id] = request_id
		elif channel == "bgm:main":
			entry["applied_bgm"] = true
			_latest_bgm_owner_request_id = request_id
		elif channel.begins_with("clip:"):
			entry["applied_presentation_clip"] = true
			_latest_presentation_clip_owner_request_id = request_id
		elif channel == "movie:main":
			entry["applied_movie"] = true
			_latest_movie_owner_request_id = request_id


func _on_chapter_indicator_transition_terminal(
	presenter_instance_id: int,
	token: int,
	operation_request_id: int,
	generation: int,
	outcome: StringName,
) -> void:
	if outcome not in [&"completed", &"superseded", &"cancelled"]:
		return
	var entry: Dictionary = _entries.get(operation_request_id, {})
	if entry.is_empty() or int(entry.get("generation", -1)) != _generation:
		return
	var key := _receipt_key_parts(
		operation_request_id,
		presenter_instance_id,
		&"chapter:indicator",
		token,
		generation,
	)
	if (
		not (entry["receipt_keys"] as Dictionary).has(key)
		or (entry["terminal_keys"] as Dictionary).has(key)
	):
		return
	(entry["terminal_keys"] as Dictionary)[key] = outcome
	if bool(entry.get("sealed", false)):
		_evaluate_terminal_state(operation_request_id)


func _on_loop_se_transition_terminal(
	presenter_instance_id: int,
	channel_id: String,
	token: int,
	operation_request_id: int,
	generation: int,
	outcome: StringName,
) -> void:
	if outcome not in [&"completed", &"superseded", &"cancelled"]:
		return
	var entry: Dictionary = _entries.get(operation_request_id, {})
	if entry.is_empty() or int(entry.get("generation", -1)) != _generation:
		return
	var key := _receipt_key_parts(
		operation_request_id,
		presenter_instance_id,
		StringName("loop_se:%s" % channel_id),
		token,
		generation,
	)
	if (
		not (entry["receipt_keys"] as Dictionary).has(key)
		or (entry["terminal_keys"] as Dictionary).has(key)
	):
		return
	(entry["terminal_keys"] as Dictionary)[key] = outcome
	if bool(entry.get("sealed", false)):
		_evaluate_terminal_state(operation_request_id)


func _on_bgm_transition_terminal(
	presenter_instance_id: int,
	token: int,
	operation_request_id: int,
	generation: int,
	outcome: StringName,
) -> void:
	if outcome not in [&"completed", &"superseded", &"cancelled", &"failed"]:
		return
	var entry: Dictionary = _entries.get(operation_request_id, {})
	if entry.is_empty() or int(entry.get("generation", -1)) != _generation:
		return
	var key := _receipt_key_parts(
		operation_request_id,
		presenter_instance_id,
		&"bgm:main",
		token,
		generation,
	)
	if (
		not (entry["receipt_keys"] as Dictionary).has(key)
		or (entry["terminal_keys"] as Dictionary).has(key)
	):
		return
	(entry["terminal_keys"] as Dictionary)[key] = outcome
	if bool(entry.get("sealed", false)):
		_evaluate_terminal_state(operation_request_id)


func _on_presentation_clip_transition_terminal(
	presenter_instance_id: int,
	token: int,
	operation_request_id: int,
	generation: int,
	outcome: StringName,
) -> void:
	if outcome not in [&"completed", &"superseded", &"cancelled"]:
		return
	var entry: Dictionary = _entries.get(operation_request_id, {})
	if entry.is_empty() or int(entry.get("generation", -1)) != _generation:
		return
	var key := _receipt_key_parts(
		operation_request_id,
		presenter_instance_id,
		&"clip:main",
		token,
		generation,
	)
	if (
		not (entry["receipt_keys"] as Dictionary).has(key)
		or (entry["terminal_keys"] as Dictionary).has(key)
	):
		return
	(entry["terminal_keys"] as Dictionary)[key] = outcome
	if bool(entry.get("sealed", false)):
		_evaluate_terminal_state(operation_request_id)


func _on_movie_transition_terminal(
	presenter_instance_id: int,
	token: int,
	operation_request_id: int,
	generation: int,
	outcome: StringName,
) -> void:
	if outcome not in [&"completed", &"superseded", &"cancelled"]:
		return
	var entry: Dictionary = _entries.get(operation_request_id, {})
	if entry.is_empty() or int(entry.get("generation", -1)) != _generation:
		return
	var key := _receipt_key_parts(
		operation_request_id,
		presenter_instance_id,
		&"movie:main",
		token,
		generation,
	)
	if (
		not (entry["receipt_keys"] as Dictionary).has(key)
		or (entry["terminal_keys"] as Dictionary).has(key)
	):
		return
	(entry["terminal_keys"] as Dictionary)[key] = outcome
	if bool(entry.get("sealed", false)):
		_evaluate_terminal_state(operation_request_id)


func _evaluate_terminal_state(request_id: int) -> void:
	var entry: Dictionary = _entries.get(request_id, {})
	if entry.is_empty() or not bool(entry.get("sealed", false)):
		return
	var terminal_keys: Dictionary = entry["terminal_keys"]
	var receipt_keys: Dictionary = entry["receipt_keys"]
	var request: PresentationBatchRequest = entry["request"]
	for terminal_key_value: Variant in terminal_keys:
		if StringName(terminal_keys[terminal_key_value]) != &"failed":
			continue
		if bool(entry.get("settling_failure", false)):
			return
		entry["settling_failure"] = true
		var context: ScenarioContext = entry.get("context")
		if context == null or not context.is_runtime_owner_current():
			if int(entry["policy"]) == PresentationBatchRequest.Policy.JOIN:
				request._settle(
					PresentationBatchRequest.Outcome.CANCELLED, _authority)
		else:
			# A marker miss leaves the one BGM player, decoder cursor, and
			# physical mix untouched. Restore every other domain still owned by
			# this batch so its cross-domain atomicity is not silently broken.
			_rollback_entry(entry, true)
			_report_entry_participant_failure(entry, String(terminal_key_value))
			if int(entry["policy"]) == PresentationBatchRequest.Policy.JOIN:
				request._settle(
					PresentationBatchRequest.Outcome.FAILED, _authority)
		_cleanup_entry(request_id)
		return
	if int(entry["policy"]) == PresentationBatchRequest.Policy.JOIN:
		for terminal_key_value: Variant in terminal_keys:
			var terminal_key := String(terminal_key_value)
			var outcome_value: Variant = terminal_keys[terminal_key_value]
			if StringName(outcome_value) == &"completed":
				continue
			if bool(entry.get("settling_failure", false)):
				return
			entry["settling_failure"] = true
			var context: ScenarioContext = entry.get("context")
			if (
				context == null
				or not context.is_runtime_owner_current()
				or not _entry_dispatch_epochs_are_current(entry)
			):
				request._settle(
					PresentationBatchRequest.Outcome.CANCELLED, _authority)
				_cleanup_entry(request_id)
				return
			if context != null and context.is_runtime_owner_current():
				_rollback_entry(entry)
				_report_entry_participant_failure(entry, terminal_key)
			request._settle(
				PresentationBatchRequest.Outcome.FAILED
				if context != null and context.is_runtime_owner_current()
				else PresentationBatchRequest.Outcome.CANCELLED,
				_authority,
			)
			_cleanup_entry(request_id)
			return
		if terminal_keys.size() == receipt_keys.size():
			request._settle(
				PresentationBatchRequest.Outcome.COMPLETED, _authority)
			_cleanup_entry(request_id)
	elif terminal_keys.size() == receipt_keys.size():
		_cleanup_entry(request_id)


func _report_entry_participant_failure(
	entry: Dictionary,
	failed_receipt_key: String = "",
) -> void:
	if (
		not bool(entry.get("has_dialogue_clear", false))
		and not bool(entry.get("has_dialogue_avatar", false))
		and not bool(entry.get("has_chapter_indicator", false))
		and not bool(entry.get("has_loop_se_operations", false))
		and not bool(entry.get("has_bgm_operation", false))
		and not bool(entry.get("has_presentation_clip", false))
		and not bool(entry.get("has_movie_operation", false))
	):
		return
	var failure_source: Dictionary = entry.get("source", {})
	if not failed_receipt_key.is_empty():
		for receipt_value: Variant in entry.get("receipts", []):
			if not receipt_value is PresentationOperationReceipt:
				continue
			var receipt: PresentationOperationReceipt = receipt_value
			if _receipt_key(receipt) != failed_receipt_key:
				continue
			var failed_channel := String(receipt.get_channel())
			if failed_channel.begins_with("loop_se:"):
				var channel_id := failed_channel.trim_prefix("loop_se:")
				failure_source = (
					entry.get("loop_se_sources", {}) as Dictionary
				).get(channel_id, failure_source)
			elif failed_channel == "chapter:indicator":
				failure_source = entry.get(
					"chapter_indicator_source", failure_source)
			elif failed_channel == "bgm:main":
				failure_source = entry.get("bgm_source", failure_source)
			elif failed_channel == "clip:main":
				failure_source = entry.get(
					"presentation_clip_source", failure_source)
			elif failed_channel == "movie:main":
				failure_source = entry.get("movie_source", failure_source)
			break
	elif (
		bool(entry.get("has_stage_operations", false))
		and not bool(entry.get("applied_stage", false))
	):
		failure_source = entry.get("stage_source", failure_source)
	elif bool(entry.get("has_dialogue_clear", false)):
		failure_source = entry.get("dialogue_clear_source", failure_source)
	elif bool(entry.get("has_dialogue_avatar", false)):
		failure_source = entry.get("dialogue_avatar_source", failure_source)
	elif bool(entry.get("has_loop_se_operations", false)):
		var applied_channels: Dictionary = entry.get(
			"applied_loop_se_channels", {})
		var source_map: Dictionary = entry.get("loop_se_sources", {})
		for channel_value: Variant in applied_channels:
			if source_map.has(channel_value):
				failure_source = source_map[channel_value]
				break
	elif bool(entry.get("has_chapter_indicator", false)):
		failure_source = entry.get("chapter_indicator_source", failure_source)
	elif bool(entry.get("has_bgm_operation", false)):
		failure_source = entry.get("bgm_source", failure_source)
	elif bool(entry.get("has_presentation_clip", false)):
		failure_source = entry.get("presentation_clip_source", failure_source)
	elif bool(entry.get("has_movie_operation", false)):
		failure_source = entry.get("movie_source", failure_source)
	_report_submit_error(
		failure_source,
		"a sealed presentation participant failed or was superseded",
	)


func _rollback_entry(entry: Dictionary, preserve_bgm: bool = false) -> void:
	var context: ScenarioContext = entry.get("context")
	if context == null or not context.is_runtime_owner_current():
		return
	var rollback_stage := _entry_owns_stage(entry)
	var rollback_dialogue_targets := _entry_owned_dialogue_targets(entry)
	var rollback_dialogue_content := _entry_owns_dialogue_content(entry)
	var rollback_dialogue_avatar := _entry_owns_dialogue_avatar(entry)
	var rollback_chapter := _entry_owns_chapter(entry)
	var rollback_loop_se_channels := _entry_owned_loop_se_channels(entry)
	var rollback_bgm := _entry_owns_bgm(entry) and not preserve_bgm
	var rollback_presentation_clip := _entry_owns_presentation_clip(entry)
	var rollback_movie := _entry_owns_movie(entry)
	if (
		not rollback_stage
		and rollback_dialogue_targets.is_empty()
		and not rollback_dialogue_content
		and not rollback_dialogue_avatar
		and not rollback_chapter
		and rollback_loop_se_channels.is_empty()
		and not rollback_bgm
		and not rollback_presentation_clip
		and not rollback_movie
	):
		return
	var previous_stage := (
		entry.get("previous_stage_layers", {}) as Dictionary).duplicate(true)
	var previous_visibility := (
		entry.get("previous_dialogue_visibility", {}) as Dictionary).duplicate(true)
	var previous_content := (
		entry.get("previous_dialogue_content", {}) as Dictionary).duplicate(true)
	var previous_avatar := (
		entry.get("previous_dialogue_avatar", {}) as Dictionary).duplicate(true)
	var previous_page := (
		entry.get("previous_dialogue_page", {}) as Dictionary).duplicate(true)
	var runtime_binding := (
		entry.get("dialogue_runtime_binding", {}) as Dictionary).duplicate(true)
	var previous_visible := bool(
		entry.get("previous_chapter_indicator_visible", false))
	var previous_loop_se := (
		entry.get("previous_loop_se_channels", {}) as Dictionary).duplicate(true)
	var previous_bgm := (
		entry.get("previous_bgm", {}) as Dictionary).duplicate(true)
	var previous_movie := (
		entry.get("previous_movie", {}) as Dictionary).duplicate(true)
	if (
		rollback_movie
		and not SignalBus.prepare_movie_rollback_state(
			int(entry.get("request_id", 0)), previous_movie)
	):
		push_error(
			"PresentationDirector: sealed movie rollback plan is unavailable for request %d"
			% int(entry.get("request_id", 0)))
		return
	SignalBus.run_presentation_projection(func() -> void:
		if rollback_stage and _entry_owns_stage(entry):
			if _presentation_state != null:
				_presentation_state.stage_layers = previous_stage.duplicate(true)
			var expected_reset_epoch := (
				SignalBus.current_stage_operation_epoch() + 1)
			_rollback_stage_reset_epoch = expected_reset_epoch
			SignalBus.reset_and_apply_stage_state(previous_stage)
			if _rollback_stage_reset_epoch == expected_reset_epoch:
				_rollback_stage_reset_epoch = 0
		var current_dialogue_targets := _entry_owned_dialogue_targets(entry)
		var targets_to_restore: Array[String] = []
		for target: String in rollback_dialogue_targets:
			if target in current_dialogue_targets:
				targets_to_restore.append(target)
		if not targets_to_restore.is_empty():
			var rollback_visibility := (
				_presentation_state.dialogue_visibility.duplicate(true)
				if _presentation_state != null
				else DialogueVisibilityState.default_state()
			)
			for target: String in targets_to_restore:
				rollback_visibility[target] = bool(
					previous_visibility.get(target, true))
			if _presentation_state != null:
				_presentation_state.dialogue_visibility = (
					rollback_visibility.duplicate(true))
			SignalBus.apply_dialogue_visibility_targets_state(
				rollback_visibility, targets_to_restore)
		if rollback_dialogue_content and _entry_owns_dialogue_content(entry):
			context.restore_dialogue_page_state(previous_page)
			if _presentation_state != null:
				_presentation_state.dialogue_content = previous_content.duplicate(true)
			SignalBus.apply_dialogue_content_state(
				previous_content, runtime_binding)
		if rollback_dialogue_avatar and _entry_owns_dialogue_avatar(entry):
			if _presentation_state != null:
				_presentation_state.dialogue_avatar = previous_avatar.duplicate(true)
			SignalBus.reset_and_apply_dialogue_avatar_state(previous_avatar)
		if rollback_chapter and _entry_owns_chapter(entry):
			context.chapter_indicator_visible = previous_visible
			SignalBus.apply_chapter_indicator_state(previous_visible)
		var current_loop_channels := _entry_owned_loop_se_channels(entry)
		var loop_targets_to_restore: Array[String] = []
		for channel_id: String in rollback_loop_se_channels:
			if channel_id in current_loop_channels:
				loop_targets_to_restore.append(channel_id)
		if not loop_targets_to_restore.is_empty():
			var rollback_loop_se := (
				_presentation_state.loop_se_channels.duplicate(true)
				if _presentation_state != null
				else {}
			)
			for channel_id: String in loop_targets_to_restore:
				if previous_loop_se.has(channel_id):
					rollback_loop_se[channel_id] = (
						previous_loop_se[channel_id] as Dictionary).duplicate(true)
				else:
					rollback_loop_se.erase(channel_id)
			if _presentation_state != null:
				_presentation_state.loop_se_channels = rollback_loop_se.duplicate(true)
			SignalBus.apply_loop_se_targets_state(
				rollback_loop_se, loop_targets_to_restore)
		if rollback_bgm and _entry_owns_bgm(entry):
			if _presentation_state != null:
				_presentation_state.current_bgm = previous_bgm.duplicate(true)
			SignalBus.reset_and_apply_bgm_state(previous_bgm)
		if rollback_presentation_clip and _entry_owns_presentation_clip(entry):
			SignalBus.reset_presentation_clip()
		if rollback_movie and _entry_owns_movie(entry):
			if _presentation_state != null:
				_presentation_state.current_movie = previous_movie.duplicate(true)
			var expected_movie_reset_epoch := SignalBus.current_movie_epoch() + 1
			_rollback_movie_reset_epoch = expected_movie_reset_epoch
			var restored_movie := SignalBus.reset_and_apply_movie_rollback_state(
				int(entry.get("request_id", 0)), previous_movie)
			if _rollback_movie_reset_epoch == expected_movie_reset_epoch:
				_rollback_movie_reset_epoch = 0
			if restored_movie:
				_adopt_rolled_back_movie(
					previous_movie,
					context,
					entry.get("movie_source", entry.get("source", {})),
				)
			else:
				push_error(
					"PresentationDirector: sealed movie rollback apply failed for request %d"
					% int(entry.get("request_id", 0)))
	)


func _adopt_rolled_back_movie(
	state: Dictionary,
	context: ScenarioContext,
	source_value: Variant,
) -> bool:
	if state.is_empty():
		return true
	if context == null or not context.is_runtime_owner_current():
		return false
	var source: Dictionary = (
		(source_value as Dictionary).duplicate(true)
		if source_value is Dictionary else {})
	var operation := MoviePresentationOperation.new({
		"action": "play",
		"asset": String(state["asset"]),
		"loop": bool(state["loop"]),
		"skippable": bool(state["skippable"]),
	}, source)
	var request := submit(
		[operation],
		PresentationBatchRequest.Policy.FIRE_AND_FORGET,
		context,
		source,
	)
	return (
		not request.is_settled()
		or request.get_outcome() == PresentationBatchRequest.Outcome.COMPLETED
	)


func _entry_dispatch_epochs_are_current(entry: Dictionary) -> bool:
	return (
		(
			not bool(entry.get("has_stage_operations", false))
			or int(entry.get("stage_epoch", -1))
				== SignalBus.current_stage_operation_epoch()
		)
		and (
			(
				(entry.get("dialogue_targets", []) as Array).is_empty()
				and not bool(entry.get("has_dialogue_clear", false))
			)
			or int(entry.get("dialogue_visibility_epoch", -1))
				== SignalBus.current_dialogue_visibility_epoch()
		)
		and (
			not bool(entry.get("has_dialogue_avatar", false))
			or int(entry.get("dialogue_avatar_epoch", -1))
				== SignalBus.current_dialogue_avatar_epoch()
		)
		and (
			not bool(entry.get("has_chapter_indicator", false))
			or int(entry.get("chapter_indicator_epoch", -1))
				== SignalBus.current_chapter_indicator_epoch()
		)
		and (
			not bool(entry.get("has_loop_se_operations", false))
			or int(entry.get("loop_se_epoch", -1))
				== SignalBus.current_loop_se_epoch()
		)
		and (
			not bool(entry.get("has_bgm_operation", false))
			or int(entry.get("bgm_epoch", -1))
				== SignalBus.current_bgm_epoch()
		)
		and (
			not bool(entry.get("has_presentation_clip", false))
			or int(entry.get("presentation_clip_epoch", -1))
				== SignalBus.current_presentation_clip_epoch()
		)
		and (
			not bool(entry.get("has_movie_operation", false))
			or int(entry.get("movie_epoch", -1))
				== SignalBus.current_movie_epoch()
		)
	)


func _entry_owns_any_rollback_domain(entry: Dictionary) -> bool:
	return (
		_entry_owns_stage(entry)
		or not _entry_owned_dialogue_targets(entry).is_empty()
		or _entry_owns_dialogue_content(entry)
		or _entry_owns_dialogue_avatar(entry)
		or _entry_owns_chapter(entry)
		or not _entry_owned_loop_se_channels(entry).is_empty()
		or _entry_owns_bgm(entry)
		or _entry_owns_presentation_clip(entry)
		or _entry_owns_movie(entry)
	)


func _entry_owns_stage(entry: Dictionary) -> bool:
	return (
		_entry_is_current(entry)
		and bool(entry.get("applied_stage", false))
		and int(entry.get("request_id", 0))
			== _latest_stage_owner_request_id
		and int(entry.get("stage_epoch", -1))
			== SignalBus.current_stage_operation_epoch()
	)


func _entry_owned_dialogue_targets(entry: Dictionary) -> Array[String]:
	var request_id := int(entry.get("request_id", 0))
	var result: Array[String] = []
	if (
		not _entry_is_current(entry)
		or int(entry.get("dialogue_visibility_epoch", -1))
		!= SignalBus.current_dialogue_visibility_epoch()
	):
		return result
	for target_value: Variant in (
		entry.get("applied_dialogue_targets", {}) as Dictionary
	).keys():
		var target := String(target_value)
		if int(_latest_dialogue_owner_request_ids.get(target, 0)) == request_id:
			result.append(target)
	return result


func _entry_owns_dialogue_content(entry: Dictionary) -> bool:
	return (
		_entry_is_current(entry)
		and bool(entry.get("applied_dialogue_content", false))
		and int(entry.get("request_id", 0))
			== _latest_dialogue_content_owner_request_id
		and int(entry.get("dialogue_visibility_epoch", -1))
			== SignalBus.current_dialogue_visibility_epoch()
	)


func _entry_owns_dialogue_avatar(entry: Dictionary) -> bool:
	return (
		_entry_is_current(entry)
		and bool(entry.get("applied_dialogue_avatar", false))
		and int(entry.get("request_id", 0))
			== _latest_dialogue_avatar_owner_request_id
		and int(entry.get("dialogue_avatar_epoch", -1))
			== SignalBus.current_dialogue_avatar_epoch()
	)


func _entry_owns_chapter(entry: Dictionary) -> bool:
	return (
		_entry_is_current(entry)
		and bool(entry.get("applied_chapter", false))
		and int(entry.get("request_id", 0))
			== _latest_chapter_owner_request_id
		and int(entry.get("chapter_indicator_epoch", -1))
			== SignalBus.current_chapter_indicator_epoch()
	)


func _entry_owned_loop_se_channels(entry: Dictionary) -> Array[String]:
	var request_id := int(entry.get("request_id", 0))
	var result: Array[String] = []
	if (
		not _entry_is_current(entry)
		or int(entry.get("loop_se_epoch", -1))
		!= SignalBus.current_loop_se_epoch()
	):
		return result
	for channel_value: Variant in (
		entry.get("applied_loop_se_channels", {}) as Dictionary
	).keys():
		var channel_id := String(channel_value)
		if int(_latest_loop_se_owner_request_ids.get(channel_id, 0)) == request_id:
			result.append(channel_id)
	return result


func _entry_owns_bgm(entry: Dictionary) -> bool:
	return (
		_entry_is_current(entry)
		and bool(entry.get("applied_bgm", false))
		and int(entry.get("request_id", 0)) == _latest_bgm_owner_request_id
		and int(entry.get("bgm_epoch", -1)) == SignalBus.current_bgm_epoch()
	)


func _entry_owns_presentation_clip(entry: Dictionary) -> bool:
	return (
		_entry_is_current(entry)
		and bool(entry.get("applied_presentation_clip", false))
		and int(entry.get("request_id", 0))
			== _latest_presentation_clip_owner_request_id
		and int(entry.get("presentation_clip_epoch", -1))
			== SignalBus.current_presentation_clip_epoch()
	)


func _entry_owns_movie(entry: Dictionary) -> bool:
	return (
		_entry_is_current(entry)
		and bool(entry.get("applied_movie", false))
		and int(entry.get("request_id", 0)) == _latest_movie_owner_request_id
		and int(entry.get("movie_epoch", -1)) == SignalBus.current_movie_epoch()
	)


func _entry_is_current(entry: Dictionary) -> bool:
	var request_id := int(entry.get("request_id", 0))
	return (
		request_id > 0
		and int(entry.get("generation", -1)) == _generation
		and _entries.has(request_id)
	)


func _on_advance_requested() -> void:
	if (
		SignalBus.is_owned_dialogue_advance_echo()
		or SignalBus.current_advance_dispatch_was_claimed()
	):
		return
	if consume_active_movie_input(&"advance"):
		return
	if consume_active_presentation_clip_input():
		return
	var current_serial := SignalBus.current_advance_dispatch_serial()
	_finish_latest_join(current_serial, true)


func on_skip_active_changed(active: bool) -> void:
	if active:
		_skip_activation_claimed_by_movie = consume_active_movie_input(&"skip")
		if _skip_activation_claimed_by_movie:
			return
		_skip_activation_claimed_by_clip = (
			consume_active_presentation_clip_input())
		if _skip_activation_claimed_by_clip:
			if _cancel_skip_after_clip_claim.is_valid():
				_cancel_skip_after_clip_claim.call()
			return
		_finish_latest_join_for_skip.call_deferred(_generation)


func current_skip_activation_was_claimed_by_presentation() -> bool:
	return _skip_activation_claimed_by_movie or _skip_activation_claimed_by_clip


func _finish_latest_join_for_skip(generation: int) -> void:
	if generation == _generation and _is_skip_active():
		if consume_active_movie_input(&"skip"):
			return
		if consume_active_presentation_clip_input():
			return
		_finish_latest_join(0, false)


## Claim the latest active clip before typewriter/dialogue ownership. This
## includes fire-and-forget entries whose request is already settled but whose
## typed receipt still owns the visible projection. The Presenter decides
## whether the sealed definition may finish or must only consume the input.
func consume_active_presentation_clip_input() -> bool:
	var request_id := _latest_presentation_clip_owner_request_id
	var entry: Dictionary = _entries.get(request_id, {})
	if entry.is_empty() or not _entry_owns_presentation_clip(entry):
		return false
	return SignalBus.claim_active_presentation_clip_input(request_id)


## Claim the latest Runtime-owned movie surface before every lower story owner.
## The Presenter applies operation skippability plus the settings-backed input
## policy while this Director preserves exact request/generation ownership.
func consume_active_movie_input(kind: StringName) -> bool:
	if kind not in [&"advance", &"right_click", &"skip"]:
		return false
	var request_id := _latest_movie_owner_request_id
	var entry: Dictionary = _entries.get(request_id, {})
	if entry.is_empty() or not _entry_owns_movie(entry):
		return false
	return SignalBus.claim_active_movie_input(request_id, kind)


func has_active_movie_owner(context: ScenarioContext = null) -> bool:
	var request_id := _latest_movie_owner_request_id
	var entry: Dictionary = _entries.get(request_id, {})
	return (
		not entry.is_empty()
		and _entry_owns_movie(entry)
		and (context == null or entry.get("context") == context)
	)


func _is_skip_active() -> bool:
	return _skip_active.is_valid() and bool(_skip_active.call())


func _finish_latest_join(
	current_serial: int,
	require_newer_serial: bool,
) -> void:
	var winner_id := 0
	for request_id_value: Variant in _entries:
		var request_id := int(request_id_value)
		var entry: Dictionary = _entries[request_id]
		var request: PresentationBatchRequest = entry["request"]
		var context: ScenarioContext = entry.get("context")
		if (
			int(entry["policy"]) != PresentationBatchRequest.Policy.JOIN
			or not bool(entry.get("sealed", false))
			or request.is_settled()
			or (
				require_newer_serial
				and current_serial
				<= int(entry.get("accept_advance_serial", -1))
			)
			or (context != null and not context.is_runtime_owner_current())
		):
			continue
		winner_id = maxi(winner_id, request_id)
	_finish_join(winner_id)


func _finish_join(request_id: int) -> void:
	var entry: Dictionary = _entries.get(request_id, {})
	if entry.is_empty() or not bool(entry.get("sealed", false)):
		return
	var stage_records: Array = []
	var visibility_records: Array = []
	var dialogue_avatar_records: Array = []
	var loop_se_records: Array = []
	var bgm_records: Array = []
	var has_presentation_clip_receipt := false
	var has_movie_receipt := false
	var has_chapter_indicator_receipt := false
	for receipt_value: Variant in entry["receipts"]:
		var receipt: PresentationOperationReceipt = receipt_value
		var channel := String(receipt.get_channel())
		if channel.begins_with("stage:"):
			stage_records.append({
				"presenter_instance_id": receipt.get_presenter_instance_id(),
				"layer_id": channel.trim_prefix("stage:"),
				"token": receipt.get_token(),
				"operation_request_id": receipt.get_batch_id(),
				"generation": receipt.get_generation(),
			})
		elif channel == "dialogue:avatar":
			dialogue_avatar_records.append({
				"presenter_instance_id": receipt.get_presenter_instance_id(),
				"token": receipt.get_token(),
				"operation_request_id": receipt.get_batch_id(),
				"generation": receipt.get_generation(),
			})
		elif channel.begins_with("dialogue:"):
			visibility_records.append({
				"presenter_instance_id": receipt.get_presenter_instance_id(),
				"target": channel.trim_prefix("dialogue:"),
				"token": receipt.get_token(),
				"operation_request_id": receipt.get_batch_id(),
				"generation": receipt.get_generation(),
			})
		elif channel == "chapter:indicator":
			has_chapter_indicator_receipt = true
		elif channel.begins_with("loop_se:"):
			loop_se_records.append({
				"presenter_instance_id": receipt.get_presenter_instance_id(),
				"channel_id": channel.trim_prefix("loop_se:"),
				"token": receipt.get_token(),
				"operation_request_id": receipt.get_batch_id(),
				"generation": receipt.get_generation(),
			})
		elif channel == "bgm:main":
			bgm_records.append({
				"presenter_instance_id": receipt.get_presenter_instance_id(),
				"token": receipt.get_token(),
				"operation_request_id": receipt.get_batch_id(),
				"generation": receipt.get_generation(),
			})
		elif channel == "clip:main":
			has_presentation_clip_receipt = true
		elif channel == "movie:main":
			has_movie_receipt = true
	if not stage_records.is_empty():
		SignalBus.stage_transition_receipts_finish_requested.emit(stage_records)
	if not visibility_records.is_empty():
		(SignalBus.get(
			&"dialogue_visibility_transition_receipts_finish_requested"
		) as Signal).emit(visibility_records)
	if not dialogue_avatar_records.is_empty():
		SignalBus.dialogue_avatar_transition_receipts_finish_requested.emit(
			dialogue_avatar_records)
	if has_chapter_indicator_receipt:
		SignalBus.chapter_indicator_finish_requested.emit(request_id)
	if not loop_se_records.is_empty():
		SignalBus.loop_se_transition_receipts_finish_requested.emit(loop_se_records)
	if not bgm_records.is_empty():
		SignalBus.bgm_transition_receipts_finish_requested.emit(bgm_records)
	if has_presentation_clip_receipt:
		SignalBus.presentation_clip_finish_requested.emit(request_id)
	if has_movie_receipt:
		SignalBus.movie_finish_requested.emit(request_id, &"skip")


func _cancel_entry(
	request_id: int,
	outcome: PresentationBatchRequest.Outcome,
) -> void:
	var entry: Dictionary = _entries.get(request_id, {})
	if entry.is_empty():
		return
	var request: PresentationBatchRequest = entry["request"]
	if not bool(entry.get("sealed", false)):
		if not _seal_entry(request_id, entry):
			if not request.is_settled():
				request._settle(
					PresentationBatchRequest.Outcome.FAILED, _authority)
			SignalBus.cancel_stage_operation_request(request_id)
			_cleanup_entry(request_id)
			return
		entry["sealed"] = true
	if not request.is_settled():
		request._settle(outcome, _authority)
	_finish_owned_dialogue_avatar_transition(entry)
	_finish_owned_bgm_transition(entry)
	_finish_owned_presentation_clip(entry)
	_finish_owned_movie(entry)
	SignalBus.cancel_stage_operation_request(request_id)
	SignalBus.cancel_presentation_operation_request(request_id)
	SignalBus.cancel_dialogue_visibility_operation_request(request_id)
	_cleanup_entry(request_id)


func _cancel_detached_entry(
	request_id: int,
	entry: Dictionary,
	outcome: PresentationBatchRequest.Outcome,
) -> void:
	if entry.is_empty():
		return
	var request: PresentationBatchRequest = entry["request"]
	if not bool(entry.get("sealed", false)):
		if not _seal_entry(request_id, entry):
			if not request.is_settled():
				request._settle(
					PresentationBatchRequest.Outcome.FAILED, _authority)
			SignalBus.cancel_stage_operation_request(request_id)
			return
		entry["sealed"] = true
	if not request.is_settled():
		request._settle(outcome, _authority)
	_finish_owned_dialogue_avatar_transition(entry)
	_finish_owned_bgm_transition(entry)
	_finish_owned_presentation_clip(entry)
	_finish_owned_movie(entry)
	SignalBus.cancel_stage_operation_request(request_id)
	SignalBus.cancel_presentation_operation_request(request_id)
	SignalBus.cancel_dialogue_visibility_operation_request(request_id)


func _finish_owned_presentation_clip(entry: Dictionary) -> void:
	if _entry_owns_presentation_clip(entry):
		SignalBus.reset_presentation_clip()


func _finish_owned_movie(entry: Dictionary) -> void:
	if _entry_owns_movie(entry):
		SignalBus.reset_movie_presentation()


## Cancelling scenario ownership must not leave an authored BGM Tween running
## without a Director receipt. The stable target was committed atomically at
## apply time, so cancellation cuts that exact transition to its target. Replay
## cancellation projects the saved previous state before reaching this helper.
func _finish_owned_dialogue_avatar_transition(entry: Dictionary) -> void:
	var records: Array = []
	for receipt_value: Variant in entry.get("receipts", []):
		if not receipt_value is PresentationOperationReceipt:
			continue
		var receipt := receipt_value as PresentationOperationReceipt
		if String(receipt.get_channel()) != "dialogue:avatar":
			continue
		records.append({
			"presenter_instance_id": receipt.get_presenter_instance_id(),
			"token": receipt.get_token(),
			"operation_request_id": receipt.get_batch_id(),
			"generation": receipt.get_generation(),
		})
	if not records.is_empty():
		SignalBus.dialogue_avatar_transition_receipts_finish_requested.emit(records)


func _finish_owned_bgm_transition(entry: Dictionary) -> void:
	var records: Array = []
	for receipt_value: Variant in entry.get("receipts", []):
		if not receipt_value is PresentationOperationReceipt:
			continue
		var receipt := receipt_value as PresentationOperationReceipt
		if String(receipt.get_channel()) != "bgm:main":
			continue
		records.append({
			"presenter_instance_id": receipt.get_presenter_instance_id(),
			"token": receipt.get_token(),
			"operation_request_id": receipt.get_batch_id(),
			"generation": receipt.get_generation(),
		})
	if not records.is_empty():
		SignalBus.bgm_transition_receipts_finish_requested.emit(records)


func _cleanup_entry(request_id: int) -> void:
	var entry: Dictionary = _entries.get(request_id, {})
	if entry.is_empty():
		return
	var request: PresentationBatchRequest = entry.get("request")
	if (
		bool(entry.get("has_chapter_indicator", false))
		and request != null
		and request.is_settled()
		and not bool(entry.get("chapter_completion_emitted", false))
	):
		entry["chapter_completion_emitted"] = true
		SignalBus.chapter_indicator_request_finished.emit(
			request_id,
			request.get_outcome() == PresentationBatchRequest.Outcome.COMPLETED,
		)
	_disconnect_entry_context(entry)
	_release_entry_movie_rollback(entry)
	_entries.erase(request_id)


func _release_entry_movie_rollback(entry: Dictionary) -> void:
	if (
		bool(entry.get("has_movie_operation", false))
		and not bool(entry.get("movie_rollback_released", false))
	):
		SignalBus.release_movie_rollback_plan(int(entry.get("request_id", 0)))
		entry["movie_rollback_released"] = true


func _disconnect_entry_context(entry: Dictionary) -> void:
	var context: ScenarioContext = entry.get("context")
	var on_context_cancel: Callable = entry.get("context_cancel", Callable())
	if (
		context != null
		and on_context_cancel.is_valid()
		and context.cancellation_requested.is_connected(on_context_cancel)
	):
		context.cancellation_requested.disconnect(on_context_cancel)
	entry["context_cancel"] = Callable()


func _context_accepts_submission(context: ScenarioContext) -> bool:
	return (
		context != null
		and not context.is_cancellation_requested()
		and context.is_runtime_owner_current()
	)


func _seal_entry(request_id: int, entry: Dictionary) -> bool:
	if request_id <= 0 or bool(entry.get("sealed", false)):
		return false
	var receipts: Array = entry.get("receipts", [])
	var request: PresentationBatchRequest = entry["request"]
	if (
		bool(entry.get("receipt_invalid", false))
		or not _receipts_are_valid(
			request_id,
			receipts,
			request.get_operations(),
		)
	):
		return false
	return request._seal(request_id, receipts, _authority)


func _receipts_are_valid(
	batch_id: int,
	receipts: Array,
	operations: Array,
) -> bool:
	if batch_id <= 0:
		return false
	var keys := {}
	for receipt_value: Variant in receipts:
		if not receipt_value is PresentationOperationReceipt:
			return false
		var receipt: PresentationOperationReceipt = receipt_value
		var channel := String(receipt.get_channel())
		var valid_channel := (
			(
				channel.begins_with("stage:")
				and channel not in ["stage:", "stage:*"]
				and channel.trim_prefix("stage:")
					== channel.trim_prefix("stage:").strip_edges()
			)
			or (
				channel.begins_with("dialogue:")
				and channel != "dialogue:"
				and channel.trim_prefix("dialogue:")
					== channel.trim_prefix("dialogue:").strip_edges()
			)
			or channel == "chapter:indicator"
			or (
				channel.begins_with("loop_se:")
				and LoopSeChannelState.is_valid_channel_id(
					channel.trim_prefix("loop_se:"))
			)
			or channel == "bgm:main"
			or channel == "clip:main"
			or channel == "movie:main"
		)
		if (
			receipt.get_batch_id() != batch_id
			or receipt.get_presenter_instance_id() <= 0
			or not valid_channel
			or receipt.get_token() <= 0
			or receipt.get_generation() <= 0
			or not _receipt_matches_authored_operation(receipt, operations)
		):
			return false
		var key := _receipt_key(receipt)
		if keys.has(key):
			return false
		keys[key] = true
	return true


func _receipt_matches_authored_operation(
	receipt: PresentationOperationReceipt,
	operations: Array,
) -> bool:
	var receipt_channel := String(receipt.get_channel())
	for operation_value: Variant in operations:
		if not operation_value is PresentationOperation:
			continue
		var authored_channel := String(
			(operation_value as PresentationOperation).get_channel())
		if authored_channel == receipt_channel:
			return true
		if authored_channel.begins_with("clip:") and receipt_channel == "clip:main":
			return true
		if (
			authored_channel == "stage:*"
			and receipt_channel.begins_with("stage:")
			and receipt_channel not in ["stage:", "stage:*"]
		):
			return true
	return false


func _receipt_key(receipt: PresentationOperationReceipt) -> String:
	return _receipt_key_parts(
		receipt.get_batch_id(),
		receipt.get_presenter_instance_id(),
		receipt.get_channel(),
		receipt.get_token(),
		receipt.get_generation(),
	)


func _receipt_key_parts(
	batch_id: int,
	presenter_instance_id: int,
	channel: StringName,
	token: int,
	generation: int,
) -> String:
	return "%d|%d|%s|%d|%d" % [
		batch_id,
		presenter_instance_id,
		String(channel),
		token,
		generation,
	]


func _on_stage_visuals_reset_requested() -> void:
	var reset_epoch := SignalBus.current_stage_reset_epoch()
	if reset_epoch > 0 and reset_epoch == _rollback_stage_reset_epoch:
		_rollback_stage_reset_epoch = 0
		if SignalBus.is_current_stage_reset_valid():
			return
	if not SignalBus.is_current_stage_reset_valid():
		return
	_cancel_for_presentation_reset()


func _on_dialogue_visibility_visuals_reset_requested() -> void:
	_dialogue_visibility_reset_allows_next_apply = true
	_cancel_for_presentation_reset()
	call_deferred("_clear_dialogue_visibility_reset_apply_marker")


func _on_loop_se_projection_reset_requested(epoch: int) -> void:
	if epoch == SignalBus.current_loop_se_epoch():
		_cancel_for_presentation_reset()


func _on_bgm_projection_reset_requested(epoch: int) -> void:
	if epoch != SignalBus.current_bgm_epoch():
		return
	# A coordinated save/load/rollback projection remains one whole lifecycle:
	# the first domain reset retires every entry exactly once. A direct BGM reset,
	# however, is domain-local and cannot revoke an unrelated typed transaction.
	if SignalBus.current_presentation_projection_lifecycle_id() > 0:
		_cancel_for_presentation_reset()
		return
	_cancel_entries_for_bgm_reset()


func _cancel_entries_for_bgm_reset() -> void:
	var request_ids: Array[int] = []
	for request_id_value: Variant in _entries.keys():
		var request_id := int(request_id_value)
		var entry: Dictionary = _entries.get(request_id, {})
		if (
			bool(entry.get("has_bgm_operation", false))
			or bool(entry.get("applied_bgm", false))
		):
			request_ids.append(request_id)
	for request_id: int in request_ids:
		_cancel_entry(request_id, PresentationBatchRequest.Outcome.CANCELLED)


func _on_presentation_clip_projection_reset_requested(epoch: int) -> void:
	if epoch != SignalBus.current_presentation_clip_epoch():
		return
	_latest_presentation_clip_owner_request_id = 0
	if SignalBus.current_presentation_projection_lifecycle_id() > 0:
		_cancel_for_presentation_reset()
		return
	var request_ids: Array[int] = []
	for request_id_value: Variant in _entries.keys():
		var request_id := int(request_id_value)
		var entry: Dictionary = _entries.get(request_id, {})
		if (
			bool(entry.get("has_presentation_clip", false))
			or bool(entry.get("applied_presentation_clip", false))
		):
			request_ids.append(request_id)
	for request_id: int in request_ids:
		_cancel_entry(request_id, PresentationBatchRequest.Outcome.CANCELLED)


func _on_movie_projection_reset_requested(epoch: int) -> void:
	if epoch != SignalBus.current_movie_epoch():
		return
	_latest_movie_owner_request_id = 0
	if epoch == _rollback_movie_reset_epoch:
		_rollback_movie_reset_epoch = 0
		return
	if SignalBus.current_presentation_projection_lifecycle_id() > 0:
		_cancel_for_presentation_reset()
		return
	var request_ids: Array[int] = []
	for request_id_value: Variant in _entries.keys():
		var request_id := int(request_id_value)
		var entry: Dictionary = _entries.get(request_id, {})
		if (
			bool(entry.get("has_movie_operation", false))
			or bool(entry.get("applied_movie", false))
		):
			request_ids.append(request_id)
	for request_id: int in request_ids:
		_cancel_entry(request_id, PresentationBatchRequest.Outcome.CANCELLED)


func _on_dialogue_visibility_state_apply_requested(
	visibility: Dictionary,
	content: Dictionary,
	runtime_binding: Dictionary,
) -> void:
	if _dialogue_visibility_reset_allows_next_apply:
		_dialogue_visibility_reset_allows_next_apply = false
		return
	cancel_all()


func _clear_dialogue_visibility_reset_apply_marker() -> void:
	_dialogue_visibility_reset_allows_next_apply = false


func _cancel_for_presentation_reset() -> void:
	var lifecycle_id := SignalBus.current_presentation_projection_lifecycle_id()
	if lifecycle_id <= 0:
		_retired_presentation_projection_lifecycle_id = 0
		cancel_all()
		return
	if lifecycle_id == _retired_presentation_projection_lifecycle_id:
		return
	_retired_presentation_projection_lifecycle_id = lifecycle_id
	cancel_all()


func _on_presentation_projection_lifecycle_finished(lifecycle_id: int) -> void:
	if lifecycle_id == _retired_presentation_projection_lifecycle_id:
		_retired_presentation_projection_lifecycle_id = 0


func _on_engine_abort_requested() -> void:
	_retired_presentation_projection_lifecycle_id = 0
	cancel_all()
