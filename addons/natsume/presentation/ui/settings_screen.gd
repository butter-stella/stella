## Settings screen — sliders and toggles for game configuration.
extends PanelContainer

@onready var settings_container: VBoxContainer = %SettingsContainer


func _ready():
	NatsumeRuntime.game_state.state_changed.connect(_on_state_changed)
	visible = false


func _on_state_changed(_from: int, to: int):
	if to == GameStateMachine.State.SETTINGS:
		_show()
	elif visible:
		_hide_screen()


func _show():
	visible = true
	_build_ui()


func _hide_screen():
	visible = false
	NatsumeRuntime.settings_manager.save()
	NatsumeRuntime.game_state.return_to_previous()


func _build_ui():
	for child in settings_container.get_children():
		child.queue_free()

	var s = NatsumeRuntime.settings_manager.settings

	# Title
	var title = Label.new()
	title.text = "设置"
	title.add_theme_font_size_override("font_size", 28)
	settings_container.add_child(title)
	settings_container.add_child(HSeparator.new())

	# Text speed
	_add_slider("文字速度", s.character_interval, 0, 100, func(val):
		NatsumeRuntime.settings_manager.set_value("character_interval", int(val))
	)

	# Auto play delay
	_add_slider("自动播放延迟（秒）", s.auto_play_delay * 10, 5, 50, func(val):
		NatsumeRuntime.settings_manager.set_value("auto_play_delay", val / 10.0)
	)

	settings_container.add_child(HSeparator.new())

	# BGM volume
	_add_slider("BGM 音量", s.bgm_volume * 100, 0, 100, func(val):
		NatsumeRuntime.settings_manager.set_value("bgm_volume", val / 100.0)
	)

	# SE volume
	_add_slider("SE 音量", s.se_volume * 100, 0, 100, func(val):
		NatsumeRuntime.settings_manager.set_value("se_volume", val / 100.0)
	)

	# Voice volume
	_add_slider("语音音量", s.voice_volume * 100, 0, 100, func(val):
		NatsumeRuntime.settings_manager.set_value("voice_volume", val / 100.0)
	)

	settings_container.add_child(HSeparator.new())

	# Fullscreen toggle
	_add_toggle("全屏", s.fullscreen, func(toggled):
		NatsumeRuntime.settings_manager.set_value("fullscreen", toggled)
		if toggled:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		else:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	)

	settings_container.add_child(HSeparator.new())

	# Reset button
	var reset_btn = Button.new()
	reset_btn.text = "恢复默认"
	reset_btn.custom_minimum_size = Vector2(150, 40)
	reset_btn.pressed.connect(func():
		NatsumeRuntime.settings_manager.reset_to_default()
		_build_ui()
	)
	settings_container.add_child(reset_btn)


func _add_slider(label_text: String, current_value: float, min_val: float, max_val: float, on_change: Callable):
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 20)

	var label = Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(200, 0)
	hbox.add_child(label)

	var slider = HSlider.new()
	slider.min_value = min_val
	slider.max_value = max_val
	slider.value = current_value
	slider.custom_minimum_size = Vector2(300, 0)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(on_change)
	hbox.add_child(slider)

	var value_label = Label.new()
	value_label.text = str(int(current_value))
	value_label.custom_minimum_size = Vector2(50, 0)
	slider.value_changed.connect(func(val): value_label.text = str(int(val)))
	hbox.add_child(value_label)

	settings_container.add_child(hbox)


func _add_toggle(label_text: String, current_value: bool, on_change: Callable):
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 20)

	var label = Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(200, 0)
	hbox.add_child(label)

	var toggle = CheckButton.new()
	toggle.button_pressed = current_value
	toggle.toggled.connect(on_change)
	hbox.add_child(toggle)

	settings_container.add_child(hbox)


func _input(event: InputEvent) -> void:
	if not visible:
		return

	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ESCAPE:
			_hide_screen()
			get_viewport().set_input_as_handled()

	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_hide_screen()
			get_viewport().set_input_as_handled()
