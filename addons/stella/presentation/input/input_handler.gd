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
				dialogue.cancel_pending_skip()
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
			if dialogue and dialogue.complete_typewriter():
				get_viewport().set_input_as_handled()
				return
			_request_dialogue_advance(dialogue)
			get_viewport().set_input_as_handled()
			return

		# Normal mode
		if dialogue and dialogue.complete_typewriter():
			get_viewport().set_input_as_handled()
			return

		_request_dialogue_advance(dialogue)

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
	# Ctrl release is cleanup and remains unconditional. Ctrl press, however,
	# must not reach the dialogue beneath a system overlay.
	if event.keycode == KEY_CTRL:
		if not event.pressed:
			if dialogue:
				dialogue._ctrl_held = false
				if not StellaRuntime.skip_controller.is_active:
					dialogue.cancel_pending_skip()
			return
		if not StellaRuntime.game_state.is_playing():
			# Do not preserve a stale held flag if an overlay opened while Ctrl
			# was already down; the underlying typewriter must remain untouched.
			if dialogue:
				dialogue._ctrl_held = false
				if not StellaRuntime.skip_controller.is_active:
					dialogue.cancel_pending_skip()
			return
		if event.echo:
			return
		if _restore_soft_hidden_dialogue(dialogue):
			return
		if dialogue:
			dialogue._ctrl_held = true
			# Ctrl pressed while text fully shown: advance immediately to start skipping
			if not dialogue._is_typing:
				_request_dialogue_advance(dialogue)
		return
	# Keyboard restore mirrors the hidden-state left click: the restoring key is
	# consumed and must never also advance the scenario.
	if (event.pressed and not event.echo
		and event.keycode in [KEY_SPACE, KEY_ENTER]
		and _restore_soft_hidden_dialogue(dialogue)):
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
		_handle_normal_advance(dialogue)


func _get_dialogue():
	return get_node_or_null("%DialoguePanel")


func _request_dialogue_advance(dialogue) -> void:
	if dialogue != null and dialogue.has_method("request_current_dialogue_advance"):
		if bool(dialogue.request_current_dialogue_advance()):
			get_viewport().set_input_as_handled()
			return
	# Compatibility for custom scenes that still expose only the legacy global
	# input notification, and for non-dialogue blockers such as @wait click.
	# New DialogueHandler commands require request.advance().
	SignalBus.emit_advance_requested()
	get_viewport().set_input_as_handled()


func _handle_normal_advance(dialogue) -> void:
	if dialogue and dialogue.complete_typewriter():
		get_viewport().set_input_as_handled()
		return
	_request_dialogue_advance(dialogue)


func _restore_soft_hidden_dialogue(dialogue) -> bool:
	if (
		dialogue == null
		or not dialogue._ui_hidden
		or not StellaRuntime.game_state.is_playing()
	):
		return false
	dialogue._ui_hidden = false
	dialogue.visible = true
	get_viewport().set_input_as_handled()
	return true
