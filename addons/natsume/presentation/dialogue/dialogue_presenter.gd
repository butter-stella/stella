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

## Icon paths — set these to customize toolbar button icons.
var toolbar_icons: Dictionary = {
	"voice_replay": "", "auto": "", "skip": "", "backlog": "",
	"quick_save": "", "quick_load": "",
	"save": "", "load": "", "settings": "",
}
var _voice_replay_btn: Button
var _auto_btn: Button
var _skip_btn: Button


func _ready():
	SignalBus.show_dialogue.connect(_on_show_dialogue)
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
	_config_loader = NatsumeRuntime.character_config_loader
	_avatar_container = get_node_or_null("%AvatarContainer")
	if _avatar_container:
		_avatar_texture = _avatar_container.get_node_or_null("AvatarTexture")
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
	if _current_voice != "":
		SignalBus.voice_play.emit(_current_voice, _current_voice_character)


func _on_auto_pressed():
	NatsumeRuntime.toggle_auto_play()
	_update_toggle_buttons()


func _on_skip_pressed():
	NatsumeRuntime.toggle_skip()
	_update_toggle_buttons()


func _on_backlog_pressed():
	NatsumeRuntime.show_backlog()


func _on_quick_save_pressed():
	NatsumeRuntime.quick_save()


func _on_quick_load_pressed():
	NatsumeRuntime.quick_load()


func _on_save_pressed():
	NatsumeRuntime.show_save_load("save")


func _on_load_pressed():
	NatsumeRuntime.show_save_load("load")


func _on_settings_pressed():
	NatsumeRuntime.show_settings()


func _is_toggle_active(btn_id: String) -> bool:
	match btn_id:
		"auto": return NatsumeRuntime.is_auto_playing()
		"skip": return NatsumeRuntime.is_skipping()
	return false


func _update_button_modulate(btn: Button, btn_id: String):
	btn.modulate = Color.YELLOW if _is_toggle_active(btn_id) else Color.WHITE


func _update_toggle_buttons():
	if _auto_btn:
		_update_button_modulate(_auto_btn, "auto")
	if _skip_btn:
		_update_button_modulate(_skip_btn, "skip")


func _is_skipping() -> bool:
	return NatsumeRuntime.is_skipping() or _ctrl_held


func _on_show_dialogue(character: String, text: String, voice: String, mode: String):
	if _ui_hidden:
		return

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
		await get_tree().create_timer(NatsumeRuntime.get_setting("skip_interval") / 1000.0).timeout
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
			await get_tree().create_timer(NatsumeRuntime.get_setting("skip_interval") / 1000.0).timeout
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

	# Auto-play: wait for voice (if configured) then delay then advance
	if NatsumeRuntime.is_auto_playing():
		if NatsumeRuntime.get_setting("auto_play_wait_voice") and _voice_playing:
			await SignalBus.voice_finished
		var delay = NatsumeRuntime.get_setting("auto_play_delay")
		await get_tree().create_timer(delay).timeout
		if NatsumeRuntime.is_auto_playing():
			SignalBus.advance_requested.emit()





func _apply_nvl_layout():
	anchor_left = 0.1
	anchor_top = 0.1
	anchor_right = 0.9
	anchor_bottom = 0.9
	offset_left = 0
	offset_top = 0
	offset_right = 0
	offset_bottom = 0
	modulate.a = 0.9


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
	var base_path = NatsumeRuntime.characters_path + "%s/" % character
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
