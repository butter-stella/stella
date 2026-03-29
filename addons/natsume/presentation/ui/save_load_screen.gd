## Save/Load screen — grid of save slots with save/load modes.
extends PanelContainer

@onready var title_label: Label = %SaveLoadTitle
@onready var save_tab: Button = %SaveTab
@onready var load_tab: Button = %LoadTab
@onready var slots_container: GridContainer = %SlotsContainer

var _mode: String = "save"  # "save" or "load"
var _slot_count: int = 8


func _ready():
	NatsumeRuntime.game_state.state_changed.connect(_on_state_changed)
	visible = false

	save_tab.pressed.connect(func(): _set_mode("save"))
	load_tab.pressed.connect(func(): _set_mode("load"))


func _on_state_changed(_from: int, to: int):
	if to == GameStateMachine.State.SAVE_LOAD:
		_show()
	elif visible:
		_hide_screen()


func _show():
	visible = true
	_refresh_slots()
	_update_tabs()


func _hide_screen():
	visible = false
	NatsumeRuntime.game_state.return_to_previous()


func set_mode(mode: String):
	_mode = mode


func _set_mode(mode: String):
	_mode = mode
	_update_tabs()
	_refresh_slots()


func _update_tabs():
	title_label.text = "存档" if _mode == "save" else "读档"
	save_tab.modulate = Color.YELLOW if _mode == "save" else Color.WHITE
	load_tab.modulate = Color.YELLOW if _mode == "load" else Color.WHITE


func _refresh_slots():
	for child in slots_container.get_children():
		child.queue_free()

	var save_list = NatsumeRuntime.save_manager.get_save_list()

	for i in range(1, _slot_count + 1):
		var slot_btn = Button.new()
		slot_btn.custom_minimum_size = Vector2(200, 80)
		slot_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

		if save_list.has(i):
			# Load save file to get timestamp
			var path = NatsumeRuntime.save_manager.save_dir + "save_%d.json" % i
			var timestamp_str = _get_save_timestamp(path)
			slot_btn.text = "Slot %d\n%s" % [i, timestamp_str]
		else:
			slot_btn.text = "Slot %d\n— 空 —" % i
			if _mode == "load":
				slot_btn.disabled = true

		var slot_id = i
		slot_btn.pressed.connect(func(): _on_slot_pressed(slot_id))
		slots_container.add_child(slot_btn)


func _on_slot_pressed(slot_id: int):
	if _mode == "save":
		NatsumeRuntime.save_manager.save(slot_id)
		_refresh_slots()
	else:  # load
		visible = false
		if NatsumeRuntime.continue_from_save(slot_id):
			pass  # continue_from_save handles state transition
		else:
			push_warning("SaveLoadScreen: failed to load slot %d" % slot_id)
			visible = true


func _get_save_timestamp(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var data = JSON.parse_string(file.get_as_text())
	if data == null or not data is Dictionary:
		return ""
	var ts = data.get("timestamp", 0)
	if ts == 0:
		return ""
	var dt = Time.get_datetime_dict_from_unix_time(int(ts))
	return "%04d/%02d/%02d %02d:%02d" % [dt["year"], dt["month"], dt["day"], dt["hour"], dt["minute"]]


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
