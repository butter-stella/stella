## Global signal bus for decoupling Core and Presentation layers.
## Registered as an Autoload singleton.
extends Node

# Dialogue
## Unified dialogue signal — both normal and @combine dialogues flow through here.
## segments: Array of {text: String, voice: String, stage_ops: Array}
## A normal single-line dialogue has segments.size() == 1. A @combine block has
## multiple segments; voices and named-stage cues advance at segment boundaries.
## Inline [expr:expression] markers belong only to the text/avatar timeline. Either
## way, the dialogue is one unit for advance/skip/backlog.
signal show_dialogue(character: String, segments: Array, mode: String)
signal hide_dialogue()
signal advance_requested()

# Stack-scoped metadata keeps the dialogue payload focused while
# DialogueHandler synchronously attaches an STLA presentation profile and the
# current runtime NVL page activation.
# DialoguePresenter copies the current value before its first await.
var _dialogue_presentation_stack: Array[Dictionary] = []


func emit_show_dialogue(
	character: String,
	segments: Array,
	mode: String,
	presentation_profile: Dictionary = {},
	declarative_presentation: bool = false,
	nvl_page_key: String = "",
) -> void:
	_dialogue_presentation_stack.append({
		"profile": presentation_profile.duplicate(true),
		"declarative": declarative_presentation,
		"nvl_page_key": nvl_page_key,
	})
	show_dialogue.emit(character, segments, mode)
	_dialogue_presentation_stack.pop_back()


func current_dialogue_presentation_profile() -> Dictionary:
	if _dialogue_presentation_stack.is_empty():
		return {}
	return _dialogue_presentation_stack[-1]["profile"].duplicate(true)


func current_dialogue_uses_declarative_presentation() -> bool:
	if _dialogue_presentation_stack.is_empty():
		return false
	return _dialogue_presentation_stack[-1]["declarative"]


func current_dialogue_nvl_page_key() -> String:
	if _dialogue_presentation_stack.is_empty():
		return ""
	return _dialogue_presentation_stack[-1]["nvl_page_key"]

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
