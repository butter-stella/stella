## Global signal bus for decoupling Core and Presentation layers.
## Registered as an Autoload singleton.
extends Node

# Dialogue
## Canonical internal request. Core and built-in presenters consume this typed,
## self-contained payload; show_dialogue below remains the extension adapter.
signal dialogue_requested(request: DialogueRequest)
## Presentation may enrich the current typed request with the names of active
## custom RichTextEffects. Runtime already stored the canonical entry directly;
## this value-only event lets it recompute that same entry without retaining a
## callback or depending on a concrete Presenter node.
signal dialogue_backlog_effects_resolved(request: DialogueRequest, effect_names: Array)
## Unified dialogue signal — both normal and @combine dialogues flow through here.
## segments: Array of {text: String, voice: String, stage_ops: Array}
## A normal single-line dialogue has segments.size() == 1. A @combine block has
## multiple segments; voices and named-stage cues advance at segment boundaries.
## Inline [expr:expression] markers belong only to the text/avatar timeline. Either
## way, the dialogue is one unit for advance/skip/backlog.
signal show_dialogue(character: String, segments: Array, mode: String)
signal hide_dialogue()
signal advance_requested()
## Emitted before advance_requested listeners run, including when extensions
## invoke the public signal's emit() method directly.
signal advance_dispatch_started(serial: int)

# Stack-scoped metadata exists only for the legacy three-argument signal
# adapter. Canonical DialogueRequest delivery above is self-contained and does
# not depend on this mutable payload identity.
var _dialogue_presentation_stack: Array[Dictionary] = []
var _show_dialogue_dispatch_serial: int = 0
var _dialogue_request_serial: int = 0
var _dialogue_request_dispatch_depth: int = 0
var _pending_dialogue_advance_notifications: Array[int] = []
var _last_raw_show_dispatch_serial: int = -1
var _last_raw_show_segments: Variant = null
var _advance_dispatch_serial: int = 0
# DialoguePresenter-owned events keep normal Godot Signal delivery semantics.
# Stateful built-in consumers consult this synchronous frame so a nested SHOW
# cannot let the retired signal tail overwrite the replacement state. Direct
# raw emits have no matching frame and remain legacy-compatible.
var _owned_dialogue_event_stack: Array[Dictionary] = []
var _voice_playback_token_serial: int = 0
var _voice_completion_states: Dictionary = {}
var _voice_request_responses: Dictionary = {}
var _compatibility_voice_play_echo_pending: int = 0
var _compatibility_voice_lifecycle_echo_pending: int = 0


func _init() -> void:
	# Connect at construction time so this hook always precedes runtime waiters
	# and scene-owned presenters, independent of their later connection order.
	show_dialogue.connect(_on_show_dialogue_dispatch_started)
	advance_requested.connect(_on_advance_requested_dispatch_started)
	voice_play.connect(_on_voice_play_dispatch_started)
	voice_started.connect(_on_voice_started_dispatch_started)
	voice_progress.connect(_on_voice_progress_dispatch_started)
	voice_finished.connect(_on_voice_finished_dispatch_started)
	dialogue_voice_started.connect(_on_dialogue_voice_started_dispatch_started)
	dialogue_voice_progress.connect(_on_dialogue_voice_progress_dispatch_started)
	dialogue_voice_finished.connect(_on_dialogue_voice_finished_dispatch_started)


func emit_show_dialogue(
	character: String,
	segments: Array,
	mode: String,
	presentation_profile: Dictionary = {},
	declarative_presentation: bool = false,
	nvl_page_key: String = "",
	presentation_provenance: Dictionary = {},
	nvl_page_entries: Array = [],
) -> void:
	emit_dialogue_request(DialogueRequest.new(
		character,
		segments,
		mode,
		presentation_profile,
		declarative_presentation,
		nvl_page_key,
		presentation_provenance,
		nvl_page_entries,
	))


func emit_dialogue_request(request: DialogueRequest) -> void:
	if request == null or request.get_segments().is_empty():
		return
	_dialogue_request_serial += 1
	var request_entry_id := request.get_entry_id()
	if request_entry_id.is_empty():
		request_entry_id = "signal-bus:%d" % _dialogue_request_serial
	var canonical := DialogueRequest.new(
		request.get_character(),
		request.get_segments(),
		request.get_mode(),
		request.get_presentation_profile(),
		request.uses_declarative_presentation(),
		request.get_nvl_page_key(),
		request.get_presentation_provenance(),
		request.get_nvl_page_entries(),
		request_entry_id,
		request.get_command_uid(),
		request.get_activation(),
		request.get_scenario_identity(),
		request.get_legacy_scenario_id(),
		request.get_scene_id(),
		request.get_legacy_command_index(),
	)
	var activation := canonical.get_activation()
	if activation != null:
		if activation.is_pending():
			activation.resolved.connect(
				_on_dialogue_activation_resolved.bind(
					activation.get_instance_id()
				),
				CONNECT_ONE_SHOT,
			)
		else:
			_on_dialogue_activation_resolved(
				activation.get_outcome(), activation.get_instance_id())
	# Built-in state observes an immutable snapshot before the mutable public
	# compatibility signal is delivered to extensions.
	_dialogue_request_dispatch_depth += 1
	dialogue_requested.emit(canonical)
	var compatibility_segments := canonical.get_segments()
	_dialogue_presentation_stack.append({
		"dispatch_serial": _show_dialogue_dispatch_serial + 1,
		# Keep the live synchronous payload reference for reentrant dispatch lookup.
		# Public listeners are allowed to filter the mutable segments Array before
		# Presenter runs; retaining this reference keeps the sidecar attached to that
		# same dispatch after an in-place edit. Godot typed signals preserve the Array
		# identity throughout synchronous delivery on every supported engine version.
		"segments": compatibility_segments,
		"profile": canonical.get_presentation_profile(),
		"declarative": canonical.uses_declarative_presentation(),
		"nvl_page_key": canonical.get_nvl_page_key(),
		"nvl_page_entries": canonical.get_nvl_page_entries(),
		"provenance": canonical.get_presentation_provenance(),
	})
	show_dialogue.emit(
		canonical.get_character(), compatibility_segments, canonical.get_mode())
	_dialogue_presentation_stack.pop_back()
	_dialogue_request_dispatch_depth -= 1
	if _dialogue_request_dispatch_depth == 0:
		_flush_dialogue_advance_notifications()


func _on_dialogue_activation_resolved(
	outcome: DialogueActivation.Outcome,
	activation_id: int,
) -> void:
	if outcome != DialogueActivation.Outcome.ADVANCED:
		return
	if _dialogue_request_dispatch_depth > 0:
		_pending_dialogue_advance_notifications.append(activation_id)
		return
	advance_requested.emit()


func _flush_dialogue_advance_notifications() -> void:
	if _pending_dialogue_advance_notifications.is_empty():
		return
	var pending := _pending_dialogue_advance_notifications.duplicate()
	_pending_dialogue_advance_notifications.clear()
	for _activation_id in pending:
		advance_requested.emit()


## Compatibility notification emitter. Direct advance_requested.emit() remains
## observable by presentation/extensions, but neither path resolves a blocking
## DialogueHandler; consumers must call DialogueRequest.advance().
func emit_advance_requested() -> void:
	advance_requested.emit()


func current_advance_dispatch_serial() -> int:
	return _advance_dispatch_serial


## Canonical typed request. Built-in AudioPresenter consumes this signal;
## voice_play is emitted afterwards as a read-only compatibility notification.
func request_voice_playback(
	asset: String,
	character: String,
	owner_validator: Callable = Callable(),
	emit_compatibility_signal: bool = true,
) -> VoicePlaybackResponse:
	var request := VoicePlaybackRequest.new(asset, character, owner_validator)
	var response := VoicePlaybackResponse.new()
	if not request.is_current():
		response._resolve(false)
		return response
	_voice_request_responses[request.get_instance_id()] = response
	voice_playback_requested.emit(request)
	if emit_compatibility_signal:
		# The construction-time prehook consumes exactly this echo. A raw emit
		# nested by a later compatibility listener is a new request and must not
		# inherit a broad call-stack suppression flag.
		_compatibility_voice_play_echo_pending += 1
		voice_play.emit(asset, character)
	_voice_request_responses.erase(request.get_instance_id())
	return response


func resolve_voice_playback_request(
	request: VoicePlaybackRequest,
	accepted: bool,
) -> int:
	if request == null:
		return -1
	var response: VoicePlaybackResponse = _voice_request_responses.get(
		request.get_instance_id())
	if response == null or response.was_handled():
		return response.get_playback_token() if response != null else -1
	if not accepted:
		response._resolve(false)
		return -1
	_voice_playback_token_serial += 1
	var completion := VoicePlaybackCompletion.new()
	response._resolve(true, _voice_playback_token_serial, completion)
	_voice_completion_states[_voice_playback_token_serial] = completion
	return _voice_playback_token_serial


func voice_playback_request_is_pending(request: VoicePlaybackRequest) -> bool:
	if request == null:
		return false
	var response: VoicePlaybackResponse = _voice_request_responses.get(
		request.get_instance_id())
	return response != null and not response.was_handled()


func emit_voice_playback_event(event: VoicePlaybackEvent) -> bool:
	if event == null or not event.is_current():
		return false
	var kind := event.get_kind()
	var playback_token := event.get_playback_token()
	if kind == VoicePlaybackEvent.Kind.FINISHED \
		and playback_token >= 0 \
		and _voice_completion_states.has(playback_token):
		var completion: VoicePlaybackCompletion = _voice_completion_states[playback_token]
		completion._mark_finished()
		_voice_completion_states.erase(playback_token)
	voice_playback_event.emit(event)
	if not event.is_current():
		return false
	_compatibility_voice_lifecycle_echo_pending += 1
	match kind:
		VoicePlaybackEvent.Kind.STARTED:
			voice_started.emit(event.get_character(), event.get_asset())
		VoicePlaybackEvent.Kind.PROGRESS:
			voice_progress.emit(event.get_position(), event.get_duration())
		VoicePlaybackEvent.Kind.FINISHED:
			voice_finished.emit()
	return event.is_current()


func emit_owned_dialogue_voice_started(
	total_duration: float,
	owner_validator: Callable,
) -> bool:
	return emit_dialogue_voice_playback_event(
		DialogueVoicePlaybackEvent.started(total_duration, owner_validator))


func emit_owned_dialogue_voice_progress(
	position: float,
	total_duration: float,
	owner_validator: Callable,
) -> bool:
	return emit_dialogue_voice_playback_event(
		DialogueVoicePlaybackEvent.progress(
			position, total_duration, owner_validator))


func emit_owned_dialogue_voice_finished(owner_validator: Callable) -> bool:
	return emit_dialogue_voice_playback_event(
		DialogueVoicePlaybackEvent.finished(owner_validator))


func emit_dialogue_voice_playback_event(
	event: DialogueVoicePlaybackEvent,
) -> bool:
	if event == null or not event.is_current():
		return false
	dialogue_voice_playback_event.emit(event)
	if not event.is_current():
		return false
	match event.get_kind():
		DialogueVoicePlaybackEvent.Kind.STARTED:
			_emit_owned_dialogue_event(
				&"dialogue_voice_started", [event.get_total_duration()],
				event.is_current)
		DialogueVoicePlaybackEvent.Kind.PROGRESS:
			_emit_owned_dialogue_event(
				&"dialogue_voice_progress",
				[event.get_position(), event.get_total_duration()],
				event.is_current)
		DialogueVoicePlaybackEvent.Kind.FINISHED:
			_emit_owned_dialogue_event(
				&"dialogue_voice_finished", [], event.is_current)
	return event.is_current()


func dialogue_voice_started_event_is_current(
	total_duration: float,
	consumer_id: int = 0,
) -> bool:
	var frame := _owned_dialogue_event_frame(
		&"dialogue_voice_started", [total_duration])
	return _dialogue_event_frame_is_current(frame, consumer_id)


func dialogue_voice_finished_event_is_current(consumer_id: int = 0) -> bool:
	var frame := _owned_dialogue_event_frame(&"dialogue_voice_finished", [])
	return _dialogue_event_frame_is_current(frame, consumer_id)


func dialogue_voice_progress_event_is_current(
	position: float,
	total_duration: float,
	consumer_id: int = 0,
) -> bool:
	var frame := _owned_dialogue_event_frame(
		&"dialogue_voice_progress", [position, total_duration])
	return _dialogue_event_frame_is_current(frame, consumer_id)


func _emit_owned_dialogue_event(
	signal_name: StringName,
	arguments: Array,
	owner_validator: Callable,
) -> bool:
	if not _owned_event_validator_is_current(owner_validator):
		return false
	_owned_dialogue_event_stack.append({
		"signal": signal_name,
		"arguments": arguments.duplicate(true),
		"owner_validator": owner_validator,
		"dispatch_started": false,
		"nested_raw_dispatch_count": 0,
		"dispatch_consumers": {},
	})
	match signal_name:
		&"dialogue_voice_started":
			dialogue_voice_started.emit(arguments[0])
		&"dialogue_voice_progress":
			dialogue_voice_progress.emit(arguments[0], arguments[1])
		&"dialogue_voice_finished":
			dialogue_voice_finished.emit()
	_owned_dialogue_event_stack.pop_back()
	return _owned_event_validator_is_current(owner_validator)


func _owned_dialogue_event_frame(
	signal_name: StringName,
	arguments: Array,
) -> Dictionary:
	if _owned_dialogue_event_stack.is_empty():
		return {}
	var frame: Dictionary = _owned_dialogue_event_stack[-1]
	if frame.get("signal") != signal_name \
		or frame.get("arguments") != arguments:
		return {}
	return frame


func _owned_event_validator_is_current(owner_validator: Callable) -> bool:
	return owner_validator.is_valid() and bool(owner_validator.call())


func _dialogue_event_frame_is_current(
	frame: Dictionary,
	consumer_id: int,
) -> bool:
	if frame.is_empty() or _frame_dispatch_is_nested_raw(frame, consumer_id):
		return true
	return _owned_event_validator_is_current(
		frame.get("owner_validator", Callable()))


## Same-payload raw re-emits happen synchronously before the suspended outer
## owned callback resumes. Each consumer therefore consumes one raw-dispatch
## count per nested callback, then sees the outer owned frame again. Callers
## that coexist with other helper users should pass a stable consumer_id (node
## instance IDs are suitable); the default preserves the single-consumer API.
func _frame_dispatch_is_nested_raw(
	frame: Dictionary,
	consumer_id: int,
) -> bool:
	var nested_count := int(frame.get("nested_raw_dispatch_count", 0))
	var consumers: Dictionary = frame.get("dispatch_consumers", {})
	var consumed_count := int(consumers.get(consumer_id, 0))
	if consumed_count >= nested_count:
		return false
	consumers[consumer_id] = consumed_count + 1
	return true


func _mark_owned_dialogue_event_dispatch(
	signal_name: StringName,
	arguments: Array,
) -> Dictionary:
	var frame := _owned_dialogue_event_frame(signal_name, arguments)
	if frame.is_empty():
		return {}
	if not bool(frame.get("dispatch_started", false)):
		frame["dispatch_started"] = true
		return frame
	frame["nested_raw_dispatch_count"] = int(
		frame.get("nested_raw_dispatch_count", 0)) + 1
	return {}


func _on_voice_play_dispatch_started(
	asset: String,
	character: String,
) -> void:
	if _compatibility_voice_play_echo_pending > 0:
		_compatibility_voice_play_echo_pending -= 1
		return
	request_voice_playback(asset, character, Callable(), false)


func _on_voice_started_dispatch_started(
	character: String,
	asset: String,
) -> void:
	if _compatibility_voice_lifecycle_echo_pending > 0:
		_compatibility_voice_lifecycle_echo_pending -= 1
		return
	voice_playback_event.emit(VoicePlaybackEvent.started(
		character, asset, -1, Callable(), true))


func _on_voice_progress_dispatch_started(
	position: float,
	duration: float,
) -> void:
	if _compatibility_voice_lifecycle_echo_pending > 0:
		_compatibility_voice_lifecycle_echo_pending -= 1
		return
	voice_playback_event.emit(VoicePlaybackEvent.progress(
		position, duration, -1, Callable(), true))


func _on_voice_finished_dispatch_started() -> void:
	if _compatibility_voice_lifecycle_echo_pending > 0:
		_compatibility_voice_lifecycle_echo_pending -= 1
		return
	voice_playback_event.emit(VoicePlaybackEvent.finished(
		-1, Callable(), true))


func _on_dialogue_voice_started_dispatch_started(
	total_duration: float,
) -> void:
	var owned_frame := _mark_owned_dialogue_event_dispatch(
		&"dialogue_voice_started", [total_duration])
	if owned_frame.is_empty():
		dialogue_voice_playback_event.emit(
			DialogueVoicePlaybackEvent.started(
				total_duration, Callable(), true))


func _on_dialogue_voice_progress_dispatch_started(
	position: float,
	total_duration: float,
) -> void:
	var owned_frame := _mark_owned_dialogue_event_dispatch(
		&"dialogue_voice_progress", [position, total_duration])
	if owned_frame.is_empty():
		dialogue_voice_playback_event.emit(
			DialogueVoicePlaybackEvent.progress(
				position, total_duration, Callable(), true))


func _on_dialogue_voice_finished_dispatch_started() -> void:
	var owned_frame := _mark_owned_dialogue_event_dispatch(
		&"dialogue_voice_finished", [])
	if owned_frame.is_empty():
		dialogue_voice_playback_event.emit(
			DialogueVoicePlaybackEvent.finished(Callable(), true))


func _on_show_dialogue_dispatch_started(
	character: String,
	segments: Array,
	mode: String,
) -> void:
	_show_dialogue_dispatch_serial += 1
	var expected_wrapper := false
	if not _dialogue_presentation_stack.is_empty():
		var frame: Dictionary = _dialogue_presentation_stack[-1]
		expected_wrapper = (
			int(frame.get("dispatch_serial", -1)) == _show_dialogue_dispatch_serial
			and is_same(frame.get("segments"), segments)
		)
	if not expected_wrapper:
		_last_raw_show_dispatch_serial = _show_dialogue_dispatch_serial
		_last_raw_show_segments = segments
		# A direct legacy emit is translated once at the boundary. It carries no
		# sidecar profile/provenance and cannot mutate an in-flight canonical request.
		# It still needs a dispatch identity so Backlog enrichment and consecutive
		# programmatic dialogues never collapse into the same command:-1 row.
		_dialogue_request_serial += 1
		dialogue_requested.emit(DialogueRequest.new(
			character,
			segments,
			mode,
			{},
			false,
			"",
			{},
			[],
			"signal-bus:%d" % _dialogue_request_serial,
			-1,
		))


func _on_advance_requested_dispatch_started() -> void:
	_advance_dispatch_serial += 1
	advance_dispatch_started.emit(_advance_dispatch_serial)


## Returns the presentation metadata belonging to `segments`. Passing the
## callback payload makes nested raw `show_dialogue.emit()` calls unambiguous:
## they have no wrapper frame and therefore receive legacy empty metadata.
## The no-argument form is retained for extensions and is deliberately
## conservative after a nested raw dispatch rather than returning stale data.
func current_dialogue_metadata(segments: Variant = null) -> Dictionary:
	var frame := _current_dialogue_presentation_frame(segments)
	if frame.is_empty():
		return {}
	return {
		"profile": frame["profile"].duplicate(true),
		"declarative": bool(frame["declarative"]),
		"nvl_page_key": String(frame["nvl_page_key"]),
		"nvl_page_entries": frame["nvl_page_entries"].duplicate(true),
		"provenance": frame["provenance"].duplicate(true),
	}


func current_dialogue_presentation_profile(segments: Variant = null) -> Dictionary:
	var metadata := current_dialogue_metadata(segments)
	return metadata.get("profile", {})


func current_dialogue_uses_declarative_presentation(segments: Variant = null) -> bool:
	return bool(current_dialogue_metadata(segments).get("declarative", false))


func current_dialogue_nvl_page_key(segments: Variant = null) -> String:
	return String(current_dialogue_metadata(segments).get("nvl_page_key", ""))


## Runtime-only authoring location for the active STLA Profile. Like the
## profile itself, this is available only during synchronous show dispatch.
func current_dialogue_presentation_provenance(segments: Variant = null) -> Dictionary:
	return current_dialogue_metadata(segments).get("provenance", {})


func _current_dialogue_presentation_frame(segments: Variant) -> Dictionary:
	if _dialogue_presentation_stack.is_empty():
		return {}
	if segments != null:
		# A raw nested emit can deliberately reuse the outer payload verbatim. It
		# is indistinguishable by value, so prefer empty legacy metadata over
		# attributing an authoring warning to the wrong dispatch. Outer listeners
		# after such an emit are likewise conservative and receive no sidecar.
		if _last_raw_show_dispatch_serial == _show_dialogue_dispatch_serial \
			and is_same(_last_raw_show_segments, segments):
			return {}
		for index in range(_dialogue_presentation_stack.size() - 1, -1, -1):
			var frame: Dictionary = _dialogue_presentation_stack[index]
			if is_same(frame.get("segments"), segments):
				return frame
		return {}
	var latest: Dictionary = _dialogue_presentation_stack[-1]
	if int(latest.get("dispatch_serial", -1)) != _show_dialogue_dispatch_serial:
		return {}
	return latest

# Background
signal bg_changed(asset: String, transition: String, duration: float)

# Generic named stage layers
## operations: Array of {action, id, properties, transition, duration}.
## force_cut is used when skipping to a dialogue's final authored checkpoint;
## presenters reduce the whole batch before touching resources.
signal stage_operations_requested(operations: Array, force_cut: bool)
## Internal request lifecycle notification used by async dialogue playback.
## delivered=false means validation, cancellation, or a visual reset revoked it.
signal stage_operation_request_finished(request_id: int, delivered: bool)
## Hard reset notification for the complete StagePresenter projection. Call it
## through reset_stage_visuals(), which also invalidates authored operations.
signal stage_visuals_reset_requested()
## Visual-only projection used by save/load and rollback. PresentationState
## deliberately does not consume this signal. This replaces all named layers.
signal stage_state_apply_requested(layers: Dictionary)
## A presenter acknowledges each transition it actually starts. The token is
## globally monotonic, so callers can later finish exactly that transition
## without cancelling a newer tween that happens to reuse the same layer id.
signal stage_transition_started(
	presenter_instance_id: int,
	layer_id: String,
	token: int,
	operation_request_id: int,
)
## Visual-only completion for transition records previously acknowledged by
## stage_transition_started. Each record contains presenter_instance_id,
## layer_id, and token; stale or foreign records are ignored by presenters.
signal stage_transitions_finish_requested(transitions: Array)

var _stage_operation_queue: Array[Dictionary] = []
var _stage_operation_dispatching := false
var _stage_operation_dispatch_stack: Array[int] = []
var _stage_operation_epoch_stack: Array[int] = []
var _next_stage_operation_request_id := 1
var _stage_operation_epoch := 1


## Allocate an identity before submission when a caller needs to own the exact
## transitions caused by its batch. Most callers can omit this and let
## emit_stage_operations allocate an anonymous identity.
func reserve_stage_operation_request_id() -> int:
	var request_id := _next_stage_operation_request_id
	_next_stage_operation_request_id += 1
	return request_id


func current_stage_operation_request_id() -> int:
	if _stage_operation_dispatch_stack.is_empty():
		return 0
	return _stage_operation_dispatch_stack.back()


func is_current_stage_operation_valid() -> bool:
	if _stage_operation_epoch_stack.is_empty():
		return true
	return _stage_operation_epoch_stack.back() == _stage_operation_epoch


func is_stage_operation_request_active(request_id: int) -> bool:
	if request_id in _stage_operation_dispatch_stack:
		return true
	for request in _stage_operation_queue:
		if int(request.get("request_id", 0)) == request_id:
			return true
	return false


## Cancel a request that has been queued behind the batch currently being
## delivered. A request already in delivery cannot be revoked.
func cancel_stage_operation_request(request_id: int) -> bool:
	for index in range(_stage_operation_queue.size()):
		if int(_stage_operation_queue[index].get("request_id", 0)) == request_id:
			_stage_operation_queue.remove_at(index)
			stage_operation_request_finished.emit(request_id, false)
			return true
	return false


## Revoke every queued batch and invalidate the batch currently being delivered.
## State and visual consumers both consult the same epoch, preventing a reset
## listener between them from leaving one side with stale authored state.
func reset_stage_visuals() -> void:
	_stage_operation_epoch += 1
	var cancelled_requests := _stage_operation_queue.duplicate(true)
	_stage_operation_queue.clear()
	for request in cancelled_requests:
		stage_operation_request_finished.emit(
			int(request.get("request_id", 0)),
			false,
		)
	stage_visuals_reset_requested.emit()


## Serialize authored stage mutations before delivering them to state trackers
## and presenters. A listener may request another batch synchronously; that
## batch is delivered only after every listener has consumed the current one,
## so canonical save state and visible state cannot observe different orders.
func emit_stage_operations(
	operations: Array,
	force_cut: bool = false,
	request_id: int = 0,
	on_dispatch_started: Callable = Callable(),
) -> int:
	if request_id <= 0:
		request_id = reserve_stage_operation_request_id()
	for operation in operations:
		if not StageLayerState.validate_operation(operation, true):
			push_warning(
				"SignalBus: rejected invalid stage operation batch %d" % request_id
			)
			stage_operation_request_finished.emit(request_id, false)
			return request_id
	_stage_operation_queue.append({
		"operations": operations.duplicate(true),
		"force_cut": force_cut,
		"request_id": request_id,
		"epoch": _stage_operation_epoch,
		"on_dispatch_started": on_dispatch_started,
	})
	if _stage_operation_dispatching:
		return request_id

	_stage_operation_dispatching = true
	while not _stage_operation_queue.is_empty():
		var request: Dictionary = _stage_operation_queue.pop_front()
		var dispatched_request_id := int(request.get("request_id", 0))
		var request_epoch := int(request.get("epoch", 0))
		_stage_operation_dispatch_stack.append(dispatched_request_id)
		_stage_operation_epoch_stack.append(request_epoch)
		var dispatch_callback: Callable = request.get(
			"on_dispatch_started", Callable()
		)
		if request_epoch == _stage_operation_epoch and dispatch_callback.is_valid():
			dispatch_callback.call()
		stage_operations_requested.emit(
			(request.get("operations", []) as Array).duplicate(true),
			bool(request.get("force_cut", false)),
		)
		_stage_operation_dispatch_stack.pop_back()
		_stage_operation_epoch_stack.pop_back()
		stage_operation_request_finished.emit(
			dispatched_request_id,
			request_epoch == _stage_operation_epoch,
		)
	_stage_operation_dispatching = false
	return request_id

# Audio
signal bgm_play(asset: String, fade_duration: float)
signal bgm_stop(fade_duration: float)
signal se_play(asset: String, loop: bool)
signal se_stop(asset: String)
signal voice_play(asset: String, character: String)
signal voice_playback_requested(request: VoicePlaybackRequest)
signal voice_playback_event(event: VoicePlaybackEvent)
signal dialogue_voice_playback_event(event: DialogueVoicePlaybackEvent)
signal system_se_play(asset: String)
signal voice_started(character: String, asset: String)
signal voice_finished()
signal voice_progress(position: float, duration: float)

## High-level dialogue voice signals — emitted by DialoguePresenter so that
## a @combine block (or any dialogue with multiple segment voices) is treated
## as one logical playback for UI purposes (e.g. a single continuous progress
## bar instead of one bar per segment). For a normal single-voice dialogue
## these mirror voice_started / voice_progress / voice_finished 1:1.
signal dialogue_voice_started(total_duration: float)
signal dialogue_voice_progress(position: float, total_duration: float)
signal dialogue_voice_finished()

## Request that DialoguePresenter replay an arbitrary list of voice assets as
## one logical dialogue (uses the same voice queue + progress bar machinery as
## the in-game replay button). Used by the backlog screen so that:
##   - the progress bar reflects the full combined duration
##   - playback state lives in the always-present DialoguePresenter, so closing
##     the backlog overlay does NOT cancel the audio
##   - advancing to the next in-game dialogue cleanly cancels any in-flight
##     replay via the same _dialogue_gen mechanism
signal dialogue_voice_replay_requested(voices: Array, character: String)

# Choice
signal choice_show(prompt: String, options: Array)
signal choice_selected(option_id: String)

# Effects
signal effect_requested(effect_type: String, params: Dictionary)
signal fade_requested(direction: String, duration: float)

# System
signal scenario_started_event(scenario_id: String)
signal scenario_ended_event(scenario_id: String)
signal scene_changed_event(scene_id: String)
signal variable_changed(var_name: String, value: Variant)
signal settings_changed(key: String, value: Variant)

## Engine abort signal — fired by the runtime when the currently running
## scenario coroutine must be cancelled (e.g. backlog jump replaces the
## ScenarioContext under the engine and needs the in-flight handler to
## return promptly so the new context can take over).
##
## All blocking handlers (dialogue/wait/choice/etc.) should race their
## native await against this signal via CommandHandler.await_with_abort
## and return early when it fires.
signal engine_abort_requested()
