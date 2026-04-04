## Main screen editor for .nat scenario files.
@tool
extends Control

var _code_edit: CodeEdit
var _file_label: Label
var _save_button: Button
var _current_path: String = ""
var _highlighter: NatSyntaxHighlighter


func _ready() -> void:
	_build_ui()


func _build_ui() -> void:
	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(PRESET_FULL_RECT)
	add_child(vbox)

	# Toolbar
	var toolbar := HBoxContainer.new()
	vbox.add_child(toolbar)

	_file_label = Label.new()
	_file_label.text = "No file open"
	_file_label.size_flags_horizontal = SIZE_EXPAND_FILL
	toolbar.add_child(_file_label)

	_save_button = Button.new()
	_save_button.text = "Save"
	_save_button.pressed.connect(_on_save_pressed)
	_save_button.disabled = true
	toolbar.add_child(_save_button)

	# Code editor
	_code_edit = CodeEdit.new()
	_code_edit.size_flags_vertical = SIZE_EXPAND_FILL
	_code_edit.gutters_draw_line_numbers = true
	_code_edit.minimap_draw = true
	_code_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_code_edit.caret_blink = true
	_code_edit.highlight_current_line = true
	_code_edit.scroll_smooth = true

	_highlighter = NatSyntaxHighlighter.new()
	_code_edit.syntax_highlighter = _highlighter

	_code_edit.text_changed.connect(_on_text_changed)
	vbox.add_child(_code_edit)


func open_file(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("NatEditor: Cannot open file: %s" % path)
		return
	_current_path = path
	_code_edit.text = file.get_as_text()
	file.close()
	_file_label.text = path.get_file()
	_save_button.disabled = true


func get_current_path() -> String:
	return _current_path


func _on_text_changed() -> void:
	_save_button.disabled = false
	if _file_label and _current_path != "":
		_file_label.text = _current_path.get_file() + " (*)"


func _on_save_pressed() -> void:
	if _current_path == "":
		return
	var file := FileAccess.open(_current_path, FileAccess.WRITE)
	if file == null:
		push_warning("NatEditor: Cannot save file: %s" % _current_path)
		return
	file.store_string(_code_edit.text)
	file.close()
	_save_button.disabled = true
	_file_label.text = _current_path.get_file()


func _unhandled_key_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed:
		if event.ctrl_pressed and event.keycode == KEY_S:
			_on_save_pressed()
			get_viewport().set_input_as_handled()
