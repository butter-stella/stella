## Displays dialogue text with typewriter effect.
## Subscribes to SignalBus.show_dialogue.
extends PanelContainer

@onready var name_label: Label = %NameLabel
@onready var text_label: RichTextLabel = %TextLabel

var _char_interval: float = 0.03  # seconds per character
var _is_typing: bool = false


func _ready():
	SignalBus.show_dialogue.connect(_on_show_dialogue)
	SignalBus.scenario_ended_event.connect(func(_id): visible = false)
	visible = false


func _on_show_dialogue(character: String, text: String, _voice: String, _mode: String):
	visible = true

	if character != "":
		name_label.text = character
		name_label.visible = true
	else:
		name_label.text = ""
		name_label.visible = false

	text_label.text = text
	text_label.visible_characters = 0
	_is_typing = true

	# Typewriter effect
	var total_chars = text.length()
	for i in range(total_chars):
		if not _is_typing:
			break
		text_label.visible_characters = i + 1
		await get_tree().create_timer(_char_interval).timeout

	# Show all text when done
	text_label.visible_characters = -1
	_is_typing = false


func _unhandled_input(event: InputEvent) -> void:
	# Click during typing → show all text immediately
	if _is_typing and event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_is_typing = false
			text_label.visible_characters = -1
			get_viewport().set_input_as_handled()
