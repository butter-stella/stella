@tool
extends EditorPlugin

const AUTOLOADS = {
	"SignalBus": "res://addons/stella/autoload/signal_bus.gd",
	"StellaRuntime": "res://addons/stella/autoload/stella_runtime.gd",
}

const DEFAULT_MAIN_SCENE = "res://addons/stella/scenes/title.tscn"

var _stl_editor: Control
var _stl_editor_script := preload("res://addons/stella/editor/stl_editor.gd")


func _enter_tree():
	for autoload_name in AUTOLOADS:
		if not ProjectSettings.has_setting("autoload/" + autoload_name):
			add_autoload_singleton(autoload_name, AUTOLOADS[autoload_name])

	# Set main scene to built-in title if not configured
	var current_main = ProjectSettings.get_setting("application/run/main_scene", "")
	if current_main == "":
		ProjectSettings.set_setting("application/run/main_scene", DEFAULT_MAIN_SCENE)
		ProjectSettings.save()

	# Add main screen editor for .stl files
	_stl_editor = _stl_editor_script.new()
	_stl_editor.name = "StlEditor"
	get_editor_interface().get_editor_main_screen().add_child(_stl_editor)
	_make_visible(false)

	# Open .stl files on double-click in FileSystem dock
	get_editor_interface().get_file_system_dock().file_double_clicked.connect(_on_file_double_clicked)


func _exit_tree():
	for autoload_name in AUTOLOADS:
		remove_autoload_singleton(autoload_name)

	var fs_dock = get_editor_interface().get_file_system_dock()
	if fs_dock.file_double_clicked.is_connected(_on_file_double_clicked):
		fs_dock.file_double_clicked.disconnect(_on_file_double_clicked)
	if _stl_editor:
		_stl_editor.queue_free()
		_stl_editor = null


func _has_main_screen() -> bool:
	return true


func _get_plugin_name() -> String:
	return "Stl"


func _get_plugin_icon() -> Texture2D:
	return get_editor_interface().get_base_control().get_theme_icon("Script", "EditorIcons")


func _on_file_double_clicked(path: String) -> void:
	if path.get_extension() == "stl" and _stl_editor:
		get_editor_interface().set_main_screen_editor("Stl")
		_stl_editor.open_file(path)


func _make_visible(visible: bool) -> void:
	if _stl_editor:
		_stl_editor.visible = visible
