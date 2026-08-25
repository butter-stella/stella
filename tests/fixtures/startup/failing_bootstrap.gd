extends "res://addons/stella/scenes/bootstrap.gd"
## Synthetic bootstrap that makes both title scene changes fail deterministically.

var change_attempts: Array[PackedScene] = []


func _ready() -> void:
	pass


func _change_scene_to_packed(scene: PackedScene) -> Error:
	change_attempts.append(scene)
	return ERR_CANT_CREATE
