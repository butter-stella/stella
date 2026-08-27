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
		if (
			StellaRuntime.game_state.is_playing()
			and _consume_movie_input(&"advance")
		):
			get_viewport().set_input_as_handled()
			return
		# The published full-screen clip is the foremost story-input owner. This
		# precedes choice, soft-hide, hovered GUI, Skip/Auto, and dialogue so one
		# physical click can never operate content hidden behind the clip.
		if (
			StellaRuntime.game_state.is_playing()
			and _consume_presentation_clip_advance()
		):
			get_viewport().set_input_as_handled()
			return
		# An active choice owns normal story input before hidden-dialogue,
		# typewriter, or wait-click fallbacks. Interactive controls still receive
		# the click through GUI propagation so an option or toolbar action remains
		# an explicit user selection/action.
		if StellaRuntime.is_choice_active():
			var choice_hovered = get_viewport().gui_get_hovered_control()
			if choice_hovered is Button or choice_hovered is Slider:
				return
			if not StellaRuntime.game_state.is_playing():
				return
			if StellaRuntime.is_skipping():
				StellaRuntime.skip_controller.stop()
				if dialogue:
					dialogue._ctrl_held = false
					dialogue._update_toggle_buttons()
					dialogue.cancel_pending_skip()
			elif StellaRuntime.auto_play.is_active:
				if StellaRuntime.get_setting("auto_play_click_interrupt"):
					StellaRuntime.auto_play.stop()
					if dialogue:
						dialogue._update_toggle_buttons()
			get_viewport().set_input_as_handled()
			return
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
			_handle_normal_advance(dialogue)
			return

		# Normal mode
		_handle_normal_advance(dialogue)

	elif event.button_index == MOUSE_BUTTON_RIGHT:
		if not StellaRuntime.game_state.is_playing():
			return
		if _consume_movie_input(&"right_click"):
			get_viewport().set_input_as_handled()
			return
		if StellaRuntime.can_execute_action(
			StellaActionRegistry.ACTION_HIDE_UI
		):
			StellaRuntime.execute_action(
				StellaActionRegistry.ACTION_HIDE_UI)
			get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventJoypadButton:
		_handle_joypad_advance(event)
		return
	if not event is InputEventKey:
		return
	var dialogue = _get_dialogue()
	# Ctrl release is unconditional cleanup. On press, a live movie is the
	# foremost modal owner even when a Choice is visible underneath it. Record
	# the central momentary intent before claiming the exact movie generation;
	# the consumed edge can never reach the Choice or next dialogue owner.
	if event.keycode == KEY_CTRL:
		if not event.pressed:
			if dialogue:
				dialogue._ctrl_held = false
				if not StellaRuntime.skip_controller.is_active:
					dialogue.cancel_pending_skip()
			return
		if (
			not event.echo
			and StellaRuntime.game_state.is_playing()
			and StellaRuntime.presentation_director != null
			and StellaRuntime.presentation_director.has_active_movie_owner()
		):
			if dialogue:
				dialogue._ctrl_held = true
			_consume_movie_input(&"skip")
			get_viewport().set_input_as_handled()
			return
	if (
		event.pressed
		and not event.echo
		and event.keycode in [KEY_SPACE, KEY_ENTER]
		and StellaRuntime.game_state.is_playing()
		and _consume_movie_input(&"advance")
	):
		get_viewport().set_input_as_handled()
		return
	if (
		event.pressed
		and not event.echo
		and event.keycode in [KEY_SPACE, KEY_ENTER, KEY_CTRL]
		and StellaRuntime.game_state.is_playing()
		and _consume_presentation_clip_advance()
	):
		get_viewport().set_input_as_handled()
		return
	# ui_accept on a focused option Button is consumed by GUI before reaching
	# _unhandled_input. Every remaining normal advance key is modal-owned and
	# cannot restore/complete/advance content behind the choice.
	if StellaRuntime.is_choice_active():
		if event.keycode == KEY_CTRL:
			if dialogue:
				dialogue._ctrl_held = false
				dialogue.cancel_pending_skip()
			if event.pressed and not event.echo:
				get_viewport().set_input_as_handled()
			return
		if (
			event.pressed
			and not event.echo
			and event.keycode in [KEY_SPACE, KEY_ENTER]
		):
			if StellaRuntime.game_state.is_playing():
				if _activate_focused_choice_option():
					return
				get_viewport().set_input_as_handled()
			return
	# Movie ownership was resolved before Choice. Remaining Ctrl presses retain
	# the established clip/choice/dialogue ordering.
	if event.keycode == KEY_CTRL:
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
		if _consume_presentation_clip_advance():
			get_viewport().set_input_as_handled()
			return
			# Ctrl pressed while text fully shown: advance immediately to start skipping
		if dialogue and not dialogue._is_typing:
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
		StellaRuntime.execute_action(StellaActionRegistry.ACTION_FLOWCHART)
		return
	if not StellaRuntime.game_state.is_playing():
		return
	if event.keycode == KEY_SPACE or event.keycode == KEY_ENTER:
		_handle_normal_advance(dialogue)


func _handle_joypad_advance(event: InputEventJoypadButton) -> void:
	if not event.pressed or event.button_index != JOY_BUTTON_A:
		return
	var dialogue = _get_dialogue()
	if (
		StellaRuntime.game_state.is_playing()
		and _consume_movie_input(&"advance")
	):
		get_viewport().set_input_as_handled()
		return
	if (
		StellaRuntime.game_state.is_playing()
		and _consume_presentation_clip_advance()
	):
		get_viewport().set_input_as_handled()
		return
	if StellaRuntime.is_choice_active():
		if StellaRuntime.game_state.is_playing():
			if _activate_focused_choice_option():
				return
			get_viewport().set_input_as_handled()
		return
	if _restore_soft_hidden_dialogue(dialogue):
		return
	if not StellaRuntime.game_state.is_playing():
		return
	_handle_normal_advance(dialogue)


func _get_dialogue():
	return get_node_or_null("%DialoguePanel")


## Ask only the focused option's presenter to translate ui_accept into its
## semantic activation. Walking ancestors keeps toolbar/unrelated Buttons on
## their native GUI path and avoids assuming the default ChoicePanel layout.
func _activate_focused_choice_option() -> bool:
	var focused := get_viewport().gui_get_focus_owner()
	if not focused is Button:
		return false
	var owner: Node = focused
	while owner != null:
		if owner.has_method("activate_focused_choice_option"):
			var activated := bool(
				owner.call("activate_focused_choice_option"))
			if activated:
				get_viewport().set_input_as_handled()
			return activated
		owner = owner.get_parent()
	return false


## Resolve one accepted normal advance event to exactly one owner/result, then
## stop propagation before synchronous completion can expose a new UI/owner to
## the tail of the same physical event.
func _handle_normal_advance(_dialogue) -> void:
	StellaRuntime.execute_action(StellaActionRegistry.ACTION_ADVANCE)
	get_viewport().set_input_as_handled()


## A movie is the foremost story-input owner. The Director resolves the exact
## typed receipt while the Presenter applies operation and settings policy.
func _consume_movie_input(kind: StringName) -> bool:
	return (
		StellaRuntime.presentation_director != null
		and StellaRuntime.presentation_director.consume_active_movie_input(kind)
	)


## A published clip is a modal presentation boundary even when its command was
## fire-and-forget. The one Runtime-owned Director synchronously claims every
## active projection: skippable clips finish, while unskippable clips consume
## the edge without mutating their bounded clock or the dialogue behind them.
func _consume_presentation_clip_advance() -> bool:
	return (
		StellaRuntime.presentation_director != null
		and StellaRuntime.presentation_director.consume_active_presentation_clip_input()
	)


func _request_dialogue_advance(_dialogue = null) -> void:
	StellaRuntime.execute_action(StellaActionRegistry.ACTION_ADVANCE)
	get_viewport().set_input_as_handled()


func _restore_soft_hidden_dialogue(_dialogue = null) -> bool:
	if not StellaRuntime.is_action_active(
		StellaActionRegistry.ACTION_HIDE_UI
	):
		return false
	if StellaRuntime.execute_action(
		StellaActionRegistry.ACTION_HIDE_UI
	) != StellaActionRegistry.ExecuteResult.EXECUTED:
		return false
	get_viewport().set_input_as_handled()
	return true
