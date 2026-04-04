@tool
extends EditorPlugin

const AUTOLOADS = {
	"SignalBus": "res://addons/natsume/autoload/signal_bus.gd",
	"NatsumeRuntime": "res://addons/natsume/autoload/natsume_runtime.gd",
}

const DEFAULT_MAIN_SCENE = "res://addons/natsume/scenes/title.tscn"

var _nat_editor: Control
var _nat_editor_script := preload("res://addons/natsume/editor/nat_editor.gd")


func _enter_tree():
	for autoload_name in AUTOLOADS:
		if not ProjectSettings.has_setting("autoload/" + autoload_name):
			add_autoload_singleton(autoload_name, AUTOLOADS[autoload_name])

	# Set main scene to built-in title if not configured
	var current_main = ProjectSettings.get_setting("application/run/main_scene", "")
	if current_main == "":
		ProjectSettings.set_setting("application/run/main_scene", DEFAULT_MAIN_SCENE)
		ProjectSettings.save()

	# Add main screen editor for .nat files
	_nat_editor = _nat_editor_script.new()
	_nat_editor.name = "NatEditor"
	get_editor_interface().get_editor_main_screen().add_child(_nat_editor)
	_make_visible(false)

	# Open .nat files on double-click in FileSystem dock
	get_editor_interface().get_file_system_dock().file_double_clicked.connect(_on_file_double_clicked)


func _exit_tree():
	for autoload_name in AUTOLOADS:
		remove_autoload_singleton(autoload_name)

	var fs_dock = get_editor_interface().get_file_system_dock()
	if fs_dock.file_double_clicked.is_connected(_on_file_double_clicked):
		fs_dock.file_double_clicked.disconnect(_on_file_double_clicked)
	if _nat_editor:
		_nat_editor.queue_free()
		_nat_editor = null


func _has_main_screen() -> bool:
	return true


func _get_plugin_name() -> String:
	return "Nat"


func _get_plugin_icon() -> Texture2D:
	return get_editor_interface().get_base_control().get_theme_icon("Script", "EditorIcons")


func _on_file_double_clicked(path: String) -> void:
	if path.get_extension() == "nat" and _nat_editor:
		get_editor_interface().set_main_screen_editor("Nat")
		_nat_editor.open_file(path)


func _make_visible(visible: bool) -> void:
	if _nat_editor:
		_nat_editor.visible = visible
