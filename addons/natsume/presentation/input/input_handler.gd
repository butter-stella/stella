## Handles dialogue advance, typing completion, and UI toggle.
##
## _input: left-click during typing → complete text + consume (must preempt GUI).
## _unhandled_input: all other interactions (advance, right-click, keyboard).
extends Node


func _input(event: InputEvent) -> void:
	if not event is InputEventMouseButton or not event.pressed:
		return
	if event.button_index != MOUSE_BUTTON_LEFT:
		return
	var dialogue = _get_dialogue()
	if dialogue == null:
		return
	if dialogue._is_typing:
		dialogue._is_typing = false
		dialogue.text_label.visible_characters = -1
		get_viewport().set_input_as_handled()
	elif dialogue._ui_hidden:
		dialogue._ui_hidden = false
		dialogue.visible = true
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if not NatsumeRuntime.game_state.is_playing():
		return

	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			SignalBus.advance_requested.emit()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_toggle_ui_visibility()

	elif event is InputEventKey and event.pressed and not event.echo:
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


func _toggle_ui_visibility() -> void:
	var dialogue = _get_dialogue()
	if dialogue == null:
		return
	if dialogue._ui_hidden:
		dialogue._ui_hidden = false
		dialogue.visible = true
	elif dialogue.visible and not dialogue._is_typing:
		dialogue._ui_hidden = true
		dialogue.visible = false


func _get_dialogue():
	return get_node_or_null("%DialoguePanel")
