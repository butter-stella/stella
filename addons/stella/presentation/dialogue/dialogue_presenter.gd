## Displays dialogue text with typewriter effect.
## Supports ADV (bottom box), NVL (fullscreen accumulate), overlay modes.
## Includes bottom toolbar for game controls.
## Handles skip (toolbar + Ctrl held) and auto-play.
extends Control

@onready var name_label: Label = %NameLabel
@onready var text_label: RichTextLabel = %TextLabel
@onready var toolbar: HBoxContainer = %Toolbar
var _avatar_texture: TextureRect
var _avatar_container: Control

var _char_interval: float = 0.03  # seconds per character
var _is_typing: bool = false
var _nvl_text: String = ""  # accumulated NVL text (already shown)
var _current_mode: String = "adv"
var _ui_hidden: bool = false
var _ctrl_held: bool = false  # Ctrl key skip
var _current_voice: String = ""  # current dialogue voice asset
var _current_voice_character: String = ""
var _voice_playing: bool = false
var _current_character: String = ""  # current speaking character for avatar
var _config_loader: CharacterConfigLoader
var _known_expressions: Dictionary = {}  # character_id -> current expression

# Store original anchors for switching between ADV and NVL layout
var _adv_anchor_top: float
var _adv_offset_top: float
var _dialogue_bg: Panel
var _text_area: VBoxContainer

## Icon paths — set these to customize toolbar button icons.
var toolbar_icons: Dictionary = {
	"voice_replay": "", "auto": "", "skip": "", "backlog": "",
	"quick_save": "", "quick_load": "",
	"save": "", "load": "", "settings": "",
}
var _voice_replay_btn: Button
var _auto_btn: Button
var _skip_btn: Button
var _dialogue_gen: int = 0  # increments on each new dialogue, stale coroutines check this

# Dialogue state — owned by the currently visible/active dialogue. Only updated
# by _on_show_dialogue and cleared by _on_hide_dialogue. The toolbar 重听 button
# reads these so an in-flight backlog replay never corrupts what the toolbar
# would replay for the current dialogue.
var _dialogue_segments: Array = []
var _dialogue_voice_character: String = ""
var _dialogue_total_duration: float = 0.0

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
	SignalBus.voice_started.connect(func(_c, _a): _voice_playing = true)
	SignalBus.voice_finished.connect(func(): _voice_playing = false)
	SignalBus.char_show.connect(func(c, e, _p): _known_expressions[c] = e)
	SignalBus.char_expression_changed.connect(_on_avatar_expression_changed)
	SignalBus.char_hide.connect(func(c):
		if c == "all": _known_expressions.clear()
		else: _known_expressions.erase(c)
	)
	_config_loader = StellaRuntime.character_config_loader
	_avatar_container = get_node_or_null("%AvatarContainer")
	if _avatar_container:
		_avatar_texture = _avatar_container.get_node_or_null("AvatarTexture")
	_dialogue_bg = get_node_or_null("DialogueBg")
	_text_area = get_node_or_null("HBox/TextArea")
	visible = false
	_adv_anchor_top = anchor_top
	_adv_offset_top = offset_top
	_setup_toolbar()


func _setup_toolbar():
	if toolbar == null:
		return

	var buttons = [
		{"id": "voice_replay", "text": "重听", "callback": _on_voice_replay_pressed},
		{"id": "auto", "text": "自动", "callback": _on_auto_pressed},
		{"id": "skip", "text": "快进", "callback": _on_skip_pressed},
		{"id": "backlog", "text": "记录", "callback": _on_backlog_pressed},
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
			"expression": "",
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
func _start_voice_playback(character: String, segments: Array, is_dialogue_playback: bool = true) -> void:
	_playback_is_dialogue = is_dialogue_playback
	_playback_aborted = false
	_playback_played_duration = 0.0
	_playback_segment_durations.clear()
	_playback_total_duration = 0.0
	for seg in segments:
		var v := String(seg.get("voice", ""))
		var dur := 0.0
		if v != "":
			var stream = _load_voice_stream(v)
			if stream:
				dur = stream.get_length()
		_playback_segment_durations.append(dur)
		_playback_total_duration += dur
	if _playback_total_duration > 0.0 and _playback_is_dialogue:
		SignalBus.dialogue_voice_started.emit(_playback_total_duration)
	_run_voice_queue(character, segments, _dialogue_gen)


func _on_auto_pressed():
	StellaRuntime.toggle_auto_play()
	_update_toggle_buttons()
	# If auto-play just activated and text is fully shown, advance immediately
	if StellaRuntime.is_auto_playing() and not _is_typing:
		SignalBus.advance_requested.emit()


func _on_skip_pressed():
	StellaRuntime.toggle_skip()
	_update_toggle_buttons()
	# If skip just activated and text is fully shown, advance immediately
	if StellaRuntime.is_skipping() and not _is_typing:
		SignalBus.advance_requested.emit()


func _on_backlog_pressed():
	StellaRuntime.show_backlog()


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


func _is_skipping() -> bool:
	return StellaRuntime.is_skipping() or _ctrl_held


## Unified dialogue handler.
## Both normal single-line dialogue and @combine multi-segment dialogue flow
## through here. A normal dialogue is just segments.size() == 1.
## - Voices play sequentially via _run_voice_queue (works for 1 or N segments)
## - Typewriter runs continuously over concatenated text
## - Inline `[expr]` markers and `{wait/speed}` effects from each segment's text
##   are merged into global timelines with offset adjustment
## - Click-to-finish: snap text to end + cancel voice queue + apply final expression
func _on_show_dialogue(character: String, segments: Array, mode: String) -> void:
	if _ui_hidden or segments.size() == 0:
		return

	_dialogue_gen += 1
	var gen = _dialogue_gen

	# Snapshot dialogue state. _start_voice_playback later writes _playback_*
	# but never touches _dialogue_*, so a backlog replay can run in parallel
	# without corrupting what the toolbar 重听 button will play.
	_dialogue_segments = segments.duplicate(true)
	_dialogue_voice_character = character
	# Kick off the dialogue's own playback. This computes _playback_total_duration.
	_start_voice_playback(character, segments)
	# Now snapshot the freshly-computed total as the dialogue's total — used
	# by the toolbar replay button visibility check (cheap, no reload).
	_dialogue_total_duration = _playback_total_duration

	# Process all segments: concat text, merge inline markers + effects with offsets
	var full_text := ""
	var all_effects: Array = []
	var timeline := ExpressionTimeline.new()
	var all_markers: Array = []
	for seg in segments:
		var seg_text := String(seg.get("text", ""))
		var offset := full_text.length()
		# Inline `[expr]` markers
		var tl_result = ExpressionTimeline.new().extract_from_text(seg_text)
		var seg_clean: String = tl_result["clean_text"]
		for m in tl_result["markers"]:
			all_markers.append({
				"expression": m["expression"],
				"at_char": int(m["at_char"]) + offset,
			})
		# Inline `{wait/speed}` effects
		var processed = _process_inline_effects(seg_clean)
		seg_clean = processed["text"]
		for ef in processed["effects"]:
			all_effects.append({
				"type": ef["type"],
				"value": ef["value"],
				"pos": int(ef["pos"]) + offset,
			})
		full_text += seg_clean
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

	if toolbar:
		toolbar.visible = (mode == "adv")

	# Mode-specific text setup
	var new_line_text: String = ""
	if mode == "nvl":
		_apply_nvl_layout()
		name_label.visible = false
		if character != "":
			new_line_text = "%s：%s" % [character, full_text]
		else:
			new_line_text = full_text
		var combined = _nvl_text + new_line_text
		text_label.text = combined
		var old_char_count = _nvl_text.length()
		text_label.visible_characters = old_char_count
		_nvl_text = combined + "\n"
	elif mode == "overlay":
		_apply_overlay_layout()
		name_label.visible = false
		new_line_text = full_text
		text_label.text = full_text
		text_label.visible_characters = 0
	else:  # adv
		_apply_adv_layout()
		_nvl_text = ""
		new_line_text = full_text
		if character != "":
			name_label.text = character
			name_label.visible = true
		else:
			name_label.text = ""
			name_label.visible = false
		text_label.text = full_text
		text_label.visible_characters = 0

	# Avatar: first segment's explicit expression takes priority, else current known
	var first_expr := String(segments[0].get("expression", ""))
	var avatar_expr = first_expr if first_expr != "" else String(_known_expressions.get(character, "default"))
	_update_avatar(character, avatar_expr, mode)

	# (Voice queue was already kicked off above by _start_voice_playback —
	# do not start another one here.)

	await get_tree().process_frame
	_is_typing = true

	# Skip mode: show all text immediately and snap to final state
	if _is_skipping():
		text_label.visible_characters = -1
		_is_typing = false
		_finalize_dialogue(character, segments)
		await get_tree().create_timer(StellaRuntime.get_setting("skip_interval") / 1000.0).timeout
		SignalBus.advance_requested.emit()
		return

	# Typewriter
	var start_visible = text_label.visible_characters
	var total_new_chars = new_line_text.length()
	for i in range(total_new_chars):
		if not _is_typing:
			break
		if _is_skipping():
			text_label.visible_characters = -1
			_is_typing = false
			_finalize_dialogue(character, segments)
			await get_tree().create_timer(StellaRuntime.get_setting("skip_interval") / 1000.0).timeout
			SignalBus.advance_requested.emit()
			return

		text_label.visible_characters = start_visible + i + 1

		var expr = timeline.get_expression_at_char(i)
		if expr != "" and character != "":
			SignalBus.char_expression_changed.emit(character, expr)

		var delay = _char_interval
		for effect in all_effects:
			if effect["pos"] == i:
				if effect["type"] == "wait":
					await get_tree().create_timer(effect["value"] / 1000.0).timeout
				elif effect["type"] == "speed":
					delay = effect["value"] / 1000.0

		await get_tree().create_timer(delay).timeout
		if gen != _dialogue_gen:
			return

	# Click-to-finish detection: input_handler sets _is_typing=false and visible=-1
	if not _playback_aborted and not _is_typing and text_label.visible_characters == -1:
		_finalize_dialogue(character, segments)

	text_label.visible_characters = -1
	_is_typing = false

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
			SignalBus.advance_requested.emit()


func _run_voice_queue(character: String, segments: Array, gen: int) -> void:
	# Plays all segment voices sequentially. Owns every segment so a missing/empty
	# voice can't hang the queue. Between segments, awaits voice_finished iff the
	# previous segment actually played a voice. Works identically for single- and
	# multi-segment dialogues.
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
		var expr := String(seg.get("expression", ""))
		if expr != "" and character != "":
			SignalBus.char_expression_changed.emit(character, expr)
			if _current_mode == "adv":
				_update_avatar(character, expr, "adv")
		var voice := String(seg.get("voice", ""))
		prev_had_voice = (voice != "")
		if voice != "" and not _is_skipping():
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


func _finalize_dialogue(character: String, segments: Array) -> void:
	# User aborted typewriter (or skip mode) — cancel the voice queue progression
	# and snap expression to the final segment's expression. For a single-segment
	# dialogue with empty expression this is a no-op.
	_playback_aborted = true
	if _playback_total_duration > 0.0 and _playback_is_dialogue:
		SignalBus.dialogue_voice_finished.emit()
	if segments.size() == 0:
		return
	var last_seg = segments[segments.size() - 1]
	var last_expr := String(last_seg.get("expression", ""))
	if last_expr != "" and character != "":
		SignalBus.char_expression_changed.emit(character, last_expr)
		if _current_mode == "adv":
			_update_avatar(character, last_expr, "adv")


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


func _process_inline_effects(text: String) -> Dictionary:
	var clean: String = ""
	var effects: Array = []
	var i: int = 0
	var char_pos: int = 0

	while i < text.length():
		if text[i] == "{":
			var close = text.find("}", i)
			if close != -1:
				var tag = text.substr(i + 1, close - i - 1)
				var parts = tag.split(":")
				if parts.size() == 2:
					effects.append({
						"type": parts[0],
						"value": float(parts[1]),
						"pos": char_pos,
					})
				i = close + 1
				continue
		clean += text[i]
		char_pos += 1
		i += 1

	return {"text": clean, "effects": effects}


func _on_hide_dialogue():
	visible = false
	_nvl_text = ""
	_current_character = ""
	_voice_playing = false
	# Dialogue state — clear so the toolbar replay button hides
	_dialogue_segments = []
	_dialogue_voice_character = ""
	_dialogue_total_duration = 0.0
	# Playback session state — also reset. Bump the queue gen so any in-flight
	# voice queue coroutine (e.g. a backlog replay still running) sees the
	# mismatch on its next iteration and exits cleanly instead of leaking into
	# the next dialogue.
	_playback_queue_gen += 1
	_playback_queue_active = false
	_playback_aborted = false
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
		_avatar_container.visible = false
		_avatar_texture.texture = null
		return

	var config = _config_loader.get_config(character)

	if not config.has_avatar_rect():
		_current_character = ""
		_avatar_container.visible = false
		_avatar_texture.texture = null
		return

	# Load the character's expression sprite and crop via AtlasTexture
	var base_path = StellaRuntime.characters_path + "%s/" % character
	var sprite_path = _resolve_sprite_path(character, expression, config, base_path)
	if sprite_path == "" or not FileAccess.file_exists(sprite_path):
		if sprite_path != "":
			push_warning("DialoguePresenter: avatar sprite not found: %s" % sprite_path)
		_current_character = ""
		_avatar_container.visible = false
		_avatar_texture.texture = null
		return

	var source_tex = load(sprite_path) as Texture2D
	if source_tex == null:
		_current_character = ""
		_avatar_container.visible = false
		_avatar_texture.texture = null
		return

	_current_character = character
	var atlas = AtlasTexture.new()
	atlas.atlas = source_tex
	atlas.region = config.avatar_rect
	_avatar_texture.texture = atlas
	_avatar_container.visible = true


func _resolve_sprite_path(character: String, expression: String, config: CharacterConfig, base_path: String) -> String:
	if config.is_layered():
		# For layered mode, use the face sprite
		var face_file = config.get_face(expression)
		if face_file != "":
			return base_path + "%s.png" % face_file
		return ""
	else:
		return base_path + "%s.png" % expression


func _on_avatar_expression_changed(character: String, expression: String) -> void:
	_known_expressions[character] = expression
	if character == _current_character and _current_mode == "adv":
		_update_avatar(character, expression, "adv")


