## Displays dialogue text with typewriter effect.
## Supports ADV (bottom box), NVL (fullscreen accumulate), overlay modes.
## Includes bottom toolbar for game controls.
## Handles skip (toolbar + Ctrl held) and auto-play.
extends Control

const DEFAULT_NVL_ENTRY_PREFIX := ""
const DEFAULT_NVL_ENTRY_SEPARATOR := "\n"

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
var _nvl_has_entries: bool = false
var _nvl_visible_characters: int = 0
var _active_nvl_page_key: String = ""
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
var _finalization_pending: bool = false
var _finalization_in_progress: bool = false

# Playback session state — owned by whichever voice queue is currently running
# (could be the dialogue's own initial playback, a toolbar replay, or a backlog
# replay request). Reset on every _start_voice_playback call.
var _playback_aborted: bool = false  # user clicked to skip the dialogue typewriter
var _playback_queue_active: bool = false  # voice queue coroutine is alive
var _playback_queue_gen: int = 0  # bumped to cancel any in-flight queue
var _playback_total_duration: float = 0.0  # sum of all segment voice durations
var _playback_played_duration: float = 0.0  # cumulative duration of finished segments
var _playback_segment_durations: Array = []  # per-segment voice durations (0 if empty)
# When false, the in-flight playback is for the backlog (or other external UI):
# the queue + audio still run, but the dialogue_voice_* signals (which drive the
# in-game progress bar) are suppressed so the dialogue toolbar bar stays quiet.
var _playback_is_dialogue: bool = true


func _ready():
	SignalBus.show_dialogue.connect(_on_show_dialogue)
	SignalBus.hide_dialogue.connect(_on_hide_dialogue)
	SignalBus.voice_progress.connect(_on_voice_progress_relay)
	SignalBus.dialogue_voice_replay_requested.connect(_on_dialogue_voice_replay_requested)
	SignalBus.scenario_ended_event.connect(func(_id): visible = false)
	# Refresh the "回选项" button state whenever execution surfaces a new
	# command (dialogue or choice). Both signals fire AFTER the engine has
	# advanced to the command being presented, so can_jump_to_previous_choice()
	# reads the right current_cmd_uid. scenario lifecycle signals handle
	# start/end-of-run resets.
	SignalBus.show_dialogue.connect(func(_c, _s, _m): _refresh_prev_choice_btn())
	SignalBus.choice_show.connect(func(_p, _o): _refresh_prev_choice_btn())
	SignalBus.scenario_started_event.connect(func(_id): _refresh_prev_choice_btn())
	SignalBus.scenario_ended_event.connect(func(_id): _refresh_prev_choice_btn())
	SignalBus.voice_started.connect(func(_c, _a): _voice_playing = true)
	SignalBus.voice_finished.connect(func(): _voice_playing = false)
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
	_capture_authored_presentation()
	_validate_configured_profiles()


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
	_start_voice_playback(_dialogue_voice_character, _dialogue_segments)


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
	_start_voice_playback(character, segments, false)


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
	is_dialogue_playback: bool = true,
	apply_segment_presentation: bool = false,
) -> void:
	var playback_gen := _dialogue_gen
	_playback_is_dialogue = is_dialogue_playback
	_playback_aborted = false
	_playback_played_duration = 0.0
	_playback_segment_durations.clear()
	_playback_total_duration = 0.0
	var character_voice_enabled := _is_character_voice_enabled(character)
	for seg in segments:
		var v := String(seg.get("voice", ""))
		var dur := 0.0
		if v != "" and character_voice_enabled:
			var stream = _load_voice_stream(v)
			if stream:
				dur = stream.get_length()
		_playback_segment_durations.append(dur)
		_playback_total_duration += dur
	if _playback_total_duration > 0.0 and _playback_is_dialogue:
		SignalBus.dialogue_voice_started.emit(_playback_total_duration)
		if playback_gen != _dialogue_gen:
			return
	_run_voice_queue(
		character,
		segments,
		playback_gen,
		apply_segment_presentation,
	)


func _on_auto_pressed():
	StellaRuntime.toggle_auto_play()
	_update_toggle_buttons()
	# If auto-play just activated and text is fully shown, advance immediately
	if StellaRuntime.is_auto_playing() and not _is_typing:
		finalize_current_dialogue_for_advance()
		SignalBus.advance_requested.emit()


func _on_skip_pressed():
	StellaRuntime.toggle_skip()
	_update_toggle_buttons()
	if not StellaRuntime.is_skipping():
		return
	# Skip just activated. If the typewriter is mid-flight, snap the text to
	# end (same semantics as click-to-complete) so the user immediately sees
	# the full line — otherwise the button lights up but the typewriter keeps
	# running, which looks like skip isn't working.
	if _is_typing:
		complete_current_dialogue()
		return
	# Text already fully shown — advance now so the next dialogue can run
	# through the gate (which decides whether skip continues or stops).
	finalize_current_dialogue_for_advance()
	SignalBus.advance_requested.emit()


## Complete the active typewriter synchronously, including any remaining
## @combine presentation cues.
func complete_current_dialogue() -> void:
	if not _is_typing:
		return
	_is_typing = false
	text_label.visible_characters = -1
	_finalize_dialogue(_dialogue_voice_character, _dialogue_segments)


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
	if _presentation_dispatch_depth > 0:
		_finalization_pending = true
		return
	if _segment_presentation_complete and _stage_transition_records.is_empty():
		return
	_finalize_dialogue(_dialogue_voice_character, _dialogue_segments)


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
func _on_show_dialogue(character: String, segments: Array, mode: String) -> void:
	if segments.size() == 0:
		return
	var request := {
		"character": character,
		"segments": segments.duplicate(true),
		"mode": mode,
		"nvl_page_key": SignalBus.current_dialogue_nvl_page_key(),
		"presentation_profile": (
			SignalBus.current_dialogue_presentation_profile().duplicate(true)
		),
		"declarative_presentation": (
			SignalBus.current_dialogue_uses_declarative_presentation()
		),
	}
	# A presentation signal may have listeners both before and after this
	# presenter. Delay a synchronously nested SHOW until the current batch has
	# reached every listener, otherwise a late StagePresenter could apply an old
	# operation after the new dialogue has already claimed the same layer.
	if _presentation_dispatch_depth > 0:
		# Multiple synchronous SHOW requests cannot all own the same UI. Match the
		# normal signal semantics by letting the newest request supersede earlier
		# queued requests before presentation control returns to the dialogue.
		_queued_dialogue_requests.clear()
		_queued_dialogue_requests.append(request)
		return
	_show_dialogue_request(request)


func _show_dialogue_request(request: Dictionary) -> void:
	var request_segments: Array = request.get("segments", [])
	var presentation_profile: Dictionary = request.get("presentation_profile", {})
	_show_dialogue_now(
		String(request.get("character", "")),
		request_segments,
		String(request.get("mode", "adv")),
		String(request.get("nvl_page_key", "")),
		presentation_profile,
		bool(request.get("declarative_presentation", false)),
	)


func _show_dialogue_now(
	character: String,
	segments: Array,
	mode: String,
	nvl_page_key: String,
	stla_profile_data: Dictionary,
	uses_stla_presentation: bool,
) -> void:
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

	_dialogue_gen += 1
	var gen = _dialogue_gen
	# Invalidate the old dialogue before cancellation emits request-finished.
	# A suspended old voice queue can then wake only to observe a stale gen.
	_cancel_pending_stage_operation_requests()

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
	_finalization_pending = false
	_finalization_in_progress = false
	# Kick off the dialogue's own playback. This computes _playback_total_duration.
	_start_voice_playback(character, segments, true, true)
	# Presentation signals are synchronous extension points. A listener may have
	# started a newer dialogue while the first segment was being projected.
	if gen != _dialogue_gen:
		return
	# Now snapshot the freshly-computed total as the dialogue's total — used
	# by the toolbar replay button visibility check (cheap, no reload).
	_dialogue_total_duration = _playback_total_duration

	# Process all segments: concat text, merge inline markers + effects with offsets
	var full_text := ""
	var all_effects: Array = []
	var timeline := ExpressionTimeline.new()
	var all_markers: Array = []
	var authored_visible_length := 0
	for seg in segments:
		var seg_text := String(seg.get("text", ""))
		var offset := authored_visible_length
		# Parse avatar markers and typewriter effects in one pass so both use
		# positions in the final visible text. Sequential passes misplace whichever
		# annotation follows the syntax removed by the first pass.
		var processed := ExpressionTimeline.parse_inline_annotations(seg_text)
		for warning in processed["warnings"]:
			push_warning("DialoguePresenter: %s" % String(warning))
		var seg_clean: String = processed["clean_text"]
		for m in processed["markers"]:
			all_markers.append({
				"expression": m["expression"],
				"at_char": int(m["at_char"]) + offset,
			})
		for ef in processed["effects"]:
			all_effects.append({
				"type": ef["type"],
				"value": ef["value"],
				"pos": int(ef["pos"]) + offset,
			})
		full_text += seg_clean
		authored_visible_length += int(processed["visible_length"])
	timeline.markers = all_markers

	_current_voice_character = character
	var first_voice := String(segments[0].get("voice", ""))
	_current_voice = first_voice
	if _voice_replay_btn:
		# Show the replay button as long as ANY segment has a voice — read from
		# DIALOGUE state (not playback state) so a backlog replay running in the
		# background can't accidentally hide the button.
		_voice_replay_btn.visible = (_dialogue_total_duration > 0.0)

	visible = true
	_current_mode = mode
	_active_uses_stla_presentation = uses_stla_presentation
	_active_stla_mode_profile = (
		DialogueModeProfile.from_dictionary(stla_profile_data)
		if not stla_profile_data.is_empty()
		else null
	)

	var uses_presentation_profile := _apply_dialogue_mode_presentation(
		mode, _active_stla_mode_profile, uses_stla_presentation)
	if toolbar and not uses_presentation_profile:
		toolbar.visible = (mode == "adv")

	# Mode-specific text setup
	var new_line_text: String = ""
	var authored_text_offset: int = 0
	if mode == "nvl":
		name_label.visible = false
		var entry_format := _resolve_nvl_entry_format()
		var entry_prefix: String = entry_format["prefix"]
		var speaker_prefix := "%s：" % character if not character.is_empty() else ""
		new_line_text = entry_prefix + speaker_prefix + full_text
		authored_text_offset = entry_prefix.length() + speaker_prefix.length()
		var separator: String = (
			entry_format["separator"] if _nvl_has_entries else "")
		var previously_visible := _nvl_text + separator
		var previously_visible_count := (
			_nvl_visible_characters + separator.length()
		)
		var combined := previously_visible + new_line_text
		text_label.text = combined
		text_label.visible_characters = previously_visible_count
		_nvl_text = combined
		_nvl_visible_characters = (
			previously_visible_count
			+ authored_text_offset
			+ authored_visible_length
		)
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

	# Avatar state belongs to dialogue presentation. An inline marker at character
	# zero supplies the initial avatar without emitting a stage/character signal.
	var avatar_expr := "default"
	if character != "":
		_avatar_expressions[character] = avatar_expr
	var initial_inline_expr := timeline.get_expression_at_char(0)
	if character != "" and initial_inline_expr != "":
		avatar_expr = initial_inline_expr
		_avatar_expressions[character] = avatar_expr
	# Skip applies only the final combined state; avoid flashing segment zero.
	if not _should_skip_current():
		_update_avatar(character, avatar_expr, mode)

	# (Voice queue was already kicked off above by _start_voice_playback —
	# do not start another one here.)

	await get_tree().process_frame
	if gen != _dialogue_gen:
		return
	_is_typing = true

	# If toolbar skip is active and the new line is unread (with skip_only_read
	# on), un-toggle it now so the button reflects reality and the user reads
	# normally. Runs once per dialogue — pure-query checks below can't side
	# effect, so this is the explicit gate.
	_apply_unread_skip_gate()

	# Skip mode: show all text immediately and snap to final state
	if _should_skip_current():
		text_label.visible_characters = -1
		_is_typing = false
		_finalize_dialogue(character, segments)
		await get_tree().create_timer(StellaRuntime.get_setting("skip_interval") / 1000.0).timeout
		if gen != _dialogue_gen:
			return
		SignalBus.advance_requested.emit()
		return

	# Typewriter
	var start_visible = text_label.visible_characters
	# Inline avatar/effect annotations are not visible characters. Drive the loop
	# from parsed visible coordinates so removed source syntax cannot shift cue
	# boundaries.
	var total_new_chars = authored_text_offset + authored_visible_length
	var current_char_interval := _char_interval
	for i in range(total_new_chars):
		if not _is_typing:
			break
		if _should_skip_current():
			text_label.visible_characters = -1
			_is_typing = false
			_finalize_dialogue(character, segments)
			await get_tree().create_timer(StellaRuntime.get_setting("skip_interval") / 1000.0).timeout
			if gen != _dialogue_gen:
				return
			SignalBus.advance_requested.emit()
			return

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
				int(effect["pos"]) == authored_visible_length
				and effect["type"] == "wait"
				and float(effect["value"]) > 0.0
			):
				await get_tree().create_timer(effect["value"] / 1000.0).timeout
				if gen != _dialogue_gen:
					return

	# Click-to-finish detection: input_handler sets _is_typing=false and visible=-1
	if not _playback_aborted and not _is_typing and text_label.visible_characters == -1:
		_finalize_dialogue(character, segments)

	text_label.visible_characters = -1
	_is_typing = false
	_apply_final_inline_avatar_expression(character, segments)
	_mark_current_line_read()

	# Auto-play: wait for the voice queue to drain all segments, then advance
	if StellaRuntime.is_auto_playing():
		if StellaRuntime.get_setting("auto_play_wait_voice"):
			while _playback_queue_active and not _playback_aborted:
				await get_tree().process_frame
				if gen != _dialogue_gen:
					return
			if _voice_playing:
				await SignalBus.voice_finished
				if gen != _dialogue_gen:
					return
		var ap_delay = StellaRuntime.get_setting("auto_play_delay")
		await get_tree().create_timer(ap_delay).timeout
		if gen != _dialogue_gen:
			return
		if StellaRuntime.is_auto_playing():
			finalize_current_dialogue_for_advance()
			SignalBus.advance_requested.emit()


func _run_voice_queue(
	character: String,
	segments: Array,
	gen: int,
	apply_segment_presentation: bool = false,
) -> void:
	if gen != _dialogue_gen:
		return
	# During the dialogue's initial playback, each segment's named-stage batch
	# is emitted before its voice starts. Toolbar/backlog replay passes false so
	# replaying audio cannot mutate the current visual state.
	_playback_queue_gen += 1
	var q_gen = _playback_queue_gen
	_playback_queue_active = true
	var prev_had_voice := false
	for i in range(segments.size()):
		if prev_had_voice:
			await SignalBus.voice_finished
			if q_gen != _playback_queue_gen or gen != _dialogue_gen or _playback_aborted:
				if q_gen == _playback_queue_gen:
					_playback_queue_active = false
				return
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
			)
			while (
				stage_request_id > 0
				and SignalBus.is_stage_operation_request_active(stage_request_id)
			):
				await SignalBus.stage_operation_request_finished
				if q_gen != _playback_queue_gen or gen != _dialogue_gen or _playback_aborted:
					if q_gen == _playback_queue_gen:
						_playback_queue_active = false
					return
			var stage_request_delivered := bool(
				_stage_operation_request_results.get(stage_request_id, false)
			)
			_stage_operation_request_results.erase(stage_request_id)
			if stage_request_id > 0 and not stage_request_delivered:
				if q_gen == _playback_queue_gen:
					_playback_queue_active = false
				return
			if q_gen != _playback_queue_gen or gen != _dialogue_gen or _playback_aborted:
				if q_gen == _playback_queue_gen:
					_playback_queue_active = false
				return
		if q_gen != _playback_queue_gen or gen != _dialogue_gen or _playback_aborted:
			if q_gen == _playback_queue_gen:
				_playback_queue_active = false
			return
		var voice := String(seg.get("voice", ""))
		var measured_duration := (
			float(_playback_segment_durations[i])
			if i < _playback_segment_durations.size()
			else 0.0
		)
		prev_had_voice = (
			voice != ""
			and measured_duration > 0.0
			and _is_character_voice_enabled(character)
			and not _should_skip_current()
		)
		if prev_had_voice:
			_current_voice = voice
			SignalBus.voice_play.emit(voice, character)

	# Wait for the LAST segment's voice to actually finish before declaring the
	# whole dialogue voice playback done. Otherwise dialogue_voice_finished
	# would fire the instant the last segment STARTS playing, hiding the
	# progress bar before the user has heard most of the final clip.
	if prev_had_voice:
		await SignalBus.voice_finished
		if q_gen != _playback_queue_gen or gen != _dialogue_gen or _playback_aborted:
			if q_gen == _playback_queue_gen:
				_playback_queue_active = false
			return
		var last_idx = segments.size() - 1
		if last_idx >= 0 and last_idx < _playback_segment_durations.size():
			_playback_played_duration += float(_playback_segment_durations[last_idx])

	if q_gen == _playback_queue_gen:
		_playback_queue_active = false
		if _playback_total_duration > 0.0 and _playback_is_dialogue:
			SignalBus.dialogue_voice_finished.emit()


func _apply_segment_presentation(
	segment: Dictionary,
	force_cut: bool,
	segment_index: int = -1,
	segment_count: int = 0,
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
	elif not stage_ops is Array:
		push_warning("DialoguePresenter: segment stage_ops must be an Array")
	return request_id


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
	var segment_index := int((owner as Dictionary).get("segment_index", -1))
	if segment_index < 0:
		return
	_next_stage_segment_index = maxi(_next_stage_segment_index, segment_index + 1)
	var segment_count := int((owner as Dictionary).get("segment_count", 0))
	if segment_count > 0 and _next_stage_segment_index >= segment_count:
		_segment_presentation_complete = true


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
	if not _queued_dialogue_requests.is_empty():
		var request: Dictionary = _queued_dialogue_requests.pop_front()
		_show_dialogue_request(request)
		return
	if (
		not _finalization_pending
		or _finalization_in_progress
	):
		return
	_finalization_pending = false
	if not _dialogue_segments.is_empty():
		_finalize_dialogue(_dialogue_voice_character, _dialogue_segments)


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
		return
	# Replaying already-applied operations is not idempotent (for example,
	# update-before-show changes meaning on a second reduction). Ask each
	# presenter to finish only the exact transition tokens it acknowledged while
	# this dialogue was dispatching. Newer work on the same id is left alone.
	var finish_records: Array = _finalization_transition_records.values()
	if not finish_records.is_empty():
		SignalBus.stage_transitions_finish_requested.emit(finish_records)
	_finalization_transition_records.clear()
	_finalization_in_progress = false


func _finalize_dialogue(character: String, segments: Array) -> void:
	if _finalization_in_progress:
		return
	if _presentation_dispatch_depth > 0:
		_finalization_pending = true
		return
	_finalization_pending = false
	# User aborted typewriter (or skip mode): cancel voice progression and snap
	# directly to the combined dialogue's final authored presentation state.
	var queue_was_active := _playback_queue_active
	var finalization_gen := _dialogue_gen
	_playback_aborted = true
	_mark_current_line_read()
	_apply_final_inline_avatar_expression(character, segments)
	_apply_final_segment_presentation(segments, true)
	if finalization_gen != _dialogue_gen:
		return
	if (
		queue_was_active
		and _playback_total_duration > 0.0
		and _playback_is_dialogue
	):
		SignalBus.dialogue_voice_finished.emit()


## Relays low-level voice_progress (per-clip) into dialogue_voice_progress
## (per-dialogue), adding the cumulative duration of already-finished segments.
## Only relays during DIALOGUE playback — backlog/external replays don't drive
## the in-game progress bar.
func _on_voice_progress_relay(position: float, _duration: float) -> void:
	if _playback_total_duration > 0.0 and _playback_is_dialogue:
		var total_pos = _playback_played_duration + position
		SignalBus.dialogue_voice_progress.emit(total_pos, _playback_total_duration)


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


## Advanced programmatic fallback. Normal projects should use @dialogue_profile.
## Scene-authored state is restored before the new profile applies.
func set_presentation_profile(profile: DialoguePresentationProfile) -> void:
	if is_node_ready():
		_restore_authored_presentation()
	presentation_profile = profile
	_profile_warning_keys.clear()
	_auxiliary_visibility_baseline.clear()
	if not is_node_ready():
		return
	_text_rect_target = _resolve_text_rect_target()
	_validate_configured_profiles()
	if visible:
		var uses_profile := _apply_dialogue_mode_presentation(
			_current_mode, _active_stla_mode_profile,
			_active_uses_stla_presentation)
		if toolbar and not uses_profile:
			toolbar.visible = (_current_mode == "adv")


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
	var prefix := DEFAULT_NVL_ENTRY_PREFIX
	var separator := DEFAULT_NVL_ENTRY_SEPARATOR
	var mode_profile := _active_stla_mode_profile
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


func _reset_nvl_accumulator() -> void:
	_nvl_text = ""
	_nvl_has_entries = false
	_nvl_visible_characters = 0
	_active_nvl_page_key = ""


func _on_hide_dialogue():
	# Invalidate every async branch of the current dialogue before clearing the
	# visible state. Without this, an old typewriter can finish after a runtime
	# reset and mark its line in the replacement ReadFlagManager.
	_dialogue_gen += 1
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
	_finalization_pending = false
	_finalization_in_progress = false
	# Playback session state — also reset. Bump the queue gen so any in-flight
	# voice queue coroutine (e.g. a backlog replay still running) sees the
	# mismatch on its next iteration and exits cleanly instead of leaking into
	# the next dialogue.
	_playback_queue_gen += 1
	_playback_queue_active = false
	_playback_aborted = true
	_playback_total_duration = 0.0
	_playback_played_duration = 0.0
	_playback_segment_durations.clear()
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
