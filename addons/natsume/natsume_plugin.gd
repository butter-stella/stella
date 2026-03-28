@tool
extends EditorPlugin

const AUTOLOADS = {
	"SignalBus": "res://addons/natsume/autoload/signal_bus.gd",
	"NatsumeRuntime": "res://addons/natsume/autoload/natsume_runtime.gd",
}


func _enter_tree():
	for autoload_name in AUTOLOADS:
		if not ProjectSettings.has_setting("autoload/" + autoload_name):
			add_autoload_singleton(autoload_name, AUTOLOADS[autoload_name])


func _exit_tree():
	for autoload_name in AUTOLOADS:
		remove_autoload_singleton(autoload_name)
