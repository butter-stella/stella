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
		# UI hidden: restore
		if _restore_soft_hidden_dialogue(dialogue):
			return
		# Skip if clicking on an interactive Control (button, slider, etc.)
		var hovered = get_viewport().gui_get_hovered_control()
		if hovered is Button or hovered is Slider:
			return

		if not StellaRuntime.game_state.is_playing():
			return

		# Skip mode: click stops skip
		if StellaRuntime.is_skipping():
			StellaRuntime.skip_controller.stop()
			if dialogue:
				dialogue._ctrl_held = false
				dialogue._update_toggle_buttons()
			get_viewport().set_input_as_handled()
			return

		# Auto mode: special click handling
		if StellaRuntime.is_auto_playing():
			if not StellaRuntime.get_setting("auto_play_click_interrupt"):
				# Setting disabled: ignore clicks entirely during auto
				get_viewport().set_input_as_handled()
				return
			# Setting enabled: stop auto mode
			StellaRuntime.auto_play.stop()
			if dialogue:
				dialogue._update_toggle_buttons()
			if dialogue and dialogue._is_typing:
				dialogue.complete_current_dialogue()
				get_viewport().set_input_as_handled()
				return
			if dialogue:
				dialogue.finalize_current_dialogue_for_advance()
			SignalBus.advance_requested.emit()
			get_viewport().set_input_as_handled()
			return

		# Normal mode
		if dialogue and dialogue._is_typing:
			dialogue.complete_current_dialogue()
			get_viewport().set_input_as_handled()
			return

		if dialogue:
			dialogue.finalize_current_dialogue_for_advance()
		SignalBus.advance_requested.emit()

	elif event.button_index == MOUSE_BUTTON_RIGHT:
		if not StellaRuntime.game_state.is_playing():
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
	var dialogue = _get_dialogue()
	# Keyboard restore mirrors the hidden-state left click: the restoring key is
	# consumed and must never also advance the scenario or start Ctrl skipping.
	if (event.pressed and not event.echo
		and event.keycode in [KEY_SPACE, KEY_ENTER, KEY_CTRL]
		and _restore_soft_hidden_dialogue(dialogue)):
		return
	# Ctrl tracks press AND release — must not be blocked by pressed/echo guard
	if event.keycode == KEY_CTRL:
		if dialogue:
			dialogue._ctrl_held = event.pressed
			# Ctrl pressed while text fully shown: advance immediately to start skipping
			if event.pressed and not dialogue._is_typing:
				dialogue.finalize_current_dialogue_for_advance()
				SignalBus.advance_requested.emit()
		return
	if not event.pressed or event.echo:
		return
	# F9: open flowchart overlay (issue #97). Works from PLAYING state only.
	if event.keycode == KEY_F9:
		if StellaRuntime.game_state.is_playing() and StellaRuntime.scenario_graph != null:
			StellaRuntime.show_flowchart()
		return
	if not StellaRuntime.game_state.is_playing():
		return
	if event.keycode == KEY_SPACE or event.keycode == KEY_ENTER:
		if dialogue and dialogue._is_typing:
			dialogue.complete_current_dialogue()
		else:
			if dialogue:
				dialogue.finalize_current_dialogue_for_advance()
			SignalBus.advance_requested.emit()


func _get_dialogue():
	return get_node_or_null("%DialoguePanel")


func _restore_soft_hidden_dialogue(dialogue) -> bool:
	if dialogue == null or not dialogue._ui_hidden:
		return false
	dialogue._ui_hidden = false
	dialogue.visible = true
	get_viewport().set_input_as_handled()
	return true
