## Handles dialogue advance, typing completion, and UI toggle.
##
## Mouse via _input — checks gui_get_hovered_control() to skip when
## clicking on interactive Controls (buttons, sliders, etc.).
## Keyboard via _unhandled_input (not affected by mouse_filter).
extends Node


func _input(event: InputEvent) -> void:
	if not event is InputEventMouseButton or not event.pressed:
		return

	var dialogue = _get_dialogue()

	if event.button_index == MOUSE_BUTTON_LEFT:
		# Typing: complete text immediately, consume event (block buttons too)
		if dialogue and dialogue._is_typing:
			dialogue._is_typing = false
			dialogue.text_label.visible_characters = -1
			get_viewport().set_input_as_handled()
			return
		# UI hidden: restore
		if dialogue and dialogue._ui_hidden:
			dialogue._ui_hidden = false
			dialogue.visible = true
			get_viewport().set_input_as_handled()
			return
		# Skip if clicking on an interactive Control (button, slider, etc.)
		var hovered = get_viewport().gui_get_hovered_control()
		if hovered is Button or hovered is Slider:
			return
		# Advance dialogue
		if NatsumeRuntime.game_state.is_playing():
			SignalBus.advance_requested.emit()

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


func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventKey:
		return
	# Ctrl tracks press AND release — must not be blocked by pressed/echo guard
	if event.keycode == KEY_CTRL:
		var dialogue = _get_dialogue()
		if dialogue:
			dialogue._ctrl_held = event.pressed
			# Ctrl pressed while text fully shown: advance immediately to start skipping
			if event.pressed and not dialogue._is_typing:
				SignalBus.advance_requested.emit()
		return
	if not event.pressed or event.echo:
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


func _get_dialogue():
	return get_node_or_null("%DialoguePanel")
