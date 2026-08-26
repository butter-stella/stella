## Displays dialogue text with typewriter effect.
## Supports ADV (bottom box), NVL (fullscreen accumulate), overlay modes.
## Includes bottom toolbar for game controls.
## Handles skip (toolbar + Ctrl held) and auto-play.
extends Control

signal _owned_stage_operation_finished(request_id: int, delivered: bool)

const DialogueClearOperationRequest = preload(
	"res://addons/stella/core/data/dialogue_clear_operation_request.gd")
const DialogueAvatarOperationRequest = preload(
	"res://addons/stella/core/data/dialogue_avatar_operation_request.gd")
const DEFAULT_NVL_ENTRY_PREFIX := ""
const DEFAULT_NVL_ENTRY_SEPARATOR := "\n"
const _CHARACTER_MAP_SENTINEL := "\u2060"
const _LIFECYCLE_HIDE := &"hide"
const _LIFECYCLE_TRANSITION := &"transition"
const _LIFECYCLE_EXIT := &"exit"
const _TIMER_PURPOSE_TYPEWRITER := &"typewriter"
const _TIMER_PURPOSE_SKIP := &"skip"
const _TIMER_PURPOSE_AUTO := &"auto"
const _VOICE_EVENT_PURPOSE_AUTO := &"auto"
const _VOICE_EVENT_PURPOSE_QUEUE := &"queue"
const _NEXT_FRAME_PURPOSE_SHOW := &"show"
const _TYPEWRITER_PUNCTUATION := "，。！？；：、,.!?;:…—"


class DialogueTimerWaiter:
	extends RefCounted

	signal settled(natural_timeout: bool)

	var timer: Timer
	var dialogue_gen: int = -1
	var purpose: StringName
	var attempt: int = -1
	var is_settled: bool = false


	func settle(natural_timeout: bool) -> bool:
		if is_settled:
			return false
		is_settled = true
		settled.emit(natural_timeout)
		return true


class DialogueVoiceEventWaiter:
	extends RefCounted

	signal settled

	var dialogue_gen: int = -1
	var purpose: StringName
	var attempt: int = -1
	var queue_gen: int = -1
	var event: VoicePlaybackEvent
	var cancelled: bool = false
	var is_settled: bool = false


	func settle(p_event: VoicePlaybackEvent, p_cancelled: bool) -> bool:
		if is_settled:
			return false
		is_settled = true
		event = p_event
		cancelled = p_cancelled
		settled.emit()
		return true


class DialogueNextFrameWaiter:
	extends RefCounted

	signal settled(natural_frame: bool)

	var dialogue_gen: int = -1
	var purpose: StringName
	var callback: Callable
	var is_settled: bool = false


	func settle(natural_frame: bool) -> bool:
		if is_settled:
			return false
		is_settled = true
		settled.emit(natural_frame)
		return true

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

## Settings-backed caches in seconds. Tests and extensions historically assign
## _char_interval directly; the mirror fields let active SHOW atomically refresh
## unchanged caches from settings while preserving an explicit field override.
var _char_interval: float = 0.05
var _punctuation_pause: float = 0.2
var _settings_character_interval: float = 0.05
var _settings_punctuation_pause: float = 0.2
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
# toolbar skip. Read flags are written by DialogueHandler after normal command
# completion and intentionally are NOT reverted by rollback (backlog / flowchart
# / choice rewind) — once advanced, always read. See stella_runtime.gd:436.
var _current_scenario_id: String = ""
var _current_scenario_identity: String = ""
var _current_scene_id: String = ""
var _current_command_index: int = -1
var _current_command_uid: int = -1
var _current_dialogue_activation: DialogueActivation
var _current_voice: String = ""  # current dialogue voice asset
var _current_voice_character: String = ""
var _voice_layer_progress: Dictionary = {}
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
var _canonical_dialogue_visibility := {
	"surface": true,
	"quick_menu": true,
}
var _dialogue_visibility_token_serial: int = 0
var _dialogue_visibility_generation: Dictionary = {
	"surface": 1,
	"quick_menu": 1,
}
var _dialogue_visibility_nodes: Dictionary = {}
var _dialogue_visibility_binding: Dictionary = {}
var _dialogue_visibility_runtime_binding: Dictionary = {}
var _dialogue_visibility_profile_baseline: Dictionary = {}
var _dialogue_visibility_effective_signatures: Dictionary = {
	"surface": "",
	"quick_menu": "",
}
var _dialogue_visibility_active: Dictionary = {}
var _dialogue_clear_participant_capability: RefCounted
var _dialogue_avatar_participant_capability: RefCounted
var _addressable_avatar_sprite: Sprite2D
var _addressable_avatar_outgoing: Sprite2D
var _addressable_avatar_state: Dictionary = DialogueAvatarState.default_state()
var _dialogue_avatar_request_plans: Dictionary = {}
var _dialogue_avatar_tween: Tween
var _dialogue_avatar_token_serial: int = 0
var _dialogue_avatar_generation: int = 1
var _dialogue_avatar_active_receipt: Dictionary = {}
const _DIALOGUE_AVATAR_TEXTURE_EXTENSIONS := [".png", ".jpg", ".jpeg", ".webp", ".svg"]

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
var _dialogue_timer_serial: int = 0
var _dialogue_timer_waiters: Dictionary = {}
var _dialogue_timer_authority_exiting: bool = false
var _voice_event_waiter_serial: int = 0
var _voice_event_waiters: Dictionary = {}
var _voice_event_waiter_authority_exiting: bool = false
var _next_frame_waiter_serial: int = 0
var _next_frame_waiters: Dictionary = {}
var _next_frame_waiter_authority_exiting: bool = false

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
	_dialogue_clear_participant_capability = (
		StellaRuntime._register_dialogue_clear_presenter(self))
	if _dialogue_clear_participant_capability == null:
		push_error(
			"DialoguePresenter could not join the internal clear registry")
		return
	_char_interval = _read_typewriter_setting_seconds("character_interval")
	_punctuation_pause = _read_typewriter_setting_seconds("punctuation_pause")
	_settings_character_interval = _char_interval
	_settings_punctuation_pause = _punctuation_pause
	SignalBus.dialogue_requested.connect(_on_dialogue_requested)
	SignalBus.hide_dialogue.connect(_on_hide_dialogue)
	SignalBus.dialogue_advance_committed.connect(
		_on_dialogue_advance_committed)
	# SignalBus emits this pre-dispatch event before every direct public/raw advance.
	# A replacement Presenter created later in that same signal stack never sees
	# the old transition, so it cannot accidentally retire the newly shown line.
	SignalBus.advance_dispatch_started.connect(_on_advance_dispatch_started)
	SignalBus.voice_playback_event.connect(_on_voice_playback_event)
	SignalBus.dialogue_voice_replay_requested.connect(_on_dialogue_voice_replay_requested)
	SignalBus.dialogue_voice_segment_replay_requested.connect(
		_on_dialogue_voice_segment_replay_requested)
	SignalBus.scenario_started_event.connect(_on_scenario_started)
	SignalBus.scene_changed_event.connect(_on_scene_changed)
	SignalBus.scenario_ended_event.connect(_on_scenario_ended)
	StellaRuntime.game_state.state_changed.connect(_on_game_state_changed)
	StellaRuntime.auto_play.active_changed.connect(_on_auto_play_active_changed)
	StellaRuntime.auto_play.effective_changed.connect(
		_on_auto_play_effective_changed)
	StellaRuntime.skip_controller.active_changed.connect(_on_skip_active_changed)
	SignalBus.choice_show.connect(_on_choice_modal_started)
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
	SignalBus.presentation_operation_request_finished.connect(
		_on_stage_operation_request_finished
	)
	if SignalBus.has_signal(&"dialogue_visibility_operations_requested"):
		(SignalBus.get(&"dialogue_visibility_operations_requested") as Signal).connect(
			_on_dialogue_visibility_operations_requested
		)
	SignalBus.dialogue_clear_validate_requested.connect(
		_on_dialogue_clear_validate_requested)
	SignalBus.dialogue_clear_accept_requested.connect(
		_on_dialogue_clear_accept_requested)
	SignalBus.dialogue_clear_apply_requested.connect(
		_on_dialogue_clear_apply_requested)
	SignalBus.dialogue_avatar_validate_requested.connect(
		_on_dialogue_avatar_validate_requested)
	SignalBus.dialogue_avatar_accept_requested.connect(
		_on_dialogue_avatar_accept_requested)
	SignalBus.dialogue_avatar_apply_readiness_requested.connect(
		_on_dialogue_avatar_apply_readiness_requested)
	SignalBus.dialogue_avatar_apply_requested.connect(
		_on_dialogue_avatar_apply_requested)
	SignalBus.dialogue_avatar_visuals_reset_requested.connect(
		_on_dialogue_avatar_visuals_reset_requested)
	SignalBus.dialogue_avatar_state_apply_requested.connect(
		_on_dialogue_avatar_state_apply_requested)
	SignalBus.dialogue_avatar_transition_receipts_finish_requested.connect(
		_on_dialogue_avatar_transition_receipts_finish_requested)
	if SignalBus.has_signal(&"dialogue_visibility_state_apply_requested"):
		(SignalBus.get(&"dialogue_visibility_state_apply_requested") as Signal).connect(
			_on_dialogue_visibility_state_apply_requested
		)
	SignalBus.dialogue_content_state_apply_requested.connect(
		_on_dialogue_content_state_apply_requested)
	SignalBus.dialogue_visibility_targets_state_apply_requested.connect(
		_on_dialogue_visibility_targets_state_apply_requested)
	if SignalBus.has_signal(&"dialogue_visibility_visuals_reset_requested"):
		(SignalBus.get(&"dialogue_visibility_visuals_reset_requested") as Signal).connect(
			_on_dialogue_visibility_visuals_reset_requested
		)
	if SignalBus.has_signal(&"dialogue_visibility_transition_receipts_finish_requested"):
		(SignalBus.get(
			&"dialogue_visibility_transition_receipts_finish_requested"
		) as Signal).connect(_on_dialogue_visibility_transition_receipts_finish_requested)
	SignalBus.settings_changed.connect(_on_typewriter_setting_changed)
	_config_loader = StellaRuntime.character_config_loader
	_avatar_container = get_node_or_null("%AvatarContainer")
	if _avatar_container:
		_avatar_texture = _avatar_container.get_node_or_null("AvatarTexture")
		_addressable_avatar_sprite = Sprite2D.new()
		_addressable_avatar_sprite.name = "AddressableAvatar"
		_addressable_avatar_sprite.centered = false
		_addressable_avatar_sprite.visible = false
		_avatar_container.add_child(_addressable_avatar_sprite)
	_dialogue_avatar_participant_capability = (
		StellaRuntime._register_dialogue_avatar_presenter(self))
	if _dialogue_avatar_participant_capability == null:
		push_error(
			"DialoguePresenter could not join the internal avatar registry")
		return
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
	_capture_dialogue_visibility_nodes()
	_validate_configured_profiles()
	text_label.resized.connect(_on_indicator_layout_changed)
	text_label.theme_changed.connect(_on_indicator_layout_changed)
	text_label.get_v_scroll_bar().value_changed.connect(
		func(_value): _on_indicator_layout_changed())


func _read_typewriter_setting_seconds(key: String) -> float:
	return _validate_typewriter_setting_seconds(
		key, StellaRuntime.get_setting(key))


func _validate_typewriter_setting_seconds(
	key: String,
	value: Variant,
) -> float:
	var defaults := GameSettings.new()
	var fallback_ms: int = (
		defaults.character_interval
		if key == "character_interval"
		else defaults.punctuation_pause
	)
	if typeof(value) != TYPE_INT or int(value) < 0:
		push_warning((
			"DialoguePresenter: %s must be a non-negative integer in "
			+ "milliseconds; using GameSettings default %d ms"
		) % [key, fallback_ms])
		return float(fallback_ms) / 1000.0
	return float(value) / 1000.0


func _snapshot_typewriter_delay_seconds(
	key: String,
	value: Variant,
) -> float:
	if (
		typeof(value) != TYPE_INT
		and typeof(value) != TYPE_FLOAT
	) or not is_finite(float(value)) or float(value) < 0.0:
		var defaults := GameSettings.new()
		var fallback_ms: int = (
			defaults.character_interval
			if key == "character_interval"
			else defaults.punctuation_pause
		)
		push_warning((
			"DialoguePresenter: cached %s must be a non-negative finite "
			+ "number of seconds; using GameSettings default %d ms"
		) % [key, fallback_ms])
		return float(fallback_ms) / 1000.0
	return float(value)


func _on_typewriter_setting_changed(key: String, value: Variant) -> void:
	if key == "character_interval":
		var interval := _validate_typewriter_setting_seconds(key, value)
		_char_interval = interval
		_settings_character_interval = interval
	elif key == "punctuation_pause":
		var pause := _validate_typewriter_setting_seconds(key, value)
		_punctuation_pause = pause
		_settings_punctuation_pause = pause


func _reconcile_typewriter_settings_cache() -> void:
	# SettingsManager reset restores its whole model before publishing individual
	# keys. A listener connected before this Presenter may synchronously SHOW on
	# the first notification, so reconcile the authoritative pair at the SHOW
	# boundary. Preserve fields that tests/extensions changed directly by
	# comparing them with the last values received from settings.
	var character_overridden := _char_interval != _settings_character_interval
	var punctuation_overridden := (
		_punctuation_pause != _settings_punctuation_pause)
	var current_character := _read_typewriter_setting_seconds(
		"character_interval")
	var current_punctuation := _read_typewriter_setting_seconds(
		"punctuation_pause")
	_settings_character_interval = current_character
	_settings_punctuation_pause = current_punctuation
	if not character_overridden:
		_char_interval = current_character
	if not punctuation_overridden:
		_punctuation_pause = current_punctuation


static func _typewriter_character_delay_seconds(
	character: String,
	interval_seconds: float,
	punctuation_pause_seconds: float,
) -> float:
	var delay := interval_seconds
	if character.length() == 1 and _TYPEWRITER_PUNCTUATION.contains(character):
		delay += punctuation_pause_seconds
	return delay


func _await_dialogue_timer(
	duration: float,
	dialogue_gen: int,
	purpose: StringName,
	attempt: int = -1,
) -> bool:
	if (
		_dialogue_timer_authority_exiting
		or dialogue_gen != _dialogue_gen
		or not is_inside_tree()
		or is_queued_for_deletion()
	):
		return false
	_dialogue_timer_serial += 1
	var waiter_id := _dialogue_timer_serial
	var waiter := DialogueTimerWaiter.new()
	waiter.dialogue_gen = dialogue_gen
	waiter.purpose = purpose
	waiter.attempt = attempt
	var timer := Timer.new()
	timer.name = "DialogueTimer_%d" % waiter_id
	timer.one_shot = true
	timer.process_callback = Timer.TIMER_PROCESS_IDLE
	timer.process_mode = Node.PROCESS_MODE_ALWAYS
	timer.ignore_time_scale = false
	waiter.timer = timer
	_dialogue_timer_waiters[waiter_id] = waiter
	add_child(timer)
	timer.timeout.connect(
		_on_dialogue_timer_timeout.bind(waiter_id), CONNECT_ONE_SHOT)
	# SceneTree.create_timer(0) settles on the next idle boundary. Timer requires
	# a positive wait_time, so the smallest positive duration preserves that
	# asynchronous boundary without introducing a wall-clock polling path.
	timer.start(maxf(duration, 0.000001))
	var natural_timeout: bool = await waiter.settled
	return natural_timeout


func _on_dialogue_timer_timeout(waiter_id: int) -> void:
	_settle_dialogue_timer_waiter(waiter_id, true)


func _settle_dialogue_timer_waiter(
	waiter_id: int,
	natural_timeout: bool,
) -> bool:
	var waiter := _dialogue_timer_waiters.get(waiter_id) as DialogueTimerWaiter
	if waiter == null:
		return false
	# Erase authority before stopping or settling. Both operations can synchronously
	# re-enter Presenter code; the retired waiter must already be unreachable.
	_dialogue_timer_waiters.erase(waiter_id)
	var timer := waiter.timer
	waiter.timer = null
	if is_instance_valid(timer):
		timer.stop()
		timer.queue_free()
	return waiter.settle(natural_timeout)


func _cancel_dialogue_timer_waiters(
	dialogue_gen: int,
	purpose: StringName = &"",
	attempt: int = -1,
) -> void:
	for waiter_id_value: Variant in _dialogue_timer_waiters.keys():
		var waiter_id := int(waiter_id_value)
		var waiter := (
			_dialogue_timer_waiters.get(waiter_id) as DialogueTimerWaiter)
		if waiter == null or waiter.dialogue_gen != dialogue_gen:
			continue
		if not purpose.is_empty() and waiter.purpose != purpose:
			continue
		if attempt >= 0 and waiter.attempt != attempt:
			continue
		_settle_dialogue_timer_waiter(waiter_id, false)


func _cancel_all_dialogue_timer_waiters() -> void:
	for waiter_id_value: Variant in _dialogue_timer_waiters.keys():
		_settle_dialogue_timer_waiter(int(waiter_id_value), false)


func _await_owned_voice_event(
	dialogue_gen: int,
	purpose: StringName,
	attempt: int = -1,
	queue_gen: int = -1,
) -> DialogueVoiceEventWaiter:
	if (
		_voice_event_waiter_authority_exiting
		or dialogue_gen != _dialogue_gen
		or not is_inside_tree()
		or is_queued_for_deletion()
	):
		return null
	if purpose == _VOICE_EVENT_PURPOSE_AUTO:
		if (
			attempt < 0
			or _auto_pending_dialogue_gen != dialogue_gen
			or _auto_pending_attempt != attempt
		):
			return null
	elif purpose == _VOICE_EVENT_PURPOSE_QUEUE:
		if queue_gen < 0 or queue_gen != _playback_queue_gen:
			return null
	else:
		return null
	_voice_event_waiter_serial += 1
	var waiter_id := _voice_event_waiter_serial
	var waiter := DialogueVoiceEventWaiter.new()
	waiter.dialogue_gen = dialogue_gen
	waiter.purpose = purpose
	waiter.attempt = attempt
	waiter.queue_gen = queue_gen
	_voice_event_waiters[waiter_id] = waiter
	await waiter.settled
	return waiter


func _settle_voice_event_waiter(
	waiter_id: int,
	event: VoicePlaybackEvent,
	cancelled: bool,
) -> bool:
	var waiter := (
		_voice_event_waiters.get(waiter_id) as DialogueVoiceEventWaiter)
	if waiter == null:
		return false
	# Authority is erased before settlement because the resumed continuation may
	# synchronously register its next wait or publish another physical event.
	_voice_event_waiters.erase(waiter_id)
	return waiter.settle(event, cancelled)


func _settle_voice_event_entry_snapshot(
	waiter_ids: Array,
	event: VoicePlaybackEvent,
) -> void:
	for waiter_id_value: Variant in waiter_ids:
		_settle_voice_event_waiter(int(waiter_id_value), event, false)


func _cancel_voice_event_waiters(
	dialogue_gen: int = -1,
	purpose: StringName = &"",
	attempt: int = -1,
	queue_gen: int = -1,
) -> void:
	for waiter_id_value: Variant in _voice_event_waiters.keys():
		var waiter_id := int(waiter_id_value)
		var waiter := (
			_voice_event_waiters.get(waiter_id) as DialogueVoiceEventWaiter)
		if waiter == null:
			continue
		if dialogue_gen >= 0 and waiter.dialogue_gen != dialogue_gen:
			continue
		if not purpose.is_empty() and waiter.purpose != purpose:
			continue
		if attempt >= 0 and waiter.attempt != attempt:
			continue
		if queue_gen >= 0 and waiter.queue_gen != queue_gen:
			continue
		_settle_voice_event_waiter(waiter_id, null, true)


func _cancel_all_voice_event_waiters() -> void:
	for waiter_id_value: Variant in _voice_event_waiters.keys():
		_settle_voice_event_waiter(int(waiter_id_value), null, true)


func _await_owned_next_frame(
	dialogue_gen: int,
	purpose: StringName,
) -> bool:
	if (
		_next_frame_waiter_authority_exiting
		or dialogue_gen != _dialogue_gen
		or purpose != _NEXT_FRAME_PURPOSE_SHOW
		or not is_inside_tree()
		or is_queued_for_deletion()
	):
		return false
	_next_frame_waiter_serial += 1
	var waiter_id := _next_frame_waiter_serial
	var waiter := DialogueNextFrameWaiter.new()
	waiter.dialogue_gen = dialogue_gen
	waiter.purpose = purpose
	waiter.callback = _on_owned_next_frame.bind(waiter_id)
	_next_frame_waiters[waiter_id] = waiter
	get_tree().process_frame.connect(waiter.callback, CONNECT_ONE_SHOT)
	var natural_frame: bool = await waiter.settled
	return natural_frame


func _on_owned_next_frame(waiter_id: int) -> void:
	_settle_next_frame_waiter(waiter_id, true)


func _settle_next_frame_waiter(
	waiter_id: int,
	natural_frame: bool,
) -> bool:
	var waiter := (
		_next_frame_waiters.get(waiter_id) as DialogueNextFrameWaiter)
	if waiter == null:
		return false
	# Disconnect and erase authority before synchronous settlement. A resumed
	# SHOW may publish a replacement generation and register another frame wait.
	_next_frame_waiters.erase(waiter_id)
	var callback := waiter.callback
	waiter.callback = Callable()
	var tree := get_tree()
	if (
		callback.is_valid()
		and tree != null
		and tree.process_frame.is_connected(callback)
	):
		tree.process_frame.disconnect(callback)
	return waiter.settle(natural_frame)


func _cancel_next_frame_waiters(dialogue_gen: int) -> void:
	for waiter_id_value: Variant in _next_frame_waiters.keys():
		var waiter_id := int(waiter_id_value)
		var waiter := (
			_next_frame_waiters.get(waiter_id) as DialogueNextFrameWaiter)
		if waiter != null and waiter.dialogue_gen == dialogue_gen:
			_settle_next_frame_waiter(waiter_id, false)


func _cancel_all_next_frame_waiters() -> void:
	for waiter_id_value: Variant in _next_frame_waiters.keys():
		_settle_next_frame_waiter(int(waiter_id_value), false)


func _publish_next_dialogue_generation() -> int:
	var previous_gen := _dialogue_gen
	_dialogue_gen += 1
	_cancel_dialogue_timer_waiters(previous_gen)
	_cancel_voice_event_waiters(previous_gen)
	_cancel_next_frame_waiters(previous_gen)
	return _dialogue_gen


func _publish_next_voice_queue_generation() -> int:
	var previous_queue_gen := _playback_queue_gen
	# Publish replacement ownership before waking the old continuation. It must
	# observe itself as stale even when cancellation resumes synchronously.
	_playback_queue_gen += 1
	_cancel_voice_event_waiters(
		-1, _VOICE_EVENT_PURPOSE_QUEUE, -1, previous_queue_gen)
	return _playback_queue_gen


func _exit_tree() -> void:
	_dialogue_timer_authority_exiting = true
	_voice_event_waiter_authority_exiting = true
	_next_frame_waiter_authority_exiting = true
	_cancel_all_dialogue_timer_waiters()
	_cancel_all_voice_event_waiters()
	_cancel_all_next_frame_waiters()
	StellaRuntime._unregister_dialogue_clear_presenter(
		self, _dialogue_clear_participant_capability)
	_dialogue_clear_participant_capability = null
	_retire_addressable_avatar_transition(&"cancelled")
	StellaRuntime._unregister_dialogue_avatar_presenter(
		self, _dialogue_avatar_participant_capability)
	_dialogue_avatar_participant_capability = null
	_dialogue_avatar_request_plans.clear()
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
		if btn_info["id"] == "backlog" and not StellaRuntime.config.backlog:
			continue
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
			"voice_layers": [{
				"id": "main",
				"asset": String(v),
				"character": character,
				"dsp": "",
				"line": 0,
			}],
		})
	_request_voice_replay(character, segments, false)


func _on_dialogue_voice_segment_replay_requested(
	segments: Array,
	character: String,
) -> void:
	if segments.is_empty():
		return
	var canonical_segments: Array = []
	for segment_value: Variant in segments:
		var selection := _voice_layers_for_segment(segment_value)
		if not bool(selection.get("valid", false)):
			return
		var layers: Array = selection.get("segment_layers", [])
		if layers.is_empty():
			return
		canonical_segments.append({
			"text": "",
			"voice_layers": layers.duplicate(true),
			"presentation_ops": [],
			"presentation_operation_lines": [],
		})
	_request_voice_replay(character, canonical_segments, false)


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
		var request_id := int(raw_request_id)
		if not SignalBus.cancel_presentation_operation_request(request_id):
			SignalBus.cancel_stage_operation_request(request_id)


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
	_abort_current_dialogue_activation()
	if owner_gen != _dialogue_gen or queue_gen != _playback_queue_gen:
		return false
	if not _retire_logical_voice_session_internal(
		owner_gen, queue_gen, allow_detached
	):
		return false
	if owner_gen != _dialogue_gen or queue_gen != _playback_queue_gen:
		return false
	_queued_voice_replay_request.clear()
	_abort_queued_dialogue_requests()
	if owner_gen != _dialogue_gen or queue_gen != _playback_queue_gen:
		return false
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
	_publish_next_voice_queue_generation()
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
	_abort_queued_dialogue_requests()
	if revision != _boundary_revision:
		return
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
	_publish_next_dialogue_generation()
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
	var queue_gen := _publish_next_voice_queue_generation()
	if owner_gen != _dialogue_gen or queue_gen != _playback_queue_gen:
		return false
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
	_character: String,
	segments: Array,
) -> Array:
	var durations: Array = []
	for segment_value: Variant in segments:
		var duration := 0.0
		var selection := _voice_layers_for_segment(segment_value, false)
		if bool(selection.get("valid", false)):
			for layer_value: Variant in selection.get("request_layers", []):
				var layer: Dictionary = layer_value
				if not _is_character_voice_enabled(
					String(layer.get("character", ""))):
					continue
				var stream := _load_voice_stream(String(layer.get("asset", "")))
				if stream != null:
					duration = maxf(duration, stream.get_length())
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
	if StellaRuntime.is_choice_active():
		# Toolbar intent may change while the menu is open, but the choice remains
		# the sole blocker. Its successor command creates any new Auto tail.
		return
	if not StellaRuntime.game_state.is_playing():
		# Public facade/actions may configure Auto while a system overlay owns
		# input. Preserve that public controller state, but never start a dialogue
		# tail until PLAYING resumes.
		return
	if (
		StellaRuntime.is_auto_play_effective()
		and _dialogue_ready
		and _indicator_candidate_dialogue_gen == _dialogue_gen
	):
		_continue_auto_play_after_ready(_dialogue_gen)


func _on_auto_play_effective_changed(effective: bool) -> void:
	if not is_inside_tree() or is_queued_for_deletion():
		return
	# Suspension release must never revive the completed dialogue that preceded
	# a choice. The next command owns creation of a fresh Auto tail. The negative
	# edge, however, synchronously retires any timer that was already pending.
	if not effective:
		_retire_auto_play_attempt()


func _on_choice_modal_started(_prompt: String, _options: Array) -> void:
	if not StellaRuntime.is_choice_presentation_dispatch_current():
		return
	# Choice is a hard blocker even when settings keep Auto/Skip intent active.
	# Retire the preceding dialogue's timers without entering the normal
	# cancelled-skip restoration path, which could otherwise schedule Auto again.
	_ctrl_held = false
	_cancel_dialogue_timer_waiters(_dialogue_gen, _TIMER_PURPOSE_SKIP)
	_skip_pending_dialogue_gen = -1
	_retire_auto_play_attempt()


func _on_skip_pressed():
	StellaRuntime.toggle_skip()


func _on_skip_active_changed(active: bool) -> void:
	if not is_inside_tree() or is_queued_for_deletion():
		return
	_update_toggle_buttons()
	if not active:
		cancel_pending_skip()
		return
	if StellaRuntime.is_choice_active():
		# A menu-time toolbar toggle changes future intent only. Never let the old
		# ready dialogue or typewriter become an advance source behind the choice.
		return
	if not StellaRuntime.game_state.is_playing():
		# Preserve the public controller state while an overlay owns input. The
		# PLAYING transition below re-applies it to the still-ready dialogue.
		return
	# Apply the unread gate before finalizing the typewriter. A toolbar press on
	# an unread line must stop skip without scheduling a command advance.
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
		request_current_dialogue_advance()


func _schedule_advance_after_skip_delay(gen: int) -> void:
	_skip_pending_dialogue_gen = gen
	if not await _await_dialogue_timer(
		StellaRuntime.get_setting("skip_interval") / 1000.0,
		gen,
		_TIMER_PURPOSE_SKIP,
	):
		return
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
	request_current_dialogue_advance()


func cancel_pending_skip() -> void:
	if _skip_pending_dialogue_gen != _dialogue_gen:
		return
	_cancel_dialogue_timer_waiters(
		_dialogue_gen, _TIMER_PURPOSE_SKIP)
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
	if StellaRuntime.is_auto_play_effective():
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
	if StellaRuntime.is_auto_play_effective():
		_continue_auto_play_after_ready(gen)
	return true


## Consume one normal advance input at the active typewriter boundary.
## The caller supplies the live input policy: disabled completion still owns
## the input, but leaves every typewriter field and outstanding timer intact.
## Forced callers such as Skip continue to use complete_typewriter() directly.
func consume_typewriter_advance(allow_completion: bool) -> bool:
	if not _is_typing:
		return false
	if allow_completion:
		complete_typewriter()
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
		"auto": return StellaRuntime.auto_play.is_active
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
	return StellaRuntime.skip_controller.should_skip(
		_current_scenario_id,
		_current_scene_id,
		_current_command_index,
		StellaRuntime.read_flags,
		StellaRuntime.get_setting("skip_only_read"),
		_current_scenario_identity,
		_current_command_uid,
	)


## Side-effect counterpart to `_should_skip_current()`. If toolbar skip is
## active but blocked by an unread line, stop the toolbar skip so the button
## un-highlights and the user reads normally. Safe to call any number of times:
## once `skip_controller.is_active` is false, this is a no-op.
func _apply_unread_skip_gate() -> void:
	if _ctrl_held:
		return
	if _should_skip_current():
		return
	StellaRuntime.skip_controller.stop()
	_update_toggle_buttons()


func _capture_request_identity(request: Dictionary) -> void:
	_current_scenario_id = ""
	_current_scenario_identity = ""
	_current_scene_id = ""
	_current_command_index = -1
	_current_command_uid = -1
	_current_dialogue_activation = request.get("activation") as DialogueActivation
	_current_scenario_identity = String(request.get("scenario_identity", ""))
	_current_scenario_id = String(request.get("legacy_scenario_id", ""))
	_current_scene_id = String(request.get("scene_id", ""))
	_current_command_index = int(request.get("legacy_command_index", -1))
	_current_command_uid = int(request.get("command_uid", -1))
	if (
		not _current_scenario_identity.is_empty()
		and not _current_scene_id.is_empty()
		and _current_command_uid >= 0
	):
		return
	# Compatibility for direct legacy Presenter calls that predate the typed
	# request identity. Runtime DialogueHandler requests never use this path.
	if StellaRuntime.engine == null or StellaRuntime.engine.context == null:
		return
	var ctx = StellaRuntime.engine.context
	if ctx.scenario_data == null:
		return
	var scene = ctx.current_scene()
	if scene == null:
		return
	_current_scenario_id = ctx.scenario_data.id
	_current_scenario_identity = ctx.scenario_data.get_read_identity()
	_current_scene_id = scene.id
	_current_command_index = ctx.current_command_index
	var command := ctx.current_command()
	_current_command_uid = command.uid if command != null else -1


## Input, auto-play, and skip acknowledge the exact request currently rendered.
## Legacy raw SHOW calls have no blocking activation and retain their global
## compatibility notification.
func request_current_dialogue_advance() -> bool:
	if _current_dialogue_activation != null:
		if _current_dialogue_activation.advance():
			return true
		_current_dialogue_activation = null
		return false
	SignalBus.emit_advance_requested()
	return true


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
	# The whole request is validated before replacement can retire the previous
	# dialogue or voice group. A later malformed segment therefore cannot cause a
	# partial visible/dialogue mutation.
	for segment_value: Variant in dialogue_request.get_segments():
		if not bool(_voice_layers_for_segment(segment_value).get("valid", false)):
			dialogue_request.abort()
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
		"activation": dialogue_request.get_activation(),
		"scenario_identity": dialogue_request.get_scenario_identity(),
		"legacy_scenario_id": dialogue_request.get_legacy_scenario_id(),
		"scene_id": dialogue_request.get_scene_id(),
		"legacy_command_index": dialogue_request.get_legacy_command_index(),
		"command_uid": dialogue_request.get_command_uid(),
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
		_abort_queued_dialogue_requests()
		if int(request.get("boundary_revision", -1)) != _boundary_revision:
			_abort_dialogue_request(request)
			return
		_queued_dialogue_requests.append(request)
		return
	_abort_queued_dialogue_requests()
	_accept_dialogue_request(request)


## A Presenter can render only one queued replacement. Every displaced typed
## request must be explicitly cancelled so its DialogueHandler cannot remain
## suspended after the UI chooses a newer owner.
func _abort_queued_dialogue_requests() -> void:
	var displaced := _queued_dialogue_requests.duplicate()
	_queued_dialogue_requests.clear()
	for queued_request in displaced:
		if not queued_request is Dictionary:
			continue
		var request: Dictionary = queued_request
		_abort_dialogue_request(request)


func _abort_dialogue_request(request: Dictionary) -> void:
	var activation := request.get("activation") as DialogueActivation
	if activation != null:
		activation.abort()


## Returns whether synchronous replacement callbacks gave this request a
## presenter-owned slot. A superseded incoming activation that is neither
## current nor queued must be cancelled explicitly so its handler cannot hang.
func _dialogue_request_is_owned(request: Dictionary) -> bool:
	var activation := request.get("activation") as DialogueActivation
	if activation == null:
		return false
	if activation == _current_dialogue_activation:
		return true
	for queued_request in _queued_dialogue_requests:
		if not queued_request is Dictionary:
			continue
		var queued: Dictionary = queued_request
		var queued_activation := queued.get("activation") as DialogueActivation
		if queued_activation == activation:
			return true
	return false


## The Presenter owns at most one visible typed request. Any boundary that
## replaces or hides that presentation must resolve the old Core waiter before
## dropping its reference. Clear first so an abort callback may synchronously
## publish a replacement without this retirement path cancelling the newcomer.
func _abort_current_dialogue_activation() -> void:
	var activation := _current_dialogue_activation
	_current_dialogue_activation = null
	if activation != null:
		activation.abort()


## Compatibility for tests/extensions that called the old presenter callback
## directly. Runtime delivery always enters through dialogue_requested.
func _on_show_dialogue(character: String, segments: Array, mode: String) -> void:
	_on_dialogue_requested(DialogueRequest.new(character, segments, mode))


func _accept_dialogue_request(request: Dictionary) -> void:
	var revision := int(request.get("boundary_revision", -1))
	if revision != _boundary_revision:
		_abort_dialogue_request(request)
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
	elif not _dialogue_request_is_owned(request):
		_abort_dialogue_request(request)
	if _boundary_operation_depth == 0:
		_drain_deferred_presentation_work()


func _retire_dialogue_for_replacement() -> bool:
	var owner_gen := _dialogue_gen
	var queue_gen := _playback_queue_gen
	_abort_current_dialogue_activation()
	if owner_gen != _dialogue_gen or queue_gen != _playback_queue_gen:
		return false
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
	_capture_request_identity(request)
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
	# Settings changes may arrive while this coroutine is active. Snapshot both
	# delays at the active SHOW boundary so the whole line has one deterministic
	# timing policy; a later line observes the updated caches.
	_reconcile_typewriter_settings_cache()
	var line_character_interval := _snapshot_typewriter_delay_seconds(
		"character_interval", _char_interval)
	var line_punctuation_pause := _snapshot_typewriter_delay_seconds(
		"punctuation_pause", _punctuation_pause)
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
	var gen := _publish_next_dialogue_generation()
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
	var first_voice_selection := _voice_layers_for_segment(segments[0], false)
	var first_layers: Array = first_voice_selection.get("request_layers", [])
	_current_voice = (
		String(first_layers[0].get("asset", ""))
		if not first_layers.is_empty()
		else "")

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
	_update_dialogue_visibility_node_baseline(name_label)
	_update_dialogue_visibility_node_baseline(text_label)
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
	if not await _await_owned_next_frame(gen, _NEXT_FRAME_PURPOSE_SHOW):
		return
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
	var parsed_text_snapshot := text_label.get_parsed_text()
	var current_char_interval := line_character_interval
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
							if not await _await_dialogue_timer(
								wait_seconds, gen, _TIMER_PURPOSE_TYPEWRITER):
								return
					elif effect["type"] == "speed":
						current_char_interval = effect["value"] / 1000.0
			if not _is_typing:
				break
			var expr = timeline.get_expression_at_char(authored_index)
			if expr != "" and character != "":
				_set_avatar_expression(character, expr)

		text_label.visible_characters = start_visible + i + 1

		var parsed_index: int = int(start_visible) + i
		var revealed_character: String = (
			parsed_text_snapshot.substr(parsed_index, 1)
			if parsed_index < parsed_text_snapshot.length()
			else ""
		)
		var character_delay: float = _typewriter_character_delay_seconds(
			revealed_character,
			current_char_interval,
			line_punctuation_pause,
		)
		if character_delay > 0.0:
			if not await _await_dialogue_timer(
				character_delay, gen, _TIMER_PURPOSE_TYPEWRITER):
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
				if not await _await_dialogue_timer(
					effect["value"] / 1000.0,
					gen,
					_TIMER_PURPOSE_TYPEWRITER,
				):
					return

	# Public playback facades can activate skip during the final character's
	# timer, after the loop's last leading check. Observe that transition before
	# natural completion makes this unread line ready.
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
	_mark_dialogue_ready_for_indicator(gen)

	# Auto-play: wait for the voice queue to drain all segments, then advance.
	# Click/keyboard completion calls the same tail with its replacement gen.
	if StellaRuntime.is_auto_play_effective():
		await _continue_auto_play_after_ready(gen)


func _continue_auto_play_after_ready(gen: int) -> void:
	if (
		gen != _dialogue_gen
		or not StellaRuntime.is_auto_play_effective()
		or StellaRuntime.is_choice_active()
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
	if not await _await_dialogue_timer(
		auto_play_delay, gen, _TIMER_PURPOSE_AUTO, attempt):
		return
	if (
		gen != _dialogue_gen
		or _auto_pending_dialogue_gen != gen
		or _auto_pending_attempt != attempt
		or not StellaRuntime.game_state.is_playing()
	):
		return
	_auto_pending_dialogue_gen = -1
	_auto_pending_attempt = -1
	if StellaRuntime.is_auto_play_effective() \
		and not StellaRuntime.is_choice_active() \
		and StellaRuntime.game_state.is_playing():
		request_current_dialogue_advance()


func _wait_for_active_voice_finished(gen: int, attempt: int) -> bool:
	var expected_token := _active_voice_token
	while _voice_playing:
		var waiter := await _await_owned_voice_event(
			gen, _VOICE_EVENT_PURPOSE_AUTO, attempt)
		if waiter == null or waiter.cancelled:
			return false
		var event: VoicePlaybackEvent = waiter.event
		if (
			gen != _dialogue_gen
			or _auto_pending_dialogue_gen != gen
			or _auto_pending_attempt != attempt
			or not StellaRuntime.game_state.is_playing()
		):
			return false
		if (
			event != null
			and event.get_kind() == VoicePlaybackEvent.Kind.FINISHED
			and event.get_playback_token() >= 0
			and event.get_playback_token() == expected_token
			and event.is_current()
		):
			return true
	return true


func _retire_auto_play_attempt() -> void:
	var retiring_gen := _auto_pending_dialogue_gen
	var retiring_attempt := _auto_pending_attempt
	_auto_attempt_serial += 1
	_auto_pending_dialogue_gen = -1
	_auto_pending_attempt = -1
	if retiring_gen >= 0 and retiring_attempt >= 0:
		_cancel_dialogue_timer_waiters(
			retiring_gen, _TIMER_PURPOSE_AUTO, retiring_attempt)
		_cancel_voice_event_waiters(
			retiring_gen,
			_VOICE_EVENT_PURPOSE_AUTO,
			retiring_attempt,
		)


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


func _on_dialogue_advance_committed(activation_id: int) -> void:
	if (
		_current_dialogue_activation != null
		and _current_dialogue_activation.get_instance_id() == activation_id
	):
		_current_dialogue_activation = null
		_finalize_current_dialogue_for_advance()
		return
	# A synchronous headless consumer may commit while this Presenter has the
	# matching SHOW parked behind another presentation dispatch. Remove only that
	# retired request; it must never render later or affect the active owner.
	for index in range(_queued_dialogue_requests.size()):
		var queued: Dictionary = _queued_dialogue_requests[index]
		var activation := queued.get("activation") as DialogueActivation
		if activation != null and activation.get_instance_id() == activation_id:
			_queued_dialogue_requests.remove_at(index)
			return


func _on_advance_dispatch_started(_serial: int) -> void:
	# This path is only for a direct legacy advance_requested emission. Canonical
	# dialogue commits use the owner-scoped callback above and suppress this echo.
	_finalize_current_dialogue_for_advance()


func _finalize_current_dialogue_for_advance() -> void:
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
			if StellaRuntime.is_auto_play_effective():
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
	_publish_next_dialogue_generation()
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
				await _owned_stage_operation_finished
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
		var voice_selection := _voice_layers_for_segment(seg)
		if not bool(voice_selection.get("valid", false)):
			_retire_voice_queue_if_current(queue_gen)
			return
		var request_layers: Array = voice_selection.get("request_layers", [])
		var should_request_voice := (
			not request_layers.is_empty() and not _should_skip_current())
		previous_voice_token = -1
		previous_completion_state = null
		_playback_voice_token = -1
		if should_request_voice:
			_current_voice = String(request_layers[0].get("asset", ""))
			var voice_response := SignalBus.request_voice_layers(
				request_layers, owner_validator)
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


func _voice_layers_for_segment(
	segment: Variant,
	report_error: bool = true,
) -> Dictionary:
	if not segment is Dictionary:
		if report_error:
			push_error("DialoguePresenter: voice segment must be a Dictionary")
		return {"valid": false}
	var segment_dictionary: Dictionary = segment
	if not segment_dictionary.has("voice_layers"):
		if report_error:
			push_error("DialoguePresenter: voice segment requires canonical voice_layers")
		return {"valid": false}
	var layers_value: Variant = segment_dictionary["voice_layers"]
	if not layers_value is Array:
		if report_error:
			push_error("DialoguePresenter: voice_layers must be an Array")
		return {"valid": false}
	var source_path := ""
	var scenario_id := ""
	var context: ScenarioContext = (
		StellaRuntime.engine.context if StellaRuntime.engine != null else null)
	if context != null and context.scenario_data != null:
		source_path = context.scenario_data.source_path
		scenario_id = context.scenario_data.id
	var request_layers: Array = []
	var segment_layers: Array = []
	if (layers_value as Array).is_empty():
		return {
			"valid": true,
			"segment_layers": [],
			"request_layers": [],
		}
	for layer_value: Variant in layers_value:
		if not layer_value is Dictionary:
			if report_error:
				push_error("DialoguePresenter: voice layer must be a Dictionary")
			return {"valid": false}
		var layer: Dictionary = layer_value
		var expected_keys := ["id", "asset", "character", "dsp", "line"]
		for key_value: Variant in layer.keys():
			if not String(key_value) in expected_keys:
				if report_error:
					push_error(
						"DialoguePresenter: voice layer has unknown field '%s'"
							% String(key_value))
				return {"valid": false}
		for required_key in expected_keys:
			if not layer.has(required_key):
				if report_error:
					push_error(
						"DialoguePresenter: voice layer is missing '%s'" % required_key)
				return {"valid": false}
		if not layer["line"] is int or int(layer["line"]) < 0:
			if report_error:
				push_error("DialoguePresenter: voice layer source line is invalid")
			return {"valid": false}
		segment_layers.append(layer.duplicate(true))
		request_layers.append({
			"id": layer["id"],
			"asset": layer["asset"],
			"character": layer["character"],
			"dsp": layer["dsp"],
			"source": {
				"source_path": source_path,
				"scenario_id": scenario_id,
				"line": int(layer["line"]),
			},
		})
	var canonical := VoicePlaybackRequest.canonicalize_layers(request_layers)
	if not String(canonical.get("error", "")).is_empty():
		if report_error:
			var source_line := (
				int(segment_layers[0].get("line", 0))
				if not segment_layers.is_empty()
				else 0)
			var location := source_path if not source_path.is_empty() else "<runtime>"
			if source_line > 0:
				location = "%s:%d" % [location, source_line]
			push_error(
				"DialoguePresenter: invalid voice_layers at %s: %s"
					% [location, String(canonical.get("error", ""))])
		return {"valid": false}
	return {
		"valid": true,
		"segment_layers": segment_layers,
		"request_layers": canonical.get("layers", []),
	}


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
	var presentation_ops = segment.get("presentation_ops", [])
	var request_id := 0
	if presentation_ops is Array and not presentation_ops.is_empty():
		var director: PresentationDirector = StellaRuntime.presentation_director
		if director == null:
			push_error(
				"DialoguePresenter: segment presentation cue requires the Runtime Director")
			return 0
		var reservation := director.reserve_request()
		if reservation == null:
			push_error(
				"DialoguePresenter: segment presentation request could not be reserved")
			return 0
		request_id = reservation.get_request_id()
		_stage_operation_request_owners[request_id] = {
			"dialogue_gen": dispatch_gen,
			"finalization": _finalization_in_progress,
			"queue_gen": queue_gen,
			"segment_index": segment_index,
			"segment_count": segment_count,
			"dispatch_active": false,
			"await_result": queue_gen >= 0,
		}
		var abandon_reservation := func() -> void:
			director.abandon_request_reservation(reservation)
			_on_stage_operation_request_finished(request_id, false)
		var operation_lines_value: Variant = segment.get(
			"presentation_operation_lines")
		if (
			not operation_lines_value is Array
			or (operation_lines_value as Array).size() != presentation_ops.size()
		):
			push_error(
				"DialoguePresenter: segment presentation source-line sidecar is malformed")
			abandon_reservation.call()
			return request_id
		var context: ScenarioContext = (
			StellaRuntime.engine.context if StellaRuntime.engine != null else null)
		var source_path := ""
		var scenario_id := ""
		if context != null and context.scenario_data != null:
			source_path = context.scenario_data.source_path
			scenario_id = context.scenario_data.id
		var typed_operations: Array[PresentationOperation] = []
		var avatar_simulated := (
			StellaRuntime.presentation_state.dialogue_avatar.duplicate(true))
		for operation_index in range(presentation_ops.size()):
			var line_value: Variant = (operation_lines_value as Array)[operation_index]
			if not line_value is int or int(line_value) <= 0:
				push_error(
					"DialoguePresenter: segment presentation source line is malformed")
				abandon_reservation.call()
				return request_id
			var operation_value: Variant = presentation_ops[operation_index]
			if not operation_value is Dictionary:
				push_error(
					"DialoguePresenter: segment presentation operation is malformed")
				abandon_reservation.call()
				return request_id
			var envelope: Dictionary = operation_value
			var envelope_keys := envelope.keys()
			envelope_keys.sort()
			if envelope_keys != ["kind", "payload"] or not envelope["payload"] is Dictionary:
				push_error(
					"DialoguePresenter: segment presentation envelope is malformed")
				abandon_reservation.call()
				return request_id
			var operation_source := {
				"source_path": source_path,
				"scenario_id": scenario_id,
				"line": int(line_value),
			}
			var payload: Dictionary = (envelope["payload"] as Dictionary).duplicate(true)
			match String(envelope["kind"]):
				"stage":
					typed_operations.append(StagePresentationOperation.new(
						payload, operation_source))
				"dialogue_avatar":
					if not DialogueAvatarState.operation_is_supported(
						avatar_simulated, payload):
						push_error(
							"DialoguePresenter: segment dialogue avatar action is invalid for current state")
						abandon_reservation.call()
						return request_id
					typed_operations.append(DialogueAvatarPresentationOperation.new(
						payload,
						avatar_simulated,
						DialogueAvatarState.reduce(
							avatar_simulated, [payload], false),
						operation_source,
					))
					avatar_simulated = DialogueAvatarState.reduce(
						avatar_simulated, [payload], false)
				_:
					push_error(
						"DialoguePresenter: segment presentation kind is unsupported")
					abandon_reservation.call()
					return request_id
		if (
			context == null
			or not context.is_runtime_owner_current()
		):
			push_error(
				"DialoguePresenter: segment presentation cue requires the current Runtime Director")
			abandon_reservation.call()
			return request_id
		var source := typed_operations[0].get_source()
		var typed_request := director.submit(
			typed_operations,
			PresentationBatchRequest.Policy.FIRE_AND_FORGET,
			context,
			source,
			force_cut,
			reservation,
			_on_owned_stage_operation_dispatch.bind(request_id),
		)
		if (
			typed_request.is_settled()
			and _stage_operation_request_owners.has(request_id)
		):
			_on_stage_operation_request_finished(
				request_id,
				typed_request.get_outcome()
					== PresentationBatchRequest.Outcome.COMPLETED,
			)
	elif presentation_ops is Array:
		_mark_segment_presentation_dispatched(segment_index, segment_count)
	else:
		push_warning("DialoguePresenter: segment presentation_ops must be an Array")
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
	if (
		int((owner as Dictionary).get("dialogue_gen", -1)) == _dialogue_gen
		and bool((owner as Dictionary).get("await_result", false))
	):
		_stage_operation_request_results[request_id] = delivered
	_owned_stage_operation_finished.emit(request_id, delivered)
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
	var replacement_gen := _publish_next_dialogue_generation()
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
		var request_id := int(raw_request_id)
		if not SignalBus.cancel_presentation_operation_request(request_id):
			SignalBus.cancel_stage_operation_request(request_id)


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
	var remaining_presentation_ops: Array = []
	var remaining_presentation_operation_lines: Array = []
	for index in range(segments.size()):
		var segment = segments[index]
		if not segment is Dictionary:
			continue
		var segment_presentation_ops = segment.get("presentation_ops", [])
		var segment_presentation_lines = segment.get(
			"presentation_operation_lines", [])
		if (
			index >= _next_stage_segment_index
			and segment_presentation_ops is Array
		):
			remaining_presentation_ops.append_array(
				segment_presentation_ops.duplicate(true))
			if segment_presentation_lines is Array:
				remaining_presentation_operation_lines.append_array(
					segment_presentation_lines.duplicate())

	# Commit the logical finalization before emitting either operation batch.
	# Synchronous callbacks now observe a completed cursor and an empty shared
	# transition ledger; the guard above prevents recursive finalization.
	_finalization_transition_records = _stage_transition_records.duplicate(true)
	_next_stage_segment_index = segments.size()
	_stage_transition_records.clear()
	_cancel_pending_stage_operation_requests()
	_segment_presentation_complete = true

	_apply_segment_presentation({
		"presentation_ops": remaining_presentation_ops,
		"presentation_operation_lines": remaining_presentation_operation_lines,
	}, force_cut)
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
		var waiter := await _await_owned_voice_event(
			owner_gen, _VOICE_EVENT_PURPOSE_QUEUE, -1, queue_gen)
		if waiter == null or waiter.cancelled:
			return false
		var event: VoicePlaybackEvent = waiter.event
		if not _voice_queue_is_current(owner_gen, queue_gen):
			return false
		if (
			event != null
			and event.get_kind() == VoicePlaybackEvent.Kind.FINISHED
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
	# Only waiters that existed at callback entry may observe this event. A
	# continuation resumed by nested delivery can register its next wait without
	# the outer callback consuming that new authority.
	var entry_waiter_ids: Array = _voice_event_waiters.keys()
	if event != null and event.is_current():
		match event.get_kind():
			VoicePlaybackEvent.Kind.STARTED:
				if not (
					event.get_playback_token() < 0
					and _active_voice_token >= 0
				):
					_active_voice_token = event.get_playback_token()
					_voice_playing = true
				if event.get_playback_token() >= 0:
					_voice_layer_progress[event.get_layer_id()] = {
						"position": 0.0,
						"duration": 0.0,
					}
			VoicePlaybackEvent.Kind.PROGRESS:
				if not (
					event.get_playback_token() < 0
					and _playback_voice_token >= 0
				):
					_voice_layer_progress[event.get_layer_id()] = {
						"position": event.get_position(),
						"duration": event.get_duration(),
					}
					var group_position := 0.0
					var group_duration := 0.0
					for progress_value: Variant in _voice_layer_progress.values():
						if progress_value is Dictionary:
							group_position = maxf(group_position, float(
								(progress_value as Dictionary).get("position", 0.0)))
							group_duration = maxf(group_duration, float(
								(progress_value as Dictionary).get("duration", 0.0)))
					_relay_voice_progress(
						group_position, group_duration, event.get_playback_token())
			VoicePlaybackEvent.Kind.FINISHED:
				_on_voice_playback_finished(event.get_playback_token())
			VoicePlaybackEvent.Kind.LAYER_FINISHED:
				pass
	_settle_voice_event_entry_snapshot(entry_waiter_ids, event)


func _on_voice_playback_finished(playback_token: int) -> void:
	if playback_token < 0 and _active_voice_token >= 0:
		return
	if playback_token >= 0 and playback_token != _active_voice_token:
		return
	_active_voice_token = -1
	_voice_playing = false
	_voice_layer_progress.clear()
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
	var mode_profile := stla_mode_profile
	if mode_profile == null and presentation_profile != null:
		mode_profile = presentation_profile.get_mode(mode)
	var profile_is_valid := mode_profile != null
	if mode_profile != null:
		var errors := mode_profile.validation_errors()
		profile_is_valid = errors.is_empty()
		for error in errors:
			_profile_warning(mode, String(error))
	var binding := _dialogue_visibility_binding_for_profile(
		mode_profile if profile_is_valid else null)
	var signatures := _dialogue_visibility_signatures(
		mode, mode_profile if profile_is_valid else null, binding)
	var affected_targets := _dialogue_visibility_changed_targets(signatures)
	var preserved_work := _preserve_dialogue_visibility_work(affected_targets)
	_retire_dialogue_visibility_targets(affected_targets, &"superseded")
	_restore_authored_presentation(false)
	var uses_profile := profile_is_valid
	if profile_is_valid:
		_apply_mode_profile(mode, mode_profile, false)
	elif mode != "adv" or (
		not uses_stla_presentation
		and stla_mode_profile == null
		and presentation_profile == null
	):
		_apply_legacy_mode_layout(mode)
		uses_profile = false
	_resolve_dialogue_visibility_binding(binding, false)
	_capture_dialogue_visibility_profile_baseline()
	_dialogue_visibility_effective_signatures = signatures.duplicate(true)
	_apply_canonical_dialogue_visibility()
	_restore_preserved_dialogue_visibility_work(preserved_work)
	return uses_profile or (
		mode == "adv"
		and (uses_stla_presentation or presentation_profile != null)
	)


func _resolve_nvl_entry_format() -> Dictionary:
	return _resolve_nvl_entry_format_for_profile(_active_stla_mode_profile)


func _dialogue_visibility_binding_for_profile(
	profile: DialogueModeProfile,
) -> Dictionary:
	var defaults := (
		_dialogue_visibility_runtime_binding.get("default", {
			"surface_groups": ["dialogue_surface"],
			"quick_menu_groups": ["quick_menu"],
		}) as Dictionary
	).duplicate(true)
	var current: Dictionary = {}
	if profile != null:
		var provenance := profile.get("_stla_provenance") as Dictionary
		current = (
			_dialogue_visibility_runtime_binding.get("current", {}) as Dictionary
		).duplicate(true)
		var previous_profile_name := String(current.get("profile_name", ""))
		current["profile_name"] = String(provenance.get("profile_name", ""))
		if (
			not current.get("profile", null) is Dictionary
			or previous_profile_name
				!= String(provenance.get("profile_name", ""))
		):
			current["profile"] = {}
		current["provenance"] = provenance.duplicate(true)
		current["surface_groups"] = profile.surface_groups.duplicate()
		current["quick_menu_groups"] = profile.quick_menu_groups.duplicate()
	else:
		current = {
			"profile_name": "",
			"profile": {},
			"provenance": {},
			"surface_groups": (defaults.get("surface_groups", []) as Array).duplicate(),
			"quick_menu_groups": (defaults.get("quick_menu_groups", []) as Array).duplicate(),
		}
	var binding := _dialogue_visibility_runtime_binding.duplicate(true)
	binding["current"] = current
	binding["default"] = defaults
	return binding


func _dialogue_visibility_signatures(
	mode: String,
	profile: DialogueModeProfile,
	binding: Dictionary,
) -> Dictionary:
	return {
		"surface": _dialogue_visibility_target_signature(
			mode, profile, binding, "surface"),
		"quick_menu": _dialogue_visibility_target_signature(
			mode, profile, binding, "quick_menu"),
	}


func _dialogue_visibility_target_signature(
	mode: String,
	profile: DialogueModeProfile,
	binding: Dictionary,
	target: String,
) -> String:
	var current := binding.get("current", {}) as Dictionary
	var provenance := current.get("provenance", {}) as Dictionary
	var field_name := "%s_groups" % target
	var target_groups := _normalized_group_signature(
		current.get(field_name, []))
	var provenance_lines: Array[String] = []
	var raw_field_lines := provenance.get("field_lines", {}) as Dictionary
	for relevant_field: String in [field_name, "visibility_groups"]:
		if not raw_field_lines.has(relevant_field):
			continue
		provenance_lines.append(
			"%s=%d" % [relevant_field, int(raw_field_lines[relevant_field])])
	var visibility_groups: Array[String] = []
	if profile != null:
		var target_nodes := _binding_nodes_for_groups(target_groups)
		var target_ids: Dictionary = {}
		for node: CanvasItem in target_nodes:
			target_ids[node.get_instance_id()] = true
		var visibility_names: Array = profile.visibility_groups.keys()
		visibility_names.sort()
		for group_value: Variant in visibility_names:
			var group_name := String(group_value)
			var affects_target := false
			for node: CanvasItem in _find_auxiliary_group_nodes(StringName(group_name)):
				if target_ids.has(node.get_instance_id()):
					affects_target = true
					break
			if not affects_target:
				continue
			visibility_groups.append(
				"%s=%s" % [group_name, bool(profile.visibility_groups[group_value])])
	return JSON.stringify({
		"mode": mode,
		"profile_name": String(current.get("profile_name", "")),
		"source_path": String(provenance.get("source_path", "")),
		"field_lines": provenance_lines,
		"target": target,
		"groups": target_groups,
		"visibility_groups": visibility_groups,
	})


func _normalized_group_signature(raw_groups: Variant) -> Array[String]:
	var groups: Array[String] = []
	if raw_groups is Array:
		for group_value: Variant in raw_groups:
			var group_name := String(group_value).strip_edges()
			if not group_name.is_empty() and group_name not in groups:
				groups.append(group_name)
	groups.sort()
	return groups


func _dialogue_visibility_changed_targets(signatures: Dictionary) -> Array[String]:
	var changed: Array[String] = []
	for target: String in ["surface", "quick_menu"]:
		if String(signatures.get(target, "")) != String(
			_dialogue_visibility_effective_signatures.get(target, "")):
			changed.append(target)
	return changed


func _dialogue_visibility_profile_from_binding(
	binding: Dictionary,
) -> DialogueModeProfile:
	var current := binding.get("current", {}) as Dictionary
	var profile_value: Variant = current.get("profile", {})
	if profile_value is DialogueModeProfile:
		return profile_value as DialogueModeProfile
	if profile_value is Dictionary and not (profile_value as Dictionary).is_empty():
		return DialogueModeProfile.from_dictionary(
			profile_value as Dictionary,
			current.get("provenance", {}) as Dictionary,
		)
	return null


func _retire_dialogue_visibility_targets(
	targets: Array[String],
	outcome: StringName,
) -> void:
	for target: String in targets:
		_retire_dialogue_visibility_target(target, outcome)


func _preserve_dialogue_visibility_work(
	affected_targets: Array[String],
) -> Dictionary:
	var preserved: Dictionary = {}
	for target: String in ["surface", "quick_menu"]:
		if target in affected_targets or not _dialogue_visibility_active.has(target):
			continue
		var baseline: Dictionary = {}
		var visuals: Array[Dictionary] = []
		for node_value: Variant in _dialogue_visibility_nodes.get(target, []):
			var node: CanvasItem = node_value
			if not is_instance_valid(node):
				continue
			var instance_id := node.get_instance_id()
			if _dialogue_visibility_profile_baseline.has(instance_id):
				baseline[instance_id] = (
					_dialogue_visibility_profile_baseline[instance_id] as Dictionary
				).duplicate()
			visuals.append({
				"node": node,
				"visible": node.visible,
				"modulate": node.modulate,
			})
		preserved[target] = {"baseline": baseline, "visuals": visuals}
	return preserved


func _restore_preserved_dialogue_visibility_work(preserved: Dictionary) -> void:
	for target_value: Variant in preserved:
		var entry: Dictionary = preserved[target_value]
		for baseline_key: Variant in (entry.get("baseline", {}) as Dictionary):
			_dialogue_visibility_profile_baseline[baseline_key] = (
				entry["baseline"][baseline_key] as Dictionary
			).duplicate()
		for visual_value: Variant in entry.get("visuals", []):
			var visual: Dictionary = visual_value
			var node := visual.get("node") as CanvasItem
			if not is_instance_valid(node):
				continue
			node.visible = bool(visual.get("visible", true))
			node.modulate = visual.get("modulate", node.modulate)


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


func _apply_mode_profile(
	mode: String,
	profile: DialogueModeProfile,
	commit_visibility: bool = true,
) -> void:
	var direct_binding: Dictionary = {}
	var direct_signatures: Dictionary = {}
	var direct_preserved: Dictionary = {}
	if commit_visibility:
		direct_binding = _dialogue_visibility_binding_for_profile(profile)
		direct_signatures = _dialogue_visibility_signatures(
			mode, profile, direct_binding)
		var affected_targets := _dialogue_visibility_changed_targets(
			direct_signatures)
		direct_preserved = _preserve_dialogue_visibility_work(affected_targets)
		_retire_dialogue_visibility_targets(affected_targets, &"superseded")
		_restore_authored_presentation(false)
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
	if commit_visibility:
		_resolve_dialogue_visibility_binding(direct_binding, false)
		_capture_dialogue_visibility_profile_baseline()
		_dialogue_visibility_effective_signatures = direct_signatures.duplicate(true)
		_apply_canonical_dialogue_visibility()
		_restore_preserved_dialogue_visibility_work(direct_preserved)


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


func _restore_authored_presentation(apply_canonical_gate: bool = true) -> void:
	_restore_dialogue_visibility_profile_baseline()
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
	if apply_canonical_gate:
		_apply_canonical_dialogue_visibility()


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


func _capture_dialogue_visibility_nodes() -> void:
	_dialogue_visibility_nodes = {
		"surface": [],
		"quick_menu": [],
	}
	_resolve_dialogue_visibility_binding({})


func _restore_dialogue_visibility_profile_baseline() -> void:
	for entry_value: Variant in _dialogue_visibility_profile_baseline.values():
		var entry: Dictionary = entry_value
		var node: CanvasItem = entry.get("node")
		if not is_instance_valid(node):
			continue
		node.visible = bool(entry.get("visible", true))
		var restored_modulate := node.modulate
		restored_modulate.a = float(entry.get("alpha", restored_modulate.a))
		node.modulate = restored_modulate
	_dialogue_visibility_profile_baseline.clear()


func _capture_dialogue_visibility_profile_baseline() -> void:
	_dialogue_visibility_profile_baseline.clear()
	for target: String in _dialogue_visibility_nodes:
		for node_value: Variant in _dialogue_visibility_nodes.get(target, []):
			var node: CanvasItem = node_value
			if not is_instance_valid(node):
				continue
			_dialogue_visibility_profile_baseline[node.get_instance_id()] = {
				"node": node,
				"visible": node.visible,
				"alpha": node.modulate.a,
			}


func _update_dialogue_visibility_node_baseline(node: CanvasItem) -> void:
	if node == null or not is_instance_valid(node):
		return
	for target: String in _dialogue_visibility_nodes:
		if node not in (_dialogue_visibility_nodes.get(target, []) as Array):
			continue
		_dialogue_visibility_profile_baseline[node.get_instance_id()] = {
			"node": node,
			"visible": node.visible,
			"alpha": node.modulate.a,
		}
		return


func _sync_dialogue_visibility_target_baseline(target: String) -> void:
	if (
		not bool(_canonical_dialogue_visibility.get(target, true))
		or _dialogue_visibility_active.has(target)
	):
		return
	for node_value: Variant in _dialogue_visibility_nodes.get(target, []):
		var node: CanvasItem = node_value
		if is_instance_valid(node):
			_update_dialogue_visibility_node_baseline(node)


func _dialogue_visibility_fade_participants(target: String) -> Array[Dictionary]:
	var participants: Array[Dictionary] = []
	for node_value: Variant in _dialogue_visibility_nodes.get(target, []):
		var node: CanvasItem = node_value
		if not is_instance_valid(node):
			continue
		var baseline := (
			_dialogue_visibility_profile_baseline.get(
				node.get_instance_id(),
				{"visible": node.visible, "alpha": node.modulate.a},
			) as Dictionary
		)
		var baseline_alpha := float(baseline.get("alpha", node.modulate.a))
		if not bool(baseline.get("visible", true)) or is_zero_approx(baseline_alpha):
			continue
		participants.append({
			"node": node,
			"visible": true,
			"alpha": baseline_alpha,
		})
	return participants


func _apply_canonical_dialogue_visibility(active_target: String = "") -> void:
	for target: String in _canonical_dialogue_visibility.keys():
		if _dialogue_visibility_active.has(target) and target != active_target:
			continue
		for node_value: Variant in _dialogue_visibility_nodes.get(target, []):
			var node: CanvasItem = node_value
			if is_instance_valid(node):
				_capture_auxiliary_visibility(node)
				var baseline := (
					_dialogue_visibility_profile_baseline.get(
						node.get_instance_id(),
						{"visible": node.visible, "alpha": node.modulate.a}
					) as Dictionary
				)
				node.visible = (
					bool(_canonical_dialogue_visibility[target])
					and bool(baseline.get("visible", true))
				)
				var canonical_modulate := node.modulate
				canonical_modulate.a = float(baseline.get("alpha", canonical_modulate.a))
				node.modulate = canonical_modulate


func _emit_dialogue_visibility_receipt(
	target: String,
	request_id: int,
) -> Dictionary:
	_dialogue_visibility_token_serial += 1
	var generation := int(_dialogue_visibility_generation.get(target, 1))
	(SignalBus.get(&"dialogue_visibility_transition_receipt_started") as Signal).emit(
		get_instance_id(),
		target,
		_dialogue_visibility_token_serial,
		request_id,
		generation,
	)
	return {
		"target": target,
		"token": _dialogue_visibility_token_serial,
		"generation": generation,
		"operation_request_id": request_id,
	}


func _on_dialogue_visibility_operations_requested(
	operations: Array,
	force_cut: bool,
) -> void:
	var request_id := SignalBus.current_dialogue_visibility_request_id()
	if not SignalBus.is_current_dialogue_visibility_operation_valid():
		return
	var request_binding: Dictionary = {}
	for operation_value: Variant in operations:
		if (
			operation_value is PresentationOperation
			and operation_value.has_method("get_runtime_binding")
		):
			request_binding = operation_value.call("get_runtime_binding") as Dictionary
			break
	if (
		_dialogue_visibility_nodes.is_empty()
		or (
			not request_binding.is_empty()
			and request_binding != _dialogue_visibility_runtime_binding
		)
	):
		if _dialogue_visibility_nodes.is_empty():
			_resolve_dialogue_visibility_binding(request_binding)
		elif not request_binding.is_empty():
			var incoming_profile := _dialogue_visibility_profile_from_binding(
				request_binding)
			var incoming_signatures := _dialogue_visibility_signatures(
				_current_mode, incoming_profile, request_binding)
			var affected_targets := _dialogue_visibility_changed_targets(
				incoming_signatures)
			if affected_targets.is_empty():
				_dialogue_visibility_runtime_binding = request_binding.duplicate(true)
			else:
				var preserved_work := _preserve_dialogue_visibility_work(
					affected_targets)
				_retire_dialogue_visibility_targets(
					affected_targets, &"superseded")
				_restore_authored_presentation(false)
				var incoming_profile_valid := incoming_profile != null
				if incoming_profile != null:
					var incoming_errors := incoming_profile.validation_errors()
					incoming_profile_valid = incoming_errors.is_empty()
					for error_value: Variant in incoming_errors:
						_profile_warning(_current_mode, String(error_value))
				if incoming_profile_valid:
					_apply_mode_profile(_current_mode, incoming_profile, false)
				else:
					_apply_legacy_mode_layout(_current_mode)
				_resolve_dialogue_visibility_binding(request_binding, false)
				_capture_dialogue_visibility_profile_baseline()
				_dialogue_visibility_effective_signatures = (
					incoming_signatures.duplicate(true))
				_apply_canonical_dialogue_visibility()
				_restore_preserved_dialogue_visibility_work(preserved_work)
	for operation_value: Variant in operations:
		var payload: Dictionary = {}
		if operation_value is PresentationOperation:
			payload = (operation_value as PresentationOperation).get_payload()
		elif operation_value is Dictionary:
			payload = (operation_value as Dictionary).duplicate(true)
		var target := String(payload.get("target", "")).strip_edges()
		if target not in ["surface", "quick_menu"]:
			continue
		_retire_dialogue_visibility_target(target, &"superseded")
		_sync_dialogue_visibility_target_baseline(target)
		_dialogue_visibility_generation[target] = int(
			_dialogue_visibility_generation.get(target, 1)
		) + 1
		var target_visible := String(payload.get("action", "show")) == "show"
		if force_cut or (
			String(payload.get("transition", "cut")) == "cut"
			and float(payload.get("duration", 0.0)) <= 0.0
		):
			_canonical_dialogue_visibility[target] = target_visible
			_apply_canonical_dialogue_visibility(target)
			continue
		var node_states := _dialogue_visibility_fade_participants(target)
		if node_states.is_empty():
			_canonical_dialogue_visibility[target] = target_visible
			_apply_canonical_dialogue_visibility(target)
			continue
		var identity := _emit_dialogue_visibility_receipt(target, request_id)
		var tween := create_tween()
		tween.set_parallel(true)
		identity["tween"] = tween
		identity["nodes"] = node_states
		identity["target_visible"] = target_visible
		_dialogue_visibility_active[target] = identity
		_canonical_dialogue_visibility[target] = target_visible
		if target_visible:
			_apply_canonical_dialogue_visibility(target)
			for state: Dictionary in node_states:
				var node: CanvasItem = state["node"]
				if not is_instance_valid(node) or not bool(state["visible"]):
					continue
				var transparent := node.modulate
				transparent.a = 0.0
				node.modulate = transparent
				tween.tween_property(node, "modulate:a", float(state["alpha"]), float(payload["duration"]))
		else:
			for state: Dictionary in node_states:
				var node: CanvasItem = state["node"]
				if not is_instance_valid(node):
					continue
				node.visible = bool(state["visible"])
				var baseline_modulate := node.modulate
				baseline_modulate.a = float(state["alpha"])
				node.modulate = baseline_modulate
				tween.tween_property(node, "modulate:a", 0.0, float(payload["duration"]))
		var terminal_identity := identity.duplicate()
		var on_finished := func() -> void:
			_complete_dialogue_visibility_target(
				String(terminal_identity.get("target", "")), terminal_identity)
		tween.finished.connect(on_finished, CONNECT_ONE_SHOT)


func _on_dialogue_clear_validate_requested(
	request: DialogueClearOperationRequest,
) -> void:
	if request == null or not request.is_target(self):
		return
	var operation := request.get_operation()
	if (
		operation == null
		or operation.get_payload() != {"scope": "page"}
		or not PresentationState._validate_dialogue_content(
			operation.get_target_content(), false)
		or not bool(operation.get_target_content().get("cleared", false))
	):
		SignalBus.reject_dialogue_clear_request(
			request,
			self,
			_dialogue_clear_participant_capability,
			"DialoguePresenter received a non-canonical clear operation",
		)
		return
	SignalBus.validate_dialogue_clear_request(
		request, self, _dialogue_clear_participant_capability)


func _on_dialogue_clear_accept_requested(
	request: DialogueClearOperationRequest,
) -> void:
	if request == null or not request.is_target(self):
		return
	SignalBus.accept_dialogue_clear_request(
		request, self, _dialogue_clear_participant_capability)


func _on_dialogue_clear_apply_requested(
	request: DialogueClearOperationRequest,
) -> void:
	if request == null or not request.is_target(self):
		return
	var operation := request.get_operation()
	if operation == null or not _apply_dialogue_clear(operation):
		return
	SignalBus.acknowledge_dialogue_clear_apply(
		request, self, _dialogue_clear_participant_capability)


func _on_dialogue_avatar_validate_requested(
	request: DialogueAvatarOperationRequest,
) -> void:
	if request == null or not request.is_target(self):
		return
	var operation := request.get_operation()
	if (
		operation == null
		or operation.get_channel() != &"dialogue:avatar"
		or not DialogueAvatarState.validate_operation(
			operation.get_payload(), false)
		or (
			request.get_chain_index() == 0
			and operation.get_before_state() != _addressable_avatar_state
		)
		or operation.get_target_state() != request.get_target_state()
		or not DialogueAvatarState.validate_snapshot_state(
			request.get_target_state(), false)
		or _avatar_container == null
		or _addressable_avatar_sprite == null
		or not is_instance_valid(_addressable_avatar_sprite)
	):
		SignalBus.reject_dialogue_avatar_request(
			request,
			self,
			_dialogue_avatar_participant_capability,
			"DialoguePresenter avatar binding or canonical before-state is invalid",
		)
		return
	var target := request.get_target_state()
	var texture: Texture2D
	if bool(target.get("present", false)):
		texture = _resolve_addressable_avatar_texture(target)
		if texture == null:
			SignalBus.reject_dialogue_avatar_request(
				request,
				self,
				_dialogue_avatar_participant_capability,
				"avatar asset could not be resolved as Texture2D",
			)
			return
	var plan_id := request.get_instance_id()
	_dialogue_avatar_request_plans[plan_id] = {
		"request": weakref(request),
		"target": target.duplicate(true),
		"texture": texture,
	}
	request.settled.connect(
		func(_success: bool, _cancelled: bool) -> void:
			_dialogue_avatar_request_plans.erase(plan_id),
		CONNECT_ONE_SHOT,
	)
	SignalBus.validate_dialogue_avatar_request(
		request, self, _dialogue_avatar_participant_capability)


func _on_dialogue_avatar_accept_requested(
	request: DialogueAvatarOperationRequest,
) -> void:
	if request == null or not request.is_target(self):
		return
	if not _dialogue_avatar_request_plans.has(request.get_instance_id()):
		return
	SignalBus.accept_dialogue_avatar_request(
		request, self, _dialogue_avatar_participant_capability)


func _on_dialogue_avatar_apply_readiness_requested(
	request: DialogueAvatarOperationRequest,
) -> void:
	if request == null or not request.is_target(self):
		return
	var plan: Dictionary = _dialogue_avatar_request_plans.get(
		request.get_instance_id(), {})
	if (
		plan.is_empty()
		or (plan.get("request") as WeakRef).get_ref() != request
		or plan.get("target", {}) != request.get_target_state()
		or request.get_operation().get_before_state() != _addressable_avatar_state
		or _avatar_container == null
		or _addressable_avatar_sprite == null
		or not is_instance_valid(_addressable_avatar_sprite)
		or (
			bool(request.get_target_state().get("present", false))
			and not plan.get("texture") is Texture2D
		)
	):
		return
	SignalBus.mark_dialogue_avatar_apply_ready(
		request, self, _dialogue_avatar_participant_capability)


func _on_dialogue_avatar_apply_requested(
	request: DialogueAvatarOperationRequest,
) -> void:
	if request == null or not request.is_target(self):
		return
	var plan: Dictionary = _dialogue_avatar_request_plans.get(
		request.get_instance_id(), {})
	if plan.is_empty():
		return
	# Claim the sealed private plan before mutation. Readiness already proved all
	# captured Presenter plans, so the remainder of this method is infallible.
	if not SignalBus.acknowledge_dialogue_avatar_apply(
		request, self, _dialogue_avatar_participant_capability):
		return
	var operation := request.get_operation()
	var target: Dictionary = plan["target"]
	var texture: Texture2D = plan.get("texture") as Texture2D
	var effective_cut := (
		request.get_force_cut()
		or String(operation.get_payload().get("transition", "cut")) == "cut"
		or float(operation.get_payload().get("duration", 0.0)) <= 0.0
	)
	_retire_addressable_avatar_transition(&"superseded")
	_dialogue_avatar_generation += 1
	if effective_cut:
		_apply_addressable_avatar_target(target, texture)
		return
	_start_addressable_avatar_fade(
		target,
		texture,
		float(operation.get_payload()["duration"]),
		request.get_request_id(),
	)


func _on_dialogue_avatar_visuals_reset_requested(_epoch: int) -> void:
	_retire_addressable_avatar_transition(&"cancelled")
	_dialogue_avatar_generation += 1
	_apply_addressable_avatar_target(
		DialogueAvatarState.default_state(), null)


func _on_dialogue_avatar_state_apply_requested(
	state: Dictionary,
	_epoch: int,
) -> void:
	if not DialogueAvatarState.validate_snapshot_state(state, false):
		return
	var texture: Texture2D
	if bool(state.get("present", false)):
		texture = _resolve_addressable_avatar_texture(state)
		if texture == null:
			push_error("DialoguePresenter: restored dialogue avatar asset is unavailable")
			return
	_retire_addressable_avatar_transition(&"cancelled")
	_dialogue_avatar_generation += 1
	_apply_addressable_avatar_target(state, texture)


func _on_dialogue_avatar_transition_receipts_finish_requested(
	records: Array,
) -> void:
	if _dialogue_avatar_active_receipt.is_empty():
		return
	for record_value: Variant in records:
		if not record_value is Dictionary:
			continue
		var record: Dictionary = record_value
		if (
			int(record.get("presenter_instance_id", -1)) == get_instance_id()
			and int(record.get("token", -1))
				== int(_dialogue_avatar_active_receipt.get("token", -2))
			and int(record.get("operation_request_id", -1))
				== int(_dialogue_avatar_active_receipt.get(
					"operation_request_id", -2))
			and int(record.get("generation", -1))
				== int(_dialogue_avatar_active_receipt.get("generation", -2))
		):
			_complete_addressable_avatar_transition(&"completed")
			return


func _start_addressable_avatar_fade(
	target: Dictionary,
	texture: Texture2D,
	duration: float,
	request_id: int,
) -> void:
	var before := _addressable_avatar_state.duplicate(true)
	var before_texture := _addressable_avatar_sprite.texture
	if bool(before.get("present", false)) and bool(before.get("visible", false)):
		_addressable_avatar_outgoing = Sprite2D.new()
		_addressable_avatar_outgoing.name = "AddressableAvatarOutgoing"
		_addressable_avatar_outgoing.centered = false
		_avatar_container.add_child(_addressable_avatar_outgoing)
		_configure_addressable_avatar_sprite(
			_addressable_avatar_outgoing, before, before_texture)
	var target_visible := bool(target.get("present", false)) and bool(
		target.get("visible", false))
	_apply_addressable_avatar_target(target, texture)
	if target_visible:
		var start_modulate := _addressable_avatar_sprite.modulate
		start_modulate.a = 0.0
		_addressable_avatar_sprite.modulate = start_modulate
		_addressable_avatar_sprite.visible = true
		_avatar_container.visible = true
	_dialogue_avatar_token_serial += 1
	_dialogue_avatar_active_receipt = {
		"presenter_instance_id": get_instance_id(),
		"token": _dialogue_avatar_token_serial,
		"operation_request_id": request_id,
		"generation": _dialogue_avatar_generation,
		"target": target.duplicate(true),
		"texture": texture,
	}
	_dialogue_avatar_tween = create_tween().set_parallel(true)
	if _addressable_avatar_outgoing != null:
		_dialogue_avatar_tween.tween_property(
			_addressable_avatar_outgoing, "modulate:a", 0.0, duration)
	if target_visible:
		_dialogue_avatar_tween.tween_property(
			_addressable_avatar_sprite,
			"modulate:a",
			float(target.get("opacity", 1.0)),
			duration,
		)
	var terminal_identity := _dialogue_avatar_active_receipt.duplicate(true)
	_dialogue_avatar_tween.finished.connect(func() -> void:
		if _dialogue_avatar_active_receipt == terminal_identity:
			_complete_addressable_avatar_transition(&"completed"),
		CONNECT_ONE_SHOT,
	)
	SignalBus.dialogue_avatar_transition_receipt_started.emit(
		get_instance_id(),
		_dialogue_avatar_token_serial,
		request_id,
		_dialogue_avatar_generation,
	)


func _complete_addressable_avatar_transition(outcome: StringName) -> void:
	if _dialogue_avatar_active_receipt.is_empty():
		return
	var record := _dialogue_avatar_active_receipt.duplicate(true)
	var target: Dictionary = record.get(
		"target", DialogueAvatarState.default_state())
	var texture: Texture2D = record.get("texture") as Texture2D
	if _dialogue_avatar_tween != null and _dialogue_avatar_tween.is_valid():
		_dialogue_avatar_tween.kill()
	_dialogue_avatar_tween = null
	_apply_addressable_avatar_target(target, texture)
	_free_addressable_avatar_outgoing()
	_dialogue_avatar_active_receipt.clear()
	SignalBus.dialogue_avatar_transition_terminal.emit(
		get_instance_id(),
		int(record.get("token", -1)),
		int(record.get("operation_request_id", -1)),
		int(record.get("generation", -1)),
		outcome,
	)


func _retire_addressable_avatar_transition(outcome: StringName) -> void:
	if _dialogue_avatar_active_receipt.is_empty():
		if _dialogue_avatar_tween != null and _dialogue_avatar_tween.is_valid():
			_dialogue_avatar_tween.kill()
		_dialogue_avatar_tween = null
		_free_addressable_avatar_outgoing()
		return
	_complete_addressable_avatar_transition(outcome)


func _free_addressable_avatar_outgoing() -> void:
	if (
		_addressable_avatar_outgoing != null
		and is_instance_valid(_addressable_avatar_outgoing)
	):
		_addressable_avatar_outgoing.queue_free()
	_addressable_avatar_outgoing = null


func _apply_addressable_avatar_target(
	state: Dictionary,
	texture: Texture2D,
) -> void:
	_addressable_avatar_state = state.duplicate(true)
	if _addressable_avatar_sprite == null or not is_instance_valid(
		_addressable_avatar_sprite):
		return
	_configure_addressable_avatar_sprite(
		_addressable_avatar_sprite, _addressable_avatar_state, texture)
	var owns_avatar := bool(_addressable_avatar_state.get("present", false))
	if _avatar_texture != null:
		_avatar_texture.visible = not owns_avatar
	if owns_avatar:
		_avatar_container.visible = bool(_addressable_avatar_state["visible"])
	elif not _current_character.is_empty():
		_update_avatar(
			_current_character, _current_avatar_expression, _current_mode)
	else:
		_avatar_container.visible = false
	_update_dialogue_visibility_node_baseline(_avatar_container)


func _configure_addressable_avatar_sprite(
	sprite: Sprite2D,
	state: Dictionary,
	texture: Texture2D,
) -> void:
	var present := bool(state.get("present", false))
	sprite.texture = texture if present else null
	sprite.position = _avatar_pair(state.get("position", [0.0, 0.0]))
	sprite.offset = -_avatar_pair(state.get("origin", [0.0, 0.0]))
	sprite.scale = _avatar_pair(state.get("scale", [1.0, 1.0]))
	sprite.rotation = float(state.get("rotation", 0.0))
	sprite.z_index = int(state.get("z_index", 0))
	var avatar_modulate := Color.WHITE
	avatar_modulate.a = float(state.get("opacity", 1.0))
	sprite.modulate = avatar_modulate
	sprite.visible = present and bool(state.get("visible", false))


func _resolve_addressable_avatar_texture(state: Dictionary) -> Texture2D:
	var source_kind := String(state.get("source_kind", ""))
	if source_kind == "asset":
		return _load_dialogue_avatar_texture(String(state.get("asset", "")))
	if source_kind != "character":
		return null
	var character := String(state.get("character", ""))
	var expression := String(state.get("expression", ""))
	var config := _config_loader.get_config(character)
	var asset_stem := config.resolve_avatar_asset(expression)
	var texture := _load_dialogue_avatar_texture(
		"character:%s/%s" % [character, asset_stem])
	if texture == null or not config.has_avatar_rect():
		return texture
	var atlas := AtlasTexture.new()
	atlas.atlas = texture
	atlas.region = config.avatar_rect
	return atlas


func _load_dialogue_avatar_texture(asset_id: String) -> Texture2D:
	var path := asset_id
	if asset_id.begins_with("background:"):
		path = StellaRuntime.backgrounds_path + asset_id.trim_prefix("background:")
	elif asset_id.begins_with("character:"):
		path = StellaRuntime.characters_path + asset_id.trim_prefix("character:")
	elif asset_id.begins_with("stage:"):
		path = StellaRuntime.stage_assets_path + asset_id.trim_prefix("stage:")
	elif not asset_id.begins_with("res://"):
		return null
	if ResourceLoader.exists(path):
		return ResourceLoader.load(
			path, "Texture2D", ResourceLoader.CACHE_MODE_REUSE) as Texture2D
	if not path.get_extension().is_empty():
		return null
	for extension: String in _DIALOGUE_AVATAR_TEXTURE_EXTENSIONS:
		var candidate := path + extension
		if ResourceLoader.exists(candidate):
			return ResourceLoader.load(
				candidate,
				"Texture2D",
				ResourceLoader.CACHE_MODE_REUSE,
			) as Texture2D
	return null


func _avatar_pair(value: Variant) -> Vector2:
	return Vector2(float(value[0]), float(value[1]))


func _apply_dialogue_clear(
	operation: DialogueClearPresentationOperation,
) -> bool:
	if (
		SignalBus.current_dialogue_visibility_request_id() <= 0
		or not SignalBus.is_current_dialogue_visibility_operation_valid()
	):
		return false
	var retiring_gen := _dialogue_gen
	var retiring_queue_gen := _playback_queue_gen
	if not _retire_dialogue_lifecycle(false):
		return false
	if (
		retiring_gen != _dialogue_gen
		or retiring_queue_gen + 1 != _playback_queue_gen
		or not SignalBus.is_current_dialogue_visibility_operation_valid()
	):
		return false
	_publish_next_dialogue_generation()
	_skip_pending_dialogue_gen = -1
	_retire_auto_play_attempt()
	_invalidate_advance_indicator()
	_is_typing = false
	_current_dialogue_activation = null
	_current_scenario_id = ""
	_current_scenario_identity = ""
	_current_scene_id = ""
	_current_command_index = -1
	_current_command_uid = -1
	_avatar_expressions.clear()
	_apply_visual_only_dialogue_restore(
		operation.get_target_content(), operation.get_runtime_binding(), true)
	_apply_canonical_dialogue_visibility()
	return SignalBus.is_current_dialogue_visibility_operation_valid()


func _on_dialogue_visibility_state_apply_requested(
	visibility: Dictionary,
	content: Dictionary,
	runtime_binding: Dictionary,
) -> void:
	# Save/load and rollback projection are hard generation boundaries. Wake all
	# waiters before replacing their canonical content so no stale continuation
	# can mutate the restored presentation.
	_publish_next_dialogue_generation()
	for target: String in ["surface", "quick_menu"]:
		_retire_dialogue_visibility_target(target, &"cancelled")
	_canonical_dialogue_visibility = visibility.duplicate(true)
	_dialogue_visibility_runtime_binding = runtime_binding.duplicate(true)
	_apply_visual_only_dialogue_restore(content, runtime_binding)
	_apply_canonical_dialogue_visibility()


func _on_dialogue_content_state_apply_requested(
	content: Dictionary,
	runtime_binding: Dictionary,
) -> void:
	_publish_next_dialogue_generation()
	_apply_visual_only_dialogue_restore(content, runtime_binding, true)
	_apply_canonical_dialogue_visibility()


func _on_dialogue_visibility_targets_state_apply_requested(
	visibility: Dictionary,
	targets: Array,
) -> void:
	for target_value: Variant in targets:
		var target := String(target_value).strip_edges()
		if target not in ["surface", "quick_menu"]:
			continue
		_retire_dialogue_visibility_target(target, &"cancelled")
		_canonical_dialogue_visibility[target] = bool(visibility.get(target, true))
		_apply_canonical_dialogue_visibility(target)


func _on_dialogue_visibility_visuals_reset_requested() -> void:
	for target_value: Variant in _dialogue_visibility_active.keys().duplicate():
		_retire_dialogue_visibility_target(String(target_value), &"cancelled")
	_dialogue_visibility_active.clear()
	_canonical_dialogue_visibility = {
		"surface": true,
		"quick_menu": true,
	}
	for target: String in _dialogue_visibility_generation.keys():
		_dialogue_visibility_generation[target] = int(
			_dialogue_visibility_generation.get(target, 1)
		) + 1
	_apply_canonical_dialogue_visibility()


func _on_dialogue_visibility_transition_receipts_finish_requested(
	transitions: Array,
) -> void:
	for transition_value: Variant in transitions:
		if not transition_value is Dictionary:
			continue
		var transition: Dictionary = transition_value
		var target := String(transition.get("target", "")).strip_edges()
		if not _dialogue_visibility_active.has(target):
			continue
		var active: Dictionary = _dialogue_visibility_active[target]
		if (
			int(transition.get("presenter_instance_id", -1)) != get_instance_id()
			or int(transition.get("token", -1)) != int(active.get("token", -2))
			or int(transition.get("operation_request_id", -1))
				!= int(active.get("operation_request_id", -2))
			or int(transition.get("generation", -1))
				!= int(active.get("generation", -2))
		):
			continue
		_complete_dialogue_visibility_target(target, active)


func _resolve_dialogue_visibility_binding(
	runtime_binding: Dictionary,
	restore_profile_baseline: bool = true,
) -> void:
	if restore_profile_baseline:
		_restore_dialogue_visibility_profile_baseline()
	if not runtime_binding.is_empty():
		_dialogue_visibility_runtime_binding = runtime_binding.duplicate(true)
	elif not _dialogue_visibility_runtime_binding.is_empty():
		runtime_binding = _dialogue_visibility_runtime_binding.duplicate(true)
	var current := (
		runtime_binding.get("current", {}) as Dictionary
	).duplicate(true)
	var defaults := (
		runtime_binding.get("default", {
			"surface_groups": ["dialogue_surface"],
			"quick_menu_groups": ["quick_menu"],
		}) as Dictionary
	).duplicate(true)
	var profile_name := String(current.get("profile_name", ""))
	var provenance := (
		current.get("provenance", {}) as Dictionary
	).duplicate(true)
	var resolved := {
		"surface_groups": _normalize_dialogue_visibility_groups(
			current.get("surface_groups", defaults.get("surface_groups", [])),
			"surface_groups",
			profile_name,
			provenance,
			defaults,
		),
		"quick_menu_groups": _normalize_dialogue_visibility_groups(
			current.get("quick_menu_groups", defaults.get("quick_menu_groups", [])),
			"quick_menu_groups",
			profile_name,
			provenance,
			defaults,
		),
	}
	var surface_nodes := _binding_nodes_for_groups(
		resolved["surface_groups"] as Array
	)
	var quick_nodes := _binding_nodes_for_groups(
		resolved["quick_menu_groups"] as Array
	)
	var overlap_groups := _group_overlap(
		resolved["surface_groups"] as Array,
		resolved["quick_menu_groups"] as Array,
		surface_nodes,
		quick_nodes,
	)
	if not overlap_groups.is_empty():
		_emit_dialogue_visibility_binding_warning(
			profile_name,
			provenance,
			"surface_groups",
			"quick_menu_groups",
			overlap_groups,
			"overlap",
		)
		resolved = defaults.duplicate(true)
		surface_nodes = _binding_nodes_for_groups(
			resolved["surface_groups"] as Array
		)
		quick_nodes = _binding_nodes_for_groups(
			resolved["quick_menu_groups"] as Array
		)
		if not _group_overlap(
			resolved["surface_groups"] as Array,
			resolved["quick_menu_groups"] as Array,
			surface_nodes,
			quick_nodes,
		).is_empty():
			resolved["surface_groups"] = []
			resolved["quick_menu_groups"] = []
			surface_nodes = []
			quick_nodes = []
	var resolved_current := current.duplicate(true)
	resolved_current["profile_name"] = profile_name
	resolved_current["provenance"] = provenance.duplicate(true)
	resolved_current["surface_groups"] = resolved["surface_groups"].duplicate()
	resolved_current["quick_menu_groups"] = resolved["quick_menu_groups"].duplicate()
	_dialogue_visibility_binding = {
		"current": resolved_current,
		"default": defaults.duplicate(true),
		"profile_name": profile_name,
		"provenance": provenance.duplicate(true),
	}
	_dialogue_visibility_nodes = {
		"surface": surface_nodes,
		"quick_menu": quick_nodes,
	}
	_capture_dialogue_visibility_profile_baseline()


func _normalize_dialogue_visibility_groups(
	raw_groups: Variant,
	field_name: String,
	profile_name: String,
	provenance: Dictionary,
	defaults: Dictionary,
) -> Array[String]:
	var normalized: Array[String] = []
	if raw_groups is Array:
		for group_value: Variant in raw_groups:
			var group_name := String(group_value).strip_edges()
			if group_name.is_empty():
				continue
			normalized.append(group_name)
	if normalized.is_empty():
		var fallback: Array = defaults.get(field_name, [])
		for group_value: Variant in fallback:
			var group_name := String(group_value).strip_edges()
			if not group_name.is_empty():
				normalized.append(group_name)
	if normalized.is_empty():
		return normalized
	var resolved_nodes := _binding_nodes_for_groups(normalized)
	if resolved_nodes.is_empty():
		for group_name: String in normalized:
			_emit_dialogue_visibility_binding_warning(
				profile_name,
				provenance,
				field_name,
				"",
				[group_name],
				"missing",
			)
		return []
	return normalized


func _binding_nodes_for_groups(group_names: Array) -> Array[CanvasItem]:
	var result: Array[CanvasItem] = []
	var seen: Dictionary = {}
	for group_name_value: Variant in group_names:
		var group_name := StringName(String(group_name_value))
		for node in _find_auxiliary_group_nodes(group_name):
			var instance_id := node.get_instance_id()
			if seen.has(instance_id):
				continue
			seen[instance_id] = true
			result.append(node)
	return result


func _group_overlap(
	surface_groups: Array,
	quick_groups: Array,
	surface_nodes: Array,
	quick_nodes: Array,
) -> Array[String]:
	var surface_ids: Dictionary = {}
	for node: CanvasItem in surface_nodes:
		surface_ids[node.get_instance_id()] = true
	var overlap: Array[String] = []
	var has_overlap := false
	for node: CanvasItem in quick_nodes:
		if surface_ids.has(node.get_instance_id()):
			has_overlap = true
	if has_overlap:
		for group_name_value: Variant in surface_groups:
			overlap.append(String(group_name_value))
		for group_name_value: Variant in quick_groups:
			var group_name := String(group_name_value)
			if group_name not in overlap:
				overlap.append(group_name)
	return overlap


func _emit_dialogue_visibility_binding_warning(
	profile_name: String,
	provenance: Dictionary,
	field_name: String,
	other_field_name: String,
	group_names: Array,
	failure_kind: String,
) -> void:
	var source_path := String(provenance.get("source_path", ""))
	var field_lines := provenance.get("field_lines", {}) as Dictionary
	var line := int(field_lines.get(field_name, 0))
	var normalized_groups: Array[String] = []
	var seen_groups: Dictionary = {}
	for group_name_value: Variant in group_names:
		var group_name := String(group_name_value).strip_edges()
		if group_name.is_empty() or seen_groups.has(group_name):
			continue
		seen_groups[group_name] = true
		normalized_groups.append(group_name)
	normalized_groups.sort()
	var other_line := int(field_lines.get(other_field_name, 0))
	var warning_key := "dialogue-visibility-binding:%s:%s:%s:%d:%s:%d:%s:%s" % [
		source_path,
		profile_name,
		field_name,
		line,
		other_field_name,
		other_line,
		failure_kind,
		"|".join(normalized_groups),
	]
	var message := (
		"profile=%s source=%s field=%s line=%d"
		% [profile_name, source_path, field_name, line]
	)
	for group_name in normalized_groups:
		message += " group=%s" % group_name
	if not other_field_name.is_empty():
		message += " field=%s line=%d" % [other_field_name, other_line]
	message += " failure_kind=%s" % failure_kind
	if _profile_warning_keys.has(warning_key):
		return
	_profile_warning_keys[warning_key] = true
	push_warning("DialoguePresenter runtime binding: %s" % message)


func _apply_visual_only_dialogue_restore(
	content: Dictionary,
	runtime_binding: Dictionary,
	preserve_current_presentation: bool = false,
) -> void:
	_abort_current_dialogue_activation()
	if not preserve_current_presentation:
		_restore_authored_presentation()
	_current_voice = ""
	_current_voice_character = ""
	_voice_layer_progress.clear()
	_voice_playing = false
	_active_voice_token = -1
	_playback_queue_active = false
	_playback_owner_dialogue_gen = -1
	_playback_aborted = true
	_playback_dialogue_finished_emitted = false
	_playback_total_duration = 0.0
	_playback_played_duration = 0.0
	_playback_segment_durations.clear()
	_playback_voice_token = -1
	_stage_transition_records.clear()
	_finalization_transition_records.clear()
	_stage_operation_request_owners.clear()
	_stage_operation_request_results.clear()
	_queued_voice_replay_request.clear()
	_finalization_pending = false
	_finalization_in_progress = false
	_dialogue_ready = false
	_indicator_candidate_dialogue_gen = -1
	_skip_pending_dialogue_gen = -1
	_auto_pending_dialogue_gen = -1
	_active_uses_stla_presentation = bool(
		content.get("declarative_presentation", false)
	)
	_current_mode = String(content.get("mode", "adv"))
	_current_character = String(content.get("character", ""))
	_current_avatar_expression = String(content.get("avatar_expression", ""))
	_dialogue_segments = (content.get("segments", []) as Array).duplicate(true)
	_dialogue_voice_character = ""
	_dialogue_total_duration = 0.0
	if _voice_replay_btn != null:
		_voice_replay_btn.visible = false
	_segment_presentation_complete = false
	_next_stage_segment_index = 0
	if not bool(content.get("active", false)):
		if not preserve_current_presentation:
			_apply_dialogue_mode_presentation("adv", null, false)
		visible = false
		_reset_nvl_accumulator()
		name_label.text = ""
		name_label.visible = false
		text_label.text = ""
		text_label.visible_characters = -1
		if _avatar_container:
			_avatar_container.visible = false
			if _avatar_texture:
				_avatar_texture.texture = null
		return
	visible = true
	var current := (runtime_binding.get("current", {}) as Dictionary).duplicate(true)
	var profile_dict := (current.get("profile", {}) as Dictionary).duplicate(true)
	if not profile_dict.is_empty():
		var mode_profile := DialogueModeProfile.from_dictionary(
			profile_dict,
			current.get("provenance", {}) as Dictionary,
		)
		_active_stla_mode_profile = mode_profile
		if not preserve_current_presentation:
			_apply_dialogue_mode_presentation(
				_current_mode, mode_profile, _active_uses_stla_presentation)
	else:
		_active_stla_mode_profile = null
		if not preserve_current_presentation:
			_apply_dialogue_mode_presentation(
				_current_mode, null, _active_uses_stla_presentation)
	if bool(content.get("cleared", false)):
		_reset_nvl_accumulator()
		name_label.text = ""
		name_label.visible = false
		text_label.text = ""
		text_label.visible_characters = -1
		if _avatar_container:
			_avatar_container.visible = false
			if _avatar_texture:
				_avatar_texture.texture = null
		_update_dialogue_visibility_node_baseline(name_label)
		_update_dialogue_visibility_node_baseline(text_label)
		return
	if _current_mode == "nvl":
		name_label.text = ""
		name_label.visible = false
		var pieces: Array[String] = []
		var binding_entries: Array = runtime_binding.get("nvl_entries", [])
		var content_entries: Array = content.get("nvl_entries", [])
		for index in range(content_entries.size()):
			var entry: Dictionary = content_entries[index]
			var profile_name := String(entry.get("profile_name", ""))
			var entry_binding := {}
			for candidate_value: Variant in binding_entries:
				var candidate: Dictionary = candidate_value
				if String(candidate.get("profile_name", "")) == profile_name:
					entry_binding = candidate
					break
			var entry_profile := (entry_binding.get("profile", {}) as Dictionary).duplicate(true)
			var prefix := DEFAULT_NVL_ENTRY_PREFIX
			var separator := DEFAULT_NVL_ENTRY_SEPARATOR
			if not entry_profile.is_empty():
				var entry_mode_profile := DialogueModeProfile.from_dictionary(
					entry_profile,
					entry_binding.get("provenance", {}) as Dictionary,
				)
				if entry_mode_profile.overrides_property(&"entry_prefix"):
					prefix = entry_mode_profile.entry_prefix
				if entry_mode_profile.overrides_property(&"entry_separator"):
					separator = entry_mode_profile.entry_separator
			if index > 0:
				pieces.append(separator)
			var speaker := String(entry.get("character", ""))
			var speaker_prefix := "%s：" % speaker if not speaker.is_empty() else ""
			var segs: Array = entry.get("segments", [])
			var text := String((segs[0] as Dictionary).get("text", "")) if not segs.is_empty() else ""
			pieces.append(prefix + speaker_prefix + text)
		_nvl_render_source = "".join(pieces)
		_nvl_text = _nvl_render_source
		_nvl_has_entries = not content_entries.is_empty()
		text_label.text = _nvl_render_source
		text_label.visible_characters = -1
	else:
		_reset_nvl_accumulator()
		var full_text := String((_dialogue_segments[0] as Dictionary).get("text", "")) if not _dialogue_segments.is_empty() else ""
		if _current_mode == "adv" and not _current_character.is_empty():
			name_label.text = _current_character
			name_label.visible = true
		else:
			name_label.text = ""
			name_label.visible = false
		text_label.text = full_text
		text_label.visible_characters = -1
	_update_dialogue_visibility_node_baseline(name_label)
	_update_dialogue_visibility_node_baseline(text_label)
	_update_avatar(_current_character, _current_avatar_expression, _current_mode)


func _retire_dialogue_visibility_target(
	target: String,
	outcome: StringName,
) -> void:
	if not _dialogue_visibility_active.has(target):
		return
	var active: Dictionary = _dialogue_visibility_active[target]
	_dialogue_visibility_active.erase(target)
	var tween := active.get("tween") as Tween
	if tween != null and tween.is_valid():
		tween.kill()
	_restore_dialogue_visibility_temporary_state(active)
	(SignalBus.get(&"dialogue_visibility_transition_terminal") as Signal).emit(
		get_instance_id(),
		target,
		int(active.get("token", 0)),
		int(active.get("operation_request_id", 0)),
		int(active.get("generation", 0)),
		outcome,
	)


func _dialogue_visibility_identity_is_current(
	target: String,
	identity: Dictionary,
) -> bool:
	if not _dialogue_visibility_active.has(target):
		return false
	var active: Dictionary = _dialogue_visibility_active[target]
	return (
		int(active.get("token", -1)) == int(identity.get("token", -2))
		and int(active.get("operation_request_id", -1))
			== int(identity.get("operation_request_id", -2))
		and int(active.get("generation", -1))
			== int(identity.get("generation", -2))
	)


func _restore_dialogue_visibility_temporary_state(active: Dictionary) -> void:
	for state_value: Variant in active.get("nodes", []):
		var state: Dictionary = state_value
		var node := state.get("node") as CanvasItem
		if not is_instance_valid(node):
			continue
		var restored := node.modulate
		restored.a = float(state.get("alpha", restored.a))
		node.modulate = restored


func _complete_dialogue_visibility_target(
	target: String,
	identity: Dictionary,
) -> void:
	if not _dialogue_visibility_identity_is_current(target, identity):
		return
	var active: Dictionary = _dialogue_visibility_active[target]
	_dialogue_visibility_active.erase(target)
	var tween := active.get("tween") as Tween
	if tween != null and tween.is_valid():
		tween.kill()
	_restore_dialogue_visibility_temporary_state(active)
	_canonical_dialogue_visibility[target] = bool(active.get("target_visible", true))
	_apply_canonical_dialogue_visibility()
	(SignalBus.get(&"dialogue_visibility_transition_terminal") as Signal).emit(
		get_instance_id(),
		target,
		int(active.get("token", 0)),
		int(active.get("operation_request_id", 0)),
		int(active.get("generation", 0)),
		&"completed",
	)


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
	# reset and mutate the replacement dialogue presentation.
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
	var hide_gen := _publish_next_dialogue_generation()
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
	_current_scenario_identity = ""
	_current_scene_id = ""
	_current_command_index = -1
	_current_command_uid = -1
	_current_dialogue_activation = null
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
	_abort_queued_dialogue_requests()
	_queued_voice_replay_request.clear()
	_finalization_pending = false
	_finalization_in_progress = false
	# Playback session state — also reset. Bump the queue gen so any in-flight
	# voice queue coroutine (e.g. a backlog replay still running) sees the
	# mismatch on its next iteration and exits cleanly instead of leaking into
	# the next dialogue.
	_publish_next_voice_queue_generation()
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
	if bool(_addressable_avatar_state.get("present", false)):
		_current_character = character if mode == "adv" else ""
		_current_avatar_expression = expression if mode == "adv" else ""
		_avatar_texture.texture = null
		_avatar_texture.visible = false
		_avatar_container.visible = bool(
			_addressable_avatar_state.get("visible", false))
		_update_dialogue_visibility_node_baseline(_avatar_container)
		return

	# Only show avatar in ADV mode when a character is speaking
	if mode != "adv" or character == "":
		_current_character = ""
		_current_avatar_expression = ""
		_avatar_container.visible = false
		_avatar_texture.texture = null
		_update_dialogue_visibility_node_baseline(_avatar_container)
		return

	var config = _config_loader.get_config(character)

	if not config.has_avatar_rect():
		_current_character = ""
		_current_avatar_expression = ""
		_avatar_container.visible = false
		_avatar_texture.texture = null
		_update_dialogue_visibility_node_baseline(_avatar_container)
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
		_update_dialogue_visibility_node_baseline(_avatar_container)
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
		_update_dialogue_visibility_node_baseline(_avatar_container)
		return

	_current_character = character
	_current_avatar_expression = expression
	var atlas = AtlasTexture.new()
	atlas.atlas = source_tex
	atlas.region = config.avatar_rect
	_avatar_texture.texture = atlas
	_avatar_container.visible = true
	_update_dialogue_visibility_node_baseline(_avatar_container)
	_apply_canonical_dialogue_visibility()


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
