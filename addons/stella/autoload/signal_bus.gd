## Global signal bus for decoupling Core and Presentation layers.
## Registered as an Autoload singleton.
extends Node

const ChapterIndicatorRequest = preload(
	"res://addons/stella/core/data/chapter_indicator_request.gd")
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
signal dialogue_visibility_operations_requested(operations: Array, force_cut: bool)
signal presentation_operation_request_finished(request_id: int, delivered: bool)
signal presentation_projection_lifecycle_finished(lifecycle_id: int)
signal dialogue_visibility_visuals_reset_requested()
signal dialogue_visibility_state_apply_requested(
	visibility: Dictionary,
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

# Runtime-owned graceful shutdown is a synchronous capability handshake with
# the same unique AudioPresenter that owns BGM and loop-SE projection. The
# Runtime observes the later AudioServer mix boundary; the Bus only proves that
# all Stella audio was retired before that observation begins.
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


func register_loop_se_presenter(
	presenter: Object,
	registrar_authority: Object,
) -> RefCounted:
	if (
		registrar_authority != _loop_se_registrar_authority
		or presenter == null
		or not is_instance_valid(presenter)
		or not presenter is Node
		or (presenter as Node).is_queued_for_deletion()
	):
		return null
	var registered := _current_loop_se_presenter()
	if registered != null:
		if registered == presenter:
			return _loop_se_capability
		return null
	_loop_se_presenter = weakref(presenter)
	_loop_se_capability = RefCounted.new()
	return _loop_se_capability


func announce_loop_se_presenter_registered(
	presenter: Object,
	capability: RefCounted,
) -> bool:
	if not _loop_se_participant_identity_matches(presenter, capability):
		return false
	loop_se_presenter_registered.emit()
	return true


func unregister_loop_se_presenter(
	presenter: Object,
	capability: RefCounted,
	registrar_authority: Object,
) -> void:
	if (
		registrar_authority == _loop_se_registrar_authority
		and _loop_se_participant_identity_matches(presenter, capability)
	):
		_loop_se_presenter = null
		_loop_se_capability = null


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
	if not LoopSeChannelState.validate_channels(channels, true):
		return 0
	return _reset_loop_se_projection(channels)


func apply_loop_se_targets_state(
	channels: Dictionary,
	targets: Array,
) -> bool:
	if not LoopSeChannelState.validate_channels(channels, true):
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


func register_bgm_presenter(
	presenter: Object,
	registrar_authority: Object,
) -> RefCounted:
	if (
		registrar_authority != _bgm_registrar_authority
		or presenter == null
		or not is_instance_valid(presenter)
		or not presenter is Node
		or (presenter as Node).is_queued_for_deletion()
	):
		return null
	var registered := _current_bgm_presenter()
	if registered != null:
		return _bgm_capability if registered == presenter else null
	_bgm_presenter = weakref(presenter)
	_bgm_capability = RefCounted.new()
	return _bgm_capability


func announce_bgm_presenter_registered(
	presenter: Object,
	capability: RefCounted,
) -> bool:
	if not _bgm_participant_identity_matches(presenter, capability):
		return false
	bgm_presenter_registered.emit()
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


func unregister_bgm_presenter(
	presenter: Object,
	capability: RefCounted,
	registrar_authority: Object,
) -> void:
	if (
		registrar_authority == _bgm_registrar_authority
		and _bgm_participant_identity_matches(presenter, capability)
	):
		_bgm_presenter = null
		_bgm_capability = null


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
	if not BgmChannelState.validate_snapshot_state(state, true):
		return 0
	return _reset_bgm_projection(state)


func apply_bgm_state(state: Dictionary) -> bool:
	if not BgmChannelState.validate_snapshot_state(state, true):
		return false
	bgm_state_apply_requested.emit(state.duplicate(true), _bgm_epoch)
	return true


## Title configuration uses the same Runtime-owned channel projection but does
## not create an authored lifecycle owner or a save-state commit.
func apply_title_bgm_cut(asset: String) -> int:
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


## Like projection validity, direct compatibility emits remain valid. Reset
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


## The optional apply callback reports the exact channels in each contiguous
## authored run immediately before its consumer signal. Director uses this to
## distinguish mutation-free participant rejection from partial apply failure.
func emit_presentation_operations(
	operations: Array,
	force_cut: bool = false,
	request_id: int = 0,
	on_apply_started: Callable = Callable(),
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
			or (operation is LoopSePresentationOperation
				and not LoopSeChannelState.validate_operation(payload, true))
			or (operation is BgmPresentationOperation
				and not BgmChannelState.validate_operation(payload, true))
			or not operation is StagePresentationOperation
				and not operation is DialogueVisibilityPresentationOperation
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
		"stage_epoch": _stage_operation_epoch,
		"visibility_epoch": _dialogue_visibility_epoch,
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
	var chapter_epoch := int(request.get("chapter_epoch", 0))
	var loop_se_epoch := int(request.get("loop_se_epoch", 0))
	var bgm_epoch := int(request.get("bgm_epoch", 0))
	var operations: Array = request.get("operations", [])
	var force_cut := bool(request.get("force_cut", false))
	var apply_started_callback: Callable = request.get(
		"on_apply_started", Callable())
	var uses_stage := false
	var uses_dialogue_visibility := false
	var uses_chapter_indicator := false
	var uses_loop_se := false
	var uses_bgm := false
	for operation_value: Variant in operations:
		if operation_value is StagePresentationOperation:
			uses_stage = true
		elif operation_value is DialogueVisibilityPresentationOperation:
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
	_loop_se_epoch_stack.append(loop_se_epoch)
	_bgm_epoch_stack.append(bgm_epoch)
	var chapter_requests: Dictionary = {}
	var loop_se_requests: Dictionary = {}
	var bgm_requests: Dictionary = {}
	var preflight_valid := true
	for operation_value: Variant in operations:
		if operation_value is ChapterIndicatorPresentationOperation:
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
	_dispatching_chapter_indicator_request = null
	_dispatching_loop_se_request = null
	_dispatching_bgm_request = null
	var epochs_valid := _presentation_operation_epochs_are_current(
		stage_epoch,
		visibility_epoch,
		chapter_epoch,
		loop_se_epoch,
		bgm_epoch,
		uses_stage,
		uses_dialogue_visibility,
		uses_chapter_indicator,
		uses_loop_se,
		uses_bgm,
	)
	if not preflight_valid or not epochs_valid:
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
			if apply_started_callback.is_valid():
				apply_started_callback.call(stage_channels)
			stage_operations_requested.emit(stage_run, force_cut)
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
			chapter_epoch,
			loop_se_epoch,
			bgm_epoch,
			uses_stage,
			uses_dialogue_visibility,
			uses_chapter_indicator,
			uses_loop_se,
			uses_bgm,
		):
			delivered = false
			break
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
			chapter_epoch,
			loop_se_epoch,
			bgm_epoch,
			uses_stage,
			uses_dialogue_visibility,
			uses_chapter_indicator,
			uses_loop_se,
			uses_bgm,
		),
	)


func _presentation_operation_epochs_are_current(
	stage_epoch: int,
	visibility_epoch: int,
	chapter_epoch: int,
	loop_se_epoch: int,
	bgm_epoch: int,
	uses_stage: bool,
	uses_dialogue_visibility: bool,
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
	for request: Dictionary in _presentation_operation_queue:
		if _request_belongs_to_retained_projection(request):
			request["stage_epoch"] = reset_epoch
	for request: Dictionary in cancelled_requests:
		stage_operation_request_finished.emit(
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
