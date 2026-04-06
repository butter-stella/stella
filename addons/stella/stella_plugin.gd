@tool
extends EditorPlugin

const AUTOLOADS = {
	"SignalBus": "res://addons/stella/autoload/signal_bus.gd",
	"StellaRuntime": "res://addons/stella/autoload/stella_runtime.gd",
}

const DEFAULT_MAIN_SCENE = "res://addons/stella/scenes/title.tscn"

var _stla_editor: Control
var _stla_editor_script := preload("res://addons/stella/editor/stla_editor.gd")


func _enter_tree():
	for autoload_name in AUTOLOADS:
		if not ProjectSettings.has_setting("autoload/" + autoload_name):
			add_autoload_singleton(autoload_name, AUTOLOADS[autoload_name])

	# Set main scene to built-in title if not configured
	var current_main = ProjectSettings.get_setting("application/run/main_scene", "")
	if current_main == "":
		ProjectSettings.set_setting("application/run/main_scene", DEFAULT_MAIN_SCENE)
		ProjectSettings.save()

	# Register .stla as a recognized text file extension so the FileSystem dock
	# shows it. Without this, Godot hides unknown text extensions.
	_register_stla_extension()

	# Add main screen editor for .stla files
	_stla_editor = _stla_editor_script.new()
	_stla_editor.name = "StlaEditor"
	get_editor_interface().get_editor_main_screen().add_child(_stla_editor)
	_make_visible(false)

	# Open .stla files on double-click in FileSystem dock
	get_editor_interface().get_file_system_dock().file_double_clicked.connect(_on_file_double_clicked)


func _exit_tree():
	for autoload_name in AUTOLOADS:
		remove_autoload_singleton(autoload_name)

	var fs_dock = get_editor_interface().get_file_system_dock()
	if fs_dock.file_double_clicked.is_connected(_on_file_double_clicked):
		fs_dock.file_double_clicked.disconnect(_on_file_double_clicked)
	if _stla_editor:
		_stla_editor.queue_free()
		_stla_editor = null


func _has_main_screen() -> bool:
	return true


func _get_plugin_name() -> String:
	return "Stla"


func _get_plugin_icon() -> Texture2D:
	return get_editor_interface().get_base_control().get_theme_icon("Script", "EditorIcons")


func _on_file_double_clicked(path: String) -> void:
	if path.get_extension() == "stla" and _stla_editor:
		get_editor_interface().set_main_screen_editor("Stla")
		_stla_editor.open_file(path)


func _make_visible(visible: bool) -> void:
	if _stla_editor:
		_stla_editor.visible = visible


func _register_stla_extension() -> void:
	var editor_settings := get_editor_interface().get_editor_settings()
	const SETTING := "docks/filesystem/textfile_extensions"
	if not editor_settings.has_setting(SETTING):
		return
	var raw: String = editor_settings.get_setting(SETTING)
	var exts := raw.split(",", false)
	if "stla" in exts:
		return
	exts.append("stla")
	editor_settings.set_setting(SETTING, ",".join(exts))
