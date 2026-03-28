## Displays dialogue text with typewriter effect.
## Supports ADV (bottom box), NVL (fullscreen accumulate), overlay modes.
## Handles inline expression switching via ExpressionTimeline.
extends PanelContainer

@onready var name_label: Label = %NameLabel
@onready var text_label: RichTextLabel = %TextLabel

var _char_interval: float = 0.03  # seconds per character
var _is_typing: bool = false
var _nvl_text: String = ""  # accumulated NVL text
var _current_mode: String = "adv"


func _ready():
	SignalBus.show_dialogue.connect(_on_show_dialogue)
	SignalBus.scenario_ended_event.connect(func(_id): visible = false)
	visible = false


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

	# NVL mode: accumulate text
	if mode == "nvl":
		if character != "":
			_nvl_text += "%s: %s\n" % [character, clean_text]
		else:
			_nvl_text += "%s\n" % clean_text
		name_label.visible = false
		text_label.text = _nvl_text
	elif mode == "overlay":
		name_label.visible = false
		text_label.text = clean_text
		modulate.a = 0.7
	else:
		_nvl_text = ""
		modulate.a = 1.0
		if character != "":
			name_label.text = character
			name_label.visible = true
		else:
			name_label.text = ""
			name_label.visible = false
		text_label.text = clean_text

	text_label.visible_characters = 0
	_is_typing = true

	# Typewriter effect with inline expression switching and effects
	var total_chars = clean_text.length()
	for i in range(total_chars):
		if not _is_typing:
			break

		text_label.visible_characters = i + 1

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
