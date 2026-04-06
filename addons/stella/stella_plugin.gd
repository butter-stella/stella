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

	# Add main screen editor for .stla files. Since Godot 4's FileSystemDock
	# has no public double-click signal, users open .stla files via the built-in
	# script editor (Godot recognizes them as text files now), or by switching
	# to the "Stla" main screen and opening manually.
	_stla_editor = _stla_editor_script.new()
	_stla_editor.name = "StlaEditor"
	get_editor_interface().get_editor_main_screen().add_child(_stla_editor)
	_make_visible(false)


func _exit_tree():
	for autoload_name in AUTOLOADS:
		remove_autoload_singleton(autoload_name)

	if _stla_editor:
		_stla_editor.queue_free()
		_stla_editor = null


func _has_main_screen() -> bool:
	return true


func _get_plugin_name() -> String:
	return "Stla"


func _get_plugin_icon() -> Texture2D:
	return get_editor_interface().get_base_control().get_theme_icon("Script", "EditorIcons")


func _make_visible(visible: bool) -> void:
	if _stla_editor:
		_stla_editor.visible = visible


func _register_stla_extension() -> void:
	const SETTING := "docks/filesystem/textfile_extensions"
	var editor_settings := get_editor_interface().get_editor_settings()
	var raw := ""
	if editor_settings.has_setting(SETTING):
		var v = editor_settings.get_setting(SETTING)
		if v is String:
			raw = v
	# Check if "stla" is already present (whitespace-tolerant).
	for ext in raw.split(",", false):
		if ext.strip_edges() == "stla":
			print("[Stella] .stla already registered in %s" % SETTING)
			return
	var new_value := raw
	if new_value != "" and not new_value.ends_with(","):
		new_value += ","
	new_value += "stla"
	editor_settings.set_setting(SETTING, new_value)
	print("[Stella] Registered .stla extension. %s = %s" % [SETTING, new_value])
