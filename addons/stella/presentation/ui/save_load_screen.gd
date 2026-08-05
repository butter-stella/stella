## Save/Load screen — grid of save slots with save/load modes.
## Loaded as overlay by StellaRuntime, closed with ESC or right-click.
extends PanelContainer

@onready var title_label: Label = %SaveLoadTitle
@onready var save_tab: Button = %SaveTab
@onready var load_tab: Button = %LoadTab
@onready var slots_container: GridContainer = %SlotsContainer

var _mode: String = "save"  # "save" or "load"
var _slot_count: int = 8


func _ready():
	_slot_count = StellaRuntime.config.save_slots
	save_tab.pressed.connect(func(): set_mode("save"))
	load_tab.pressed.connect(func(): set_mode("load"))
	_update_tabs()
	_refresh_slots()


func _close():
	StellaRuntime.close_overlay()


func set_mode(mode: String) -> void:
	if mode != "save" and mode != "load":
		push_warning("SaveLoadScreen: mode must be 'save' or 'load', got '%s'" % mode)
		return
	_mode = mode
	if not is_node_ready():
		return
	_update_tabs()
	_refresh_slots()


func _update_tabs():
	title_label.text = "存档" if _mode == "save" else "读档"
	save_tab.modulate = Color.YELLOW if _mode == "save" else Color.WHITE
	load_tab.modulate = Color.YELLOW if _mode == "load" else Color.WHITE


func _refresh_slots():
	for child in slots_container.get_children():
		slots_container.remove_child(child)
		child.queue_free()

	var save_list = StellaRuntime.get_save_list()

	for i in range(1, _slot_count + 1):
		var slot_btn = Button.new()
		slot_btn.custom_minimum_size = Vector2(200, 80)
		slot_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

		if save_list.has(i):
			var meta = StellaRuntime.get_save_metadata(i)
			var timestamp_str = meta.get("timestamp_str", "")
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
		StellaRuntime.save(slot_id)
		_refresh_slots()
	else:  # load
		if not await StellaRuntime.continue_from_save(slot_id):
			push_warning("SaveLoadScreen: failed to load slot %d" % slot_id)


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
