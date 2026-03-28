## Displays dialogue text with typewriter effect.
## Supports ADV (bottom box), NVL (fullscreen accumulate), overlay modes.
## Handles inline expression switching via ExpressionTimeline.
extends PanelContainer

@onready var name_label: Label = %NameLabel
@onready var text_label: RichTextLabel = %TextLabel

var _char_interval: float = 0.03  # seconds per character
var _is_typing: bool = false
var _nvl_text: String = ""  # accumulated NVL text (already shown)
var _current_mode: String = "adv"

# Store original anchors for switching between ADV and NVL layout
var _adv_anchor_top: float
var _adv_offset_top: float


func _ready():
	SignalBus.show_dialogue.connect(_on_show_dialogue)
	SignalBus.scenario_ended_event.connect(func(_id): visible = false)
	visible = false
	# Save ADV layout values
	_adv_anchor_top = anchor_top
	_adv_offset_top = offset_top


func _on_show_dialogue(character: String, text: String, _voice: String, mode: String):
	visible = true
	_current_mode = mode

	# Extract inline expression markers
	var timeline = ExpressionTimeline.new()
	var result = timeline.extract_from_text(text)
	var clean_text: String = result["clean_text"]
	timeline.markers = result["markers"]

	# Handle inline effects {wait:500} {speed:0.3}
	var processed = _process_inline_effects(clean_text)
	clean_text = processed["text"]
	var effects = processed["effects"]

	# Prepare display based on mode
	var new_line_text: String = ""

	if mode == "nvl":
		_apply_nvl_layout()
		name_label.visible = false
		# Build the new line
		if character != "":
			new_line_text = "%s：%s" % [character, clean_text]
		else:
			new_line_text = clean_text
		# Full text = old accumulated + new line
		var full_text = _nvl_text + new_line_text
		text_label.text = full_text
		# Only typewrite the new portion — show old text instantly
		var old_char_count = _nvl_text.length()
		text_label.visible_characters = old_char_count
		# After typewriter completes, add newline to accumulated
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

	_is_typing = true

	# Typewriter effect — only for the new text portion
	var start_visible = text_label.visible_characters
	var total_new_chars = new_line_text.length()
	for i in range(total_new_chars):
		if not _is_typing:
			break

		text_label.visible_characters = start_visible + i + 1

		# Check expression timeline
		var expr = timeline.get_expression_at_char(i)
		if expr != "" and character != "":
			SignalBus.char_expression_changed.emit(character, expr)

		# Check inline effects at this position
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


func _unhandled_input(event: InputEvent) -> void:
	if _is_typing and event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_is_typing = false
			text_label.visible_characters = -1
			get_viewport().set_input_as_handled()


func _apply_nvl_layout():
	# Fullscreen centered layout for NVL mode
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
	# Centered, semi-transparent overlay
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
	# Restore bottom dialogue box
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
