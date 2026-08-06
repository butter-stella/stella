extends "res://addons/stella/presentation/ui/save_load_screen.gd"
## Test fixture matching downstream overlays that customize mode application.

var applied_modes: Array[String] = []


func _set_mode(mode: String) -> void:
	applied_modes.append(mode)
	super._set_mode(mode)
