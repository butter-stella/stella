## Displays dialogue text with typewriter effect.
## Supports ADV (bottom box), NVL (fullscreen accumulate), overlay modes.
## Includes bottom toolbar for game controls.
## Handles skip (toolbar + Ctrl held) and auto-play.
extends Control

const DEFAULT_NVL_ENTRY_PREFIX := ""
const DEFAULT_NVL_ENTRY_SEPARATOR := "\n"
const _CHARACTER_MAP_SENTINEL := "\u2060"
const _LIFECYCLE_HIDE := &"hide"
const _LIFECYCLE_TRANSITION := &"transition"
const _LIFECYCLE_EXIT := &"exit"

@export_group("Dialogue Presentation")
## Advanced scene-side fallback. Normal projects declare profiles in STLA.
@export var presentation_profile: DialoguePresentationProfile
## Optional Control that receives the profile's text rectangle. When empty,
## the TextLabel itself is used. Prefer a non-Container child for exact rects.
@export_node_path("Control") var text_rect_target_path: NodePath

@onready var name_label: Label = %NameLabel
@onready var text_label: RichTextLabel = %TextLabel
@onready var toolbar: HBoxContainer = %Toolbar
var _avatar_texture: TextureRect
var _avatar_container: Control

var _char_interval: float = 0.03  # seconds per character
var _is_typing: bool = false
var _nvl_text: String = ""  # current NVL page, including the active entry
var _nvl_render_source: String = ""
var _nvl_has_entries: bool = false
var _nvl_incremental_document_valid: bool = false
var _nvl_visible_characters: int = 0
var _active_nvl_page_key: String = ""
## Test-observable counters keep the plain NVL hot path honest without relying
## on machine-specific microbenchmarks alone.
var _nvl_full_text_rebuild_count: int = 0
var _nvl_incremental_append_count: int = 0
var _parsed_character_full_parse_count: int = 0
var _current_mode: String = "adv"
var _ui_hidden: bool = false
var _ctrl_held: bool = false  # Ctrl key skip
# Cached position of the currently displayed line — filled from engine.context
# on _on_show_dialogue, consulted by _should_skip_current() for read-aware
# toolbar skip, written by _mark_current_line_read() when the user has seen
# the line. Read flags intentionally are NOT reverted by rollback (backlog /
# flowchart / choice rewind) — once seen, always seen. See stella_runtime.gd:436.
var _current_scenario_id: String = ""
var _current_scene_id: String = ""
var _current_command_index: int = -1
var _current_voice: String = ""  # current dialogue voice asset
var _current_voice_character: String = ""
var _voice_playing: bool = false
var _active_voice_token: int = -1
var _current_character: String = ""  # current speaking character for avatar
var _current_avatar_expression: String = ""
var _config_loader: CharacterConfigLoader
## Current-line avatar state. Every dialogue starts from `default`; inline
## [expr:name] markers update this cache and the dialogue avatar only. Stage
## layers are changed exclusively by stage cues.
var _avatar_expressions: Dictionary = {}  # character_id -> avatar expression

# Store original anchors for switching between ADV and NVL layout
var _adv_anchor_top: float
var _adv_offset_top: float
var _dialogue_bg: Control
var _text_area: VBoxContainer
var _text_rect_target: Control
var _authored_presentation: Dictionary = {}
var _auxiliary_visibility_baseline: Dictionary = {}
var _profile_warning_keys: Dictionary = {}
var _active_stla_mode_profile: DialogueModeProfile
var _active_uses_stla_presentation: bool = false

# A configured wait glyph is presentation-only. It is created lazily so
# projects that do not opt in keep the exact legacy scene tree and visuals.
var _advance_indicator: DialogueAdvanceIndicator
var _advance_indicator_offset: Vector2 = Vector2.ZERO
var _indicator_candidate_dialogue_gen: int = -1
var _indicator_token: int = 0
var _dialogue_ready: bool = false
var _indicator_operation_depth: int = 0
var _indicator_configuration_revision: int = 0
var _indicator_deferred_action: String = ""
var _indicator_deferred_gen: int = -1
var _indicator_flushing_deferred: bool = false
var _skip_pending_dialogue_gen: int = -1
var _auto_pending_dialogue_gen: int = -1
## Monotonic ownership for an Auto tail. Dialogue generations identify the
## displayed line, but toggling Auto off and back on can reuse that same line.
var _auto_attempt_serial: int = 0
var _auto_pending_attempt: int = -1

## Icon paths — set these to customize toolbar button icons.
var toolbar_icons: Dictionary = {
	"voice_replay": "", "auto": "", "skip": "", "backlog": "",
	"quick_save": "", "quick_load": "",
	"save": "", "load": "", "settings": "",
}
var _voice_replay_btn: Button
var _auto_btn: Button
var _skip_btn: Button
var _prev_choice_btn: Button
var _dialogue_gen: int = 0  # increments on each new dialogue, stale coroutines check this

# Dialogue state — owned by the currently visible/active dialogue. Only updated
# by _on_show_dialogue and cleared by _on_hide_dialogue. The toolbar 重听 button
# reads these so an in-flight backlog replay never corrupts what the toolbar
# would replay for the current dialogue.
var _dialogue_segments: Array = []
var _dialogue_voice_character: String = ""
var _dialogue_total_duration: float = 0.0
var _segment_presentation_complete: bool = false
var _next_stage_segment_index: int = 0
var _stage_transition_records: Dictionary = {}
var _finalization_transition_records: Dictionary = {}
var _stage_operation_request_owners: Dictionary = {}
var _stage_operation_request_results: Dictionary = {}
var _presentation_dispatch_depth: int = 0
var _presentation_dispatch_generations: Array[int] = []
var _queued_dialogue_requests: Array[Dictionary] = []
var _queued_voice_replay_request: Dictionary = {}
var _deferred_lifecycle_boundary: Dictionary = {}
var _boundary_operation_depth: int = 0
var _boundary_revision: int = 0
var _finalization_pending: bool = false
var _finalization_in_progress: bool = false

# Playback session state — owned by whichever voice queue is currently running
# (could be the dialogue's own initial playback, a toolbar replay, or a backlog
# replay request). Reset on every _start_voice_playback call.
var _playback_aborted: bool = false  # user clicked to skip the dialogue typewriter
var _playback_queue_active: bool = false  # voice queue coroutine is alive
var _playback_queue_gen: int = 0  # bumped to cancel any in-flight queue
var _playback_owner_dialogue_gen: int = -1
var _playback_dialogue_finished_emitted: bool = false
var _playback_total_duration: float = 0.0  # sum of all segment voice durations
var _playback_played_duration: float = 0.0  # cumulative duration of finished segments
var _playback_segment_durations: Array = []  # per-segment voice durations (0 if empty)
var _playback_voice_token: int = -1  # accepted AudioPresenter clip for this queue
# When false, the in-flight playback is for the backlog (or other external UI):
# the queue + audio still run, but the dialogue_voice_* signals (which drive the
# in-game progress bar) are suppressed so the dialogue toolbar bar stays quiet.
var _playback_is_dialogue: bool = true


func _ready():
	SignalBus.dialogue_requested.connect(_on_dialogue_requested)
	SignalBus.hide_dialogue.connect(_on_hide_dialogue)
	# SignalBus emits this pre-dispatch event before every public/raw advance.
	# A replacement Presenter created later in that same signal stack never sees
	# the old transition, so it cannot accidentally retire the newly shown line.
	SignalBus.advance_dispatch_started.connect(_on_advance_dispatch_started)
	SignalBus.voice_playback_event.connect(_on_voice_playback_event)
	SignalBus.dialogue_voice_replay_requested.connect(_on_dialogue_voice_replay_requested)
	SignalBus.scenario_started_event.connect(_on_scenario_started)
	SignalBus.scene_changed_event.connect(_on_scene_changed)
	SignalBus.scenario_ended_event.connect(_on_scenario_ended)
	StellaRuntime.game_state.state_changed.connect(_on_game_state_changed)
	StellaRuntime.auto_play.active_changed.connect(_on_auto_play_active_changed)
	StellaRuntime.skip_controller.active_changed.connect(_on_skip_active_changed)
	# Refresh the "回选项" button state whenever execution surfaces a new
	# command (dialogue or choice). Both signals fire AFTER the engine has
	# advanced to the command being presented, so can_jump_to_previous_choice()
	# reads the right current_cmd_uid. scenario lifecycle signals handle
	# start/end-of-run resets.
	SignalBus.dialogue_requested.connect(func(_request): _refresh_prev_choice_btn())
	SignalBus.choice_show.connect(func(_p, _o): _refresh_prev_choice_btn())
	SignalBus.scenario_started_event.connect(func(_id): _refresh_prev_choice_btn())
	SignalBus.scenario_ended_event.connect(func(_id): _refresh_prev_choice_btn())
	SignalBus.stage_transition_started.connect(_on_stage_transition_started)
	SignalBus.stage_operation_request_finished.connect(
		_on_stage_operation_request_finished
	)
	_config_loader = StellaRuntime.character_config_loader
	_avatar_container = get_node_or_null("%AvatarContainer")
	if _avatar_container:
		_avatar_texture = _avatar_container.get_node_or_null("AvatarTexture")
	_dialogue_bg = get_node_or_null("DialogueBg") as Control
	_text_area = get_node_or_null("HBox/TextArea")
	_text_rect_target = _resolve_text_rect_target()
	visible = false
	_adv_anchor_top = anchor_top
	_adv_offset_top = offset_top
	_setup_toolbar()
	# A replacement Presenter may enter the tree after the public controllers
	# were already enabled, so there may be no active_changed edge to repaint it.
	_update_toggle_buttons()
	_capture_authored_presentation()
	_validate_configured_profiles()
	text_label.resized.connect(_on_indicator_layout_changed)
	text_label.theme_changed.connect(_on_indicator_layout_changed)
	text_label.get_v_scroll_bar().value_changed.connect(
		func(_value): _on_indicator_layout_changed())


func _exit_tree() -> void:
	_request_lifecycle_boundary(_LIFECYCLE_EXIT)


func _setup_toolbar():
	if toolbar == null:
		return

	var buttons = [
		{"id": "voice_replay", "text": "重听", "callback": _on_voice_replay_pressed},
		{"id": "auto", "text": "自动", "callback": _on_auto_pressed},
		{"id": "skip", "text": "快进", "callback": _on_skip_pressed},
		{"id": "backlog", "text": "记录", "callback": _on_backlog_pressed},
		{"id": "prev_choice", "text": "回选项", "callback": _on_prev_choice_pressed},
		{"id": "quick_save", "text": "快存", "callback": _on_quick_save_pressed},
		{"id": "quick_load", "text": "快读", "callback": _on_quick_load_pressed},
		{"id": "save", "text": "存档", "callback": _on_save_pressed},
		{"id": "load", "text": "读档", "callback": _on_load_pressed},
		{"id": "settings", "text": "设置", "callback": _on_settings_pressed},
	]

	for child in toolbar.get_children():
		child.queue_free()

	for btn_info in buttons:
		var btn = Button.new()
		btn.flat = true
		btn.custom_minimum_size = Vector2(60, 30)
		btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		btn.pressed.connect(btn_info["callback"])
		btn.mouse_entered.connect(func(): btn.modulate = Color(1.2, 1.2, 1.2) if not _is_toggle_active(btn_info["id"]) else btn.modulate)
		btn.mouse_exited.connect(func(): _update_button_modulate(btn, btn_info["id"]))

		var icon_path = toolbar_icons.get(btn_info["id"], "")
		if icon_path != "" and FileAccess.file_exists(icon_path):
			var icon = load(icon_path) as Texture2D
			if icon:
				btn.icon = icon
				btn.text = ""
			else:
				btn.text = btn_info["text"]
		else:
			btn.text = btn_info["text"]

		toolbar.add_child(btn)

		if btn_info["id"] == "voice_replay":
			_voice_replay_btn = btn
			btn.visible = false
		elif btn_info["id"] == "auto":
			_auto_btn = btn
		elif btn_info["id"] == "skip":
			_skip_btn = btn
		elif btn_info["id"] == "prev_choice":
			_prev_choice_btn = btn
			btn.disabled = true  # no history at startup


func _on_voice_replay_pressed():
	# Replay the CURRENT dialogue's segments (read from dialogue state, never
	# from playback state — so an in-flight backlog replay can't corrupt this).
	if _dialogue_segments.size() == 0:
		return
	_request_voice_replay(
		_dialogue_voice_character, _dialogue_segments, true)


## External entry point for the backlog (or any other UI) to request replaying
## a list of voice assets. Plays via the same queue + audio path as the dialogue,
## but with `is_dialogue_playback = false` so the in-game progress bar / toolbar
## stays quiet (the backlog overlay has its own UI for feedback).
func _on_dialogue_voice_replay_requested(voices: Array, character: String) -> void:
	if voices.is_empty():
		return
	var segments: Array = []
	for v in voices:
		segments.append({
			"text": "",
			"voice": String(v),
		})
	_request_voice_replay(character, segments, false)


## Replay is audio-only: it never folds or redispatches authored stage cues.
## If an owned stage batch is currently being delivered, park the newest replay
## until every listener has consumed that batch. A synchronously queued SHOW has
## higher priority and discards this request when it takes ownership.
func _request_voice_replay(
	character: String,
	segments: Array,
	is_dialogue_playback: bool,
) -> void:
	if segments.is_empty():
		return
	# SHOW/hide/scene boundaries own the retiring lifecycle. A FINISHED callback
	# cannot use replay to replace that ownership before the boundary commits.
	if (
		_boundary_operation_depth > 0
		or not _queued_dialogue_requests.is_empty()
		or not _deferred_lifecycle_boundary.is_empty()
	):
		return
	var request := {
		"character": character,
		"segments": segments.duplicate(true),
		"dialogue_gen": _dialogue_gen,
		"is_dialogue_playback": is_dialogue_playback,
	}
	if _presentation_dispatch_depth > 0 or _finalization_in_progress:
		_queued_voice_replay_request = request
		return
	_begin_voice_replay(request)


func _begin_voice_replay(request: Dictionary) -> void:
	var owner_gen := int(request.get("dialogue_gen", -1))
	if owner_gen != _dialogue_gen:
		return
	var retiring_queue_gen := _playback_queue_gen
	# A request already inside raw stage signal delivery cannot be revoked. Keep
	# replay deferred so its late listeners still belong to the old queue.
	if _voice_queue_has_dispatching_stage_request(retiring_queue_gen):
		_queued_voice_replay_request = request
		return
	# A batch queued behind unrelated stage work has not affected presentation or
	# cursor state yet. Revoke exactly that old playback queue's request before
	# claiming replay ownership; finalization-owned batches use queue_gen = -1.
	_cancel_queued_stage_requests_for_voice_queue(retiring_queue_gen)
	if (
		owner_gen != _dialogue_gen
		or retiring_queue_gen != _playback_queue_gen
	):
		return
	if not _retire_logical_voice_session(owner_gen, retiring_queue_gen):
		return
	_stage_operation_request_results.clear()
	_start_voice_playback(
		String(request.get("character", "")),
		request.get("segments", []) as Array,
		owner_gen,
		bool(request.get("is_dialogue_playback", false)),
		false,
	)


func _voice_queue_has_dispatching_stage_request(queue_gen: int) -> bool:
	for raw_request_id in _stage_operation_request_owners.keys():
		var owner = _stage_operation_request_owners.get(raw_request_id, {})
		if (
			owner is Dictionary
			and int((owner as Dictionary).get("queue_gen", -1)) == queue_gen
			and bool((owner as Dictionary).get("dispatch_active", false))
		):
			return true
	return false


func _cancel_queued_stage_requests_for_voice_queue(queue_gen: int) -> void:
	for raw_request_id in _stage_operation_request_owners.keys():
		var owner = _stage_operation_request_owners.get(raw_request_id, {})
		if (
			not owner is Dictionary
			or int((owner as Dictionary).get("queue_gen", -1)) != queue_gen
			or bool((owner as Dictionary).get("dispatch_active", false))
		):
			continue
		SignalBus.cancel_stage_operation_request(int(raw_request_id))


func _logical_dialogue_voice_session_is_open() -> bool:
	return (
		_playback_total_duration > 0.0
		and _playback_is_dialogue
		and not _playback_dialogue_finished_emitted
	)


## Close the old high-level dialogue voice lifecycle before a toolbar replay
## emits its next START, or before backlog playback emits its first low-level
## voice request. The queue generation is bumped only by the subsequent start,
## so the owned FINISH remains current throughout its synchronous dispatch.
func _retire_logical_voice_session(owner_gen: int, queue_gen: int) -> bool:
	return _retire_logical_voice_session_internal(
		owner_gen, queue_gen, false)


func _retire_logical_voice_session_internal(
	owner_gen: int,
	queue_gen: int,
	allow_detached: bool,
) -> bool:
	# Before the first playback there is no queue owner to retire. Replay still
	# needs to be able to claim that empty slot (notably from an empty backlog).
	if _playback_owner_dialogue_gen < 0:
		_playback_aborted = true
		_playback_queue_active = false
		return owner_gen == _dialogue_gen and queue_gen == _playback_queue_gen
	var validator: Callable = (
		_voice_session_identity_is_current.bind(owner_gen, queue_gen)
		if allow_detached
		else _voice_session_event_owner_is_current.bind(owner_gen, queue_gen)
	)
	if not validator.call():
		return false
	_playback_aborted = true
	_playback_queue_active = false
	if _logical_dialogue_voice_session_is_open():
		_playback_dialogue_finished_emitted = true
		if not SignalBus.emit_owned_dialogue_voice_finished(validator):
			return false
	return validator.call()


## Retire all asynchronous ownership held by the current dialogue without
## projecting any undispatched stage cue. Lifecycle boundaries such as hide,
## scene replacement, and tree exit use this path; click/advance uses
## `_finalize_dialogue()` because it intentionally folds to the authored end.
func _retire_dialogue_lifecycle(
	finish_active_stage_transitions: bool,
	allow_detached: bool = false,
) -> bool:
	var owner_gen := _dialogue_gen
	var queue_gen := _playback_queue_gen
	if not _retire_logical_voice_session_internal(
		owner_gen, queue_gen, allow_detached
	):
		return false
	if owner_gen != _dialogue_gen or queue_gen != _playback_queue_gen:
		return false
	_queued_voice_replay_request.clear()
	_queued_dialogue_requests.clear()
	_finalization_pending = false
	_cancel_pending_stage_operation_requests()
	var finish_records: Array = _stage_transition_records.values()
	_stage_transition_records.clear()
	if finish_active_stage_transitions and not finish_records.is_empty():
		SignalBus.stage_transitions_finish_requested.emit(
			finish_records)
		if owner_gen != _dialogue_gen or queue_gen != _playback_queue_gen:
			return false
	_finalization_transition_records.clear()
	_stage_operation_request_owners.clear()
	_stage_operation_request_results.clear()
	_playback_queue_gen += 1
	_playback_queue_active = false
	_playback_owner_dialogue_gen = -1
	_playback_aborted = true
	_playback_voice_token = -1
	_voice_playing = false
	_active_voice_token = -1
	return true


func _next_boundary_revision() -> int:
	_boundary_revision += 1
	return _boundary_revision


## Stage delivery is synchronous and cannot be revoked after its first listener.
## Record the latest UI/lifecycle boundary until the owned dispatch unwinds;
## SHOW and lifecycle requests replace one another in their public event order.
func _request_lifecycle_boundary(action: StringName) -> void:
	# Tree exit is terminal for this Presenter. Once it is pending (or the node is
	# already detached), later hide/scene notifications must not replace it with a
	# boundary whose validators require tree membership.
	if action != _LIFECYCLE_EXIT and (
		not is_inside_tree()
		or StringName(_deferred_lifecycle_boundary.get("action", &""))
			== _LIFECYCLE_EXIT
	):
		return
	if (
		action == _LIFECYCLE_EXIT
		and StringName(_deferred_lifecycle_boundary.get("action", &""))
			== _LIFECYCLE_EXIT
	):
		return
	var revision := _next_boundary_revision()
	_queued_dialogue_requests.clear()
	_queued_voice_replay_request.clear()
	_finalization_pending = false
	if _presentation_dispatch_depth > 0 or _finalization_in_progress:
		_deferred_lifecycle_boundary = {
			"action": action,
			"revision": revision,
		}
		return
	_deferred_lifecycle_boundary.clear()
	_apply_lifecycle_boundary(action, revision)


func _apply_lifecycle_boundary(action: StringName, revision: int) -> void:
	if revision != _boundary_revision:
		return
	_boundary_operation_depth += 1
	match action:
		_LIFECYCLE_HIDE:
			_apply_hide_dialogue_boundary(revision)
		_LIFECYCLE_TRANSITION:
			_apply_indicator_transition_boundary(revision)
		_LIFECYCLE_EXIT:
			_apply_exit_boundary(revision)
	_boundary_operation_depth = maxi(0, _boundary_operation_depth - 1)
	if _boundary_operation_depth == 0:
		_drain_deferred_presentation_work()


func _apply_exit_boundary(revision: int) -> void:
	# A remove_child() can happen inside an owned stage signal. In that case this
	# runs from request-finished while detached, after the dispatch owner unwinds.
	_retire_dialogue_lifecycle(false, true)
	if revision != _boundary_revision:
		return
	_dialogue_gen += 1
	_indicator_token += 1
	_indicator_candidate_dialogue_gen = -1
	_dialogue_ready = false
	if _advance_indicator != null:
		_advance_indicator.cleanup()


## Shared playback-init for the queue. Writes ONLY _playback_* state — never
## _dialogue_*. Used by:
##   - _on_show_dialogue (dialogue's own playback, is_dialogue_playback = true)
##   - _on_voice_replay_pressed (toolbar 重听, is_dialogue_playback = true)
##   - _on_dialogue_voice_replay_requested (backlog ▶, is_dialogue_playback = false)
##
## When is_dialogue_playback is false, dialogue_voice_started/progress/finished
## are NOT emitted — the audio still plays, but the dialogue's in-game progress
## bar doesn't react. Used so backlog playback shares queue machinery without
## hijacking the dialogue's UI.
func _start_voice_playback(
	character: String,
	segments: Array,
	owner_gen: int,
	is_dialogue_playback: bool = true,
	apply_segment_presentation: bool = false,
	prepared_segment_durations: Array = [],
) -> bool:
	if owner_gen != _dialogue_gen:
		return false
	# Claim the queue before any public signal. A synchronous listener may SHOW a
	# replacement, whose kickoff then owns a newer dialogue + queue generation.
	_playback_queue_gen += 1
	var queue_gen := _playback_queue_gen
	_playback_owner_dialogue_gen = owner_gen
	_playback_queue_active = false
	_playback_is_dialogue = is_dialogue_playback
	_playback_dialogue_finished_emitted = false
	_playback_aborted = false
	_playback_voice_token = -1
	var owner_validator := _voice_queue_event_owner_is_current.bind(
		owner_gen, queue_gen)
	_playback_played_duration = 0.0
	_playback_segment_durations = (
		prepared_segment_durations.duplicate()
		if prepared_segment_durations.size() == segments.size()
		else _resolve_voice_segment_durations(character, segments)
	)
	_playback_total_duration = _sum_voice_segment_durations(
		_playback_segment_durations)
	if _playback_total_duration > 0.0 and _playback_is_dialogue:
		if not SignalBus.emit_owned_dialogue_voice_started(
			_playback_total_duration, owner_validator):
			return false
		if not _voice_queue_is_current(owner_gen, queue_gen):
			return false
	_run_voice_queue(
		character, segments, owner_gen, queue_gen, apply_segment_presentation)
	return _voice_queue_is_current(owner_gen, queue_gen)


func _resolve_voice_segment_durations(
	character: String,
	segments: Array,
) -> Array:
	var durations: Array = []
	var character_voice_enabled := _is_character_voice_enabled(character)
	for seg in segments:
		var voice := String(seg.get("voice", ""))
		var duration := 0.0
		if not voice.is_empty() and character_voice_enabled:
			var stream := _load_voice_stream(voice)
			if stream != null:
				duration = stream.get_length()
		durations.append(duration)
	return durations


func _sum_voice_segment_durations(durations: Array) -> float:
	var total := 0.0
	for duration in durations:
		total += float(duration)
	return total


func _voice_kickoff_was_superseded_by_replay(
	owner_gen: int,
	kickoff_queue_gen: int,
) -> bool:
	return (
		owner_gen == _dialogue_gen
		and _playback_owner_dialogue_gen == owner_gen
		and _playback_queue_gen > kickoff_queue_gen
	)


func _dialogue_event_owner_is_current(owner_gen: int) -> bool:
	return (
		is_inside_tree()
		and not is_queued_for_deletion()
		and owner_gen == _dialogue_gen
	)


func _voice_queue_event_owner_is_current(
	owner_gen: int,
	queue_gen: int,
) -> bool:
	return (
		is_inside_tree()
		and not is_queued_for_deletion()
		and _voice_queue_is_current(owner_gen, queue_gen)
	)


func _voice_session_event_owner_is_current(
	owner_gen: int,
	queue_gen: int,
) -> bool:
	# Finalization deliberately aborts the queue before emitting its logical
	# FINISHED event, so this validator cannot use _voice_queue_is_current(). The
	# dialogue + queue generations still reject both a replacement SHOW and a
	# same-dialogue replay started by an earlier signal listener.
	return (
		is_inside_tree()
		and not is_queued_for_deletion()
		and _voice_session_identity_is_current(owner_gen, queue_gen)
	)


func _voice_session_identity_is_current(
	owner_gen: int,
	queue_gen: int,
) -> bool:
	return (
		owner_gen == _dialogue_gen
		and owner_gen == _playback_owner_dialogue_gen
		and queue_gen == _playback_queue_gen
	)


func _on_auto_pressed():
	StellaRuntime.toggle_auto_play()


func _on_auto_play_active_changed(active: bool) -> void:
	if not is_inside_tree() or is_queued_for_deletion():
		return
	_update_toggle_buttons()
	if not active:
		# Retire an outstanding delay immediately. Its coroutine also checks the
		# active controller, but the token prevents a later re-enable from reviving it.
		_retire_auto_play_attempt()
		return
	if not StellaRuntime.game_state.is_playing():
		# Public facade/actions may configure Auto while a system overlay owns
		# input. Preserve that public controller state, but never start a dialogue
		# tail until PLAYING resumes.
		return
	if (
		_dialogue_ready
		and _indicator_candidate_dialogue_gen == _dialogue_gen
	):
		_continue_auto_play_after_ready(_dialogue_gen)


func _on_skip_pressed():
	StellaRuntime.toggle_skip()


func _on_skip_active_changed(active: bool) -> void:
	if not is_inside_tree() or is_queued_for_deletion():
		return
	_update_toggle_buttons()
	if not active:
		cancel_pending_skip()
		return
	if not StellaRuntime.game_state.is_playing():
		# Preserve the public controller state while an overlay owns input. The
		# PLAYING transition below re-applies it to the still-ready dialogue.
		return
	# The unread gate must run before any completion path can mark the line read.
	# Otherwise a toolbar press during typing finalizes first, then observes its
	# own newly-written read flag and incorrectly schedules an advance.
	if (_is_typing or _dialogue_ready) and not _should_skip_current():
		_apply_unread_skip_gate()
		return
	# Skip just activated. If the typewriter is mid-flight, snap the text to
	# end (same semantics as click-to-complete) so the user immediately sees
	# the full line, finalize it now, then continue at the configured skip pace.
	# Waiting for the old character timer here used to strand toolbar skip on a
	# fully visible line with no follow-up advance.
	if _is_typing:
		# Retire the old typewriter coroutine rather than letting it reach the
		# normal completion hook after this independent skip-delay path starts.
		var gen := _retire_typewriter_generation()
		_retire_auto_play_attempt()
		_is_typing = false
		text_label.visible_characters = -1
		_invalidate_advance_indicator()
		if gen != _dialogue_gen:
			return
		_finalize_dialogue(
			_dialogue_voice_character, _dialogue_segments, gen)
		if gen != _dialogue_gen:
			return
		_schedule_advance_after_skip_delay(gen)
		return
	# A public facade/StellaAction toggle reaches the same ready boundary as the
	# built-in toolbar. Do not advance from title/choice/transition states that do
	# not own a completed dialogue.
	if (
		_dialogue_ready
		and _indicator_candidate_dialogue_gen == _dialogue_gen
	):
		SignalBus.emit_advance_requested()


func _schedule_advance_after_skip_delay(gen: int) -> void:
	_skip_pending_dialogue_gen = gen
	await get_tree().create_timer(
		StellaRuntime.get_setting("skip_interval") / 1000.0).timeout
	if gen != _dialogue_gen or _skip_pending_dialogue_gen != gen:
		return
	_skip_pending_dialogue_gen = -1
	if not _should_skip_current():
		_apply_unread_skip_gate()
		_restore_ready_after_cancelled_skip(gen)
		return
	if not StellaRuntime.game_state.is_playing():
		_restore_ready_after_cancelled_skip(gen)
		return
	SignalBus.emit_advance_requested()


func cancel_pending_skip() -> void:
	if _skip_pending_dialogue_gen != _dialogue_gen:
		return
	_skip_pending_dialogue_gen = -1
	_restore_ready_after_cancelled_skip(_dialogue_gen)


func _restore_ready_after_cancelled_skip(gen: int) -> void:
	if gen != _dialogue_gen or text_label.visible_characters != -1:
		return
	_indicator_candidate_dialogue_gen = gen
	_mark_dialogue_ready_for_indicator(gen)
	# Public callers can activate auto-play while a toolbar/Ctrl skip delay is
	# pending. The skip controller then stops, so this completed line must enter
	# the normal auto tail instead of leaving an active Auto toggle stranded.
	if StellaRuntime.is_auto_playing():
		_continue_auto_play_after_ready(gen)


## Completes the current typewriter synchronously and retires its outstanding
## character/effect timers. InputHandler uses this instead of mutating fields so
## a click inside a long authored {wait} reaches the ready boundary immediately.
func complete_typewriter() -> bool:
	if not _is_typing:
		return false
	_skip_pending_dialogue_gen = -1
	var gen := _retire_typewriter_generation()
	_retire_auto_play_attempt()
	_is_typing = false
	text_label.visible_characters = -1
	# Retire the old generation before any custom marker hook or public
	# completion signal can synchronously SHOW a replacement dialogue.
	_invalidate_advance_indicator()
	if gen != _dialogue_gen:
		return true
	_finalize_dialogue(_dialogue_voice_character, _dialogue_segments, gen)
	if gen != _dialogue_gen:
		return true
	_indicator_candidate_dialogue_gen = gen
	_mark_dialogue_ready_for_indicator(gen)
	if StellaRuntime.is_auto_playing():
		_continue_auto_play_after_ready(gen)
	return true


## Complete the active typewriter synchronously, including any remaining
## @combine presentation cues.
func complete_current_dialogue() -> void:
	complete_typewriter()


## Preserve the final @combine stage state when text finishes before the
## segmented voice queue. Skip also finishes an already-dispatched final cue so
## no long stage tween can leak into the next command.
func finalize_current_dialogue_for_advance() -> void:
	if _dialogue_segments.is_empty() or _finalization_in_progress:
		return
	# SignalBus delivery is synchronous. A listener that asks to finalize while
	# a segment is still being projected must wait until every presenter has
	# consumed the outer event, otherwise a late listener can start a tween after
	# the attempted cut already ran.
	if _presentation_dispatch_depth > 0 or _finalization_in_progress:
		_finalization_pending = true
		return
	if (
		_segment_presentation_complete
		and _stage_transition_records.is_empty()
		and not _logical_dialogue_voice_session_is_open()
	):
		return
	_finalize_dialogue(
		_dialogue_voice_character, _dialogue_segments, _dialogue_gen)


func _on_backlog_pressed():
	StellaRuntime.show_backlog()


func _on_prev_choice_pressed():
	StellaRuntime.jump_to_previous_choice()


func _refresh_prev_choice_btn():
	if _prev_choice_btn == null:
		return
	_prev_choice_btn.disabled = not StellaRuntime.can_jump_to_previous_choice()


func _on_quick_save_pressed():
	StellaRuntime.quick_save()


func _on_quick_load_pressed():
	StellaRuntime.quick_load()


func _on_save_pressed():
	StellaRuntime.show_save_load("save")


func _on_load_pressed():
	StellaRuntime.show_save_load("load")


func _on_settings_pressed():
	StellaRuntime.show_settings()


func _is_toggle_active(btn_id: String) -> bool:
	match btn_id:
		"auto": return StellaRuntime.is_auto_playing()
		"skip": return StellaRuntime.is_skipping()
	return false


func _update_button_modulate(btn: Button, btn_id: String):
	btn.modulate = Color.YELLOW if _is_toggle_active(btn_id) else Color.WHITE


func _update_toggle_buttons():
	if _auto_btn:
		_update_button_modulate(_auto_btn, "auto")
	if _skip_btn:
		_update_button_modulate(_skip_btn, "skip")


## Read-aware skip decision — pure query, no side effects.
## - Ctrl hold always skips (even unread text).
## - Toolbar skip respects the `skip_only_read` setting: when on, it blocks
##   at unread lines so the user doesn't race past content they haven't seen.
## Callers that want to *act* on toolbar-skip-blocked-by-unread (i.e. un-toggle
## the button) should call `_apply_unread_skip_gate()` after this returns false.
func _should_skip_current() -> bool:
	if not StellaRuntime.game_state.is_playing():
		return false
	if _ctrl_held:
		return true
	if not StellaRuntime.is_skipping():
		return false
	if not StellaRuntime.get_setting("skip_only_read"):
		return true
	# No known position (e.g. tests without a real scenario engine, or an
	# in-between state) — can't gate on read status, so allow the skip.
	if _current_command_index < 0:
		return true
	return _is_current_line_read()


## Side-effect counterpart to `_should_skip_current()`. If toolbar skip is
## active but blocked by an unread line, stop the toolbar skip so the button
## un-highlights and the user reads normally. Safe to call any number of times:
## once `skip_controller.is_active` is false, this is a no-op.
func _apply_unread_skip_gate() -> void:
	if _ctrl_held:
		return
	if not StellaRuntime.is_skipping():
		return
	if not StellaRuntime.get_setting("skip_only_read"):
		return
	if _current_command_index < 0:
		return
	if _is_current_line_read():
		return
	StellaRuntime.skip_controller.stop()
	_update_toggle_buttons()


func _capture_current_position() -> void:
	_current_scenario_id = ""
	_current_scene_id = ""
	_current_command_index = -1
	if StellaRuntime.engine == null or StellaRuntime.engine.context == null:
		return
	var ctx = StellaRuntime.engine.context
	if ctx.scenario_data == null:
		return
	var scene = ctx.current_scene()
	if scene == null:
		return
	_current_scenario_id = ctx.scenario_data.id
	_current_scene_id = scene.id
	_current_command_index = ctx.current_command_index


func _is_current_line_read() -> bool:
	if _current_command_index < 0:
		return false
	return StellaRuntime.read_flags.is_read(
		_current_scenario_id, _current_scene_id, _current_command_index)


func _mark_current_line_read() -> void:
	if _current_command_index < 0:
		return
	StellaRuntime.read_flags.mark_read(
		_current_scenario_id, _current_scene_id, _current_command_index)


## Unified dialogue handler.
## Both normal single-line dialogue and @combine multi-segment dialogue flow
## through here. A normal dialogue is just segments.size() == 1.
## - Voices play sequentially via _run_voice_queue (works for 1 or N segments)
## - Typewriter runs continuously over concatenated text
## - Inline `[expr:name]` markers and `{wait/speed}` effects from each segment's text
##   are merged into global timelines with offset adjustment
## - Click-to-finish: snap text and the local avatar to their final authored state
func _on_dialogue_requested(dialogue_request: DialogueRequest) -> void:
	if dialogue_request == null or dialogue_request.get_segments().is_empty():
		return
	if not is_inside_tree() or is_queued_for_deletion():
		return
	var effect_names := _collect_backlog_custom_effect_names()
	var custom_effect_registry := _effect_name_registry(effect_names)
	SignalBus.dialogue_backlog_effects_resolved.emit(dialogue_request, effect_names)
	var revision := _next_boundary_revision()
	var request := {
		"character": dialogue_request.get_character(),
		"segments": dialogue_request.get_segments(),
		"mode": dialogue_request.get_mode(),
		"nvl_page_key": dialogue_request.get_nvl_page_key(),
		"nvl_page_entries": dialogue_request.get_nvl_page_entries(),
		"presentation_profile": dialogue_request.get_presentation_profile(),
		"presentation_provenance": dialogue_request.get_presentation_provenance(),
		"declarative_presentation": dialogue_request.uses_declarative_presentation(),
		"custom_effect_registry": custom_effect_registry.duplicate(true),
		"boundary_revision": revision,
	}
	# This SHOW is later than any parked hide/scene boundary and therefore owns
	# the next visible state. Metadata above is retained in the request snapshot.
	_deferred_lifecycle_boundary.clear()
	_queued_voice_replay_request.clear()
	# A presentation signal may have listeners both before and after this
	# presenter. Delay a synchronously nested SHOW until the current batch has
	# reached every listener, otherwise a late StagePresenter could apply an old
	# operation after the new dialogue has already claimed the same layer.
	if _presentation_dispatch_depth > 0 or _finalization_in_progress:
		# Multiple synchronous SHOW requests cannot all own the same UI. Match the
		# normal signal semantics by letting the newest request supersede earlier
		# queued requests before presentation control returns to the dialogue.
		_queued_dialogue_requests.clear()
		_queued_dialogue_requests.append(request)
		return
	_queued_dialogue_requests.clear()
	_accept_dialogue_request(request)


## Compatibility for tests/extensions that called the old presenter callback
## directly. Runtime delivery always enters through dialogue_requested.
func _on_show_dialogue(character: String, segments: Array, mode: String) -> void:
	_on_dialogue_requested(DialogueRequest.new(character, segments, mode))


func _accept_dialogue_request(request: Dictionary) -> void:
	var revision := int(request.get("boundary_revision", -1))
	if revision != _boundary_revision:
		return
	_boundary_operation_depth += 1
	_queued_voice_replay_request.clear()
	# A direct SHOW is a replacement boundary just like an advance-driven SHOW.
	# Close the old high-level voice session before the replacement emits START.
	# If that FINISHED callback synchronously publishes a newer SHOW, it owns the
	# UI and this stale outer request must stop here.
	var retirement_survived := (
		_retire_dialogue_for_replacement()
		and revision == _boundary_revision
	)
	_boundary_operation_depth = maxi(0, _boundary_operation_depth - 1)
	# The boundary protects only retirement of the old line. Stage/voice events
	# emitted while starting the accepted replacement belong to the new line and
	# retain their normal replay deferral semantics.
	if retirement_survived:
		_show_dialogue_request(request)
	if _boundary_operation_depth == 0:
		_drain_deferred_presentation_work()


func _retire_dialogue_for_replacement() -> bool:
	var owner_gen := _dialogue_gen
	var queue_gen := _playback_queue_gen
	# A newer SHOW wins immediately: revoke undispatched cues and stop only exact
	# transitions already acknowledged for the retiring line. Never fold its
	# remaining authored cues into the replacement's stage state.
	_cancel_pending_stage_operation_requests()
	var finish_records: Array = _stage_transition_records.values()
	_stage_transition_records.clear()
	if not finish_records.is_empty():
		SignalBus.stage_transitions_finish_requested.emit(
			finish_records)
		if owner_gen != _dialogue_gen or queue_gen != _playback_queue_gen:
			return false
	if not _retire_logical_voice_session(owner_gen, queue_gen):
		return false
	return owner_gen == _dialogue_gen and queue_gen == _playback_queue_gen


func _show_dialogue_request(request: Dictionary) -> void:
	var request_segments: Array = request.get("segments", [])
	var profile_data: Dictionary = request.get("presentation_profile", {})
	var profile_provenance: Dictionary = request.get(
		"presentation_provenance", {})
	var custom_effect_registry: Dictionary = request.get(
		"custom_effect_registry", {})
	_show_dialogue_now(
		String(request.get("character", "")),
		request_segments,
		String(request.get("mode", "adv")),
		String(request.get("nvl_page_key", "")),
		request.get("nvl_page_entries", []),
		profile_data,
		profile_provenance,
		bool(request.get("declarative_presentation", false)),
		custom_effect_registry,
	)


func _show_dialogue_now(
	character: String,
	segments: Array,
	mode: String,
	nvl_page_key: String,
	nvl_page_entries: Array,
	stla_profile_data: Dictionary,
	stla_profile_provenance: Dictionary,
	uses_stla_presentation: bool,
	custom_effect_registry: Dictionary,
) -> void:
	var stla_mode_profile: DialogueModeProfile = (
		DialogueModeProfile.from_dictionary(
			stla_profile_data, stla_profile_provenance)
		if not stla_profile_data.is_empty()
		else null
	)
	_skip_pending_dialogue_gen = -1
	_retire_auto_play_attempt()

	# Publish replacement ownership before cancellation or any custom indicator
	# hook can synchronously emit signals or queue another SHOW.
	_dialogue_gen += 1
	var gen := _dialogue_gen
	_is_typing = false
	_invalidate_advance_indicator()
	if gen != _dialogue_gen:
		return
	_indicator_candidate_dialogue_gen = gen
	# Cancellation synchronously emits request-finished. Old stage/voice waiters
	# must already observe this replacement generation when they resume.
	_cancel_pending_stage_operation_requests()
	if gen != _dialogue_gen:
		return

	if mode == "nvl" and not nvl_page_key.is_empty() \
		and nvl_page_key != _active_nvl_page_key:
		_reset_nvl_accumulator()
		_active_nvl_page_key = nvl_page_key
	# A soft hide is view-only. Auto-play or another external controller may
	# already have advanced while the panel was hidden, so consume the new SHOW
	# instead of leaving the engine parked on a dialogue the presenter dropped.
	if _ui_hidden:
		_ui_hidden = false
		visible = true

	# Cache (scenario_id, scene_id, command_index) of the line we are about to
	# display — consulted by _should_skip_current() / _apply_unread_skip_gate()
	# and written by _mark_current_line_read() once the user has seen the line.
	_capture_current_position()

	# Snapshot dialogue state. _start_voice_playback later writes _playback_*
	# but never touches _dialogue_*, so a backlog replay can run in parallel
	# without corrupting what the toolbar 重听 button will play.
	_dialogue_segments = segments.duplicate(true)
	_dialogue_voice_character = character
	_segment_presentation_complete = false
	_next_stage_segment_index = 0
	_stage_transition_records.clear()
	_finalization_transition_records.clear()
	_stage_operation_request_owners.clear()
	_stage_operation_request_results.clear()
	_queued_voice_replay_request.clear()
	_finalization_pending = false
	_finalization_in_progress = false
	_dialogue_total_duration = 0.0
	if _voice_replay_btn:
		_voice_replay_btn.visible = false

	# Process all segments: concat text, merge inline markers + effects with offsets
	var full_text := ""
	var all_effects: Array = []
	var timeline := ExpressionTimeline.new()
	var all_markers: Array = []
	for seg in segments:
		var segment_source_offset := full_text.length()
		var seg_text := String(seg.get("text", ""))
		# Parse explicit avatar markers and typewriter effects together. Their
		# source offsets are already expressed in the retained BBCode source, so a
		# second pass would lose effects that the first pass removed.
		var processed := ExpressionTimeline.parse_inline_annotations(
			seg_text, custom_effect_registry)
		for warning in processed["warnings"]:
			push_warning("DialoguePresenter: %s" % String(warning))
		var seg_clean: String = processed["clean_text"]
		for m in processed["markers"]:
			all_markers.append({
				"expression": m["expression"],
				"source_offset": (
					segment_source_offset + int(m["source_offset"])),
			})
		for ef in processed["effects"]:
			all_effects.append({
				"type": ef["type"],
				"value": ef["value"],
				"source_offset": (
					segment_source_offset + int(ef["source_offset"])),
			})
		full_text += seg_clean

	_current_voice_character = character
	var first_voice := String(segments[0].get("voice", ""))
	_current_voice = first_voice

	visible = true
	_current_mode = mode
	_active_uses_stla_presentation = uses_stla_presentation
	_active_stla_mode_profile = stla_mode_profile

	var uses_presentation_profile := _apply_dialogue_mode_presentation(
		mode, _active_stla_mode_profile, uses_stla_presentation)
	if gen != _dialogue_gen:
		return
	if toolbar and not uses_presentation_profile:
		toolbar.visible = (mode == "adv")

	# Mode-specific text setup
	var new_line_text: String = ""
	var authored_source_start: int = 0
	if mode == "nvl":
		name_label.visible = false
		var entry_format := _resolve_nvl_entry_format()
		var entry_prefix: String = entry_format["prefix"]
		var entry_separator: String = entry_format["separator"]
		var speaker_prefix := "%s：" % character if not character.is_empty() else ""
		new_line_text = entry_prefix + speaker_prefix + full_text
		var previously_visible := ""
		if not nvl_page_entries.is_empty():
			var history := _build_nvl_authored_history(
				nvl_page_entries, entry_format, custom_effect_registry)
			previously_visible = history
			if nvl_page_entries.size() > 1:
				previously_visible += entry_separator
		else:
			var applied_separator := entry_separator if _nvl_has_entries else ""
			previously_visible = _nvl_text + applied_separator
		var combined := previously_visible + new_line_text
		authored_source_start = (
			previously_visible.length()
			+ entry_prefix.length()
			+ speaker_prefix.length()
		)
		var can_append_plain: bool = (
			nvl_page_entries.is_empty()
			and _nvl_has_entries
			and _nvl_incremental_document_valid
			and not _nvl_text.contains("[")
			and not entry_separator.contains("[")
			and not new_line_text.contains("[")
		)
		if can_append_plain:
			# RichTextLabel keeps its shaped document and parses only the suffix.
			# Prefix/separator fields reject BBCode at authoring time, so this path
			# is exact for the ordinary growing NVL page.
			var history_character_count := text_label.get_total_character_count()
			text_label.append_text(entry_separator + new_line_text)
			text_label.visible_characters = (
				history_character_count + entry_separator.length())
			_nvl_incremental_append_count += 1
		else:
			text_label.text = combined
			# List close tags can synthesize a newline and then consume the first
			# separator newline. Map the actual source boundary instead of adding raw
			# separator length to the previous parsed count.
			text_label.visible_characters = _parsed_character_offset(
				combined, previously_visible.length())
			_nvl_full_text_rebuild_count += 1
			_nvl_incremental_document_valid = not combined.contains("[")
		_nvl_text = combined
		_nvl_render_source = combined
		_nvl_has_entries = true
	elif mode == "overlay":
		_reset_nvl_accumulator()
		name_label.visible = false
		new_line_text = full_text
		text_label.text = full_text
		text_label.visible_characters = 0
	else:  # adv
		_reset_nvl_accumulator()
		new_line_text = full_text
		if character != "":
			name_label.text = character
			name_label.visible = true
		else:
			name_label.text = ""
			name_label.visible = false
		text_label.text = full_text
		text_label.visible_characters = 0

	# RichTextLabel itself is the authority for every typewriter boundary. Map
	# markers and effects only after the final ADV/overlay/NVL source is known, so
	# plain entry/speaker prefixes, accumulated history, list-generated newlines
	# and a consumed separator all share the exact domain used by
	# visible_characters. Positions remain relative to the authored dialogue so
	# the existing typewriter timeline semantics stay unchanged.
	var rendered_source := _nvl_render_source if mode == "nvl" else text_label.text
	var authored_parsed_start := _parsed_character_offset(
		rendered_source, authored_source_start)
	var authored_text_offset := maxi(
		0, authored_parsed_start - text_label.visible_characters)
	for marker_index in range(all_markers.size()):
		var marker: Dictionary = all_markers[marker_index]
		marker["at_char"] = (
			_parsed_character_offset(
				rendered_source,
				authored_source_start + int(marker["source_offset"]),
			)
			- authored_parsed_start
		)
		marker.erase("source_offset")
		all_markers[marker_index] = marker
	for effect_index in range(all_effects.size()):
		var effect: Dictionary = all_effects[effect_index]
		effect["pos"] = (
			_parsed_character_offset(
				rendered_source,
				authored_source_start + int(effect["source_offset"]),
			)
			- authored_parsed_start
		)
		effect.erase("source_offset")
		all_effects[effect_index] = effect
	timeline.markers = all_markers

	# Avatar state is local to dialogue presentation. A marker at character zero
	# supplies the initial image without restoring the removed char_* pipeline.
	var avatar_expr := "default"
	if character != "":
		_avatar_expressions[character] = avatar_expr
	var initial_inline_expr := timeline.get_expression_at_char(0)
	if character != "" and not initial_inline_expr.is_empty():
		avatar_expr = initial_inline_expr
		_avatar_expressions[character] = avatar_expr
	# Skip projects only the combined final state, avoiding a segment-zero flash.
	if not _should_skip_current():
		_update_avatar(character, avatar_expr, mode)

	# Commit every line-owned field before invoking custom indicator or voice
	# hooks. Synchronous input from either boundary must see one complete active
	# line, never a mixture of the retired and replacement SHOW payloads.
	if gen != _dialogue_gen:
		return
	_is_typing = true
	if not _configure_advance_indicator(
		mode, _active_stla_mode_profile, gen):
		return
	if gen != _dialogue_gen:
		return
	# Dialogue-owned replay metadata is a SHOW snapshot, not a view of the shared
	# playback queue. A dialogue_voice_started listener may synchronously replace
	# that queue with toolbar or backlog replay while the same line remains active.
	var dialogue_voice_durations := _resolve_voice_segment_durations(
		character, segments)
	_dialogue_total_duration = _sum_voice_segment_durations(
		dialogue_voice_durations)
	if _voice_replay_btn:
		_voice_replay_btn.visible = (_dialogue_total_duration > 0.0)
	var kickoff_queue_gen := _playback_queue_gen + 1
	var kickoff_survived := _start_voice_playback(
		character, segments, gen, true, true, dialogue_voice_durations)
	if (
		not kickoff_survived
		and not _voice_kickoff_was_superseded_by_replay(
			gen, kickoff_queue_gen)
	):
		return
	if gen != _dialogue_gen:
		return

	# Signal emission returns at the await below. Active/not-ready was established
	# before every reentrant hook, so same-frame input completes this line.
	await get_tree().process_frame
	if gen != _dialogue_gen:
		return

	# If toolbar skip is active and the new line is unread (with skip_only_read
	# on), un-toggle it now so the button reflects reality and the user reads
	# normally. Runs once per dialogue — pure-query checks below can't side
	# effect, so this is the explicit gate.
	_apply_unread_skip_gate()

	# Skip mode: show all text immediately and snap to final state
	if _should_skip_current():
		_invalidate_advance_indicator()
		if gen != _dialogue_gen:
			return
		text_label.visible_characters = -1
		_is_typing = false
		_finalize_dialogue(character, segments, gen)
		if gen != _dialogue_gen:
			return
		await _schedule_advance_after_skip_delay(gen)
		return

	# Typewriter
	var start_visible = text_label.visible_characters
	# RichTextLabel's visible-character API counts parsed text, not BBCode source
	# bytes. Use the renderer's character domain so formatting tags do not add
	# fake typewriter delay or corrupt an accumulated NVL entry boundary.
	var total_new_chars := maxi(
		0, text_label.get_total_character_count() - start_visible)
	var current_char_interval := _char_interval
	for i in range(total_new_chars):
		if not _is_typing:
			break
		if _should_skip_current():
			_invalidate_advance_indicator()
			if gen != _dialogue_gen:
				return
			text_label.visible_characters = -1
			_is_typing = false
			_finalize_dialogue(character, segments, gen)
			if gen != _dialogue_gen:
				return
			await _schedule_advance_after_skip_delay(gen)
			return
		_apply_unread_skip_gate()

		var authored_index := i - authored_text_offset
		if authored_index >= 0:
			# Effects authored before a visible character run before that character
			# appears. Speed changes persist until another speed annotation.
			for effect in all_effects:
				if effect["pos"] == authored_index:
					if effect["type"] == "wait":
						var wait_seconds := float(effect["value"]) / 1000.0
						if wait_seconds > 0.0:
							await get_tree().create_timer(wait_seconds).timeout
							if gen != _dialogue_gen:
								return
					elif effect["type"] == "speed":
						current_char_interval = effect["value"] / 1000.0
			if not _is_typing:
				break
			var expr = timeline.get_expression_at_char(authored_index)
			if expr != "" and character != "":
				_set_avatar_expression(character, expr)

		text_label.visible_characters = start_visible + i + 1

		if current_char_interval > 0.0:
			await get_tree().create_timer(current_char_interval).timeout
			if gen != _dialogue_gen:
				return
	if gen != _dialogue_gen:
		return
	# An effect at end-of-text has no following character. A trailing wait still
	# delays natural completion/auto-advance; a trailing speed has no effect.
	if _is_typing:
		for effect in all_effects:
			if (
				int(effect["pos"]) == total_new_chars - authored_text_offset
				and effect["type"] == "wait"
				and float(effect["value"]) > 0.0
			):
				await get_tree().create_timer(effect["value"] / 1000.0).timeout
				if gen != _dialogue_gen:
					return

	# Public playback facades can activate skip during the final character's
	# timer, after the loop's last leading check. Observe that transition before
	# natural completion marks this unread line as read.
	if _is_typing and _should_skip_current():
		_invalidate_advance_indicator()
		if gen != _dialogue_gen:
			return
		text_label.visible_characters = -1
		_is_typing = false
		_finalize_dialogue(character, segments, gen)
		if gen != _dialogue_gen:
			return
		await _schedule_advance_after_skip_delay(gen)
		return
	_apply_unread_skip_gate()

	# Defensive compatibility for extensions that still mutate the legacy
	# public state directly. InputHandler uses complete_typewriter(), which bumps
	# the generation and returns before this stale coroutine can reach the hook.
	if not _playback_aborted and not _is_typing and text_label.visible_characters == -1:
		_finalize_dialogue(character, segments, gen)
		if gen != _dialogue_gen:
			return

	text_label.visible_characters = -1
	_is_typing = false
	_apply_final_inline_avatar_expression(character, segments)
	_mark_current_line_read()
	_mark_dialogue_ready_for_indicator(gen)

	# Auto-play: wait for the voice queue to drain all segments, then advance.
	# Click/keyboard completion calls the same tail with its replacement gen.
	if StellaRuntime.is_auto_playing():
		await _continue_auto_play_after_ready(gen)


func _continue_auto_play_after_ready(gen: int) -> void:
	if (
		gen != _dialogue_gen
		or not StellaRuntime.is_auto_playing()
		or not StellaRuntime.game_state.is_playing()
	):
		return
	# Multiple completion surfaces (typewriter, cancelled skip, extensions) may
	# converge on the same ready line. Only one auto delay may own that line.
	if _auto_pending_dialogue_gen == gen and _auto_pending_attempt >= 0:
		return
	_auto_attempt_serial += 1
	var attempt := _auto_attempt_serial
	_auto_pending_dialogue_gen = gen
	_auto_pending_attempt = attempt
	if (
		StellaRuntime.get_setting("auto_play_wait_voice")
		and _playback_is_dialogue
	):
		while (
			_playback_is_dialogue
			and _playback_queue_active
			and not _playback_aborted
		):
			await get_tree().process_frame
			if (
				gen != _dialogue_gen
				or _auto_pending_dialogue_gen != gen
				or _auto_pending_attempt != attempt
				or not StellaRuntime.game_state.is_playing()
			):
				return
		if _playback_is_dialogue and _voice_playing:
			if not await _wait_for_active_voice_finished(gen, attempt):
				return
	var auto_play_delay: float = StellaRuntime.get_setting("auto_play_delay")
	await get_tree().create_timer(auto_play_delay).timeout
	if (
		gen != _dialogue_gen
		or _auto_pending_dialogue_gen != gen
		or _auto_pending_attempt != attempt
		or not StellaRuntime.game_state.is_playing()
	):
		return
	_auto_pending_dialogue_gen = -1
	_auto_pending_attempt = -1
	if StellaRuntime.is_auto_playing() \
		and StellaRuntime.game_state.is_playing():
		SignalBus.emit_advance_requested()


func _wait_for_active_voice_finished(gen: int, attempt: int) -> bool:
	var expected_token := _active_voice_token
	while _voice_playing:
		var event: VoicePlaybackEvent = await SignalBus.voice_playback_event
		if (
			gen != _dialogue_gen
			or _auto_pending_dialogue_gen != gen
			or _auto_pending_attempt != attempt
			or not StellaRuntime.game_state.is_playing()
		):
			return false
		if (
			event.get_kind() == VoicePlaybackEvent.Kind.FINISHED
			and event.get_playback_token() >= 0
			and event.get_playback_token() == expected_token
			and event.is_current()
		):
			return true
	return true


func _retire_auto_play_attempt() -> void:
	_auto_attempt_serial += 1
	_auto_pending_dialogue_gen = -1
	_auto_pending_attempt = -1


func _configure_advance_indicator(
	mode: String,
	stla_mode_profile: DialogueModeProfile,
	owner_gen: int = -1,
) -> bool:
	if owner_gen < 0:
		owner_gen = _dialogue_gen
	if owner_gen != _dialogue_gen:
		return false
	# Every attempted configuration invalidates the caller that was already inside
	# a custom scene hook. A same-generation fallback hot-swap can defer and fully
	# apply a newer profile while the outer configure() is unwinding; generation
	# alone cannot distinguish those two writes.
	_indicator_configuration_revision += 1
	var configuration_revision := _indicator_configuration_revision
	# A custom set_advance_ready() hook may synchronously SHOW/HIDE while its
	# scene object is locked inside configure()/hide_indicator(). Queue the latest
	# owner intent and apply it as soon as the outer helper call unwinds.
	if _indicator_operation_depth > 0:
		_defer_indicator_action("configure", owner_gen)
		return true
	_advance_indicator_offset = Vector2.ZERO
	var mode_profile := stla_mode_profile
	if mode_profile == null or not mode_profile.has_advance_indicator():
		if _advance_indicator != null:
			_run_indicator_operation(func(): _advance_indicator.clear_source())
		return owner_gen == _dialogue_gen

	for warning in mode_profile.advance_indicator_warnings():
		_advance_indicator_warning(mode, mode_profile, String(warning))
	var errors := mode_profile.advance_indicator_validation_errors()
	if not errors.is_empty():
		for error in errors:
			_advance_indicator_warning(mode, mode_profile, String(error))
		if _advance_indicator != null:
			_run_indicator_operation(func(): _advance_indicator.clear_source())
		return owner_gen == _dialogue_gen

	# Scene configuration wins defensively if an advanced Resource profile set
	# both sources; its validation warning still explains the conflict.
	var source: Resource = mode_profile.resolve_advance_indicator_scene()
	if source == null:
		source = mode_profile.resolve_advance_indicator_texture()
	if source == null:
		_advance_indicator_warning(mode, mode_profile,
			"advance indicator resource could not be loaded as Texture2D or PackedScene")
		if _advance_indicator != null:
			_run_indicator_operation(func(): _advance_indicator.clear_source())
		return owner_gen == _dialogue_gen

	if _advance_indicator == null or not is_instance_valid(_advance_indicator):
		_advance_indicator = DialogueAdvanceIndicator.new()
		_advance_indicator.name = "AdvanceIndicator"
		add_child(_advance_indicator)
		if owner_gen != _dialogue_gen:
			return false
		if configuration_revision != _indicator_configuration_revision:
			return true
	var configure_error := String(_run_indicator_operation(func():
		return _advance_indicator.configure(
			source, mode_profile.get_advance_indicator_animation())))
	if owner_gen != _dialogue_gen:
		return false
	if configuration_revision != _indicator_configuration_revision:
		return true
	if not configure_error.is_empty():
		_advance_indicator_warning(mode, mode_profile, configure_error)
		_run_indicator_operation(func(): _advance_indicator.clear_source())
		return owner_gen == _dialogue_gen
	_advance_indicator_offset = mode_profile.get_advance_indicator_offset()
	return true


func _defer_indicator_action(action: String, owner_gen: int) -> void:
	if owner_gen != _dialogue_gen:
		return
	_indicator_deferred_action = action
	_indicator_deferred_gen = owner_gen


func _run_indicator_operation(operation: Callable) -> Variant:
	_indicator_operation_depth += 1
	var result: Variant = operation.call()
	_indicator_operation_depth -= 1
	if _indicator_operation_depth == 0 and not _indicator_flushing_deferred:
		_flush_deferred_indicator_action()
	return result


func _flush_deferred_indicator_action() -> void:
	if _indicator_operation_depth > 0 or _indicator_flushing_deferred:
		return
	_indicator_flushing_deferred = true
	while not _indicator_deferred_action.is_empty():
		var action := _indicator_deferred_action
		var owner_gen := _indicator_deferred_gen
		_indicator_deferred_action = ""
		_indicator_deferred_gen = -1
		if owner_gen != _dialogue_gen:
			continue
		if action == "hide":
			if _advance_indicator != null and is_instance_valid(_advance_indicator):
				_run_indicator_operation(
					func(): _advance_indicator.hide_indicator())
		elif action == "configure":
			_configure_advance_indicator(
				_current_mode, _active_stla_mode_profile, owner_gen)
	_indicator_flushing_deferred = false


func _mark_dialogue_ready_for_indicator(gen: int) -> void:
	if gen != _dialogue_gen or _indicator_candidate_dialogue_gen != gen:
		return
	_dialogue_ready = true
	if _advance_indicator == null or _should_skip_current() or _ctrl_held:
		return
	var token := _indicator_token
	_show_advance_indicator_after_layout(gen, token)


func _show_advance_indicator_after_layout(gen: int, token: int) -> void:
	# The transparent renderer probe uses the same text/theme/layout inputs while
	# leaving the live label's tag stack, selection and scroll state untouched.
	_advance_indicator.prepare_layout_probe(
		text_label,
		_current_mode == "nvl",
		_nvl_render_source if _current_mode == "nvl" else "",
	)
	# Containers, fit_content and RichTextLabel wrapping settle on this boundary.
	await get_tree().process_frame
	if not _indicator_request_is_current(gen, token):
		return
	# Threaded RichTextLabel shaping may span multiple frames. Its line metrics
	# are partial until finished, and a fixed-size label need not emit resized
	# when the worker completes.
	if text_label.threaded and not text_label.is_finished():
		await text_label.finished
		if not _indicator_request_is_current(gen, token):
			return
	if text_label.threaded:
		# RichTextLabel.finished may precede the first draw that publishes final
		# scrolling metrics. Cross a complete additional frame after completion:
		# the first boundary lets the queued draw run, the second observes it.
		# Process-frame waits also remain cancellable when the label is hidden in
		# headless tests, unlike waiting indefinitely for a CanvasItem draw signal.
		await get_tree().process_frame
		if not _indicator_request_is_current(gen, token):
			return
		await get_tree().process_frame
		if not _indicator_request_is_current(gen, token):
			return
	# The mirror must first shape its scroll range, then draw its final viewport
	# once so the endpoint glyph is guaranteed to be sampled. The live label's
	# own metrics remain authoritative for vertical placement and visibility.
	_advance_indicator.sync_layout_probe_scroll()
	await get_tree().process_frame
	if not _indicator_request_is_current(gen, token):
		return
	# Godot 4.6 does not expose the virtual trailing-caret glyph reported by
	# 4.7. Isolate the final real grapheme for one transparent draw so the helper
	# can fall back to RichTextLabel's own visible-content edge without changing
	# the live label or inserting a shaping sentinel.
	if not _advance_indicator.isolate_layout_probe_endpoint():
		return
	await get_tree().process_frame
	if not _indicator_request_is_current(gen, token):
		return
	var positioned := bool(_run_indicator_operation(func():
		return _advance_indicator.position_after(
			text_label, _advance_indicator_offset)))
	if not _indicator_request_is_current(gen, token):
		return
	if not positioned:
		return
	_run_indicator_operation(func(): _advance_indicator.show_ready())


func _indicator_request_is_current(gen: int, token: int) -> bool:
	return (
		is_inside_tree()
		and gen == _dialogue_gen
		and gen == _indicator_candidate_dialogue_gen
		and token == _indicator_token
		and _dialogue_ready
		and _advance_indicator != null
		and not _should_skip_current()
		and not _ctrl_held
	)


func _invalidate_advance_indicator() -> void:
	_indicator_token += 1
	_indicator_candidate_dialogue_gen = -1
	_dialogue_ready = false
	if _advance_indicator != null and is_instance_valid(_advance_indicator):
		if _indicator_operation_depth > 0:
			_defer_indicator_action("hide", _dialogue_gen)
		else:
			_run_indicator_operation(func(): _advance_indicator.hide_indicator())


func _on_advance_dispatch_started(_serial: int) -> void:
	var was_typing := _is_typing
	var needs_voice_finalization := _logical_dialogue_voice_session_is_open()
	var needs_stage_finalization := (
		not _dialogue_segments.is_empty()
		and (
			not _segment_presentation_complete
			or not _stage_transition_records.is_empty()
		)
	)
	var retiring_character := _dialogue_voice_character
	var retiring_segments := _dialogue_segments.duplicate(true)
	# A replay deferred behind this line's stage dispatch cannot outlive a real
	# advance and unexpectedly start from the dispatch drain tail.
	_queued_voice_replay_request.clear()
	_skip_pending_dialogue_gen = -1
	_retire_auto_play_attempt()
	# Advancing is a hard async boundary for the current line. Normal input only
	# reaches it after completion; defensive external emits during typing snap to
	# the same final state. Retire the generation before finalization because its
	# public signals may synchronously SHOW the next line.
	var retired_gen := _retire_typewriter_generation()
	_is_typing = false
	if was_typing:
		text_label.visible_characters = -1
	_invalidate_advance_indicator()
	if was_typing or needs_stage_finalization or needs_voice_finalization:
		_finalize_dialogue(retiring_character, retiring_segments, retired_gen)


func _on_scenario_started(_scenario_id: String) -> void:
	_retire_indicator_transition()


func _on_game_state_changed(from_state: int, to_state: int) -> void:
	if to_state == GameStateMachine.State.PLAYING:
		if from_state != GameStateMachine.State.PLAYING:
			# A facade/action can be toggled while a system overlay is open. It must
			# remain inert there, then enter the same ready/typewriter path as the
			# built-in toolbar once gameplay owns input again.
			if StellaRuntime.is_auto_playing():
				_on_auto_play_active_changed(true)
			if StellaRuntime.is_skipping():
				_on_skip_active_changed(true)
		return
	if from_state != GameStateMachine.State.PLAYING:
		return
	# A system overlay may open from a toolbar while Ctrl is still physically
	# held, so no key-release event is guaranteed. Retire both ownership tokens at
	# the state boundary; the pending timer also checks PLAYING defensively.
	_ctrl_held = false
	cancel_pending_skip()


func _on_scene_changed(_scene_id: String) -> void:
	_retire_indicator_transition()


func _retire_indicator_transition() -> void:
	_request_lifecycle_boundary(_LIFECYCLE_TRANSITION)


func _apply_indicator_transition_boundary(revision: int) -> void:
	_skip_pending_dialogue_gen = -1
	_retire_auto_play_attempt()
	if not _retire_dialogue_lifecycle(true):
		return
	if revision != _boundary_revision:
		return
	_dialogue_gen += 1
	_is_typing = false
	_invalidate_advance_indicator()


func _on_indicator_layout_changed() -> void:
	if (
		not _dialogue_ready
		or _indicator_candidate_dialogue_gen != _dialogue_gen
		or _advance_indicator == null
	):
		return
	var gen := _dialogue_gen
	_indicator_token += 1
	_run_indicator_operation(func(): _advance_indicator.hide_indicator())
	if gen != _dialogue_gen:
		return
	_show_advance_indicator_after_layout(gen, _indicator_token)


func _on_scenario_ended(_scenario_id: String) -> void:
	_on_hide_dialogue()


func _run_voice_queue(
	character: String,
	segments: Array,
	owner_gen: int,
	queue_gen: int,
	apply_segment_presentation: bool = false,
) -> void:
	# Plays all segment voices sequentially. AudioPresenter synchronously answers
	# each request with accepted/rejected plus a playback token; only an accepted
	# clip is awaited. This keeps missing/muted/TOCTOU rejections from hanging and
	# prevents a retired FINISHED tail from releasing a replacement queue.
	_playback_queue_active = true
	var owner_validator := _voice_queue_event_owner_is_current.bind(
		owner_gen, queue_gen)
	var previous_voice_token := -1
	var previous_completion_state: VoicePlaybackCompletion
	for i in range(segments.size()):
		if not _voice_queue_is_current(owner_gen, queue_gen):
			_retire_voice_queue_if_current(queue_gen)
			return
		if previous_voice_token >= 0:
			if not await _wait_for_voice_playback_finished(
				previous_voice_token, previous_completion_state,
				owner_gen, queue_gen):
				_retire_voice_queue_if_current(queue_gen)
				return
			if _playback_voice_token == previous_voice_token:
				_playback_voice_token = -1
			# Just-finished segment was index i-1; accumulate its duration so the
			# combined progress signal can report cumulative position correctly.
			if i - 1 < _playback_segment_durations.size():
				_playback_played_duration += float(_playback_segment_durations[i - 1])
		var seg = segments[i]
		if apply_segment_presentation and not _should_skip_current():
			var stage_request_id := _apply_segment_presentation(
				seg,
				false,
				i,
				segments.size(),
				queue_gen,
			)
			while (
				stage_request_id > 0
				and SignalBus.is_stage_operation_request_active(stage_request_id)
			):
				await SignalBus.stage_operation_request_finished
				if not _voice_queue_is_current(owner_gen, queue_gen):
					_retire_voice_queue_if_current(queue_gen)
					return
			var stage_request_delivered := bool(
				_stage_operation_request_results.get(stage_request_id, false)
			)
			_stage_operation_request_results.erase(stage_request_id)
			if stage_request_id > 0 and not stage_request_delivered:
				_retire_voice_queue_if_current(queue_gen)
				return
			if not _voice_queue_is_current(owner_gen, queue_gen):
				_retire_voice_queue_if_current(queue_gen)
				return
		if not _voice_queue_is_current(owner_gen, queue_gen):
			_retire_voice_queue_if_current(queue_gen)
			return
		var voice := String(seg.get("voice", ""))
		var should_request_voice := (
			voice != "" and not _should_skip_current())
		previous_voice_token = -1
		previous_completion_state = null
		_playback_voice_token = -1
		if should_request_voice:
			_current_voice = voice
			var voice_response := SignalBus.request_voice_playback(
				voice, character, owner_validator)
			if not _voice_queue_is_current(owner_gen, queue_gen):
				_retire_voice_queue_if_current(queue_gen)
				return
			if voice_response.was_accepted():
				previous_voice_token = voice_response.get_playback_token()
				previous_completion_state = voice_response.get_completion()
				_playback_voice_token = previous_voice_token

	# Wait for the LAST segment's voice to actually finish before declaring the
	# whole dialogue voice playback done. Otherwise dialogue_voice_finished
	# would fire the instant the last segment STARTS playing, hiding the
	# progress bar before the user has heard most of the final clip.
	if previous_voice_token >= 0:
		if not await _wait_for_voice_playback_finished(
			previous_voice_token, previous_completion_state,
			owner_gen, queue_gen):
			_retire_voice_queue_if_current(queue_gen)
			return
		if _playback_voice_token == previous_voice_token:
			_playback_voice_token = -1
		var last_idx = segments.size() - 1
		if last_idx >= 0 and last_idx < _playback_segment_durations.size():
			_playback_played_duration += float(_playback_segment_durations[last_idx])

	if _voice_queue_is_current(owner_gen, queue_gen):
		_playback_queue_active = false
		if _logical_dialogue_voice_session_is_open():
			_playback_dialogue_finished_emitted = true
			if not SignalBus.emit_owned_dialogue_voice_finished(owner_validator):
				return
			if not _voice_queue_is_current(owner_gen, queue_gen):
				return


func _apply_segment_presentation(
	segment: Dictionary,
	force_cut: bool,
	segment_index: int = -1,
	segment_count: int = 0,
	queue_gen: int = -1,
) -> int:
	# Exact request ids scope transition acknowledgements even when another
	# listener queues its own stage batch before this call returns. The dispatch
	# guard begins from SignalBus' delivery callback, not submission time: a batch
	# may wait behind unrelated work and must stay guarded for its real raw-signal
	# delivery window.
	var dispatch_gen := _dialogue_gen
	var stage_ops = segment.get("stage_ops", [])
	var request_id := 0
	if stage_ops is Array and not stage_ops.is_empty():
		var emitted_ops: Array = stage_ops.duplicate(true)
		if force_cut:
			for operation in emitted_ops:
				if operation is Dictionary:
					operation["transition"] = "cut"
					operation["duration"] = 0.0
		request_id = SignalBus.reserve_stage_operation_request_id()
		_stage_operation_request_owners[request_id] = {
			"dialogue_gen": dispatch_gen,
			"finalization": _finalization_in_progress,
			"queue_gen": queue_gen,
			"segment_index": segment_index,
			"segment_count": segment_count,
			"dispatch_active": false,
		}
		SignalBus.emit_stage_operations(
			emitted_ops,
			force_cut,
			request_id,
			_on_owned_stage_operation_dispatch.bind(request_id),
		)
	elif stage_ops is Array:
		_mark_segment_presentation_dispatched(segment_index, segment_count)
	else:
		push_warning("DialoguePresenter: segment stage_ops must be an Array")
	return request_id


func _mark_segment_presentation_dispatched(
	segment_index: int,
	segment_count: int,
) -> void:
	if segment_index < 0:
		return
	_next_stage_segment_index = maxi(_next_stage_segment_index, segment_index + 1)
	if segment_count > 0 and _next_stage_segment_index >= segment_count:
		_segment_presentation_complete = true


func _on_owned_stage_operation_dispatch(request_id: int) -> void:
	var owner = _stage_operation_request_owners.get(request_id, {})
	if (
		not owner is Dictionary
		or int((owner as Dictionary).get("dialogue_gen", -1)) != _dialogue_gen
	):
		return
	(owner as Dictionary)["dispatch_active"] = true
	_stage_operation_request_owners[request_id] = owner
	_presentation_dispatch_depth += 1
	_presentation_dispatch_generations.append(_dialogue_gen)
	_mark_segment_presentation_dispatched(
		int((owner as Dictionary).get("segment_index", -1)),
		int((owner as Dictionary).get("segment_count", 0)),
	)


func _on_stage_operation_request_finished(
	request_id: int,
	delivered: bool,
) -> void:
	var owner = _stage_operation_request_owners.get(request_id, {})
	if not owner is Dictionary:
		return
	_stage_operation_request_owners.erase(request_id)
	if int((owner as Dictionary).get("dialogue_gen", -1)) == _dialogue_gen:
		_stage_operation_request_results[request_id] = delivered
	if not bool((owner as Dictionary).get("dispatch_active", false)):
		return
	_finish_presentation_dispatch()


func _finish_presentation_dispatch() -> void:
	_presentation_dispatch_depth = maxi(0, _presentation_dispatch_depth - 1)
	if not _presentation_dispatch_generations.is_empty():
		_presentation_dispatch_generations.pop_back()
	if _presentation_dispatch_depth != 0:
		return
	_drain_deferred_presentation_work()


func _drain_deferred_presentation_work() -> void:
	if (
		_presentation_dispatch_depth != 0
		or _finalization_in_progress
		or _boundary_operation_depth != 0
	):
		return
	# A hard lifecycle boundary cancels authored tails rather than folding them.
	# It is always the latest boundary because SHOW clears this slot and a later
	# lifecycle request clears queued SHOWs.
	if not _deferred_lifecycle_boundary.is_empty():
		var lifecycle := _deferred_lifecycle_boundary.duplicate(true)
		_deferred_lifecycle_boundary.clear()
		_apply_lifecycle_boundary(
			StringName(lifecycle.get("action", &"")),
			int(lifecycle.get("revision", -1)),
		)
		return
	# Finish the retiring dialogue before accepting a synchronous replacement
	# SHOW. Otherwise the replacement clears the old transition ledger and lets
	# a tween started by a later listener in the current stage dispatch leak into
	# the next line.
	if _finalization_pending:
		_finalization_pending = false
		if not _dialogue_segments.is_empty():
			_finalize_dialogue(
				_dialogue_voice_character, _dialogue_segments, _dialogue_gen)
		if _presentation_dispatch_depth != 0 or _finalization_in_progress:
			return
	# A force-cut finalization can itself queue behind another Stage operation.
	# Keep a replacement SHOW parked until that owned request has really reached
	# all listeners; starting it now would cancel the retirement batch.
	for raw_request_id in _stage_operation_request_owners.keys():
		if SignalBus.is_stage_operation_request_active(int(raw_request_id)):
			return
	if not _queued_dialogue_requests.is_empty():
		var request: Dictionary = _queued_dialogue_requests.pop_front()
		_queued_voice_replay_request.clear()
		_accept_dialogue_request(request)
		return
	if not _queued_voice_replay_request.is_empty():
		var replay_request := _queued_voice_replay_request.duplicate(true)
		_queued_voice_replay_request.clear()
		_begin_voice_replay(replay_request)


func _retire_typewriter_generation() -> int:
	var previous_gen := _dialogue_gen
	_dialogue_gen += 1
	var replacement_gen := _dialogue_gen
	# A completion/advance can be requested by an early listener while the
	# current owned stage batch is still being delivered. The late
	# StagePresenter listener must remain part of the retiring dialogue so its
	# transition token can be recorded and force-finished. Queued, not-yet-
	# delivered batches are intentionally left on the old generation: normal
	# finalization cancels and folds those operations into one cut batch.
	for raw_request_id in _stage_operation_request_owners.keys():
		var owner = _stage_operation_request_owners.get(raw_request_id, {})
		if (
			owner is Dictionary
			and bool((owner as Dictionary).get("dispatch_active", false))
			and int((owner as Dictionary).get("dialogue_gen", -1)) == previous_gen
		):
			(owner as Dictionary)["dialogue_gen"] = replacement_gen
			_stage_operation_request_owners[raw_request_id] = owner
	for index in range(_presentation_dispatch_generations.size()):
		if _presentation_dispatch_generations[index] == previous_gen:
			_presentation_dispatch_generations[index] = replacement_gen
	if _playback_owner_dialogue_gen == previous_gen:
		_playback_owner_dialogue_gen = replacement_gen
	if int(_queued_voice_replay_request.get("dialogue_gen", -1)) == previous_gen:
		_queued_voice_replay_request["dialogue_gen"] = replacement_gen
	return replacement_gen


func _on_stage_transition_started(
	presenter_instance_id: int,
	layer_id: String,
	token: int,
	operation_request_id: int,
) -> void:
	var owner = _stage_operation_request_owners.get(operation_request_id, {})
	if (
		not owner is Dictionary
		or int((owner as Dictionary).get("dialogue_gen", -1)) != _dialogue_gen
		or layer_id == ""
		or token <= 0
	):
		return
	var record := {
		"presenter_instance_id": presenter_instance_id,
		"layer_id": layer_id,
		"token": token,
	}
	var key := "%d:%s" % [presenter_instance_id, layer_id]
	if bool((owner as Dictionary).get("finalization", false)):
		_record_newest_stage_transition(
			_finalization_transition_records,
			key,
			record,
		)
	else:
		_record_newest_stage_transition(_stage_transition_records, key, record)


func _record_newest_stage_transition(
	records: Dictionary,
	key: String,
	record: Dictionary,
) -> void:
	var existing = records.get(key, {})
	if (
		existing is Dictionary
		and int((existing as Dictionary).get("token", -1))
		>= int(record.get("token", -1))
	):
		return
	records[key] = record


func _cancel_pending_stage_operation_requests() -> void:
	# Cancellation synchronously emits request-finished. Iterate a key snapshot
	# and let that handler erase only requests it actually finished; a request
	# already being delivered must remain owned until its delivery guard unwinds.
	for raw_request_id in _stage_operation_request_owners.keys():
		SignalBus.cancel_stage_operation_request(int(raw_request_id))


## Click/skip bypasses remaining voice clips. Preserve operation ordering by
## folding every pending segment batch into one atomic forced-cut emission.
func _apply_final_segment_presentation(
	segments: Array,
	force_cut: bool,
	drain_after: bool = true,
) -> void:
	if _finalization_in_progress:
		return
	var finalization_gen := _dialogue_gen
	_finalization_in_progress = true
	var remaining_stage_ops: Array = []
	for index in range(segments.size()):
		var segment = segments[index]
		if not segment is Dictionary:
			continue
		var segment_stage_ops = segment.get("stage_ops", [])
		if (
			index >= _next_stage_segment_index
			and segment_stage_ops is Array
		):
			remaining_stage_ops.append_array(segment_stage_ops.duplicate(true))

	# Commit the logical finalization before emitting either operation batch.
	# Synchronous callbacks now observe a completed cursor and an empty shared
	# transition ledger; the guard above prevents recursive finalization.
	_finalization_transition_records = _stage_transition_records.duplicate(true)
	_next_stage_segment_index = segments.size()
	_stage_transition_records.clear()
	_cancel_pending_stage_operation_requests()
	_segment_presentation_complete = true

	_apply_segment_presentation({"stage_ops": remaining_stage_ops}, force_cut)
	if finalization_gen != _dialogue_gen:
		_abort_final_segment_presentation()
		return
	# Replaying already-applied operations is not idempotent (for example,
	# update-before-show changes meaning on a second reduction). Ask each
	# presenter to finish only the exact transition tokens it acknowledged while
	# this dialogue was dispatching. Newer work on the same id is left alone.
	var finish_records: Array = _finalization_transition_records.values()
	if not finish_records.is_empty():
		SignalBus.stage_transitions_finish_requested.emit(finish_records)
		if finalization_gen != _dialogue_gen:
			_abort_final_segment_presentation()
			return
	_finalization_transition_records.clear()
	_finalization_in_progress = false
	if drain_after:
		_drain_deferred_presentation_work()


func _abort_final_segment_presentation() -> void:
	if not _finalization_in_progress:
		return
	_finalization_transition_records.clear()
	_finalization_in_progress = false
	_drain_deferred_presentation_work()


func _wait_for_voice_playback_finished(
	expected_token: int,
	completion_state: VoicePlaybackCompletion,
	owner_gen: int,
	queue_gen: int,
) -> bool:
	while _voice_queue_is_current(owner_gen, queue_gen):
		if completion_state != null and completion_state.is_finished():
			return true
		var event: VoicePlaybackEvent = await SignalBus.voice_playback_event
		if not _voice_queue_is_current(owner_gen, queue_gen):
			return false
		if (
			event.get_kind() == VoicePlaybackEvent.Kind.FINISHED
			and event.get_playback_token() == expected_token
			and event.get_playback_token() >= 0
			and event.is_current()
		):
			return true
	return false


func _voice_queue_is_current(owner_gen: int, queue_gen: int) -> bool:
	return (
		owner_gen == _dialogue_gen
		and owner_gen == _playback_owner_dialogue_gen
		and queue_gen == _playback_queue_gen
		and not _playback_aborted
	)


func _retire_voice_queue_if_current(queue_gen: int) -> void:
	if queue_gen == _playback_queue_gen:
		_playback_queue_active = false


func _finalize_dialogue(character: String, segments: Array, gen: int) -> void:
	# User aborted typewriter (or skip mode) — cancel the voice queue progression
	# and snap expression to the final segment's expression. For a single-segment
	# dialogue with empty expression this is a no-op.
	if gen != _dialogue_gen:
		_drain_deferred_presentation_work()
		return
	if _finalization_in_progress:
		_drain_deferred_presentation_work()
		return
	if _presentation_dispatch_depth > 0:
		_finalization_pending = true
		_drain_deferred_presentation_work()
		return
	_finalization_pending = false
	var voice_session_validator := _voice_session_event_owner_is_current.bind(
		gen, _playback_queue_gen)
	_playback_aborted = true
	_mark_current_line_read()
	# Keep the retiring line atomic until every finalization-owned public signal
	# has returned. In particular, a queued SHOW must not be drained by the stage
	# fold before the old logical voice session and avatar state are retired.
	_apply_final_segment_presentation(segments, true, false)
	if gen != _dialogue_gen:
		_drain_deferred_presentation_work()
		return
	# A lifecycle boundary owns retirement, including the detached validator used
	# by tree exit. Do not attempt the normal in-tree FINISH path or commit the
	# retiring line's avatar while that newer boundary is parked.
	if (
		not _deferred_lifecycle_boundary.is_empty()
		or not is_inside_tree()
	):
		_drain_deferred_presentation_work()
		return
	if _logical_dialogue_voice_session_is_open():
		_playback_dialogue_finished_emitted = true
		if not SignalBus.emit_owned_dialogue_voice_finished(
			voice_session_validator):
			_drain_deferred_presentation_work()
			return
		if gen != _dialogue_gen:
			_drain_deferred_presentation_work()
			return
	# A FINISHED listener may synchronously SHOW a replacement. Commit the old
	# final expression only after that reentrant boundary proves this dialogue is
	# still current, otherwise retired avatar state leaks into the replacement.
	if (
		_deferred_lifecycle_boundary.is_empty()
		and _queued_dialogue_requests.is_empty()
		and is_inside_tree()
	):
		_apply_final_inline_avatar_expression(character, segments)
	_drain_deferred_presentation_work()


func _on_voice_playback_event(event: VoicePlaybackEvent) -> void:
	if event == null or not event.is_current():
		return
	match event.get_kind():
		VoicePlaybackEvent.Kind.STARTED:
			if event.get_playback_token() < 0 and _active_voice_token >= 0:
				return
			_active_voice_token = event.get_playback_token()
			_voice_playing = true
		VoicePlaybackEvent.Kind.PROGRESS:
			if event.get_playback_token() < 0 and _playback_voice_token >= 0:
				return
			_relay_voice_progress(
				event.get_position(), event.get_duration(), event.get_playback_token())
		VoicePlaybackEvent.Kind.FINISHED:
			_on_voice_playback_finished(event.get_playback_token())


func _on_voice_playback_finished(playback_token: int) -> void:
	if playback_token < 0 and _active_voice_token >= 0:
		return
	if playback_token >= 0 and playback_token != _active_voice_token:
		return
	_active_voice_token = -1
	_voice_playing = false
	if playback_token < 0 or playback_token == _playback_voice_token:
		_playback_voice_token = -1


func _relay_voice_progress(
	position: float,
	_duration: float,
	playback_token: int,
) -> void:
	if _playback_total_duration <= 0.0 or not _playback_is_dialogue:
		return
	var total_pos = _playback_played_duration + position
	if playback_token < 0:
		# Raw low-level progress keeps its historical relay behavior.
		SignalBus.dialogue_voice_progress.emit(
			total_pos, _playback_total_duration)
		return
	SignalBus.emit_owned_dialogue_voice_progress(
		total_pos,
		_playback_total_duration,
		_voice_queue_event_owner_is_current.bind(
			_playback_owner_dialogue_gen, _playback_queue_gen),
	)


func _load_voice_stream(asset: String) -> AudioStream:
	for ext in ["ogg", "wav"]:
		var path = StellaRuntime.voice_path + "%s.%s" % [asset, ext]
		if ResourceLoader.exists(path):
			return load(path) as AudioStream
	return null


func _is_character_voice_enabled(character: String) -> bool:
	var enabled_by_character = StellaRuntime.get_setting(
		"character_voice_enabled"
	)
	if (
		enabled_by_character is Dictionary
		and enabled_by_character.has(character)
	):
		return bool(enabled_by_character[character])
	return true


func _effect_name_registry(effect_names: Array) -> Dictionary:
	var effect_registry: Dictionary = {}
	for raw_effect_name in effect_names:
		var effect_name := String(raw_effect_name)
		if not effect_name.is_empty():
			effect_registry[effect_name] = true
	return effect_registry


func _collect_backlog_custom_effect_names() -> Array[String]:
	var effect_names: Array[String] = []
	# A detached Presenter can remain alive for part of a frame. Its bound
	# provider Callable is still technically valid, but it no longer owns the
	# active dialogue surface and must not classify new backlog entries.
	if not is_inside_tree() or is_queued_for_deletion() or text_label == null:
		return effect_names
	for effect: RichTextEffect in text_label.custom_effects:
		if effect == null:
			continue
		var has_bbcode_property := false
		for property: Dictionary in effect.get_property_list():
			if StringName(property.get("name", &"")) == &"bbcode":
				has_bbcode_property = true
				break
		if not has_bbcode_property:
			continue
		var bbcode_value: Variant = effect.get("bbcode")
		if bbcode_value == null:
			continue
		var effect_name := String(bbcode_value).strip_edges()
		if not effect_name.is_empty() and not effect_names.has(effect_name):
			effect_names.append(effect_name)
	return effect_names


## Advanced programmatic fallback. Normal projects should use @dialogue_profile.
## Scene-authored state is restored before the new profile applies.
func set_presentation_profile(profile: DialoguePresentationProfile) -> void:
	var owner_gen := _dialogue_gen
	var has_active_dialogue := (
		is_node_ready() and not _dialogue_segments.is_empty())
	var preserves_indicator_candidate := (
		has_active_dialogue
		and _indicator_candidate_dialogue_gen == _dialogue_gen
	)
	var was_dialogue_ready := preserves_indicator_candidate and _dialogue_ready
	if has_active_dialogue:
		# Retire callbacks and custom-scene state from the old profile before
		# restoring layout can emit resize/theme signals.
		_invalidate_advance_indicator()
		if owner_gen != _dialogue_gen:
			return
	if is_node_ready():
		_restore_authored_presentation()
		if owner_gen != _dialogue_gen:
			return
	presentation_profile = profile
	_profile_warning_keys.clear()
	_auxiliary_visibility_baseline.clear()
	if not is_node_ready():
		return
	_text_rect_target = _resolve_text_rect_target()
	_validate_configured_profiles()
	if owner_gen != _dialogue_gen:
		return
	if visible or has_active_dialogue:
		var uses_profile := _apply_dialogue_mode_presentation(
			_current_mode, _active_stla_mode_profile,
			_active_uses_stla_presentation)
		if owner_gen != _dialogue_gen:
			return
		if toolbar and not uses_profile:
			toolbar.visible = (_current_mode == "adv")
	if has_active_dialogue:
		if not _configure_advance_indicator(
			_current_mode, _active_stla_mode_profile, owner_gen):
			return
		if owner_gen != _dialogue_gen:
			return
		if preserves_indicator_candidate:
			_indicator_candidate_dialogue_gen = _dialogue_gen
			if was_dialogue_ready:
				_mark_dialogue_ready_for_indicator(_dialogue_gen)


func _apply_dialogue_mode_presentation(
	mode: String,
	stla_mode_profile: DialogueModeProfile = null,
	uses_stla_presentation: bool = false,
) -> bool:
	# Every transition starts from the exact scene-authored baseline. This also
	# scrubs opt-in profile fields before returning to an unprofiled legacy mode.
	_restore_authored_presentation()
	if (not uses_stla_presentation
		and stla_mode_profile == null and presentation_profile == null):
		_apply_legacy_mode_layout(mode)
		return false

	var mode_profile := stla_mode_profile
	if mode_profile == null and presentation_profile != null:
		mode_profile = presentation_profile.get_mode(mode)
	if mode_profile == null:
		if mode == "adv":
			return true
		_apply_legacy_mode_layout(mode)
		return false

	var errors := mode_profile.validation_errors()
	if not errors.is_empty():
		for error in errors:
			_profile_warning(mode, String(error))
		if mode == "adv":
			return true
		_apply_legacy_mode_layout(mode)
		return false

	_apply_mode_profile(mode, mode_profile)
	return true


func _resolve_nvl_entry_format() -> Dictionary:
	return _resolve_nvl_entry_format_for_profile(_active_stla_mode_profile)


func _resolve_nvl_entry_format_for_profile(
	stla_mode_profile: DialogueModeProfile,
) -> Dictionary:
	var prefix := DEFAULT_NVL_ENTRY_PREFIX
	var separator := DEFAULT_NVL_ENTRY_SEPARATOR
	var mode_profile := stla_mode_profile
	if mode_profile == null and presentation_profile != null:
		mode_profile = presentation_profile.get_mode("nvl")
	# Invalid profiles use the same all-or-nothing legacy fallback as layout.
	# In particular, never re-read an invalid BBCode affix after validation
	# rejected it in _apply_dialogue_mode_presentation().
	if mode_profile != null and mode_profile.validation_errors().is_empty():
		if mode_profile.overrides_property(&"entry_prefix"):
			prefix = mode_profile.entry_prefix
		if mode_profile.overrides_property(&"entry_separator"):
			separator = mode_profile.entry_separator
	return {"prefix": prefix, "separator": separator}


func _apply_mode_profile(mode: String, profile: DialogueModeProfile) -> void:
	var override_panel_anchors := profile.overrides_property(&"panel_anchors")
	var override_panel_offsets := profile.overrides_property(&"panel_offsets")
	if override_panel_anchors or override_panel_offsets:
		var panel_rect := _capture_control_rect(self)
		_apply_control_rect(
			self,
			profile.panel_anchors if override_panel_anchors else panel_rect["anchors"],
			profile.panel_offsets if override_panel_offsets else panel_rect["offsets"],
		)
	if profile.overrides_property(&"panel_modulate"):
		modulate = profile.panel_modulate

	var override_text_anchors := profile.overrides_property(&"text_anchors")
	var override_text_offsets := profile.overrides_property(&"text_offsets")
	var override_text_margins := profile.overrides_property(&"text_margins")
	if override_text_anchors or override_text_offsets or override_text_margins:
		if _text_rect_target == null:
			_profile_warning(mode,
				"text_rect_target_path '%s' does not resolve to a Control" % text_rect_target_path)
		else:
			if _text_rect_target.get_parent() is Container:
				_profile_warning(mode,
					"text rectangle target '%s' is managed by a Container; use a free Control wrapper for exact layout"
					% _text_rect_target.get_path())
			var text_rect := _capture_control_rect(_text_rect_target)
			var anchors: Vector4 = (
				profile.text_anchors if override_text_anchors else text_rect["anchors"])
			var offsets: Vector4 = (
				profile.text_offsets if override_text_offsets else text_rect["offsets"])
			if override_text_margins:
				offsets.x += profile.text_margins.x
				offsets.y += profile.text_margins.y
				offsets.z -= profile.text_margins.z
				offsets.w -= profile.text_margins.w
			_apply_control_rect(_text_rect_target, anchors, offsets)

	if profile.overrides_property(&"horizontal_alignment"):
		text_label.horizontal_alignment = profile.horizontal_alignment
	if profile.overrides_property(&"vertical_alignment"):
		text_label.vertical_alignment = profile.vertical_alignment
	if profile.overrides_property(&"line_spacing"):
		text_label.add_theme_constant_override("line_separation", profile.line_spacing)
	if profile.overrides_property(&"fit_content"):
		text_label.fit_content = profile.fit_content
	if profile.overrides_property(&"scroll_active"):
		text_label.scroll_active = profile.scroll_active
	if profile.overrides_property(&"scroll_following"):
		text_label.scroll_following = profile.scroll_following
	if profile.overrides_property(&"autowrap_mode"):
		text_label.autowrap_mode = profile.autowrap_mode
	if profile.overrides_property(&"clip_contents"):
		text_label.clip_contents = profile.clip_contents

	if profile.overrides_property(&"background_visible"):
		if _dialogue_bg == null:
			_profile_warning(mode, "background visibility override requires a DialogueBg Control")
		else:
			_dialogue_bg.visible = profile.background_visible
	if profile.overrides_property(&"background_modulate"):
		if _dialogue_bg == null:
			_profile_warning(mode, "background modulation override requires a DialogueBg Control")
		else:
			_dialogue_bg.modulate = profile.background_modulate

	for group_name_value in profile.visibility_groups:
		var group_name := StringName(group_name_value)
		var nodes := _find_auxiliary_group_nodes(group_name)
		if nodes.is_empty():
			_profile_warning(mode,
				"visibility group '%s' has no CanvasItem descendants under DialoguePanel" % group_name)
			continue
		for node in nodes:
			_capture_auxiliary_visibility(node)
			node.visible = bool(profile.visibility_groups[group_name_value])


func _apply_legacy_mode_layout(mode: String) -> void:
	match mode:
		"nvl":
			_apply_nvl_layout()
		"overlay":
			_apply_overlay_layout()
		_:
			_apply_adv_layout()


func _capture_authored_presentation() -> void:
	_authored_presentation = {
		"panel_rect": _capture_control_rect(self),
		"panel_modulate": modulate,
		"text_alignment_horizontal": text_label.horizontal_alignment,
		"text_alignment_vertical": text_label.vertical_alignment,
		"line_spacing_overridden": text_label.has_theme_constant_override("line_separation"),
		"line_spacing": text_label.get_theme_constant("line_separation"),
		"fit_content": text_label.fit_content,
		"scroll_active": text_label.scroll_active,
		"scroll_following": text_label.scroll_following,
		"autowrap_mode": text_label.autowrap_mode,
		"clip_contents": text_label.clip_contents,
	}
	if toolbar:
		_authored_presentation["toolbar_visible"] = toolbar.visible
	if _dialogue_bg:
		_authored_presentation["background_rect"] = _capture_control_rect(_dialogue_bg)
		_authored_presentation["background_visible"] = _dialogue_bg.visible
		_authored_presentation["background_modulate"] = _dialogue_bg.modulate
	if _text_rect_target:
		_authored_presentation["text_rect"] = _capture_control_rect(_text_rect_target)
	if _text_area:
		_authored_presentation["text_area_size_flags_vertical"] = _text_area.size_flags_vertical


func _restore_authored_presentation() -> void:
	if _authored_presentation.is_empty():
		return
	_restore_control_rect(self, _authored_presentation["panel_rect"])
	modulate = _authored_presentation["panel_modulate"]
	text_label.horizontal_alignment = _authored_presentation["text_alignment_horizontal"]
	text_label.vertical_alignment = _authored_presentation["text_alignment_vertical"]
	if _authored_presentation["line_spacing_overridden"]:
		text_label.add_theme_constant_override(
			"line_separation", _authored_presentation["line_spacing"])
	else:
		text_label.remove_theme_constant_override("line_separation")
	text_label.fit_content = _authored_presentation["fit_content"]
	text_label.scroll_active = _authored_presentation["scroll_active"]
	text_label.scroll_following = _authored_presentation["scroll_following"]
	text_label.autowrap_mode = _authored_presentation["autowrap_mode"]
	text_label.clip_contents = _authored_presentation["clip_contents"]
	if toolbar and _authored_presentation.has("toolbar_visible"):
		toolbar.visible = _authored_presentation["toolbar_visible"]
	if _dialogue_bg and _authored_presentation.has("background_rect"):
		_restore_control_rect(_dialogue_bg, _authored_presentation["background_rect"])
		_dialogue_bg.visible = _authored_presentation["background_visible"]
		_dialogue_bg.modulate = _authored_presentation["background_modulate"]
	if _text_rect_target and _authored_presentation.has("text_rect"):
		_restore_control_rect(_text_rect_target, _authored_presentation["text_rect"])
	if _text_area and _authored_presentation.has("text_area_size_flags_vertical"):
		_text_area.size_flags_vertical = _authored_presentation["text_area_size_flags_vertical"]
	for entry_value in _auxiliary_visibility_baseline.values():
		var entry: Dictionary = entry_value
		var node: CanvasItem = entry["node"]
		if is_instance_valid(node):
			node.visible = entry["visible"]


func _capture_control_rect(control: Control) -> Dictionary:
	return {
		"anchors": Vector4(
			control.anchor_left, control.anchor_top,
			control.anchor_right, control.anchor_bottom),
		"offsets": Vector4(
			control.offset_left, control.offset_top,
			control.offset_right, control.offset_bottom),
	}


func _restore_control_rect(control: Control, state: Dictionary) -> void:
	_apply_control_rect(control, state["anchors"], state["offsets"])


func _apply_control_rect(control: Control, anchors: Vector4, offsets: Vector4) -> void:
	control.anchor_left = anchors.x
	control.anchor_top = anchors.y
	control.anchor_right = anchors.z
	control.anchor_bottom = anchors.w
	control.offset_left = offsets.x
	control.offset_top = offsets.y
	control.offset_right = offsets.z
	control.offset_bottom = offsets.w


func _resolve_text_rect_target() -> Control:
	if text_rect_target_path.is_empty():
		return text_label
	return get_node_or_null(text_rect_target_path) as Control


func _find_auxiliary_group_nodes(group_name: StringName) -> Array[CanvasItem]:
	var result: Array[CanvasItem] = []
	for node in find_children("*", "CanvasItem", true, false):
		if node.is_in_group(group_name):
			result.append(node as CanvasItem)
	return result


func _capture_auxiliary_visibility(node: CanvasItem) -> void:
	var instance_id := node.get_instance_id()
	if _auxiliary_visibility_baseline.has(instance_id):
		return
	_auxiliary_visibility_baseline[instance_id] = {
		"node": node,
		"visible": node.visible,
	}


func _validate_configured_profiles() -> void:
	if presentation_profile == null:
		return
	for mode in ["adv", "nvl", "overlay"]:
		var mode_profile := presentation_profile.get_mode(mode)
		if mode_profile == null:
			continue
		for error in mode_profile.validation_errors():
			_profile_warning(mode, String(error))
		if mode_profile.override_text_rect and _text_rect_target == null:
			_profile_warning(mode,
				"text_rect_target_path '%s' does not resolve to a Control" % text_rect_target_path)
		elif mode_profile.override_text_rect and _text_rect_target.get_parent() is Container:
			_profile_warning(mode,
				"text rectangle target '%s' is managed by a Container; use a free Control wrapper for exact layout"
				% _text_rect_target.get_path())
		if ((mode_profile.override_background_visibility
			or mode_profile.override_background_modulate) and _dialogue_bg == null):
			_profile_warning(mode, "background overrides require a DialogueBg Control")
		for group_name_value in mode_profile.visibility_groups:
			var group_name := StringName(group_name_value)
			if _find_auxiliary_group_nodes(group_name).is_empty():
				_profile_warning(mode,
					"visibility group '%s' has no CanvasItem descendants under DialoguePanel" % group_name)


func _profile_warning(mode: String, message: String) -> void:
	var warning_key := "%s:%s" % [mode, message]
	if _profile_warning_keys.has(warning_key):
		return
	_profile_warning_keys[warning_key] = true
	push_warning("DialoguePresenter profile '%s': %s" % [mode, message])


func _advance_indicator_warning(
	mode: String,
	mode_profile: DialogueModeProfile,
	message: String,
) -> void:
	var provenance := mode_profile.advance_indicator_diagnostic_provenance()
	var field_name := String(provenance.get(
		"indicator_field", "advance_indicator_scene"))
	var indicator_source := String(provenance.get(
		"indicator_source", "<unknown resource>"))
	var declaration_line := int(provenance.get("declaration_line", 0))
	var line_text := str(declaration_line) if declaration_line > 0 else "<unknown>"
	var origin := (
		"STLA profile '%s'; STLA source '%s'; %s declared at line %s; "
		+ "indicator source '%s'"
	) % [
		provenance.get("profile_name", "<unnamed>"),
		provenance.get("profile_source", "<unknown STLA>"),
		field_name,
		line_text,
		indicator_source,
	]

	var warning_key := "advance-indicator:%s:%s" % [origin, message]
	if _profile_warning_keys.has(warning_key):
		return
	_profile_warning_keys[warning_key] = true
	var diagnostic := message
	if not diagnostic.ends_with("."):
		diagnostic += "."
	push_warning(
		"DialoguePresenter advance indicator [%s]: %s Fix: %s"
		% [origin, diagnostic, _advance_indicator_fix_action(message, field_name)])


func _advance_indicator_fix_action(message: String, field_name: String) -> String:
	if message.contains("root must inherit CanvasItem"):
		return (
			"Set the PackedScene root to Control, Node2D, or another CanvasItem, "
			+ "then re-save the scene."
		)
	if message.contains("Control root must use top-left anchors"):
		return (
			"Set all four root Control anchors to 0 and define its size with "
			+ "offsets or minimum size."
		)
	if message.contains("scene cannot be instantiated"):
		return "Repair the PackedScene root or broken dependencies, then re-save it."
	if message.contains("mutually exclusive"):
		return "Remove one source field and keep only the intended indicator source."
	if message.contains("animation"):
		return "Set advance_indicator_animation to none, pulse, or bob."
	if message.contains("offset"):
		return "Set advance_indicator_offset to two finite numbers."
	if message.contains("resource") or message.contains("Texture2D") \
		or message.contains("PackedScene"):
		return (
			"Correct %s to an existing resource of the required type and reload the profile."
			% field_name
		)
	return "Correct %s in the identified profile and reload the dialogue." % field_name



func _apply_nvl_layout():
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	offset_left = 0
	offset_top = 0
	offset_right = 0
	offset_bottom = 0
	modulate.a = 0.9
	# DialogueBg: cover full area (ADV mode anchors it to bottom only)
	if _dialogue_bg:
		_dialogue_bg.anchor_top = 0.0
		_dialogue_bg.offset_top = 0
	# TextArea: align to top (ADV uses shrink-end = bottom)
	if _text_area:
		_text_area.size_flags_vertical = Control.SIZE_FILL


func _apply_overlay_layout():
	anchor_left = 0.15
	anchor_top = 0.3
	anchor_right = 0.85
	anchor_bottom = 0.7
	offset_left = 0
	offset_top = 0
	offset_right = 0
	offset_bottom = 0
	modulate.a = 0.7
	if _dialogue_bg:
		_dialogue_bg.anchor_top = 0.0
		_dialogue_bg.offset_top = 0
	if _text_area:
		_text_area.size_flags_vertical = Control.SIZE_FILL


func _apply_adv_layout():
	anchor_left = 0.0
	anchor_top = _adv_anchor_top
	anchor_right = 1.0
	anchor_bottom = 1.0
	offset_left = 0
	offset_top = _adv_offset_top
	offset_right = 0
	offset_bottom = 0
	modulate.a = 1.0
	# Restore DialogueBg to bottom strip
	if _dialogue_bg:
		_dialogue_bg.anchor_top = 1.0
		_dialogue_bg.offset_top = -220
	# Restore TextArea to bottom alignment
	if _text_area:
		_text_area.size_flags_vertical = Control.SIZE_SHRINK_END


## Maps a boundary in authored BBCode source to RichTextLabel's parsed
## character domain without changing the live label. The literal WORD JOINER
## remains one character even when the prefix ends in malformed BBCode, and it
## prevents an open list at the boundary from taking Godot's special
## end-of-input path. Subtracting that sentinel leaves the exact prefix count.
func _parsed_character_offset(source_text: String, source_offset: int) -> int:
	var clamped_offset := clampi(source_offset, 0, source_text.length())
	if not text_label.bbcode_enabled or not source_text.contains("["):
		return clamped_offset
	_parsed_character_full_parse_count += 1
	var parser := RichTextLabel.new()
	parser.bbcode_enabled = true
	parser.threaded = false
	parser.custom_effects = text_label.custom_effects
	parser.append_text(
		source_text.left(clamped_offset) + _CHARACTER_MAP_SENTINEL)
	var parsed_offset := maxi(0, parser.get_total_character_count() - 1)
	parser.free()
	return parsed_offset


func _reset_nvl_accumulator() -> void:
	_nvl_text = ""
	_nvl_render_source = ""
	_nvl_has_entries = false
	_nvl_incremental_document_valid = false
	_nvl_visible_characters = 0
	_active_nvl_page_key = ""


func _build_nvl_authored_history(
	entries: Array,
	_default_entry_format: Dictionary,
	custom_effect_registry: Dictionary,
) -> String:
	var rendered_history := ""
	# The final entry is the current command and is processed by the normal
	# timeline below. Earlier entries are rebuilt from authored source only; their
	# effects are stripped without replaying waits, speed changes, or expressions.
	for entry_index in range(maxi(0, entries.size() - 1)):
		var entry: Dictionary = entries[entry_index]
		var profile_data: Dictionary = entry.get("presentation_profile", {})
		var entry_profile: DialogueModeProfile = (
			DialogueModeProfile.from_dictionary(profile_data)
			if not profile_data.is_empty()
			else null
		)
		var entry_format := _resolve_nvl_entry_format_for_profile(entry_profile)
		var authored_text := ""
		for raw_segment in entry.get("segments", []):
			if raw_segment is Dictionary:
				var processed := ExpressionTimeline.parse_inline_annotations(
					String(raw_segment.get("text", "")), custom_effect_registry)
				authored_text += String(processed.get("clean_text", ""))
		var entry_character := String(entry.get("character", ""))
		var speaker_prefix := (
			"%s：" % entry_character if not entry_character.is_empty() else "")
		if entry_index > 0:
			rendered_history += String(entry_format.get("separator", ""))
		rendered_history += (
			String(entry_format.get("prefix", ""))
			+ speaker_prefix
			+ authored_text
		)
	return rendered_history


func _on_hide_dialogue():
	_request_lifecycle_boundary(_LIFECYCLE_HIDE)


func _apply_hide_dialogue_boundary(revision: int) -> void:
	# Invalidate every async branch of the current dialogue before clearing the
	# visible state. Without this, an old typewriter can finish after a runtime
	# reset and mark its line in the replacement ReadFlagManager.
	var retiring_gen := _dialogue_gen
	var retiring_queue_gen := _playback_queue_gen
	if not _retire_dialogue_lifecycle(false):
		return
	if (
		retiring_gen != _dialogue_gen
		or retiring_queue_gen + 1 != _playback_queue_gen
		or revision != _boundary_revision
	):
		return
	_dialogue_gen += 1
	var hide_gen := _dialogue_gen
	_skip_pending_dialogue_gen = -1
	_retire_auto_play_attempt()
	_ctrl_held = false
	_invalidate_advance_indicator()
	if hide_gen != _dialogue_gen:
		return
	_is_typing = false
	_restore_authored_presentation()
	_auxiliary_visibility_baseline.clear()
	_active_stla_mode_profile = null
	_active_uses_stla_presentation = false
	_current_mode = "adv"
	_current_scenario_id = ""
	_current_scene_id = ""
	_current_command_index = -1
	visible = false
	_ui_hidden = false
	_reset_nvl_accumulator()
	_current_character = ""
	_current_avatar_expression = ""
	_avatar_expressions.clear()
	_voice_playing = false
	_active_voice_token = -1
	# Dialogue state — clear so the toolbar replay button hides
	_dialogue_segments = []
	_dialogue_voice_character = ""
	_dialogue_total_duration = 0.0
	_segment_presentation_complete = false
	_next_stage_segment_index = 0
	_stage_transition_records.clear()
	_finalization_transition_records.clear()
	_cancel_pending_stage_operation_requests()
	_stage_operation_request_results.clear()
	_queued_dialogue_requests.clear()
	_queued_voice_replay_request.clear()
	_finalization_pending = false
	_finalization_in_progress = false
	# Playback session state — also reset. Bump the queue gen so any in-flight
	# voice queue coroutine (e.g. a backlog replay still running) sees the
	# mismatch on its next iteration and exits cleanly instead of leaking into
	# the next dialogue.
	_playback_queue_gen += 1
	_playback_queue_active = false
	_playback_owner_dialogue_gen = -1
	_playback_aborted = true
	_playback_dialogue_finished_emitted = false
	_playback_is_dialogue = true
	_playback_total_duration = 0.0
	_playback_played_duration = 0.0
	_playback_segment_durations.clear()
	_playback_voice_token = -1
	if _avatar_container:
		_avatar_container.visible = false
		if _avatar_texture:
			_avatar_texture.texture = null


func _update_avatar(character: String, expression: String, mode: String) -> void:
	if _avatar_container == null or _avatar_texture == null:
		return

	# Only show avatar in ADV mode when a character is speaking
	if mode != "adv" or character == "":
		_current_character = ""
		_current_avatar_expression = ""
		_avatar_container.visible = false
		_avatar_texture.texture = null
		return

	var config = _config_loader.get_config(character)

	if not config.has_avatar_rect():
		_current_character = ""
		_current_avatar_expression = ""
		_avatar_container.visible = false
		_avatar_texture.texture = null
		return

	# Load the character's expression sprite and crop via AtlasTexture
	var base_path = StellaRuntime.characters_path + "%s/" % character
	var sprite_path = _resolve_avatar_path(expression, config, base_path)
	if sprite_path == "" or not FileAccess.file_exists(sprite_path):
		if sprite_path != "":
			push_warning("DialoguePresenter: avatar sprite not found: %s" % sprite_path)
		_current_character = ""
		_current_avatar_expression = ""
		_avatar_container.visible = false
		_avatar_texture.texture = null
		return

	var source_tex = load(sprite_path) as Texture2D
	if source_tex == null:
		push_warning(
			"DialoguePresenter: avatar asset is not a Texture2D: %s"
			% sprite_path
		)
		_current_character = ""
		_current_avatar_expression = ""
		_avatar_container.visible = false
		_avatar_texture.texture = null
		return

	_current_character = character
	_current_avatar_expression = expression
	var atlas = AtlasTexture.new()
	atlas.atlas = source_tex
	atlas.region = config.avatar_rect
	_avatar_texture.texture = atlas
	_avatar_container.visible = true


func _resolve_avatar_path(
	expression: String,
	config: CharacterConfig,
	base_path: String,
) -> String:
	var asset_stem := config.resolve_avatar_asset(expression)
	if asset_stem.is_empty():
		return ""
	return base_path + "%s.png" % asset_stem


func _set_avatar_expression(character: String, expression: String) -> void:
	if character == "" or expression == "":
		return
	if (
		String(_avatar_expressions.get(character, "")) == expression
		and _current_character == character
		and _current_avatar_expression == expression
		and _avatar_texture != null
		and _avatar_texture.texture != null
	):
		return
	_avatar_expressions[character] = expression
	if character == _dialogue_voice_character and _current_mode == "adv":
		_update_avatar(character, expression, "adv")


func _apply_final_inline_avatar_expression(
	character: String,
	segments: Array,
) -> void:
	if character == "":
		return
	var final_expression := "default"
	for raw_segment in segments:
		if not raw_segment is Dictionary:
			continue
		var parsed := ExpressionTimeline.parse_inline_annotations(
			String((raw_segment as Dictionary).get("text", ""))
		)
		for marker in parsed.get("markers", []):
			final_expression = String(marker.get("expression", ""))
	_set_avatar_expression(character, final_expression)
