## Backlog screen — displays dialogue history in a scrollable list.
## Loaded as overlay by NatsumeRuntime, closed with ESC or right-click.
extends PanelContainer

@onready var scroll: ScrollContainer = %BacklogScroll
@onready var entries_container: VBoxContainer = %BacklogEntries


func _ready():
	_populate()
	# Scroll to bottom
	await get_tree().process_frame
	scroll.scroll_vertical = scroll.get_v_scroll_bar().max_value


func _close():
	NatsumeRuntime.close_overlay()


func _populate():
	for child in entries_container.get_children():
		child.queue_free()

	var entries = NatsumeRuntime.get_backlog()
	for entry in entries:
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

		# Dialogue text
		var text_label = Label.new()
		text_label.text = entry["text"]
		text_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		text_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hbox.add_child(text_label)

		entries_container.add_child(hbox)

		# Separator
		var sep = HSeparator.new()
		sep.add_theme_constant_override("separation", 4)
		entries_container.add_child(sep)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ESCAPE:
			_close()
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_close()
	# Consume all input so game scene does not receive it
	get_viewport().set_input_as_handled()
