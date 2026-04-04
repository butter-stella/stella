@tool
extends EditorPlugin

const AUTOLOADS = {
	"SignalBus": "res://addons/natsume/autoload/signal_bus.gd",
	"NatsumeRuntime": "res://addons/natsume/autoload/natsume_runtime.gd",
}

const DEFAULT_MAIN_SCENE = "res://addons/natsume/scenes/title.tscn"

var _nat_format_loader: NatFormatLoader
var _nat_format_saver: NatFormatSaver
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

	# Register .nat format loader/saver
	_nat_format_loader = NatFormatLoader.new()
	_nat_format_saver = NatFormatSaver.new()
	ResourceLoader.add_resource_format_loader(_nat_format_loader)
	ResourceSaver.add_resource_format_saver(_nat_format_saver)

	# Add main screen editor for .nat files
	_nat_editor = _nat_editor_script.new()
	_nat_editor.name = "NatEditor"
	get_editor_interface().get_editor_main_screen().add_child(_nat_editor)
	_make_visible(false)


func _exit_tree():
	for autoload_name in AUTOLOADS:
		remove_autoload_singleton(autoload_name)

	if _nat_format_loader:
		ResourceLoader.remove_resource_format_loader(_nat_format_loader)
		_nat_format_loader = null
	if _nat_format_saver:
		ResourceSaver.remove_resource_format_saver(_nat_format_saver)
		_nat_format_saver = null
	if _nat_editor:
		_nat_editor.queue_free()
		_nat_editor = null


func _has_main_screen() -> bool:
	return true


func _get_plugin_name() -> String:
	return "Nat"


func _get_plugin_icon() -> Texture2D:
	return get_editor_interface().get_base_control().get_theme_icon("Script", "EditorIcons")


func _handles(object: Object) -> bool:
	return object is NatScript


func _edit(object: Object) -> void:
	if object is NatScript and _nat_editor:
		var path := object.resource_path
		if path != "":
			_nat_editor.open_file(path)


func _make_visible(visible: bool) -> void:
	if _nat_editor:
		_nat_editor.visible = visible
