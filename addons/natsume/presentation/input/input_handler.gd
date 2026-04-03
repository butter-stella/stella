## Handles dialogue advance, typing completion, and UI toggle.
##
## _input captures all mouse events before GUI:
##   - Typing in progress → complete text, consume event (blocks buttons & advance)
##   - UI hidden → restore UI, consume event
##   - Otherwise → defer advance to end of frame (after GUI processes buttons)
##
## _unhandled_input handles keyboard (not blocked by GUI mouse_filter).
extends Node

var _advance_pending := false


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
		else:
			# Defer advance — GUI processes buttons first, then we check state
			_advance_pending = true
			call_deferred("_deferred_advance")

	elif event.button_index == MOUSE_BUTTON_RIGHT:
		if dialogue:
			if dialogue._ui_hidden:
				dialogue._ui_hidden = false
				dialogue.visible = true
			elif dialogue.visible and not dialogue._is_typing:
				dialogue._ui_hidden = true
				dialogue.visible = false
		get_viewport().set_input_as_handled()


func _deferred_advance() -> void:
	if not _advance_pending:
		return
	_advance_pending = false
	# After GUI processed: if a button changed state (opened overlay etc.), skip
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
