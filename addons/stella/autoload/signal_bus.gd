## Global signal bus for decoupling Core and Presentation layers.
## Registered as an Autoload singleton.
extends Node

const ChapterIndicatorRequest = preload(
	"res://addons/stella/core/data/chapter_indicator_request.gd")
const DialogueClearOperationRequest = preload(
	"res://addons/stella/core/data/dialogue_clear_operation_request.gd")
const DialogueAvatarOperationRequest = preload(
	"res://addons/stella/core/data/dialogue_avatar_operation_request.gd")
const LoopSeOperationRequestType = preload(
	"res://addons/stella/core/data/loop_se_operation_request.gd")
const LoopSeStateCaptureRequestType = preload(
	"res://addons/stella/core/data/loop_se_state_capture_request.gd")
const BgmOperationRequestType = preload(
	"res://addons/stella/core/data/bgm_operation_request.gd")
const BgmStateCaptureRequestType = preload(
	"res://addons/stella/core/data/bgm_state_capture_request.gd")

# Dialogue
## Canonical internal request. Core and built-in presenters consume this typed,
## self-contained payload; show_dialogue below remains the extension adapter.
signal dialogue_requested(request: DialogueRequest)
## Core emits this only after the owning DialogueHandler has committed the
## activation. Built-in presentation validates the id before retiring UI state.
signal dialogue_advance_committed(activation_id: int)
## Presentation may enrich the current typed request with the names of active
## custom RichTextEffects. Runtime already stored the canonical entry directly;
## this value-only event lets it recompute that same entry without retaining a
## callback or depending on a concrete Presenter node.
signal dialogue_backlog_effects_resolved(request: DialogueRequest, effect_names: Array)
## Unified dialogue signal — both normal and @combine dialogues flow through here.
## segments: Array of {text: String, voice: String, presentation_ops: Array}
## A normal single-line dialogue has segments.size() == 1. A @combine block has
## multiple segments; voices and typed Stage/avatar cues advance at segment boundaries.
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
var _owned_dialogue_advance_echo_pending: int = 0
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
var _current_chapter_event_stack: Array[Dictionary] = []


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
	current_chapter_changed.connect(_on_current_chapter_dispatch_started)


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
	# Built-in state observes an immutable snapshot before the mutable public
	# compatibility signal is delivered to extensions.
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


## Publish presentation completion only after Core has validated ownership and
## committed durable read state. The typed event preserves the exact owner;
## advance_requested remains a notification for extensions and AudioPresenter.
func emit_dialogue_advance_committed(activation: DialogueActivation) -> bool:
	if (
		activation == null
		or activation.get_outcome() != DialogueActivation.Outcome.ADVANCED
	):
		return false
	dialogue_advance_committed.emit(activation.get_instance_id())
	_owned_dialogue_advance_echo_pending += 1
	advance_requested.emit()
	return true


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
	dsp_preset: String = "",
	source: Dictionary = {},
) -> VoicePlaybackResponse:
	var request := VoicePlaybackRequest.new(
		asset, character, owner_validator, dsp_preset, source)
	return _dispatch_voice_playback_request(
		request, emit_compatibility_signal)


## Canonical ordered multi-layer request. One accepted response/token owns the
## whole simultaneous group; physical layer lifecycle remains typed-only.
func request_voice_layers(
	layers: Variant,
	owner_validator: Callable = Callable(),
) -> VoicePlaybackResponse:
	var request := VoicePlaybackRequest.from_layers(layers, owner_validator)
	# The long-standing single-voice signal remains a read-only notification for
	# a one-member canonical group. A simultaneous group has no lossless raw view;
	# consumers use VoicePlaybackRequest/Event and their stable layer identities.
	var emit_single_notification := (
		request.is_valid() and request.get_layers().size() == 1)
	return _dispatch_voice_playback_request(request, emit_single_notification)


func _dispatch_voice_playback_request(
	request: VoicePlaybackRequest,
	emit_compatibility_signal: bool,
) -> VoicePlaybackResponse:
	var response := VoicePlaybackResponse.new()
	if request == null or not request.is_valid():
		var detail := (
			request.get_validation_error()
			if request != null
			else "request is null"
		)
		push_error("SignalBus: invalid voice playback request: %s" % detail)
		response._resolve(false)
		return response
	if _runtime_audio_shutdown_started:
		response._resolve(false)
		return response
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
		voice_play.emit(request.get_asset(), request.get_character())
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
	if not event.should_emit_compatibility_notification():
		return event.is_current()
	_compatibility_voice_lifecycle_echo_pending += 1
	match kind:
		VoicePlaybackEvent.Kind.STARTED:
			voice_started.emit(event.get_character(), event.get_asset())
		VoicePlaybackEvent.Kind.PROGRESS:
			voice_progress.emit(event.get_position(), event.get_duration())
		VoicePlaybackEvent.Kind.FINISHED:
			voice_finished.emit()
		VoicePlaybackEvent.Kind.LAYER_FINISHED:
			pass
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
	if _owned_dialogue_advance_echo_pending > 0:
		_owned_dialogue_advance_echo_pending -= 1
		return
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
## operations: canonical Stage payloads. Public raw programmatic callers use
## this notification; authored DSL goes through the typed participant gate.
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
## Internal exact-receipt side channel. The public four-argument started signal
## remains source compatible; the Director consumes this identity carrying the
## Presenter-owned per-layer generation.
signal stage_transition_receipt_started(
	presenter_instance_id: int,
	layer_id: String,
	token: int,
	operation_request_id: int,
	generation: int,
)
## Exact terminal acknowledgement for one started Stage transition. Outcome is
## one of completed, superseded, or cancelled. The operation request id and
## globally monotonic token prevent a retired presenter/layer from satisfying a
## later batch that happens to reuse the same channel.
signal stage_transition_terminal(
	presenter_instance_id: int,
	layer_id: String,
	token: int,
	operation_request_id: int,
	generation: int,
	outcome: StringName,
)
## Visual-only completion for transition records previously acknowledged by
## stage_transition_started. Each record contains presenter_instance_id,
## layer_id, and token; stale or foreign records are ignored by presenters.
signal stage_transitions_finish_requested(transitions: Array)
## Strict issue #164 receipt completion channel. Every record contains the
## exact presenter, layer, token, operation request, and Presenter-owned
## generation identity. Legacy three-field completion remains above.
signal stage_transition_receipts_finish_requested(transitions: Array)
## Typed, source-located Stage participant gate. A contiguous run is validated
## and accepted by every Runtime-owned StagePresenter before any mixed-batch
## child mutates presentation state.
signal stage_validate_requested(request: StageOperationRequest)
signal stage_accept_requested(request: StageOperationRequest)
signal stage_apply_readiness_requested(request: StageOperationRequest)
signal stage_apply_requested(request: StageOperationRequest)

var _dispatching_stage_request: StageOperationRequest
var _applying_stage_request: StageOperationRequest
var _stage_participant_authority := RefCounted.new()
var _stage_registrar_authority: Object
var _stage_participants: Dictionary = {}


func configure_stage_registrar(authority: Object) -> bool:
	if authority == null:
		return false
	if _stage_registrar_authority == null:
		_stage_registrar_authority = authority
	return _stage_registrar_authority == authority


func register_stage_presenter(
	presenter: Object,
	registrar_authority: Object,
	transaction: Callable,
) -> RefCounted:
	if (
		registrar_authority != _stage_registrar_authority
		or presenter == null
		or not is_instance_valid(presenter)
		or not presenter is Node
		or (presenter as Node).is_queued_for_deletion()
		or not transaction.is_valid()
		or transaction.get_object() != presenter
	):
		return null
	var presenter_id := presenter.get_instance_id()
	var existing: Dictionary = _stage_participants.get(presenter_id, {})
	if not existing.is_empty():
		var weak_existing: WeakRef = existing.get("presenter")
		if weak_existing != null and weak_existing.get_ref() == presenter:
			return existing.get("capability") as RefCounted
	var capability := RefCounted.new()
	_stage_participants[presenter_id] = {
		"presenter": weakref(presenter),
		"capability": capability,
		"transaction": transaction,
	}
	return capability


func unregister_stage_presenter(
	presenter: Object,
	capability: RefCounted,
	registrar_authority: Object,
) -> void:
	if registrar_authority != _stage_registrar_authority:
		return
	if _stage_participant_is_current(presenter, capability):
		_stage_participants.erase(presenter.get_instance_id())


func reject_stage_request(
	request: StageOperationRequest,
	presenter: Object,
	capability: RefCounted,
	operation_index: int,
	error: String,
) -> bool:
	if not _stage_request_target_is_current(request, presenter, capability, false):
		return false
	return request._reject(operation_index, error, _stage_participant_authority)


func validate_stage_request(
	request: StageOperationRequest,
	presenter: Object,
	capability: RefCounted,
	plan: Dictionary,
) -> bool:
	if not _stage_request_target_is_current(request, presenter, capability, false):
		return false
	return request._validate(presenter, plan, _stage_participant_authority)


func accept_stage_request(
	request: StageOperationRequest,
	presenter: Object,
	capability: RefCounted,
) -> bool:
	if not _stage_request_target_is_current(request, presenter, capability, false):
		return false
	return request._accept(presenter, _stage_participant_authority)


func acknowledge_stage_apply(
	request: StageOperationRequest,
	presenter: Object,
	capability: RefCounted,
) -> bool:
	if not _stage_request_target_is_current(request, presenter, capability, true):
		return false
	return request._apply(presenter, _stage_participant_authority)


func mark_stage_apply_ready(
	request: StageOperationRequest,
	presenter: Object,
	capability: RefCounted,
) -> bool:
	if not _stage_request_target_is_current(request, presenter, capability, true):
		return false
	return request._mark_apply_ready(presenter, _stage_participant_authority)


func mark_stage_apply_claimed(
	request: StageOperationRequest,
	presenter: Object,
	capability: RefCounted,
) -> bool:
	if not _stage_request_target_is_current(request, presenter, capability, true):
		return false
	return request._mark_apply_claimed(presenter, _stage_participant_authority)


func fail_stage_apply(
	request: StageOperationRequest,
	presenter: Object,
	capability: RefCounted,
	operation_index: int,
	error: String,
) -> bool:
	if not _stage_request_target_is_current(request, presenter, capability, true):
		return false
	return request._fail_apply(
		presenter,
		operation_index,
		error,
		_stage_participant_authority,
	)


func _stage_request_target_is_current(
	request: StageOperationRequest,
	presenter: Object,
	capability: RefCounted,
	applying: bool,
) -> bool:
	return (
		request != null
		and request == (
			_applying_stage_request if applying else _dispatching_stage_request)
		and _stage_participant_is_current(presenter, capability)
		and request.is_target(presenter)
	)


func _stage_participant_is_current(
	presenter: Object,
	capability: Object,
) -> bool:
	if (
		presenter == null
		or capability == null
		or not is_instance_valid(presenter)
		or not presenter is Node
		or (presenter as Node).is_queued_for_deletion()
	):
		return false
	var entry: Dictionary = _stage_participants.get(presenter.get_instance_id(), {})
	if entry.is_empty() or entry.get("capability") != capability:
		return false
	var weak_presenter: WeakRef = entry.get("presenter")
	return weak_presenter != null and weak_presenter.get_ref() == presenter


func _stage_participant_snapshot() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for presenter_id: int in _stage_participants.keys():
		var entry: Dictionary = _stage_participants[presenter_id]
		var weak_presenter: WeakRef = entry.get("presenter")
		var presenter: Object = weak_presenter.get_ref() if weak_presenter != null else null
		var capability: Object = entry.get("capability")
		if not _stage_participant_is_current(presenter, capability):
			_stage_participants.erase(presenter_id)
			continue
		result.append({
			"presenter": presenter,
			"capability": capability,
			"transaction": entry.get("transaction", Callable()),
		})
	return result


func _commit_stage_request(request: StageOperationRequest) -> bool:
	if request == null or request != _applying_stage_request:
		return false
	var participants := request._get_transaction_participants(
		_stage_participant_authority)
	var held: Array[Dictionary] = []
	for participant: Dictionary in participants:
		var transaction: Callable = participant.get("transaction", Callable())
		if (
			not transaction.is_valid()
			or not bool(transaction.call(
				request, participant.get("capability"), &"hold"))
		):
			_abort_stage_request_transaction(request, held)
			return false
		held.append(participant)
	for participant: Dictionary in participants:
		var transaction: Callable = participant.get("transaction")
		if not bool(transaction.call(
			request, participant.get("capability"), &"commit")):
			_abort_stage_request_transaction(request, held)
			return false
	if not request.all_presenters_applied():
		_abort_stage_request_transaction(request, held)
		return false
	return true


func _publish_stage_request(
	request: StageOperationRequest,
	expected_epoch: int,
) -> bool:
	if request == null or request != _applying_stage_request:
		return false
	var participants := request._get_transaction_participants(
		_stage_participant_authority)
	for participant: Dictionary in participants:
		if (
			request != _applying_stage_request
			or expected_epoch != _stage_operation_epoch
			or not request.presenters_are_live()
		):
			_abort_stage_request_transaction(request, participants)
			return false
		var transaction: Callable = participant.get(
			"transaction", Callable())
		if (
			not transaction.is_valid()
			or not bool(transaction.call(
				request, participant.get("capability"), &"publish"))
		):
			_abort_stage_request_transaction(request, participants)
			return false
		if (
			request != _applying_stage_request
			or expected_epoch != _stage_operation_epoch
			or not request.presenters_are_live()
		):
			_abort_stage_request_transaction(request, participants)
			return false
	return true


func _abort_stage_request_transaction(
	request: StageOperationRequest,
	participants: Array[Dictionary] = [],
) -> void:
	var targets := participants
	if targets.is_empty() and request != null:
		targets = request._get_transaction_participants(
			_stage_participant_authority)
	for participant: Dictionary in targets:
		var transaction: Callable = participant.get(
			"transaction", Callable())
		if transaction.is_valid():
			transaction.call(
				request, participant.get("capability"), &"abort")

signal dialogue_visibility_operations_requested(operations: Array, force_cut: bool)
signal presentation_operation_request_finished(request_id: int, delivered: bool)
signal presentation_projection_lifecycle_finished(lifecycle_id: int)
signal dialogue_visibility_visuals_reset_requested()
signal dialogue_visibility_state_apply_requested(
	visibility: Dictionary,
	content: Dictionary,
	runtime_binding: Dictionary,
)
## Content-only cut projection for Director rollback. It preserves all
## dialogue-visibility transition ownership and canonical gate state.
signal dialogue_content_state_apply_requested(
	content: Dictionary,
	runtime_binding: Dictionary,
)
## Target-scoped cut projection used by Director failure rollback. Unlike a
## save/load restore, it does not rebuild dialogue content or runtime binding.
signal dialogue_visibility_targets_state_apply_requested(
	visibility: Dictionary,
	targets: Array,
)
signal dialogue_visibility_transition_receipt_started(
	presenter_instance_id: int,
	target: String,
	token: int,
	operation_request_id: int,
	generation: int,
)
signal dialogue_visibility_transition_terminal(
	presenter_instance_id: int,
	target: String,
	token: int,
	operation_request_id: int,
	generation: int,
	outcome: StringName,
)
signal dialogue_visibility_transition_receipts_finish_requested(transitions: Array)
## Canonical page-content clear is a synchronous typed participant transaction,
## independent from visibility and the selected ADV/NVL profile. A clear never
## creates a transition receipt or wall-clock owner.
signal dialogue_clear_validate_requested(request: DialogueClearOperationRequest)
signal dialogue_clear_accept_requested(request: DialogueClearOperationRequest)
signal dialogue_clear_apply_requested(request: DialogueClearOperationRequest)

var _dispatching_dialogue_clear_request: DialogueClearOperationRequest
var _applying_dialogue_clear_request: DialogueClearOperationRequest
var _dialogue_clear_participant_authority := RefCounted.new()
var _dialogue_clear_registrar_authority: Object
var _dialogue_clear_participants: Dictionary = {}


func configure_dialogue_clear_registrar(authority: Object) -> bool:
	if authority == null:
		return false
	if _dialogue_clear_registrar_authority == null:
		_dialogue_clear_registrar_authority = authority
	return _dialogue_clear_registrar_authority == authority


func register_dialogue_clear_presenter(
	presenter: Object,
	registrar_authority: Object,
) -> RefCounted:
	if (
		registrar_authority != _dialogue_clear_registrar_authority
		or presenter == null
		or not is_instance_valid(presenter)
		or not presenter is Node
		or (presenter as Node).is_queued_for_deletion()
	):
		return null
	var presenter_id := presenter.get_instance_id()
	var existing: Dictionary = _dialogue_clear_participants.get(presenter_id, {})
	if not existing.is_empty():
		var existing_presenter: Object = (
			(existing.get("presenter") as WeakRef).get_ref())
		if existing_presenter == presenter:
			return existing.get("capability") as RefCounted
	var capability := RefCounted.new()
	_dialogue_clear_participants[presenter_id] = {
		"presenter": weakref(presenter),
		"capability": capability,
	}
	return capability


func unregister_dialogue_clear_presenter(
	presenter: Object,
	capability: RefCounted,
	registrar_authority: Object,
) -> void:
	if (
		registrar_authority != _dialogue_clear_registrar_authority
		or presenter == null
		or not is_instance_valid(presenter)
	):
		return
	if _dialogue_clear_participant_is_current(presenter, capability):
		_dialogue_clear_participants.erase(presenter.get_instance_id())


func reject_dialogue_clear_request(
	request: DialogueClearOperationRequest,
	presenter: Object,
	capability: RefCounted,
	error: String,
) -> bool:
	if not _dialogue_clear_request_target_is_current(
		request, presenter, capability, false):
		return false
	return request._reject(error, _dialogue_clear_participant_authority)


func validate_dialogue_clear_request(
	request: DialogueClearOperationRequest,
	presenter: Object,
	capability: RefCounted,
) -> bool:
	if not _dialogue_clear_request_target_is_current(
		request, presenter, capability, false):
		return false
	return request._validate(presenter, _dialogue_clear_participant_authority)


func accept_dialogue_clear_request(
	request: DialogueClearOperationRequest,
	presenter: Object,
	capability: RefCounted,
) -> bool:
	if not _dialogue_clear_request_target_is_current(
		request, presenter, capability, false):
		return false
	return request._accept(presenter, _dialogue_clear_participant_authority)


func acknowledge_dialogue_clear_apply(
	request: DialogueClearOperationRequest,
	presenter: Object,
	capability: RefCounted,
) -> bool:
	if not _dialogue_clear_request_target_is_current(
		request, presenter, capability, true):
		return false
	return request._apply(presenter, _dialogue_clear_participant_authority)


func _dialogue_clear_request_target_is_current(
	request: DialogueClearOperationRequest,
	presenter: Object,
	capability: RefCounted,
	applying: bool,
) -> bool:
	return (
		request != null
		and request == (
			_applying_dialogue_clear_request
			if applying else _dispatching_dialogue_clear_request)
		and _dialogue_clear_participant_is_current(presenter, capability)
		and request.is_target(presenter)
	)


func _dialogue_clear_participant_is_current(
	presenter: Object,
	capability: Object,
) -> bool:
	if (
		presenter == null
		or capability == null
		or not is_instance_valid(presenter)
		or not presenter is Node
		or (presenter as Node).is_queued_for_deletion()
	):
		return false
	var entry: Dictionary = _dialogue_clear_participants.get(
		presenter.get_instance_id(), {})
	if entry.is_empty() or entry.get("capability") != capability:
		return false
	var registered: Object = (entry.get("presenter") as WeakRef).get_ref()
	return registered == presenter


func _dialogue_clear_participant_snapshot() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for presenter_id: int in _dialogue_clear_participants.keys():
		var entry: Dictionary = _dialogue_clear_participants[presenter_id]
		var weak_presenter: WeakRef = entry.get("presenter")
		var presenter: Object = (
			weak_presenter.get_ref() if weak_presenter != null else null)
		var capability: Object = entry.get("capability")
		if not _dialogue_clear_participant_is_current(presenter, capability):
			_dialogue_clear_participants.erase(presenter_id)
			continue
		result.append({
			"presenter": presenter,
			"capability": capability,
		})
	return result

# Addressable dialogue-avatar presentation
signal dialogue_avatar_validate_requested(request: DialogueAvatarOperationRequest)
signal dialogue_avatar_accept_requested(request: DialogueAvatarOperationRequest)
signal dialogue_avatar_apply_readiness_requested(request: DialogueAvatarOperationRequest)
signal dialogue_avatar_apply_requested(request: DialogueAvatarOperationRequest)
signal dialogue_avatar_operation_committed(
	operation: DialogueAvatarPresentationOperation)
signal dialogue_avatar_presenter_registered()
signal dialogue_avatar_visuals_reset_requested(epoch: int)
signal dialogue_avatar_state_apply_requested(state: Dictionary, epoch: int)
signal dialogue_avatar_transition_receipt_started(
	presenter_instance_id: int,
	token: int,
	operation_request_id: int,
	generation: int,
)
signal dialogue_avatar_transition_terminal(
	presenter_instance_id: int,
	token: int,
	operation_request_id: int,
	generation: int,
	outcome: StringName,
)
signal dialogue_avatar_transition_receipts_finish_requested(transitions: Array)

var _dispatching_dialogue_avatar_request: DialogueAvatarOperationRequest
var _applying_dialogue_avatar_request: DialogueAvatarOperationRequest
var _dialogue_avatar_participant_authority := RefCounted.new()
var _dialogue_avatar_registrar_authority: Object
var _dialogue_avatar_participants: Dictionary = {}
var _dialogue_avatar_epoch: int = 0
var _dialogue_avatar_epoch_stack: Array[int] = []


func configure_dialogue_avatar_registrar(authority: Object) -> bool:
	if authority == null:
		return false
	if _dialogue_avatar_registrar_authority == null:
		_dialogue_avatar_registrar_authority = authority
	return _dialogue_avatar_registrar_authority == authority


func register_dialogue_avatar_presenter(
	presenter: Object,
	registrar_authority: Object,
) -> RefCounted:
	if (
		registrar_authority != _dialogue_avatar_registrar_authority
		or presenter == null
		or not is_instance_valid(presenter)
		or not presenter is Node
		or (presenter as Node).is_queued_for_deletion()
	):
		return null
	var presenter_id := presenter.get_instance_id()
	var existing: Dictionary = _dialogue_avatar_participants.get(presenter_id, {})
	if not existing.is_empty():
		var existing_presenter: Object = (
			(existing.get("presenter") as WeakRef).get_ref())
		if existing_presenter == presenter:
			return existing.get("capability") as RefCounted
	var capability := RefCounted.new()
	_dialogue_avatar_participants[presenter_id] = {
		"presenter": weakref(presenter),
		"capability": capability,
	}
	dialogue_avatar_presenter_registered.emit()
	return capability


func unregister_dialogue_avatar_presenter(
	presenter: Object,
	capability: RefCounted,
	registrar_authority: Object,
) -> void:
	if (
		registrar_authority != _dialogue_avatar_registrar_authority
		or presenter == null
		or not is_instance_valid(presenter)
	):
		return
	if _dialogue_avatar_participant_is_current(presenter, capability):
		_dialogue_avatar_participants.erase(presenter.get_instance_id())


func reject_dialogue_avatar_request(
	request: DialogueAvatarOperationRequest,
	presenter: Object,
	capability: RefCounted,
	error: String,
) -> bool:
	if not _dialogue_avatar_request_target_is_current(
		request, presenter, capability, false):
		return false
	return request._reject(error, _dialogue_avatar_participant_authority)


func validate_dialogue_avatar_request(
	request: DialogueAvatarOperationRequest,
	presenter: Object,
	capability: RefCounted,
) -> bool:
	if not _dialogue_avatar_request_target_is_current(
		request, presenter, capability, false):
		return false
	return request._validate(presenter, _dialogue_avatar_participant_authority)


func accept_dialogue_avatar_request(
	request: DialogueAvatarOperationRequest,
	presenter: Object,
	capability: RefCounted,
) -> bool:
	if not _dialogue_avatar_request_target_is_current(
		request, presenter, capability, false):
		return false
	return request._accept(presenter, _dialogue_avatar_participant_authority)


func mark_dialogue_avatar_apply_ready(
	request: DialogueAvatarOperationRequest,
	presenter: Object,
	capability: RefCounted,
) -> bool:
	if not _dialogue_avatar_request_target_is_current(
		request, presenter, capability, true):
		return false
	return request._ready(presenter, _dialogue_avatar_participant_authority)


func acknowledge_dialogue_avatar_apply(
	request: DialogueAvatarOperationRequest,
	presenter: Object,
	capability: RefCounted,
) -> bool:
	if not _dialogue_avatar_request_target_is_current(
		request, presenter, capability, true):
		return false
	return request._apply(presenter, _dialogue_avatar_participant_authority)


func _dialogue_avatar_request_target_is_current(
	request: DialogueAvatarOperationRequest,
	presenter: Object,
	capability: RefCounted,
	applying: bool,
) -> bool:
	return (
		request != null
		and request == (
			_applying_dialogue_avatar_request
			if applying else _dispatching_dialogue_avatar_request)
		and _dialogue_avatar_participant_is_current(presenter, capability)
		and request.is_target(presenter)
	)


func _dialogue_avatar_participant_is_current(
	presenter: Object,
	capability: Object,
) -> bool:
	if (
		presenter == null
		or capability == null
		or not is_instance_valid(presenter)
		or not presenter is Node
		or (presenter as Node).is_queued_for_deletion()
	):
		return false
	var entry: Dictionary = _dialogue_avatar_participants.get(
		presenter.get_instance_id(), {})
	if entry.is_empty() or entry.get("capability") != capability:
		return false
	return (entry.get("presenter") as WeakRef).get_ref() == presenter


func _dialogue_avatar_participant_snapshot() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for presenter_id: int in _dialogue_avatar_participants.keys():
		var entry: Dictionary = _dialogue_avatar_participants[presenter_id]
		var weak_presenter: WeakRef = entry.get("presenter")
		var presenter: Object = (
			weak_presenter.get_ref() if weak_presenter != null else null)
		var capability: Object = entry.get("capability")
		if not _dialogue_avatar_participant_is_current(presenter, capability):
			_dialogue_avatar_participants.erase(presenter_id)
			continue
		result.append({"presenter": presenter, "capability": capability})
	return result


func current_dialogue_avatar_epoch() -> int:
	return _dialogue_avatar_epoch


func is_current_dialogue_avatar_operation_valid() -> bool:
	return (
		_dialogue_avatar_epoch_stack.is_empty()
		or _dialogue_avatar_epoch_stack.back() == _dialogue_avatar_epoch
	)


func reset_dialogue_avatar_visuals() -> void:
	_reset_dialogue_avatar_projection(DialogueAvatarState.default_state(), false)


func reset_and_apply_dialogue_avatar_state(state: Dictionary) -> void:
	_reset_dialogue_avatar_projection(state.duplicate(true), true)


func _reset_dialogue_avatar_projection(state: Dictionary, apply_state: bool) -> void:
	_mark_presentation_projection_retirement_started()
	_dialogue_avatar_epoch += 1
	var reset_epoch := _dialogue_avatar_epoch
	var retained: Array[Dictionary] = []
	var cancelled: Array[Dictionary] = []
	for request: Dictionary in _presentation_operation_queue:
		if _request_belongs_to_retained_projection(request):
			request["avatar_epoch"] = reset_epoch
			retained.append(request)
			continue
		var has_avatar := false
		for operation_value: Variant in request.get("operations", []):
			if operation_value is DialogueAvatarPresentationOperation:
				has_avatar = true
				break
		if has_avatar:
			cancelled.append(request)
		else:
			retained.append(request)
	_presentation_operation_queue = retained
	for request: Dictionary in cancelled:
		presentation_operation_request_finished.emit(
			int(request.get("request_id", 0)), false)
	dialogue_avatar_visuals_reset_requested.emit(reset_epoch)
	if apply_state and reset_epoch == _dialogue_avatar_epoch:
		dialogue_avatar_state_apply_requested.emit(state.duplicate(true), reset_epoch)
	if not _presentation_unified_draining and _stage_reset_depth == 0:
		_drain_all_presentation_operation_queues()

# Persistent named loop-SE channels
## A loop operation is validated and accepted by the single Runtime-owned
## AudioPresenter before any child of a mixed presentation batch is applied.
signal loop_se_validate_requested(request: LoopSeOperationRequest)
signal loop_se_accept_requested(request: LoopSeOperationRequest)
signal loop_se_apply_requested(request: LoopSeOperationRequest)
## Canonical state consumes only operations the sealed presenter applied.
signal loop_se_operation_committed(operation: LoopSePresentationOperation)
signal loop_se_transition_receipt_started(
	presenter_instance_id: int,
	channel_id: String,
	token: int,
	operation_request_id: int,
	generation: int,
)
signal loop_se_transition_terminal(
	presenter_instance_id: int,
	channel_id: String,
	token: int,
	operation_request_id: int,
	generation: int,
	outcome: StringName,
)
signal loop_se_transition_receipts_finish_requested(transitions: Array)
signal loop_se_projection_reset_requested(epoch: int)
signal loop_se_state_apply_requested(channels: Dictionary, generation: int)
signal loop_se_targets_state_apply_requested(
	channels: Dictionary,
	targets: Array,
	generation: int,
)
signal loop_se_state_capture_requested(request: LoopSeStateCaptureRequest)
signal loop_se_positions_committed(positions: Dictionary)
signal loop_se_presenter_registered()

# Single persistent BGM lifecycle channel
signal bgm_validate_requested(request: BgmOperationRequest)
signal bgm_accept_requested(request: BgmOperationRequest)
signal bgm_apply_requested(request: BgmOperationRequest)
signal bgm_operation_committed(
	operation: BgmPresentationOperation,
	state: Dictionary,
)
signal bgm_transition_receipt_started(
	presenter_instance_id: int,
	token: int,
	operation_request_id: int,
	generation: int,
)
signal bgm_transition_terminal(
	presenter_instance_id: int,
	token: int,
	operation_request_id: int,
	generation: int,
	outcome: StringName,
)
signal bgm_transition_receipts_finish_requested(transitions: Array)
signal bgm_projection_reset_requested(epoch: int)
signal bgm_state_apply_requested(state: Dictionary, generation: int)
signal bgm_title_cut_requested(asset: String, generation: int)
signal bgm_state_capture_requested(request: BgmStateCaptureRequest)
signal bgm_position_committed(position: float)
signal bgm_natural_stop_committed()
signal bgm_presenter_registered()

# Runtime-owned graceful shutdown performs a synchronous capability handshake
# with the same unique AudioPresenter that owns every Stella audio projection.
# The Runtime observes the later AudioServer mix boundary; the Bus only proves
# that all Stella audio was retired before that observation begins.
signal runtime_audio_shutdown_requested(request_serial: int)

var _stage_operation_queue: Array[Dictionary] = []
var _stage_operation_dispatching := false
var _stage_operation_dispatch_stack: Array[int] = []
var _stage_operation_epoch_stack: Array[int] = []
var _stage_projection_epoch_stack: Array[int] = []
var _stage_reset_epoch_stack: Array[int] = []
var _next_stage_operation_request_id := 1
var _stage_operation_epoch := 1
var _stage_reset_depth := 0
var _dialogue_visibility_queue: Array[Dictionary] = []
var _dialogue_visibility_dispatching := false
var _dialogue_visibility_epoch := 1
var _dialogue_visibility_dispatch_stack: Array[int] = []
var _dialogue_visibility_epoch_stack: Array[int] = []
var _loop_se_epoch := 1
var _loop_se_epoch_stack: Array[int] = []
var _dispatching_loop_se_request: LoopSeOperationRequest
var _applying_loop_se_request: LoopSeOperationRequest
var _capturing_loop_se_request: LoopSeStateCaptureRequest
var _loop_se_participant_authority := RefCounted.new()
var _loop_se_registrar_authority: Object
var _loop_se_presenter: WeakRef
var _loop_se_capability: RefCounted
var _bgm_epoch := 1
var _bgm_epoch_stack: Array[int] = []
var _dispatching_bgm_request: BgmOperationRequest
var _applying_bgm_request: BgmOperationRequest
var _capturing_bgm_request: BgmStateCaptureRequest
var _bgm_participant_authority := RefCounted.new()
var _bgm_registrar_authority: Object
var _bgm_presenter: WeakRef
var _bgm_capability: RefCounted
var _next_runtime_audio_shutdown_serial := 1
var _dispatching_runtime_audio_shutdown_serial := 0
var _runtime_audio_shutdown_acknowledged := false
var _runtime_audio_shutdown_started := false
var _runtime_audio_shutdown_epochs_retired := false
var _presentation_operation_queue: Array[Dictionary] = []
var _presentation_enqueue_serial := 1
var _presentation_projection_depth := 0
var _presentation_unified_draining := false
var _next_presentation_projection_lifecycle_id := 1
var _active_presentation_projection_lifecycle_id := 0
var _presentation_projection_retirement_started := false


## StellaRuntime is the only composition root allowed to admit the concrete
## AudioPresenter. SignalBus retains weak identity plus an opaque capability;
## Core never constructs or searches the scene tree for an audio node.
func configure_loop_se_registrar(authority: Object) -> bool:
	if authority == null:
		return false
	if _loop_se_registrar_authority == null:
		_loop_se_registrar_authority = authority
	return _loop_se_registrar_authority == authority


func announce_loop_se_presenter_registered(
	presenter: Object,
	capability: RefCounted,
) -> bool:
	if not _loop_se_participant_identity_matches(presenter, capability):
		return false
	loop_se_presenter_registered.emit()
	return true


func reject_loop_se_request(
	request: LoopSeOperationRequest,
	presenter: Object,
	capability: RefCounted,
	error: String,
) -> bool:
	if not _loop_se_request_target_is_current(request, presenter, capability, false):
		return false
	return request._reject(error, _loop_se_participant_authority)


func validate_loop_se_request(
	request: LoopSeOperationRequest,
	presenter: Object,
	capability: RefCounted,
) -> bool:
	if not _loop_se_request_target_is_current(request, presenter, capability, false):
		return false
	return request._validate(presenter, _loop_se_participant_authority)


func accept_loop_se_request(
	request: LoopSeOperationRequest,
	presenter: Object,
	capability: RefCounted,
) -> bool:
	if not _loop_se_request_target_is_current(request, presenter, capability, false):
		return false
	return request._accept(presenter, _loop_se_participant_authority)


func acknowledge_loop_se_apply(
	request: LoopSeOperationRequest,
	presenter: Object,
	capability: RefCounted,
) -> bool:
	if not _loop_se_request_target_is_current(request, presenter, capability, true):
		return false
	return request._apply(presenter, _loop_se_participant_authority)


func capture_loop_se_positions() -> Dictionary:
	var presenter := _current_loop_se_presenter()
	if presenter == null:
		return {}
	var request := LoopSeStateCaptureRequestType.new()
	request._bind_authority(_loop_se_participant_authority)
	_capturing_loop_se_request = request
	loop_se_state_capture_requested.emit(request)
	_capturing_loop_se_request = null
	return request.get_positions() if request.is_resolved() else {}


func resolve_loop_se_state_capture(
	request: LoopSeStateCaptureRequest,
	presenter: Object,
	capability: RefCounted,
	positions: Dictionary,
) -> bool:
	if (
		request == null
		or request != _capturing_loop_se_request
		or not _loop_se_participant_identity_matches(presenter, capability)
	):
		return false
	return request._resolve(positions, _loop_se_participant_authority)


## Presenter teardown commits only physical playback positions. Canonical
## asset/volume ownership stays in PresentationState and is reprojected exactly
## once when the replacement presenter registers.
func commit_loop_se_positions(
	presenter: Object,
	capability: RefCounted,
	positions: Dictionary,
) -> bool:
	if not _loop_se_participant_identity_matches(presenter, capability):
		return false
	for raw_channel_id: Variant in positions:
		var value: Variant = positions[raw_channel_id]
		if (
			not raw_channel_id is String
			or not LoopSeChannelState.is_valid_channel_id(String(raw_channel_id))
			or not (value is int or value is float)
			or not is_finite(float(value))
			or float(value) < 0.0
		):
			return false
	loop_se_positions_committed.emit(positions.duplicate(true))
	return true


func current_loop_se_epoch() -> int:
	return _loop_se_epoch


func is_current_loop_se_operation_valid() -> bool:
	if _loop_se_epoch_stack.is_empty():
		return true
	return _loop_se_epoch_stack.back() == _loop_se_epoch


func reset_loop_se_presentation() -> int:
	return _reset_loop_se_projection({})


func reset_and_apply_loop_se_state(channels: Dictionary) -> int:
	if (
		_runtime_audio_shutdown_started
		or not LoopSeChannelState.validate_channels(channels, true)
	):
		return 0
	return _reset_loop_se_projection(channels)


func apply_loop_se_targets_state(
	channels: Dictionary,
	targets: Array,
) -> bool:
	if (
		_runtime_audio_shutdown_started
		or not LoopSeChannelState.validate_channels(channels, true)
	):
		return false
	var normalized_targets: Array[String] = []
	for target_value: Variant in targets:
		var target := String(target_value)
		if (
			LoopSeChannelState.is_valid_channel_id(target)
			and target not in normalized_targets
		):
			normalized_targets.append(target)
	if normalized_targets.is_empty():
		return false
	loop_se_targets_state_apply_requested.emit(
		channels.duplicate(true), normalized_targets, _loop_se_epoch)
	return true


func _reset_loop_se_projection(channels: Dictionary) -> int:
	_mark_presentation_projection_retirement_started()
	_loop_se_epoch += 1
	var reset_epoch := _loop_se_epoch
	for request: Dictionary in _presentation_operation_queue:
		if _request_belongs_to_retained_projection(request):
			request["loop_se_epoch"] = reset_epoch
	_dispatching_loop_se_request = null
	_applying_loop_se_request = null
	loop_se_projection_reset_requested.emit(reset_epoch)
	if reset_epoch == _loop_se_epoch and not channels.is_empty():
		loop_se_state_apply_requested.emit(channels.duplicate(true), reset_epoch)
	return reset_epoch


func _loop_se_request_target_is_current(
	request: LoopSeOperationRequest,
	presenter: Object,
	capability: RefCounted,
	applying: bool,
) -> bool:
	return (
		request != null
		and request == (
			_applying_loop_se_request if applying else _dispatching_loop_se_request)
		and _loop_se_participant_identity_matches(presenter, capability)
		and request.is_target(presenter)
	)


func _current_loop_se_presenter() -> Object:
	if _loop_se_presenter == null:
		return null
	var presenter: Object = _loop_se_presenter.get_ref()
	if not _loop_se_participant_identity_matches(presenter, _loop_se_capability):
		_loop_se_presenter = null
		_loop_se_capability = null
		return null
	return presenter


func _loop_se_participant_identity_matches(
	presenter: Object,
	capability: Object,
) -> bool:
	return (
		presenter != null
		and capability != null
		and capability == _loop_se_capability
		and _loop_se_presenter != null
		and is_instance_valid(presenter)
		and presenter is Node
		and not (presenter as Node).is_queued_for_deletion()
		and _loop_se_presenter.get_ref() == presenter
	)


func configure_bgm_registrar(authority: Object) -> bool:
	if authority == null:
		return false
	if _bgm_registrar_authority == null:
		_bgm_registrar_authority = authority
	return _bgm_registrar_authority == authority


func announce_bgm_presenter_registered(
	presenter: Object,
	capability: RefCounted,
) -> bool:
	if not _bgm_participant_identity_matches(presenter, capability):
		return false
	bgm_presenter_registered.emit()
	return true


## StellaRuntime admits the concrete AudioPresenter as one atomic participant.
## Preflight both owner slots before mutating either, so a duplicate or split
## owner can never connect raw audio signals with only half the typed contract.
func register_audio_presenter(
	presenter: Object,
	loop_se_registrar_authority: Object,
	bgm_registrar_authority: Object,
) -> Dictionary:
	if (
		loop_se_registrar_authority != _loop_se_registrar_authority
		or bgm_registrar_authority != _bgm_registrar_authority
		or presenter == null
		or not is_instance_valid(presenter)
		or not presenter is Node
		or (presenter as Node).is_queued_for_deletion()
	):
		return {}
	var loop_se_owner := _current_loop_se_presenter()
	var bgm_owner := _current_bgm_presenter()
	if loop_se_owner != null or bgm_owner != null:
		if loop_se_owner == presenter and bgm_owner == presenter:
			return {
				"bgm": _bgm_capability,
				"loop_se": _loop_se_capability,
			}
		return {}
	_loop_se_presenter = weakref(presenter)
	_loop_se_capability = RefCounted.new()
	_bgm_presenter = weakref(presenter)
	_bgm_capability = RefCounted.new()
	return {
		"bgm": _bgm_capability,
		"loop_se": _loop_se_capability,
	}


func unregister_audio_presenter(
	presenter: Object,
	loop_se_capability: RefCounted,
	bgm_capability: RefCounted,
	loop_se_registrar_authority: Object,
	bgm_registrar_authority: Object,
) -> bool:
	if (
		loop_se_registrar_authority != _loop_se_registrar_authority
		or bgm_registrar_authority != _bgm_registrar_authority
		or presenter == null
		or not is_instance_valid(presenter)
		or _loop_se_presenter == null
		or _bgm_presenter == null
		or _loop_se_presenter.get_ref() != presenter
		or _bgm_presenter.get_ref() != presenter
		or loop_se_capability != _loop_se_capability
		or bgm_capability != _bgm_capability
	):
		return false
	_loop_se_presenter = null
	_loop_se_capability = null
	_bgm_presenter = null
	_bgm_capability = null
	return true


## Retire the complete Runtime-owned audio projection through its unique typed
## presenter. The presenter latches against reentrant playback, resets BGM and
## loop-SE through their canonical lifecycle paths, retires one-shots/voice, and
## acknowledges only after every local owner has been cleared.
func quiesce_runtime_audio_for_shutdown() -> bool:
	if _dispatching_runtime_audio_shutdown_serial != 0:
		return false
	_runtime_audio_shutdown_started = true
	var bgm_presenter := _current_bgm_presenter()
	var loop_se_presenter := _current_loop_se_presenter()
	if bgm_presenter == null and loop_se_presenter == null:
		return true
	if bgm_presenter == null or loop_se_presenter != bgm_presenter:
		return false
	var request_serial := _next_runtime_audio_shutdown_serial
	_next_runtime_audio_shutdown_serial += 1
	_dispatching_runtime_audio_shutdown_serial = request_serial
	_runtime_audio_shutdown_acknowledged = false
	runtime_audio_shutdown_requested.emit(request_serial)
	_cancel_queued_presentation_for_runtime_shutdown()
	_dispatching_runtime_audio_shutdown_serial = 0
	var acknowledged := _runtime_audio_shutdown_acknowledged
	_runtime_audio_shutdown_acknowledged = false
	return acknowledged


## The terminal latch is global because AudioPresenter replacement remains
## possible while StellaRuntime waits for the next real AudioServer mix. A new
## Presenter must be born closed rather than briefly admitting playback.
func runtime_audio_shutdown_has_started() -> bool:
	return _runtime_audio_shutdown_started


## Exactly the unique dual-capability owner may retire the canonical epochs.
## The retirement is globally once-only so replacing that owner during the mix
## wait cannot advance epochs a second time on a repeated quit request.
func retire_runtime_audio_epochs_for_shutdown(
	presenter: Object,
	capability: RefCounted,
) -> bool:
	if (
		not _runtime_audio_shutdown_started
		or not _bgm_participant_identity_matches(presenter, capability)
		or _current_loop_se_presenter() != presenter
	):
		return false
	if _runtime_audio_shutdown_epochs_retired:
		return true
	_runtime_audio_shutdown_epochs_retired = true
	reset_bgm_presentation()
	reset_loop_se_presentation()
	return true


func _cancel_queued_presentation_for_runtime_shutdown() -> void:
	var mixed_requests := _presentation_operation_queue.duplicate()
	var stage_requests := _stage_operation_queue.duplicate()
	var visibility_requests := _dialogue_visibility_queue.duplicate()
	_presentation_operation_queue.clear()
	_stage_operation_queue.clear()
	_dialogue_visibility_queue.clear()
	for request: Dictionary in mixed_requests:
		presentation_operation_request_finished.emit(
			int(request.get("request_id", 0)), false)
	for request: Dictionary in stage_requests:
		stage_operation_request_finished.emit(
			int(request.get("request_id", 0)), false)
	for request: Dictionary in visibility_requests:
		presentation_operation_request_finished.emit(
			int(request.get("request_id", 0)), false)


func acknowledge_runtime_audio_shutdown(
	presenter: Object,
	capability: RefCounted,
	request_serial: int,
) -> bool:
	if (
		request_serial <= 0
		or request_serial != _dispatching_runtime_audio_shutdown_serial
		or not _bgm_participant_identity_matches(presenter, capability)
		or _current_loop_se_presenter() != presenter
		or not _runtime_audio_shutdown_bus_is_idle()
	):
		return false
	_runtime_audio_shutdown_acknowledged = true
	return true


func _runtime_audio_shutdown_bus_is_idle() -> bool:
	return (
		_presentation_operation_queue.is_empty()
		and _stage_operation_queue.is_empty()
		and _dialogue_visibility_queue.is_empty()
		and not _presentation_unified_draining
		and _presentation_projection_depth == 0
		and not _stage_operation_dispatching
		and not _dialogue_visibility_dispatching
		and _stage_operation_dispatch_stack.is_empty()
		and _stage_operation_epoch_stack.is_empty()
		and _dialogue_visibility_dispatch_stack.is_empty()
		and _dialogue_visibility_epoch_stack.is_empty()
		and _loop_se_epoch_stack.is_empty()
		and _bgm_epoch_stack.is_empty()
		and _dispatching_loop_se_request == null
		and _applying_loop_se_request == null
		and _capturing_loop_se_request == null
		and _dispatching_bgm_request == null
		and _applying_bgm_request == null
		and _capturing_bgm_request == null
		and _dispatching_chapter_indicator_request == null
		and _applying_chapter_indicator_request == null
	)


func reject_bgm_request(
	request: BgmOperationRequest,
	presenter: Object,
	capability: RefCounted,
	error: String,
) -> bool:
	if not _bgm_request_target_is_current(request, presenter, capability, false):
		return false
	return request._reject(error, _bgm_participant_authority)


func validate_bgm_request(
	request: BgmOperationRequest,
	presenter: Object,
	capability: RefCounted,
) -> bool:
	if not _bgm_request_target_is_current(request, presenter, capability, false):
		return false
	return request._validate(presenter, _bgm_participant_authority)


func accept_bgm_request(
	request: BgmOperationRequest,
	presenter: Object,
	capability: RefCounted,
) -> bool:
	if not _bgm_request_target_is_current(request, presenter, capability, false):
		return false
	return request._accept(presenter, _bgm_participant_authority)


func acknowledge_bgm_apply(
	request: BgmOperationRequest,
	presenter: Object,
	capability: RefCounted,
	committed_state: Dictionary,
) -> bool:
	if not _bgm_request_target_is_current(request, presenter, capability, true):
		return false
	return request._apply(
		presenter, committed_state, _bgm_participant_authority)


func capture_bgm_position() -> float:
	var presenter := _current_bgm_presenter()
	if presenter == null:
		return 0.0
	var request := BgmStateCaptureRequestType.new()
	request._bind_authority(_bgm_participant_authority)
	_capturing_bgm_request = request
	bgm_state_capture_requested.emit(request)
	_capturing_bgm_request = null
	return request.get_position() if request.is_resolved() else 0.0


func resolve_bgm_state_capture(
	request: BgmStateCaptureRequest,
	presenter: Object,
	capability: RefCounted,
	position: float,
) -> bool:
	if (
		request == null
		or request != _capturing_bgm_request
		or not _bgm_participant_identity_matches(presenter, capability)
	):
		return false
	return request._resolve(position, _bgm_participant_authority)


func commit_bgm_position(
	presenter: Object,
	capability: RefCounted,
	position: float,
) -> bool:
	if (
		not _bgm_participant_identity_matches(presenter, capability)
		or not is_finite(position)
		or position < 0.0
	):
		return false
	bgm_position_committed.emit(position)
	return true


func commit_bgm_natural_stop(
	presenter: Object,
	capability: RefCounted,
) -> bool:
	if not _bgm_participant_identity_matches(presenter, capability):
		return false
	bgm_natural_stop_committed.emit()
	return true


func current_bgm_epoch() -> int:
	return _bgm_epoch


func is_current_bgm_operation_valid() -> bool:
	if _bgm_epoch_stack.is_empty():
		return true
	return _bgm_epoch_stack.back() == _bgm_epoch


func reset_bgm_presentation() -> int:
	return _reset_bgm_projection({})


func reset_and_apply_bgm_state(state: Dictionary) -> int:
	if (
		_runtime_audio_shutdown_started
		or not BgmChannelState.validate_snapshot_state(state, true)
	):
		return 0
	return _reset_bgm_projection(state)


func apply_bgm_state(state: Dictionary) -> bool:
	if (
		_runtime_audio_shutdown_started
		or not BgmChannelState.validate_snapshot_state(state, true)
	):
		return false
	bgm_state_apply_requested.emit(state.duplicate(true), _bgm_epoch)
	return true


## Title configuration uses the same Runtime-owned channel projection but does
## not create an authored lifecycle owner or a save-state commit.
func apply_title_bgm_cut(asset: String) -> int:
	if _runtime_audio_shutdown_started:
		return 0
	var normalized := asset.strip_edges()
	var epoch := _reset_bgm_projection({})
	if normalized.is_empty() or normalized != asset:
		return epoch
	bgm_title_cut_requested.emit(normalized, epoch)
	return epoch


func _reset_bgm_projection(state: Dictionary) -> int:
	_mark_presentation_projection_retirement_started()
	_bgm_epoch += 1
	var reset_epoch := _bgm_epoch
	for request: Dictionary in _presentation_operation_queue:
		if _request_belongs_to_retained_projection(request):
			request["bgm_epoch"] = reset_epoch
	_dispatching_bgm_request = null
	_applying_bgm_request = null
	bgm_projection_reset_requested.emit(reset_epoch)
	if reset_epoch == _bgm_epoch and not state.is_empty():
		bgm_state_apply_requested.emit(state.duplicate(true), reset_epoch)
	return reset_epoch


func _bgm_request_target_is_current(
	request: BgmOperationRequest,
	presenter: Object,
	capability: RefCounted,
	applying: bool,
) -> bool:
	return (
		request != null
		and request == (
			_applying_bgm_request if applying else _dispatching_bgm_request)
		and _bgm_participant_identity_matches(presenter, capability)
		and request.is_target(presenter)
	)


func _current_bgm_presenter() -> Object:
	if _bgm_presenter == null:
		return null
	var presenter: Object = _bgm_presenter.get_ref()
	if not _bgm_participant_identity_matches(presenter, _bgm_capability):
		_bgm_presenter = null
		_bgm_capability = null
		return null
	return presenter


func _bgm_participant_identity_matches(
	presenter: Object,
	capability: Object,
) -> bool:
	return (
		presenter != null
		and capability != null
		and capability == _bgm_capability
		and _bgm_presenter != null
		and is_instance_valid(presenter)
		and presenter is Node
		and not (presenter as Node).is_queued_for_deletion()
		and _bgm_presenter.get_ref() == presenter
	)


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


func current_stage_operation_epoch() -> int:
	return _stage_operation_epoch


## Atomic reset projections carry their exact reset generation through the
## existing state-apply signal. Raw compatibility emits have no frame and
## therefore remain valid as before.
func is_current_stage_projection_valid() -> bool:
	if _stage_projection_epoch_stack.is_empty():
		return true
	return _stage_projection_epoch_stack.back() == _stage_operation_epoch


## Like projection validity, direct public raw emits remain valid. Reset
## transactions carry an exact epoch so a nested newer boundary can stop the
## stale outer signal tail from clearing later-connected presenters.
func is_current_stage_reset_valid() -> bool:
	if _stage_reset_epoch_stack.is_empty():
		return true
	return _stage_reset_epoch_stack.back() == _stage_operation_epoch


func current_stage_reset_epoch() -> int:
	if _stage_reset_epoch_stack.is_empty():
		return 0
	return _stage_reset_epoch_stack.back()


func emit_dialogue_visibility_operations(
	operations: Array,
	force_cut: bool = false,
	request_id: int = 0,
) -> int:
	if request_id <= 0:
		request_id = reserve_stage_operation_request_id()
	if _runtime_audio_shutdown_started:
		presentation_operation_request_finished.emit(request_id, false)
		return request_id
	for operation_value: Variant in operations:
		if not DialogueVisibilityState.validate_operation(operation_value, true):
			presentation_operation_request_finished.emit(request_id, false)
			return request_id
	_dialogue_visibility_queue.append({
		"operations": operations.duplicate(true),
		"force_cut": force_cut,
		"request_id": request_id,
		"epoch": _dialogue_visibility_epoch,
		"enqueue_serial": _presentation_enqueue_serial,
		"projection_lifecycle_id": _active_presentation_projection_lifecycle_id,
		"born_after_retirement": _presentation_projection_retirement_started,
	})
	_presentation_enqueue_serial += 1
	if (
		_dialogue_visibility_dispatching
		or _stage_reset_depth > 0
		or _presentation_projection_depth > 0
		or _presentation_unified_draining
	):
		return request_id
	_drain_all_presentation_operation_queues()
	return request_id


## The optional dispatch callback fires exactly once when the queued request
## starts delivery, before any typed phase. Stage channels are reported only
## after their private participant commit quorum succeeds; existing non-Stage
## domains retain their established pre-apply ownership handoff so synchronous
## supersession terminals cannot roll back the incoming owner.
func emit_presentation_operations(
	operations: Array,
	force_cut: bool = false,
	request_id: int = 0,
	on_apply_started: Callable = Callable(),
	on_dispatch_started: Callable = Callable(),
) -> int:
	if request_id <= 0:
		request_id = reserve_stage_operation_request_id()
	if _runtime_audio_shutdown_started:
		presentation_operation_request_finished.emit(request_id, false)
		return request_id
	for operation_value: Variant in operations:
		if not operation_value is PresentationOperation:
			presentation_operation_request_finished.emit(request_id, false)
			return request_id
		var operation: PresentationOperation = operation_value
		var payload := operation.get_payload()
		if (
			(operation is StagePresentationOperation
				and not StageLayerState.validate_operation(payload, true))
			or (operation is DialogueVisibilityPresentationOperation
				and not DialogueVisibilityState.validate_operation(payload, true))
			or (operation is DialogueAvatarPresentationOperation
				and (
					not DialogueAvatarState.validate_operation(payload, true)
					or not DialogueAvatarState.validate_snapshot_state(
						operation.get_before_state(), true)
					or not DialogueAvatarState.validate_snapshot_state(
						operation.get_target_state(), true)
				))
			or (operation is DialogueClearPresentationOperation
				and (
					payload.keys() != ["scope"]
					or payload.get("scope", null) != "page"
				))
			or (operation is LoopSePresentationOperation
				and not LoopSeChannelState.validate_operation(payload, true))
			or (operation is BgmPresentationOperation
				and not BgmChannelState.validate_operation(payload, true))
			or not operation is StagePresentationOperation
				and not operation is DialogueAvatarPresentationOperation
				and not operation is DialogueVisibilityPresentationOperation
				and not operation is DialogueClearPresentationOperation
				and not operation is ChapterIndicatorPresentationOperation
				and not operation is LoopSePresentationOperation
				and not operation is BgmPresentationOperation
		):
			presentation_operation_request_finished.emit(request_id, false)
			return request_id
	_presentation_operation_queue.append({
		"operations": operations.duplicate(),
		"force_cut": force_cut,
		"request_id": request_id,
		"on_apply_started": on_apply_started,
		"on_dispatch_started": on_dispatch_started,
		"stage_epoch": _stage_operation_epoch,
		"visibility_epoch": _dialogue_visibility_epoch,
		"avatar_epoch": _dialogue_avatar_epoch,
		"chapter_epoch": _chapter_indicator_epoch,
		"loop_se_epoch": _loop_se_epoch,
		"bgm_epoch": _bgm_epoch,
		"enqueue_serial": _presentation_enqueue_serial,
		"projection_lifecycle_id": _active_presentation_projection_lifecycle_id,
		"born_after_retirement": _presentation_projection_retirement_started,
	})
	_presentation_enqueue_serial += 1
	if (
		_stage_reset_depth > 0
		or _presentation_projection_depth > 0
		or _presentation_unified_draining
	):
		return request_id
	_drain_all_presentation_operation_queues()
	return request_id


func current_dialogue_visibility_request_id() -> int:
	if _dialogue_visibility_dispatch_stack.is_empty():
		return 0
	return _dialogue_visibility_dispatch_stack.back()


func is_current_dialogue_visibility_operation_valid() -> bool:
	if _dialogue_visibility_epoch_stack.is_empty():
		return true
	return _dialogue_visibility_epoch_stack.back() == _dialogue_visibility_epoch


func current_dialogue_visibility_epoch() -> int:
	return _dialogue_visibility_epoch


func reset_dialogue_visibility_visuals() -> void:
	_mark_presentation_projection_retirement_started()
	_dialogue_visibility_epoch += 1
	var reset_epoch := _dialogue_visibility_epoch
	var cancelled_requests: Array[Dictionary] = []
	var retained_requests: Array[Dictionary] = []
	for request: Dictionary in _dialogue_visibility_queue:
		if _request_belongs_to_retained_projection(request):
			request["epoch"] = reset_epoch
			retained_requests.append(request)
		else:
			cancelled_requests.append(request)
	_dialogue_visibility_queue = retained_requests
	for request: Dictionary in _presentation_operation_queue:
		if _request_belongs_to_retained_projection(request):
			request["visibility_epoch"] = reset_epoch
	for request: Dictionary in cancelled_requests:
		presentation_operation_request_finished.emit(
			int(request.get("request_id", 0)),
			false,
		)
	dialogue_visibility_visuals_reset_requested.emit()


func cancel_dialogue_visibility_operation_request(request_id: int) -> void:
	if request_id <= 0:
		return
	_dialogue_visibility_queue = _dialogue_visibility_queue.filter(
		func(entry: Dictionary) -> bool:
			return int(entry.get("request_id", 0)) != request_id
	)


func cancel_presentation_operation_request(request_id: int) -> bool:
	for index in range(_presentation_operation_queue.size()):
		if int(_presentation_operation_queue[index].get("request_id", 0)) != request_id:
			continue
		_presentation_operation_queue.remove_at(index)
		presentation_operation_request_finished.emit(request_id, false)
		return true
	return false


func apply_dialogue_visibility_state(
	visibility: Dictionary,
	content: Dictionary,
	runtime_binding: Dictionary = {},
) -> void:
	dialogue_visibility_state_apply_requested.emit(
		visibility.duplicate(true),
		content.duplicate(true),
		runtime_binding.duplicate(true),
	)


func apply_dialogue_content_state(
	content: Dictionary,
	runtime_binding: Dictionary = {},
) -> void:
	dialogue_content_state_apply_requested.emit(
		content.duplicate(true), runtime_binding.duplicate(true))


func apply_dialogue_visibility_targets_state(
	visibility: Dictionary,
	targets: Array,
) -> void:
	var normalized_targets: Array[String] = []
	for target_value: Variant in targets:
		var target := String(target_value).strip_edges()
		if target not in ["surface", "quick_menu"] or target in normalized_targets:
			continue
		normalized_targets.append(target)
	if normalized_targets.is_empty():
		return
	_mark_presentation_projection_retirement_started()
	dialogue_visibility_targets_state_apply_requested.emit(
		visibility.duplicate(true), normalized_targets.duplicate())


func run_presentation_projection(body: Callable) -> void:
	_run_presentation_projection(body)


func current_presentation_projection_lifecycle_id() -> int:
	return _active_presentation_projection_lifecycle_id


func _run_presentation_projection(body: Callable) -> void:
	var is_outermost := (
		_presentation_projection_depth == 0
		and _active_presentation_projection_lifecycle_id == 0
	)
	if is_outermost:
		_active_presentation_projection_lifecycle_id = (
			_next_presentation_projection_lifecycle_id
		)
		_next_presentation_projection_lifecycle_id += 1
		_presentation_projection_retirement_started = false
	_presentation_projection_depth += 1
	if body.is_valid():
		body.call()
	_presentation_projection_depth -= 1
	if is_outermost:
		var lifecycle_id := _active_presentation_projection_lifecycle_id
		_drain_all_presentation_operation_queues()
		_active_presentation_projection_lifecycle_id = 0
		_presentation_projection_retirement_started = false
		if lifecycle_id > 0:
			presentation_projection_lifecycle_finished.emit(lifecycle_id)


func _mark_presentation_projection_retirement_started() -> void:
	if _active_presentation_projection_lifecycle_id > 0:
		_presentation_projection_retirement_started = true


func _request_belongs_to_retained_projection(request: Dictionary) -> bool:
	return (
		_active_presentation_projection_lifecycle_id > 0
		and bool(request.get("born_after_retirement", false))
		and int(request.get("projection_lifecycle_id", 0))
			== _active_presentation_projection_lifecycle_id
	)


func _drain_dialogue_visibility_queue() -> void:
	if (
		_dialogue_visibility_dispatching
		or _stage_reset_depth > 0
		or _presentation_projection_depth > 0
		or _presentation_unified_draining
	):
		return
	while not _dialogue_visibility_queue.is_empty():
		_drain_dialogue_visibility_queue_once()
		if _presentation_projection_depth > 0 or _presentation_unified_draining:
			return


func _drain_dialogue_visibility_queue_once() -> void:
	if _dialogue_visibility_queue.is_empty():
		return
	_dialogue_visibility_dispatching = true
	var request: Dictionary = _dialogue_visibility_queue.pop_front()
	var request_id := int(request.get("request_id", 0))
	var request_epoch := int(request.get("epoch", 0))
	_dialogue_visibility_dispatch_stack.append(request_id)
	_dialogue_visibility_epoch_stack.append(request_epoch)
	dialogue_visibility_operations_requested.emit(
		(request.get("operations", []) as Array).duplicate(true),
		bool(request.get("force_cut", false)),
	)
	_dialogue_visibility_dispatch_stack.pop_back()
	_dialogue_visibility_epoch_stack.pop_back()
	presentation_operation_request_finished.emit(
		request_id,
		request_epoch == _dialogue_visibility_epoch,
	)
	_dialogue_visibility_dispatching = false


func _drain_presentation_operation_queue() -> void:
	if (
		_stage_reset_depth > 0
		or _presentation_projection_depth > 0
		or _presentation_unified_draining
	):
		return
	while not _presentation_operation_queue.is_empty():
		_drain_presentation_operation_queue_once()
		if _presentation_projection_depth > 0 or _presentation_unified_draining:
			return


func _drain_presentation_operation_queue_once() -> void:
	if _presentation_operation_queue.is_empty():
		return
	var request: Dictionary = _presentation_operation_queue.pop_front()
	var request_id := int(request.get("request_id", 0))
	var stage_epoch := int(request.get("stage_epoch", 0))
	var visibility_epoch := int(request.get("visibility_epoch", 0))
	var avatar_epoch := int(request.get("avatar_epoch", 0))
	var chapter_epoch := int(request.get("chapter_epoch", 0))
	var loop_se_epoch := int(request.get("loop_se_epoch", 0))
	var bgm_epoch := int(request.get("bgm_epoch", 0))
	var operations: Array = request.get("operations", [])
	var force_cut := bool(request.get("force_cut", false))
	var apply_started_callback: Callable = request.get(
		"on_apply_started", Callable())
	var dispatch_started_callback: Callable = request.get(
		"on_dispatch_started", Callable())
	var uses_stage := false
	var uses_dialogue_visibility := false
	var uses_dialogue_avatar := false
	var uses_chapter_indicator := false
	var uses_loop_se := false
	var uses_bgm := false
	for operation_value: Variant in operations:
		if operation_value is StagePresentationOperation:
			uses_stage = true
		elif operation_value is DialogueAvatarPresentationOperation:
			uses_dialogue_avatar = true
		elif operation_value is DialogueVisibilityPresentationOperation:
			uses_dialogue_visibility = true
		elif operation_value is DialogueClearPresentationOperation:
			uses_dialogue_visibility = true
		elif operation_value is ChapterIndicatorPresentationOperation:
			uses_chapter_indicator = true
		elif operation_value is LoopSePresentationOperation:
			uses_loop_se = true
		elif operation_value is BgmPresentationOperation:
			uses_bgm = true
	_stage_operation_dispatch_stack.append(request_id)
	_stage_operation_epoch_stack.append(stage_epoch)
	_dialogue_visibility_dispatch_stack.append(request_id)
	_dialogue_visibility_epoch_stack.append(visibility_epoch)
	_dialogue_avatar_epoch_stack.append(avatar_epoch)
	_loop_se_epoch_stack.append(loop_se_epoch)
	_bgm_epoch_stack.append(bgm_epoch)
	if dispatch_started_callback.is_valid():
		dispatch_started_callback.call()
	var dialogue_clear_requests: Dictionary = {}
	var dialogue_avatar_requests: Dictionary = {}
	var stage_requests: Dictionary = {}
	var chapter_requests: Dictionary = {}
	var loop_se_requests: Dictionary = {}
	var bgm_requests: Dictionary = {}
	var preflight_valid := true
	var stage_runs: Array[Dictionary] = []
	var dialogue_avatar_operation_count := 0
	for operation_value: Variant in operations:
		if operation_value is DialogueAvatarPresentationOperation:
			dialogue_avatar_operation_count += 1
	var dialogue_avatar_preflight_index := 0
	var stage_preflight_index := 0
	while stage_preflight_index < operations.size():
		if not operations[stage_preflight_index] is StagePresentationOperation:
			stage_preflight_index += 1
			continue
		var first_stage_operation: StagePresentationOperation = (
			operations[stage_preflight_index])
		var stage_run: Array[StagePresentationOperation] = []
		while (
			stage_preflight_index < operations.size()
			and operations[stage_preflight_index] is StagePresentationOperation
		):
			stage_run.append(operations[stage_preflight_index])
			stage_preflight_index += 1
		stage_runs.append({
			"first_operation": first_stage_operation,
			"operations": stage_run,
		})
	for stage_run_index in range(stage_runs.size()):
		var stage_run_record: Dictionary = stage_runs[stage_run_index]
		var first_stage_operation: StagePresentationOperation = (
			stage_run_record["first_operation"])
		var stage_run: Array[StagePresentationOperation] = []
		stage_run.assign(stage_run_record["operations"])
		var stage_request := StageOperationRequest.new(stage_run, force_cut)
		stage_request._bind_authority(
			_stage_participant_authority,
			_stage_participant_is_current,
		)
		stage_request._bind_preflight_chain(
			request_id,
			stage_run_index,
			stage_runs.size(),
			_stage_participant_authority,
		)
		# Own every created request before validation. A participant may reserve
		# detached projections and a later participant/domain may still reject.
		stage_requests[first_stage_operation.get_instance_id()] = stage_request
		for participant: Dictionary in _stage_participant_snapshot():
			stage_request._snapshot_presenter(
				participant.get("presenter"),
				participant.get("capability"),
				_stage_participant_authority,
				participant.get("transaction", Callable()),
			)
		_dispatching_stage_request = stage_request
		stage_validate_requested.emit(stage_request)
		if (
			stage_epoch != _stage_operation_epoch
			or not stage_request._seal_validation(
				request_id, _stage_participant_authority)
		):
			_report_stage_rejection(stage_request.get_validation_errors())
			preflight_valid = false
			break
		stage_accept_requested.emit(stage_request)
		if (
			not stage_request.all_presenters_accepted()
			or not stage_request.presenters_are_live()
		):
			_report_stage_rejection([{
				"source": first_stage_operation.get_source(),
				"error": "a sealed StagePresenter did not accept the captured binding",
			}])
			preflight_valid = false
			break
	for operation_value: Variant in operations:
		if not preflight_valid:
			break
		if operation_value is DialogueAvatarPresentationOperation:
			var operation: DialogueAvatarPresentationOperation = operation_value
			var avatar_request := DialogueAvatarOperationRequest.new(
				operation, operation.get_target_state(), force_cut)
			avatar_request._bind_authority(
				_dialogue_avatar_participant_authority,
				_dialogue_avatar_participant_is_current,
			)
			avatar_request._bind_preflight_chain(
				dialogue_avatar_preflight_index,
				dialogue_avatar_operation_count,
				_dialogue_avatar_participant_authority,
			)
			dialogue_avatar_preflight_index += 1
			for participant: Dictionary in _dialogue_avatar_participant_snapshot():
				avatar_request._snapshot_presenter(
					participant.get("presenter"),
					participant.get("capability"),
					_dialogue_avatar_participant_authority,
				)
			dialogue_avatar_requests[operation.get_instance_id()] = avatar_request
			_dispatching_dialogue_avatar_request = avatar_request
			dialogue_avatar_validate_requested.emit(avatar_request)
			if (
				avatar_epoch != _dialogue_avatar_epoch
				or not avatar_request._seal_validation(
					request_id, _dialogue_avatar_participant_authority)
			):
				_report_dialogue_avatar_rejection(
					operation.get_source(), avatar_request.get_validation_errors())
				preflight_valid = false
				break
			dialogue_avatar_accept_requested.emit(avatar_request)
			if (
				not avatar_request.all_presenters_accepted()
				or not avatar_request.presenters_are_live()
			):
				_report_dialogue_avatar_rejection(
					operation.get_source(),
					["a sealed DialoguePresenter did not accept the captured binding"],
				)
				preflight_valid = false
				break
		elif operation_value is DialogueClearPresentationOperation:
			var operation: DialogueClearPresentationOperation = operation_value
			var clear_request := DialogueClearOperationRequest.new(operation)
			clear_request._bind_authority(
				_dialogue_clear_participant_authority,
				_dialogue_clear_participant_is_current,
			)
			for participant: Dictionary in _dialogue_clear_participant_snapshot():
				clear_request._snapshot_presenter(
					participant.get("presenter"),
					participant.get("capability"),
					_dialogue_clear_participant_authority,
				)
			dialogue_clear_requests[operation.get_instance_id()] = clear_request
			_dispatching_dialogue_clear_request = clear_request
			dialogue_clear_validate_requested.emit(clear_request)
			if (
				visibility_epoch != _dialogue_visibility_epoch
				or not clear_request._seal_validation(
					request_id, _dialogue_clear_participant_authority)
			):
				preflight_valid = false
				break
			dialogue_clear_accept_requested.emit(clear_request)
			if (
				not clear_request.all_presenters_accepted()
				or not clear_request.presenters_are_live()
			):
				preflight_valid = false
				break
		elif operation_value is ChapterIndicatorPresentationOperation:
			var operation: ChapterIndicatorPresentationOperation = operation_value
			var payload := operation.get_payload()
			var chapter_request := ChapterIndicatorRequest.new(
				String(payload.get("action", "")) == "show",
				String(payload.get("transition", "")),
				float(payload.get("duration", 0.0)),
				operation.get_source(),
			)
			chapter_request._bind_authority(
				_chapter_indicator_participant_authority,
				_chapter_indicator_participant_is_current,
			)
			for participant: Dictionary in _chapter_indicator_participant_snapshot():
				chapter_request._snapshot_presenter(
					participant.get("presenter"),
					participant.get("capability"),
					_chapter_indicator_participant_authority,
				)
			_dispatching_chapter_indicator_request = chapter_request
			chapter_indicator_validate_requested.emit(chapter_request)
			if (
				chapter_epoch != _chapter_indicator_epoch
				or not chapter_request._seal_validation(
					request_id, _chapter_indicator_participant_authority)
			):
				_report_chapter_indicator_rejection(
					chapter_request.get_source(),
					chapter_request.get_validation_errors(),
				)
				preflight_valid = false
				break
			chapter_request._set_force_cut(
				force_cut, _chapter_indicator_participant_authority)
			chapter_indicator_accept_requested.emit(chapter_request)
			if (
				not chapter_request.all_presenters_accepted()
				or not chapter_request.presenters_are_live()
			):
				_report_chapter_indicator_rejection(
					chapter_request.get_source(),
					["a sealed presenter did not accept the captured binding"],
				)
				preflight_valid = false
				break
			chapter_requests[operation.get_instance_id()] = chapter_request
		elif operation_value is LoopSePresentationOperation:
			var operation: LoopSePresentationOperation = operation_value
			var loop_request := LoopSeOperationRequestType.new(
				operation.get_payload(), operation.get_source())
			loop_request._bind_authority(
				_loop_se_participant_authority,
				_loop_se_participant_identity_matches,
			)
			loop_request._snapshot_presenter(
				_current_loop_se_presenter(),
				_loop_se_capability,
				_loop_se_participant_authority,
			)
			_dispatching_loop_se_request = loop_request
			loop_se_validate_requested.emit(loop_request)
			if (
				loop_se_epoch != _loop_se_epoch
				or not loop_request._seal_validation(
					request_id, _loop_se_participant_authority)
			):
				_report_loop_se_rejection(
					loop_request.get_source(), loop_request.get_validation_errors())
				preflight_valid = false
				break
			loop_request._set_force_cut(force_cut, _loop_se_participant_authority)
			loop_se_accept_requested.emit(loop_request)
			if not loop_request.was_accepted() or not loop_request.presenter_is_live():
				_report_loop_se_rejection(
					loop_request.get_source(),
					["the sealed AudioPresenter did not accept the captured binding"],
				)
				preflight_valid = false
				break
			loop_se_requests[operation.get_instance_id()] = loop_request
		elif operation_value is BgmPresentationOperation:
			var operation: BgmPresentationOperation = operation_value
			var bgm_request := BgmOperationRequestType.new(
				operation.get_payload(), operation.get_source())
			bgm_request._bind_authority(
				_bgm_participant_authority,
				_bgm_participant_identity_matches,
			)
			bgm_request._snapshot_presenter(
				_current_bgm_presenter(),
				_bgm_capability,
				_bgm_participant_authority,
			)
			_dispatching_bgm_request = bgm_request
			bgm_validate_requested.emit(bgm_request)
			if (
				bgm_epoch != _bgm_epoch
				or not bgm_request._seal_validation(
					request_id, _bgm_participant_authority)
			):
				_report_bgm_rejection(
					bgm_request.get_source(), bgm_request.get_validation_errors())
				preflight_valid = false
				break
			bgm_request._set_force_cut(force_cut, _bgm_participant_authority)
			bgm_accept_requested.emit(bgm_request)
			if not bgm_request.was_accepted() or not bgm_request.presenter_is_live():
				_report_bgm_rejection(
					bgm_request.get_source(),
					["the sealed AudioPresenter did not accept the captured binding"],
				)
				preflight_valid = false
				break
			bgm_requests[operation.get_instance_id()] = bgm_request
	_dispatching_stage_request = null
	_dispatching_dialogue_avatar_request = null
	_dispatching_dialogue_clear_request = null
	_dispatching_chapter_indicator_request = null
	_dispatching_loop_se_request = null
	_dispatching_bgm_request = null
	var epochs_valid := _presentation_operation_epochs_are_current(
		stage_epoch,
		visibility_epoch,
		avatar_epoch,
		chapter_epoch,
		loop_se_epoch,
		bgm_epoch,
		uses_stage,
		uses_dialogue_visibility,
		uses_dialogue_avatar,
		uses_chapter_indicator,
		uses_loop_se,
		uses_bgm,
	)
	if not preflight_valid or not epochs_valid:
		for stage_request_value: Variant in stage_requests.values():
			(stage_request_value as StageOperationRequest)._finish(
				false, false, _stage_participant_authority)
		for clear_request_value: Variant in dialogue_clear_requests.values():
			(clear_request_value as DialogueClearOperationRequest)._finish(
				false, false, _dialogue_clear_participant_authority)
		for avatar_request_value: Variant in dialogue_avatar_requests.values():
			(avatar_request_value as DialogueAvatarOperationRequest)._finish(
				false, false, _dialogue_avatar_participant_authority)
		for chapter_request_value: Variant in chapter_requests.values():
			(chapter_request_value as ChapterIndicatorRequest)._finish(
				false, false, _chapter_indicator_participant_authority)
		for loop_request_value: Variant in loop_se_requests.values():
			(loop_request_value as LoopSeOperationRequest)._finish(
				false, false, _loop_se_participant_authority)
		for bgm_request_value: Variant in bgm_requests.values():
			(bgm_request_value as BgmOperationRequest)._finish(
				false, false, _bgm_participant_authority)
		_bgm_epoch_stack.pop_back()
		_loop_se_epoch_stack.pop_back()
		_dialogue_avatar_epoch_stack.pop_back()
		_dialogue_visibility_epoch_stack.pop_back()
		_dialogue_visibility_dispatch_stack.pop_back()
		_stage_operation_epoch_stack.pop_back()
		_stage_operation_dispatch_stack.pop_back()
		presentation_operation_request_finished.emit(request_id, false)
		return
	var delivered := true
	var operation_index := 0
	while operation_index < operations.size():
		var operation: PresentationOperation = operations[operation_index]
		if operation is StagePresentationOperation:
			var first_stage_operation := operation as StagePresentationOperation
			var stage_run: Array = []
			var stage_channels: Array[StringName] = []
			while (
				operation_index < operations.size()
				and operations[operation_index] is StagePresentationOperation
			):
				var stage_operation := (
					operations[operation_index] as PresentationOperation)
				stage_run.append(stage_operation.get_payload())
				stage_channels.append(stage_operation.get_channel())
				operation_index += 1
			var stage_request: StageOperationRequest = stage_requests.get(
				first_stage_operation.get_instance_id())
			_applying_stage_request = stage_request
			stage_apply_readiness_requested.emit(stage_request)
			if (
				stage_request == null
				or not stage_request.all_presenters_apply_ready()
				or not stage_request.presenters_are_live()
				or stage_epoch != _stage_operation_epoch
			):
				if (
					stage_request != null
					and not stage_request.get_validation_errors().is_empty()
				):
					_report_stage_rejection(
						stage_request.get_validation_errors())
				_applying_stage_request = null
				delivered = false
				break
			stage_apply_requested.emit(stage_request)
			if (
				stage_request == null
				or not stage_request.all_presenters_apply_claimed()
				or not stage_request.presenters_are_live()
				or stage_epoch != _stage_operation_epoch
			):
				if (
					stage_request != null
					and not stage_request.get_validation_errors().is_empty()
				):
					_report_stage_rejection(
						stage_request.get_validation_errors())
				_applying_stage_request = null
				delivered = false
				break
			if not _commit_stage_request(stage_request):
				if not stage_request.get_validation_errors().is_empty():
					_report_stage_rejection(stage_request.get_validation_errors())
				_applying_stage_request = null
				delivered = false
				break
			if (
				stage_request != _applying_stage_request
				or not stage_request.presenters_are_live()
				or stage_epoch != _stage_operation_epoch
			):
				_abort_stage_request_transaction(stage_request)
				_applying_stage_request = null
				delivered = false
				break
			if apply_started_callback.is_valid():
				apply_started_callback.call(stage_channels)
			if not _publish_stage_request(stage_request, stage_epoch):
				_applying_stage_request = null
				delivered = false
				break
			# Canonical save state and third-party observers retain the public raw
			# notification. Runtime-owned StagePresenters ignore it while the typed
			# request is active, so the visual run is never applied twice.
			stage_operations_requested.emit(stage_run, force_cut)
			_applying_stage_request = null
		elif operation is DialogueAvatarPresentationOperation:
			var avatar_request: DialogueAvatarOperationRequest = (
				dialogue_avatar_requests.get(operation.get_instance_id()))
			_applying_dialogue_avatar_request = avatar_request
			dialogue_avatar_apply_readiness_requested.emit(avatar_request)
			if (
				avatar_request == null
				or not avatar_request.all_presenters_ready()
				or not avatar_request.presenters_are_live()
				or avatar_epoch != _dialogue_avatar_epoch
			):
				_applying_dialogue_avatar_request = null
				delivered = false
				break
			if apply_started_callback.is_valid():
				apply_started_callback.call([operation.get_channel()])
			dialogue_avatar_apply_requested.emit(avatar_request)
			_applying_dialogue_avatar_request = null
			if (
				not avatar_request.all_presenters_applied()
				or not avatar_request.presenters_are_live()
				or avatar_epoch != _dialogue_avatar_epoch
			):
				delivered = false
				break
			dialogue_avatar_operation_committed.emit(operation)
			operation_index += 1
		elif operation is DialogueVisibilityPresentationOperation:
			var visibility_run: Array = []
			var visibility_channels: Array[StringName] = []
			while (
				operation_index < operations.size()
				and operations[operation_index]
					is DialogueVisibilityPresentationOperation
			):
				var visibility_operation := (
					operations[operation_index] as PresentationOperation)
				visibility_run.append(visibility_operation)
				visibility_channels.append(visibility_operation.get_channel())
				operation_index += 1
			if apply_started_callback.is_valid():
				apply_started_callback.call(visibility_channels)
			dialogue_visibility_operations_requested.emit(
				visibility_run, force_cut)
		elif operation is DialogueClearPresentationOperation:
			var clear_request: DialogueClearOperationRequest = (
				dialogue_clear_requests.get(operation.get_instance_id()))
			if apply_started_callback.is_valid():
				apply_started_callback.call([operation.get_channel()])
			_applying_dialogue_clear_request = clear_request
			dialogue_clear_apply_requested.emit(clear_request)
			_applying_dialogue_clear_request = null
			if (
				clear_request == null
				or not clear_request.all_presenters_applied()
				or not clear_request.presenters_are_live()
				or visibility_epoch != _dialogue_visibility_epoch
			):
				delivered = false
				break
			operation_index += 1
		elif operation is ChapterIndicatorPresentationOperation:
			var chapter_request: ChapterIndicatorRequest = chapter_requests.get(
				operation.get_instance_id())
			if apply_started_callback.is_valid():
				apply_started_callback.call([operation.get_channel()])
			_applying_chapter_indicator_request = chapter_request
			chapter_indicator_apply_requested.emit(chapter_request)
			_applying_chapter_indicator_request = null
			if (
				chapter_request == null
				or not chapter_request.all_presenters_applied()
				or not chapter_request.presenters_are_live()
			):
				delivered = false
				break
			delivered = delivered and chapter_request != null
			operation_index += 1
		elif operation is LoopSePresentationOperation:
			var loop_request: LoopSeOperationRequest = loop_se_requests.get(
				operation.get_instance_id())
			if apply_started_callback.is_valid():
				apply_started_callback.call([operation.get_channel()])
			_applying_loop_se_request = loop_request
			loop_se_apply_requested.emit(loop_request)
			_applying_loop_se_request = null
			if (
				loop_request == null
				or not loop_request.was_applied()
				or not loop_request.presenter_is_live()
				or loop_se_epoch != _loop_se_epoch
			):
				delivered = false
				break
			loop_se_operation_committed.emit(operation)
			operation_index += 1
		elif operation is BgmPresentationOperation:
			var bgm_request: BgmOperationRequest = bgm_requests.get(
				operation.get_instance_id())
			if apply_started_callback.is_valid():
				apply_started_callback.call([operation.get_channel()])
			_applying_bgm_request = bgm_request
			bgm_apply_requested.emit(bgm_request)
			_applying_bgm_request = null
			if (
				bgm_request == null
				or not bgm_request.was_applied()
				or not bgm_request.presenter_is_live()
				or bgm_epoch != _bgm_epoch
			):
				delivered = false
				break
			bgm_operation_committed.emit(
				operation, bgm_request.get_committed_state())
			operation_index += 1
		if not _presentation_operation_epochs_are_current(
			stage_epoch,
			visibility_epoch,
			avatar_epoch,
			chapter_epoch,
			loop_se_epoch,
			bgm_epoch,
			uses_stage,
			uses_dialogue_visibility,
			uses_dialogue_avatar,
			uses_chapter_indicator,
			uses_loop_se,
			uses_bgm,
		):
			delivered = false
			break
	for stage_request_value: Variant in stage_requests.values():
		(stage_request_value as StageOperationRequest)._finish(
			delivered, false, _stage_participant_authority)
	for clear_request_value: Variant in dialogue_clear_requests.values():
		(clear_request_value as DialogueClearOperationRequest)._finish(
			delivered, false, _dialogue_clear_participant_authority)
	for avatar_request_value: Variant in dialogue_avatar_requests.values():
		(avatar_request_value as DialogueAvatarOperationRequest)._finish(
			delivered, false, _dialogue_avatar_participant_authority)
	for chapter_request_value: Variant in chapter_requests.values():
		(chapter_request_value as ChapterIndicatorRequest)._finish(
			delivered, false, _chapter_indicator_participant_authority)
	for loop_request_value: Variant in loop_se_requests.values():
		(loop_request_value as LoopSeOperationRequest)._finish(
			delivered, false, _loop_se_participant_authority)
	for bgm_request_value: Variant in bgm_requests.values():
		(bgm_request_value as BgmOperationRequest)._finish(
			delivered, false, _bgm_participant_authority)
	_bgm_epoch_stack.pop_back()
	_loop_se_epoch_stack.pop_back()
	_dialogue_avatar_epoch_stack.pop_back()
	_dialogue_visibility_epoch_stack.pop_back()
	_dialogue_visibility_dispatch_stack.pop_back()
	_stage_operation_epoch_stack.pop_back()
	_stage_operation_dispatch_stack.pop_back()
	presentation_operation_request_finished.emit(
		request_id,
		delivered
		and _presentation_operation_epochs_are_current(
			stage_epoch,
			visibility_epoch,
			avatar_epoch,
			chapter_epoch,
			loop_se_epoch,
			bgm_epoch,
			uses_stage,
			uses_dialogue_visibility,
			uses_dialogue_avatar,
			uses_chapter_indicator,
			uses_loop_se,
			uses_bgm,
		),
	)


func _presentation_operation_epochs_are_current(
	stage_epoch: int,
	visibility_epoch: int,
	avatar_epoch: int,
	chapter_epoch: int,
	loop_se_epoch: int,
	bgm_epoch: int,
	uses_stage: bool,
	uses_dialogue_visibility: bool,
	uses_dialogue_avatar: bool,
	uses_chapter_indicator: bool,
	uses_loop_se: bool,
	uses_bgm: bool,
) -> bool:
	return (
		(not uses_stage or stage_epoch == _stage_operation_epoch)
		and (
			not uses_dialogue_visibility
			or visibility_epoch == _dialogue_visibility_epoch
		)
		and (
			not uses_dialogue_avatar
			or avatar_epoch == _dialogue_avatar_epoch
		)
		and (
			not uses_chapter_indicator
			or chapter_epoch == _chapter_indicator_epoch
		)
		and (not uses_loop_se or loop_se_epoch == _loop_se_epoch)
		and (not uses_bgm or bgm_epoch == _bgm_epoch)
	)


func is_stage_operation_request_active(request_id: int) -> bool:
	if request_id in _stage_operation_dispatch_stack:
		return true
	for request in _stage_operation_queue:
		if int(request.get("request_id", 0)) == request_id:
			return true
	for request in _presentation_operation_queue:
		if int(request.get("request_id", 0)) != request_id:
			continue
		for operation_value: Variant in request.get("operations", []):
			if operation_value is StagePresentationOperation:
				return true
	return false


func is_applying_typed_stage_request() -> bool:
	return _applying_stage_request != null


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
	_run_stage_reset_transaction(Callable())


## Reset the old Stage generation and cut-project canonical state as one
## lifecycle transaction. Reentrant authored winners dispatch only after both
## legacy signals have completed, so the old snapshot cannot overwrite them.
func reset_and_apply_stage_state(layers: Dictionary) -> void:
	var defensive_layers := layers.duplicate(true)
	_run_stage_reset_transaction(func(reset_epoch: int) -> void:
		if reset_epoch != _stage_operation_epoch:
			return
		_stage_projection_epoch_stack.append(reset_epoch)
		stage_state_apply_requested.emit(defensive_layers.duplicate(true))
		_stage_projection_epoch_stack.pop_back()
	)


func _run_stage_reset_transaction(after_reset_consumers: Callable) -> void:
	# Mark the lifecycle boundary before request cancellation or any signal can
	# re-enter Stage submission. Reentrant winners retain normal request ids and
	# validation but remain queued until every reset consumer (and an optional
	# canonical cut projection) has completed.
	_stage_reset_depth += 1
	_mark_presentation_projection_retirement_started()
	_stage_operation_epoch += 1
	var reset_epoch := _stage_operation_epoch
	var cancelled_requests: Array[Dictionary] = []
	var retained_requests: Array[Dictionary] = []
	for request: Dictionary in _stage_operation_queue:
		if _request_belongs_to_retained_projection(request):
			request["epoch"] = reset_epoch
			retained_requests.append(request)
		else:
			cancelled_requests.append(request)
	_stage_operation_queue = retained_requests
	var cancelled_presentation_requests: Array[Dictionary] = []
	var retained_presentation_requests: Array[Dictionary] = []
	for request: Dictionary in _presentation_operation_queue:
		if _request_belongs_to_retained_projection(request):
			request["stage_epoch"] = reset_epoch
			retained_presentation_requests.append(request)
			continue
		var has_stage_child := false
		for operation_value: Variant in request.get("operations", []):
			if operation_value is StagePresentationOperation:
				has_stage_child = true
				break
		if has_stage_child:
			cancelled_presentation_requests.append(request)
		else:
			retained_presentation_requests.append(request)
	_presentation_operation_queue = retained_presentation_requests
	for request: Dictionary in cancelled_requests:
		stage_operation_request_finished.emit(
			int(request.get("request_id", 0)),
			false,
		)
	for request: Dictionary in cancelled_presentation_requests:
		presentation_operation_request_finished.emit(
			int(request.get("request_id", 0)),
			false,
		)
	# A cancelled-request callback can establish a newer nested lifecycle before
	# this transaction reaches its reset signal. In that case the old boundary
	# has no remaining authority and must not publish a stale consumer tail.
	if reset_epoch == _stage_operation_epoch:
		_stage_reset_epoch_stack.append(reset_epoch)
		stage_visuals_reset_requested.emit()
		_stage_reset_epoch_stack.pop_back()
	if (
		after_reset_consumers.is_valid()
		and reset_epoch == _stage_operation_epoch
	):
		after_reset_consumers.call(reset_epoch)
	_stage_reset_depth -= 1
	if _stage_reset_depth == 0 and not _stage_operation_dispatching:
		_drain_all_presentation_operation_queues()


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
	if _runtime_audio_shutdown_started:
		stage_operation_request_finished.emit(request_id, false)
		return request_id
	for operation in operations:
		if not StageLayerState.validate_operation(operation, true):
			push_warning(
				"SignalBus: rejected invalid stage operation batch %d" % request_id
			)
			stage_operation_request_finished.emit(request_id, false)
			return request_id
		var transition_kind := String(
			(operation as Dictionary).get("transition", "cut"))
		if StageTransitionSpec.is_projection_effect(transition_kind):
			push_error(
				"SignalBus: projection Stage transition '%s' requires the typed PresentationDirector"
				% transition_kind)
			stage_operation_request_finished.emit(request_id, false)
			return request_id
	_stage_operation_queue.append({
		"operations": operations.duplicate(true),
		"force_cut": force_cut,
		"request_id": request_id,
		"epoch": _stage_operation_epoch,
		"on_dispatch_started": on_dispatch_started,
		"enqueue_serial": _presentation_enqueue_serial,
		"projection_lifecycle_id": _active_presentation_projection_lifecycle_id,
		"born_after_retirement": _presentation_projection_retirement_started,
	})
	_presentation_enqueue_serial += 1
	if (
		_stage_operation_dispatching
		or _stage_reset_depth > 0
		or _presentation_projection_depth > 0
		or _presentation_unified_draining
	):
		return request_id
	_drain_all_presentation_operation_queues()
	return request_id


func _drain_stage_operation_queue() -> void:
	if (
		_stage_operation_dispatching
		or _stage_reset_depth > 0
		or _presentation_projection_depth > 0
		or _presentation_unified_draining
	):
		return
	while not _stage_operation_queue.is_empty():
		_drain_stage_operation_queue_once()
		if (
			_stage_reset_depth > 0
			or _presentation_projection_depth > 0
			or _presentation_unified_draining
		):
			return
	_stage_operation_dispatching = false


func _drain_stage_operation_queue_once() -> void:
	if _stage_operation_queue.is_empty():
		return
	_stage_operation_dispatching = true
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


func _drain_all_presentation_operation_queues() -> void:
	if (
		_stage_reset_depth > 0
		or _presentation_projection_depth > 0
		or _presentation_unified_draining
	):
		return
	_presentation_unified_draining = true
	while true:
		var next_queue := _next_presentation_queue_name()
		if next_queue == "":
			break
		match next_queue:
			"stage":
				_drain_stage_operation_queue_once()
			"dialogue":
				_drain_dialogue_visibility_queue_once()
			"mixed":
				_drain_presentation_operation_queue_once()
	_presentation_unified_draining = false


func _next_presentation_queue_name() -> String:
	var candidates: Array[Dictionary] = []
	if not _stage_operation_queue.is_empty():
		candidates.append({
			"queue": "stage",
			"serial": int(_stage_operation_queue[0].get("enqueue_serial", 0)),
		})
	if not _dialogue_visibility_queue.is_empty():
		candidates.append({
			"queue": "dialogue",
			"serial": int(_dialogue_visibility_queue[0].get("enqueue_serial", 0)),
		})
	if not _presentation_operation_queue.is_empty():
		candidates.append({
			"queue": "mixed",
			"serial": int(_presentation_operation_queue[0].get("enqueue_serial", 0)),
		})
	if candidates.is_empty():
		return ""
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("serial", 0)) < int(b.get("serial", 0))
	)
	return String(candidates[0].get("queue", ""))

# Audio
signal se_play(asset: String)
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
## Canonical backlog replay keeps each voice's per-segment DSP selection.
signal dialogue_voice_segment_replay_requested(segments: Array, character: String)

# Current chapter presentation
## Stable public identity/title event. The title is already resolved for the
## current TranslationServer locale. Identity/title are independent from the
## authored visibility target below.
signal current_chapter_changed(chapter_id: String, title: String)
## Transient all-or-none chapter binding preflight inside the Director batch.
## Presenter transition ownership is reported separately as exact receipts.
signal chapter_indicator_validate_requested(request: ChapterIndicatorRequest)
signal chapter_indicator_accept_requested(request: ChapterIndicatorRequest)
signal chapter_indicator_apply_requested(request: ChapterIndicatorRequest)
signal chapter_indicator_finish_requested(request_id: int)
signal chapter_indicator_request_finished(request_id: int, success: bool)
signal chapter_indicator_transition_receipt_started(
	presenter_instance_id: int,
	token: int,
	operation_request_id: int,
	generation: int,
)
signal chapter_indicator_transition_terminal(
	presenter_instance_id: int,
	token: int,
	operation_request_id: int,
	generation: int,
	outcome: StringName,
)
## Cut-only projection used after restore and when reverting a failed request.
## The generation lets every built-in presenter reject a stale outer signal tail.
signal chapter_indicator_state_apply_requested(visible: bool, generation: int)
## Cut projection for presenters that bind after validation and therefore are
## deliberately outside the current request's completion barrier.
signal chapter_indicator_projection_committed(visible: bool, generation: int)
## Visual lifecycle reset. This cancels the current barrier without changing
## the ScenarioContext-authored visibility target.
signal chapter_indicator_reset_requested(epoch: int)

var _chapter_indicator_epoch := 1
var _dispatching_chapter_indicator_request: ChapterIndicatorRequest
var _applying_chapter_indicator_request: ChapterIndicatorRequest
var _chapter_indicator_projection_active := false
var _chapter_indicator_projected_visible := false
var _chapter_indicator_participant_authority := RefCounted.new()
var _chapter_indicator_registrar_authority: Object
var _chapter_indicator_participants: Dictionary = {}


## The composition root owns concrete-presentation admission. SignalBus keeps
## only an opaque registrar authority plus exact weak participant identities,
## preserving the Core/Bus -> Presentation dependency direction.
func configure_chapter_indicator_registrar(authority: Object) -> bool:
	if authority == null:
		return false
	if _chapter_indicator_registrar_authority == null:
		_chapter_indicator_registrar_authority = authority
	return _chapter_indicator_registrar_authority == authority


func register_chapter_indicator_presenter(
	presenter: Object,
	registrar_authority: Object,
) -> RefCounted:
	if (
		registrar_authority != _chapter_indicator_registrar_authority
		or presenter == null
		or not is_instance_valid(presenter)
		or not presenter is Node
		or (presenter as Node).is_queued_for_deletion()
	):
		return null
	var presenter_id := presenter.get_instance_id()
	var existing: Dictionary = _chapter_indicator_participants.get(
		presenter_id, {})
	if not existing.is_empty():
		var existing_presenter: Object = (
			(existing.get("presenter") as WeakRef).get_ref()
		)
		if existing_presenter == presenter:
			return existing.get("capability") as RefCounted
	var capability := RefCounted.new()
	_chapter_indicator_participants[presenter_id] = {
		"presenter": weakref(presenter),
		"capability": capability,
	}
	return capability


func unregister_chapter_indicator_presenter(
	presenter: Object,
	capability: RefCounted,
	registrar_authority: Object,
) -> void:
	if (
		registrar_authority != _chapter_indicator_registrar_authority
		or presenter == null
		or not is_instance_valid(presenter)
	):
		return
	var presenter_id := presenter.get_instance_id()
	if _chapter_indicator_participant_identity_matches(presenter, capability):
		_chapter_indicator_participants.erase(presenter_id)


func reject_chapter_indicator_request(
	request: ChapterIndicatorRequest,
	presenter: Object,
	capability: RefCounted,
	error: String,
) -> bool:
	if (
		request == null
		or request != _dispatching_chapter_indicator_request
		or not _chapter_indicator_participant_is_current(presenter, capability)
		or not request.is_target(presenter)
	):
		return false
	return request._reject(error, _chapter_indicator_participant_authority)


func validate_chapter_indicator_request(
	request: ChapterIndicatorRequest,
	presenter: Object,
	capability: RefCounted,
) -> bool:
	if (
		request == null
		or request != _dispatching_chapter_indicator_request
		or not _chapter_indicator_participant_is_current(presenter, capability)
		or not request.is_target(presenter)
	):
		return false
	return request._validate(presenter, _chapter_indicator_participant_authority)


func accept_chapter_indicator_request(
	request: ChapterIndicatorRequest,
	presenter: Object,
	capability: RefCounted,
) -> bool:
	if (
		request == null
		or request != _dispatching_chapter_indicator_request
		or not _chapter_indicator_participant_is_current(presenter, capability)
		or not request.is_target(presenter)
	):
		return false
	return request._accept(presenter, _chapter_indicator_participant_authority)


func acknowledge_chapter_indicator_apply(
	request: ChapterIndicatorRequest,
	presenter: Object,
	capability: RefCounted,
) -> bool:
	if (
		request == null
		or request != _applying_chapter_indicator_request
		or not _chapter_indicator_participant_is_current(presenter, capability)
		or not request.is_target(presenter)
	):
		return false
	return request._apply(presenter, _chapter_indicator_participant_authority)


func _chapter_indicator_participant_is_current(
	presenter: Object,
	capability: Object,
) -> bool:
	if (
		presenter == null
		or capability == null
		or not is_instance_valid(presenter)
		or not presenter is Node
		or (presenter as Node).is_queued_for_deletion()
	):
		return false
	var entry: Dictionary = _chapter_indicator_participants.get(
		presenter.get_instance_id(), {})
	if entry.is_empty() or entry.get("capability") != capability:
		return false
	var registered: Object = (entry.get("presenter") as WeakRef).get_ref()
	return registered == presenter


func _chapter_indicator_participant_identity_matches(
	presenter: Object,
	capability: Object,
) -> bool:
	if presenter == null or capability == null or not is_instance_valid(presenter):
		return false
	var entry: Dictionary = _chapter_indicator_participants.get(
		presenter.get_instance_id(), {})
	if entry.is_empty() or entry.get("capability") != capability:
		return false
	var registered: Object = (entry.get("presenter") as WeakRef).get_ref()
	return registered == presenter


func _chapter_indicator_participant_snapshot() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for presenter_id: int in _chapter_indicator_participants.keys():
		var entry: Dictionary = _chapter_indicator_participants[presenter_id]
		var weak_presenter: WeakRef = entry.get("presenter")
		var presenter: Object = weak_presenter.get_ref() if weak_presenter != null else null
		var capability: Object = entry.get("capability")
		if not _chapter_indicator_participant_is_current(presenter, capability):
			_chapter_indicator_participants.erase(presenter_id)
			continue
		result.append({
			"presenter": presenter,
			"capability": capability,
		})
	return result


## Runtime-owned metadata delivery. The two-argument public signal remains a
## compatibility surface; built-in presenters consult the stack-scoped owner so
## a nested context replacement cannot let an outer stale tail overwrite them.
func emit_current_chapter_changed(
	chapter_id: String,
	title: String,
	owner_validator: Callable,
) -> bool:
	if not _chapter_event_owner_is_current(owner_validator):
		return false
	_current_chapter_event_stack.append({
		"chapter_id": chapter_id,
		"title": title,
		"owner_validator": owner_validator,
		"dispatch_started": false,
		"nested_raw_dispatch_count": 0,
		"dispatch_consumers": {},
	})
	current_chapter_changed.emit(chapter_id, title)
	_current_chapter_event_stack.pop_back()
	return _chapter_event_owner_is_current(owner_validator)


func current_chapter_event_is_current(
	chapter_id: String,
	title: String,
	consumer_id: int = 0,
) -> bool:
	var frame := _current_chapter_event_frame(chapter_id, title)
	if frame.is_empty() or _chapter_event_dispatch_is_nested_raw(frame, consumer_id):
		return true
	return _chapter_event_owner_is_current(
		frame.get("owner_validator", Callable()))


func _on_current_chapter_dispatch_started(
	chapter_id: String,
	title: String,
) -> void:
	var frame := _current_chapter_event_frame(chapter_id, title)
	if frame.is_empty():
		return
	if not bool(frame.get("dispatch_started", false)):
		frame["dispatch_started"] = true
		return
	frame["nested_raw_dispatch_count"] = int(
		frame.get("nested_raw_dispatch_count", 0)) + 1


func _current_chapter_event_frame(
	chapter_id: String,
	title: String,
) -> Dictionary:
	if _current_chapter_event_stack.is_empty():
		return {}
	var frame: Dictionary = _current_chapter_event_stack[-1]
	if (
		String(frame.get("chapter_id", "")) != chapter_id
		or String(frame.get("title", "")) != title
	):
		return {}
	return frame


func _chapter_event_dispatch_is_nested_raw(
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


func _chapter_event_owner_is_current(owner_validator: Callable) -> bool:
	return owner_validator.is_valid() and bool(owner_validator.call())


## Cancel every in-flight authored transition and hard-reset all bound visuals.
## A lifecycle cancellation is not an authored command failure and never changes
## the ScenarioContext target captured by save/rollback.
func reset_chapter_indicator_presentation() -> bool:
	_mark_presentation_projection_retirement_started()
	_chapter_indicator_epoch += 1
	var reset_epoch := _chapter_indicator_epoch
	_retain_projection_chapter_indicator_epoch(reset_epoch)
	_chapter_indicator_projection_active = false
	_chapter_indicator_projected_visible = false
	_dispatching_chapter_indicator_request = null
	_applying_chapter_indicator_request = null
	chapter_indicator_reset_requested.emit(reset_epoch)
	return false


## Publish a cut projection with exact dispatch ownership. If an earlier
## listener synchronously projects a newer context, later listeners ignore this
## outer tail instead of overwriting the fresh state.
func apply_chapter_indicator_state(visible: bool) -> int:
	# State, reset, and authored chapter requests share one ownership generation.
	# Queued mixed requests born inside this projection retain the new chapter
	# epoch; requests that do not author chapter ignore this domain's generation.
	_mark_presentation_projection_retirement_started()
	_chapter_indicator_epoch += 1
	var generation := _chapter_indicator_epoch
	_retain_projection_chapter_indicator_epoch(generation)
	_chapter_indicator_projection_active = true
	_chapter_indicator_projected_visible = visible
	_dispatching_chapter_indicator_request = null
	_applying_chapter_indicator_request = null
	chapter_indicator_state_apply_requested.emit(visible, generation)
	return generation


func _retain_projection_chapter_indicator_epoch(epoch: int) -> void:
	for request: Dictionary in _presentation_operation_queue:
		if _request_belongs_to_retained_projection(request):
			request["chapter_epoch"] = epoch


func commit_chapter_indicator_projection(visible: bool) -> int:
	_chapter_indicator_projection_active = true
	_chapter_indicator_projected_visible = visible
	chapter_indicator_projection_committed.emit(
		visible, _chapter_indicator_epoch)
	return _chapter_indicator_epoch


func _report_chapter_indicator_rejection(
	source: Dictionary,
	errors: Array,
) -> void:
	var messages: Array[String] = []
	for error_value: Variant in errors:
		messages.append(String(error_value))
	if messages.is_empty():
		messages.append("request invalidated during preflight")
	push_error(
		"%s chapter indicator request rejected: %s"
		% [_chapter_indicator_source_label(source), "; ".join(messages)])


func _report_dialogue_avatar_rejection(
	source: Dictionary,
	errors: Array,
) -> void:
	var messages: Array[String] = []
	for error_value: Variant in errors:
		messages.append(String(error_value))
	if messages.is_empty():
		messages.append("request invalidated during preflight")
	push_error(
		"%s dialogue avatar request rejected: %s"
		% [_chapter_indicator_source_label(source), "; ".join(messages)])


func _report_stage_rejection(errors: Array) -> void:
	if errors.is_empty():
		push_error("[runtime] Stage request rejected: preflight invalidated")
		return
	for error_value: Variant in errors:
		var entry: Dictionary = (
			error_value if error_value is Dictionary else {"error": String(error_value)})
		var source: Dictionary = entry.get("source", {})
		var message := String(entry.get("error", "preflight invalidated"))
		push_error(
			"%s Stage request rejected: %s"
			% [_chapter_indicator_source_label(source), message])


func _report_loop_se_rejection(source: Dictionary, errors: Array) -> void:
	var messages: Array[String] = []
	for error_value: Variant in errors:
		messages.append(String(error_value))
	if messages.is_empty():
		messages.append("request invalidated during preflight")
	push_error(
		"%s loop-SE request rejected: %s"
		% [_chapter_indicator_source_label(source), "; ".join(messages)])


func _report_bgm_rejection(source: Dictionary, errors: Array) -> void:
	var messages: Array[String] = []
	for error_value: Variant in errors:
		messages.append(String(error_value))
	if messages.is_empty():
		messages.append("request invalidated during preflight")
	push_error(
		"%s BGM request rejected: %s"
		% [_chapter_indicator_source_label(source), "; ".join(messages)])


func chapter_indicator_projection_is_current(generation: int) -> bool:
	return generation == _chapter_indicator_epoch


func current_chapter_indicator_epoch() -> int:
	return _chapter_indicator_epoch


func chapter_indicator_reset_is_current(epoch: int) -> bool:
	return epoch == _chapter_indicator_epoch


func is_chapter_indicator_projection_active() -> bool:
	return _chapter_indicator_projection_active


func get_projected_chapter_indicator_visibility() -> bool:
	return _chapter_indicator_projected_visible


func _chapter_indicator_source_label(source: Dictionary) -> String:
	var source_path := String(source.get("source_path", "")).strip_edges()
	var scenario_id := String(source.get("scenario_id", "")).strip_edges()
	var label := source_path if not source_path.is_empty() else scenario_id
	var line := int(source.get("line", 0))
	if not label.is_empty() and line > 0:
		return "[%s:%d]" % [label, line]
	if not label.is_empty():
		return "[%s]" % label
	if line > 0:
		return "[line %d]" % line
	return "[runtime]"

# Choice
signal choice_show(prompt: String, options: Array)
signal choice_hide()
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
