## Backlog screen — displays dialogue history in a scrollable list.
## Loaded as overlay by StellaRuntime, closed with ESC or right-click.
extends PanelContainer

@onready var scroll: ScrollContainer = %BacklogScroll
@onready var entries_container: VBoxContainer = %BacklogEntries


func _ready():
	_populate()
	# Scroll to bottom
	await get_tree().process_frame
	scroll.scroll_vertical = scroll.get_v_scroll_bar().max_value


func _close():
	StellaRuntime.close_overlay()


func _on_entry_clicked(index: int) -> void:
	StellaRuntime.jump_from_backlog(index)


func _populate():
	for child in entries_container.get_children():
		child.queue_free()

	var entries = StellaRuntime.get_backlog()
	for i in range(entries.size()):
		var entry = entries[i]
		var hbox = HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 12)

		# Character name
		var name_label = Label.new()
		if entry["character"] != "":
			name_label.text = entry["character"]
			name_label.add_theme_color_override("font_color", Color(1.0, 0.72, 0.77))
		else:
			name_label.text = ""
		name_label.custom_minimum_size = Vector2(100, 0)
		hbox.add_child(name_label)

		# Dialogue text — wrapped in a flat Button so the user can click
		# anywhere on the line to jump to that point in the scenario.
		var text_btn = Button.new()
		text_btn.text = entry["text"]
		text_btn.flat = true
		text_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		text_btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		text_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		var jump_index = i
		text_btn.pressed.connect(func(): _on_entry_clicked(jump_index))
		hbox.add_child(text_btn)

		# Voice replay button — delegates to DialoguePresenter via SignalBus so
		# the playback uses the same voice queue + progress bar as the in-game
		# toolbar replay, AND the playback state lives in the always-present
		# DialoguePresenter (closing the backlog overlay does NOT cancel audio).
		var entry_voices: Array = entry.get("voices", [])
		var entry_char = entry.get("character", "")
		if entry_voices.size() > 0 and StellaRuntime.get_setting("voice_replay_on_backlog") != false:
			var replay_btn = Button.new()
			replay_btn.text = "▶"
			replay_btn.flat = true
			replay_btn.custom_minimum_size = Vector2(32, 0)
			replay_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			var voices_snapshot = entry_voices.duplicate()
			replay_btn.pressed.connect(func():
				SignalBus.dialogue_voice_replay_requested.emit(voices_snapshot, entry_char)
			)
			hbox.add_child(replay_btn)

		entries_container.add_child(hbox)

		# Separator
		var sep = HSeparator.new()
		sep.add_theme_constant_override("separation", 4)
		entries_container.add_child(sep)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_close()
		accept_event()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ESCAPE:
			_close()
			get_viewport().set_input_as_handled()
