@tool
extends EditorPlugin

const AUTOLOADS = {
	"SignalBus": "res://addons/natsume/autoload/signal_bus.gd",
	"NatsumeRuntime": "res://addons/natsume/autoload/natsume_runtime.gd",
}

const DEFAULT_MAIN_SCENE = "res://addons/natsume/scenes/title.tscn"


func _enter_tree():
	for autoload_name in AUTOLOADS:
		if not ProjectSettings.has_setting("autoload/" + autoload_name):
			add_autoload_singleton(autoload_name, AUTOLOADS[autoload_name])

	# Set main scene to built-in title if not configured
	var current_main = ProjectSettings.get_setting("application/run/main_scene", "")
	if current_main == "":
		ProjectSettings.set_setting("application/run/main_scene", DEFAULT_MAIN_SCENE)
		ProjectSettings.save()


func _exit_tree():
	for autoload_name in AUTOLOADS:
		remove_autoload_singleton(autoload_name)
