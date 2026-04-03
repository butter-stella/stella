## Handles dialogue advance, typing completion, and UI toggle.
##
## Mouse via _input (GUI mouse_filter blocks _unhandled_input for mouse).
## Keyboard via _unhandled_input (not affected by mouse_filter).
##
## Mouse advance uses _process to defer until after GUI:
##   _input sets _advance_pending → GUI processes buttons →
##   button emits toolbar_button_pressed → _process checks flags.
extends Node

var _advance_pending := false
var _button_pressed := false


func _ready():
	SignalBus.toolbar_button_pressed.connect(_on_toolbar_button)


func _on_toolbar_button():
	_button_pressed = true


func _input(event: InputEvent) -> void:
	if not event is InputEventMouseButton or not event.pressed:
		return

	var dialogue = _get_dialogue()

	if event.button_index == MOUSE_BUTTON_LEFT:
		if dialogue and dialogue._is_typing:
			dialogue._is_typing = false
			dialogue.text_label.visible_characters = -1
			get_viewport().set_input_as_handled()
		elif dialogue and dialogue._ui_hidden:
			dialogue._ui_hidden = false
			dialogue.visible = true
			get_viewport().set_input_as_handled()
		elif NatsumeRuntime.game_state.is_playing():
			_advance_pending = true
			_button_pressed = false

	elif event.button_index == MOUSE_BUTTON_RIGHT:
		if not NatsumeRuntime.game_state.is_playing():
			return
		if dialogue:
			if dialogue._ui_hidden:
				dialogue._ui_hidden = false
				dialogue.visible = true
			elif dialogue.visible and not dialogue._is_typing:
				dialogue._ui_hidden = true
				dialogue.visible = false


func _process(_delta: float) -> void:
	if not _advance_pending:
		return
	_advance_pending = false
	if _button_pressed:
		_button_pressed = false
		return
	if NatsumeRuntime.game_state.is_playing():
		SignalBus.advance_requested.emit()


func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	if not NatsumeRuntime.game_state.is_playing():
		return
	if event.keycode == KEY_SPACE or event.keycode == KEY_ENTER:
		var dialogue = _get_dialogue()
		if dialogue and dialogue._is_typing:
			dialogue._is_typing = false
			dialogue.text_label.visible_characters = -1
		else:
			SignalBus.advance_requested.emit()
	elif event.keycode == KEY_CTRL:
		var dialogue = _get_dialogue()
		if dialogue:
			dialogue._ctrl_held = event.pressed


func _get_dialogue():
	return get_node_or_null("%DialoguePanel")
