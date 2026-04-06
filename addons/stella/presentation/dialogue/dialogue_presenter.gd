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
var _combine_aborted: bool = false  # set when user clicks to skip a combine typewriter
var _combine_queue_active: bool = false  # true while the combine voice-queue coroutine is running
var _combine_queue_gen: int = 0  # bumped to cancel an in-flight queue (e.g. replay restart)
var _current_combine_segments: Array = []  # snapshot for replay button


func _ready():
	SignalBus.show_dialogue.connect(_on_show_dialogue)
	SignalBus.show_dialogue_combined.connect(_on_show_dialogue_combined)
	SignalBus.hide_dialogue.connect(_on_hide_dialogue)
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
	if _current_combine_segments.size() > 0:
		_replay_combine_voices()
	elif _current_voice != "":
		SignalBus.voice_play.emit(_current_voice, _current_voice_character)


func _replay_combine_voices() -> void:
	# Restart the voice queue with the stored segments. _run_combine_voice_queue
	# bumps its own internal generation to cancel any in-flight queue coroutine,
	# leaving _dialogue_gen (and any auto-play/advance await) untouched.
	_combine_aborted = false
	_run_combine_voice_queue(_current_voice_character, _current_combine_segments, _dialogue_gen)


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


func _on_show_dialogue(character: String, text: String, voice: String, mode: String):
	if _ui_hidden:
		return

	_dialogue_gen += 1
	var gen = _dialogue_gen
	_current_combine_segments = []  # clear combine state when a normal dialogue starts

	# Trigger voice playback (suppress during skip — no point playing voice
	# for lines that are shown for only ~50ms)
	_current_voice_character = character
	if voice != "" and not _is_skipping():
		_current_voice = voice
		SignalBus.voice_play.emit(voice, character)
	else:
		_current_voice = voice if voice != "" else ""

	if _voice_replay_btn:
		_voice_replay_btn.visible = (voice != "")

	visible = true
	_current_mode = mode

	if toolbar:
		toolbar.visible = (mode == "adv")

	# Extract inline expression markers
	var timeline = ExpressionTimeline.new()
	var result = timeline.extract_from_text(text)
	var clean_text: String = result["clean_text"]
	timeline.markers = result["markers"]

	# Handle inline effects
	var processed = _process_inline_effects(clean_text)
	clean_text = processed["text"]
	var effects = processed["effects"]

	# Prepare display based on mode
	var new_line_text: String = ""

	if mode == "nvl":
		_apply_nvl_layout()
		name_label.visible = false
		if character != "":
			new_line_text = "%s：%s" % [character, clean_text]
		else:
			new_line_text = clean_text
		var full_text = _nvl_text + new_line_text
		text_label.text = full_text
		var old_char_count = _nvl_text.length()
		text_label.visible_characters = old_char_count
		_nvl_text = full_text + "\n"

	elif mode == "overlay":
		_apply_overlay_layout()
		name_label.visible = false
		new_line_text = clean_text
		text_label.text = clean_text
		text_label.visible_characters = 0

	else:  # adv
		_apply_adv_layout()
		_nvl_text = ""
		new_line_text = clean_text
		if character != "":
			name_label.text = character
			name_label.visible = true
		else:
			name_label.text = ""
			name_label.visible = false
		text_label.text = clean_text
		text_label.visible_characters = 0

	# Update avatar for the speaking character
	var expression = _known_expressions.get(character, "default")
	_update_avatar(character, expression, mode)

	await get_tree().process_frame
	_is_typing = true

	# Skip mode: show all text immediately
	if _is_skipping():
		text_label.visible_characters = -1
		_is_typing = false
		await get_tree().create_timer(StellaRuntime.get_setting("skip_interval") / 1000.0).timeout
		SignalBus.advance_requested.emit()
		return

	# Typewriter effect
	var start_visible = text_label.visible_characters
	var total_new_chars = new_line_text.length()
	for i in range(total_new_chars):
		if not _is_typing:
			break
		# Check if skip activated mid-typewriter
		if _is_skipping():
			text_label.visible_characters = -1
			_is_typing = false
			await get_tree().create_timer(StellaRuntime.get_setting("skip_interval") / 1000.0).timeout
			SignalBus.advance_requested.emit()
			return

		text_label.visible_characters = start_visible + i + 1

		var expr = timeline.get_expression_at_char(i)
		if expr != "" and character != "":
			SignalBus.char_expression_changed.emit(character, expr)

		var delay = _char_interval
		for effect in effects:
			if effect["pos"] == i:
				if effect["type"] == "wait":
					await get_tree().create_timer(effect["value"] / 1000.0).timeout
				elif effect["type"] == "speed":
					delay = effect["value"] / 1000.0

		await get_tree().create_timer(delay).timeout

	text_label.visible_characters = -1
	_is_typing = false

	# Auto-play: wait for voice (if configured) then delay then advance.
	# gen check: if a manual click advanced to the next dialogue while we
	# were waiting, _dialogue_gen will have changed — abort this coroutine.
	if StellaRuntime.is_auto_playing():
		if StellaRuntime.get_setting("auto_play_wait_voice") and _voice_playing:
			await SignalBus.voice_finished
			if gen != _dialogue_gen:
				return
		var delay = StellaRuntime.get_setting("auto_play_delay")
		await get_tree().create_timer(delay).timeout
		if gen != _dialogue_gen:
			return
		if StellaRuntime.is_auto_playing():
			SignalBus.advance_requested.emit()


## Combined dialogue from @combine block.
## Typewriter runs continuously over concatenated text; voices play sequentially;
## expression switches at each segment boundary (driven by voice_finished).
## Click during typewriter: abort typewriter + voice queue, snap to final segment's expression.
func _on_show_dialogue_combined(character: String, segments: Array, mode: String) -> void:
	if _ui_hidden or segments.size() == 0:
		return

	_dialogue_gen += 1
	var gen = _dialogue_gen
	_combine_aborted = false
	_current_combine_segments = segments.duplicate(true)

	# Pre-compute concatenated text for typewriter / backlog
	var full_text := ""
	for seg in segments:
		full_text += String(seg.get("text", ""))

	_current_voice_character = character
	var first_voice := String(segments[0].get("voice", ""))
	_current_voice = first_voice
	if _voice_replay_btn:
		_voice_replay_btn.visible = (first_voice != "")

	visible = true
	_current_mode = mode

	if toolbar:
		toolbar.visible = (mode == "adv")

	# Combined dialogue: ADV mode only (fall through for other modes using concat text)
	if mode == "nvl":
		_apply_nvl_layout()
		name_label.visible = false
		var line_text: String = (character + "：" + full_text) if character != "" else full_text
		var combined = _nvl_text + line_text
		text_label.text = combined
		text_label.visible_characters = _nvl_text.length()
		_nvl_text = combined + "\n"
	elif mode == "overlay":
		_apply_overlay_layout()
		name_label.visible = false
		text_label.text = full_text
		text_label.visible_characters = 0
	else:  # adv
		_apply_adv_layout()
		_nvl_text = ""
		if character != "":
			name_label.text = character
			name_label.visible = true
		else:
			name_label.visible = false
		text_label.text = full_text
		text_label.visible_characters = 0

	# Update avatar based on first segment's expression (will be set by queue),
	# otherwise fall back to current known expression.
	var first_expr := String(segments[0].get("expression", ""))
	var avatar_expr = first_expr if first_expr != "" else String(_known_expressions.get(character, "default"))
	_update_avatar(character, avatar_expr, mode)

	# Launch voice-queue coroutine. It owns ALL segment voice playback and expression
	# switching (including segment 0) so empty-voice segments can't hang the queue.
	_run_combine_voice_queue(character, segments, gen)

	await get_tree().process_frame
	_is_typing = true

	# Skip mode: show all text immediately and snap to final state
	if _is_skipping():
		text_label.visible_characters = -1
		_is_typing = false
		_finalize_combine(character, segments)
		await get_tree().create_timer(StellaRuntime.get_setting("skip_interval") / 1000.0).timeout
		SignalBus.advance_requested.emit()
		return

	# Typewriter over concatenated text
	var start_visible = text_label.visible_characters
	var total_chars = full_text.length() - start_visible
	for i in range(total_chars):
		if not _is_typing:
			break
		if _is_skipping():
			text_label.visible_characters = -1
			_is_typing = false
			_finalize_combine(character, segments)
			await get_tree().create_timer(StellaRuntime.get_setting("skip_interval") / 1000.0).timeout
			SignalBus.advance_requested.emit()
			return
		text_label.visible_characters = start_visible + i + 1
		await get_tree().create_timer(_char_interval).timeout
		if gen != _dialogue_gen:
			return

	# If typewriter was aborted by user click (input_handler sets _is_typing = false
	# and visible_characters = -1), snap to final segment state.
	if _combine_aborted == false and not _is_typing and text_label.visible_characters == -1:
		_finalize_combine(character, segments)

	text_label.visible_characters = -1
	_is_typing = false

	# Auto-play: wait for all segment voices to finish, then advance
	if StellaRuntime.is_auto_playing():
		if StellaRuntime.get_setting("auto_play_wait_voice"):
			# Wait until the voice queue coroutine has drained all segments
			while _combine_queue_active and not _combine_aborted:
				await get_tree().process_frame
				if gen != _dialogue_gen:
					return
			# And wait for the current (final) voice to finish naturally
			if _voice_playing:
				await SignalBus.voice_finished
				if gen != _dialogue_gen:
					return
		var delay = StellaRuntime.get_setting("auto_play_delay")
		await get_tree().create_timer(delay).timeout
		if gen != _dialogue_gen:
			return
		if StellaRuntime.is_auto_playing():
			SignalBus.advance_requested.emit()


func _run_combine_voice_queue(character: String, segments: Array, gen: int) -> void:
	# Plays all segment voices sequentially. Owns seg[0] too so a missing/empty
	# voice on any segment can't hang the queue. Between segments, awaits
	# voice_finished iff the previous segment actually played a voice.
	_combine_queue_gen += 1
	var q_gen = _combine_queue_gen
	_combine_queue_active = true
	var prev_had_voice := false
	for i in range(segments.size()):
		if prev_had_voice:
			await SignalBus.voice_finished
			if q_gen != _combine_queue_gen or gen != _dialogue_gen or _combine_aborted:
				if q_gen == _combine_queue_gen:
					_combine_queue_active = false
				return
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
	if q_gen == _combine_queue_gen:
		_combine_queue_active = false


func _finalize_combine(character: String, segments: Array) -> void:
	# User aborted typewriter (or skip mode) — snap expression to the final segment
	# and cancel the voice queue progression.
	_combine_aborted = true
	if segments.size() == 0:
		return
	var last_seg = segments[segments.size() - 1]
	var last_expr := String(last_seg.get("expression", ""))
	if last_expr != "" and character != "":
		SignalBus.char_expression_changed.emit(character, last_expr)
		if _current_mode == "adv":
			_update_avatar(character, last_expr, "adv")



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
	_current_combine_segments = []
	_combine_aborted = false
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


