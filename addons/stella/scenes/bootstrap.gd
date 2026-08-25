## Non-visual main scene that enters the resolved title scene after
## StellaRuntime has finished applying layered project configuration.
extends Node

const DEFAULT_TITLE_SCENE: PackedScene = preload("res://addons/stella/scenes/title.tscn")


func _ready() -> void:
	var title_scene := StellaRuntime.resolve_title_scene(DEFAULT_TITLE_SCENE)

	# The bootstrap itself is still entering the tree while _ready runs. Deferring
	# avoids asking SceneTree to remove that busy node during the same traversal.
	_enter_title_scene.call_deferred(title_scene)


func _enter_title_scene(title_scene: PackedScene) -> void:
	var error := _change_scene_to_packed(title_scene)
	if error == OK:
		return

	push_error(
		"StellaBootstrap: failed to enter the resolved title scene (%s)"
		% error_string(error)
	)
	if title_scene != DEFAULT_TITLE_SCENE:
		var fallback_error := _change_scene_to_packed(DEFAULT_TITLE_SCENE)
		if fallback_error == OK:
			StellaRuntime.title_scene_path = StellaRuntime.DEFAULT_TITLE_SCENE
			return
	StellaRuntime.request_quit(1)


func _change_scene_to_packed(scene: PackedScene) -> Error:
	return get_tree().change_scene_to_packed(scene)
