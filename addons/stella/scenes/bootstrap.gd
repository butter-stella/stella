## Non-visual main scene that enters the resolved title scene after
## StellaRuntime has finished applying layered project configuration.
extends Node

const DEFAULT_TITLE_SCENE = "res://addons/stella/scenes/title.tscn"
const BOOTSTRAP_SCENE = "res://addons/stella/scenes/bootstrap.tscn"


func _ready() -> void:
	var configured_path: String = StellaRuntime.title_scene_path.simplify_path()
	var title_scene := _load_title_scene(configured_path)
	if title_scene == null or _is_bootstrap_scene(title_scene):
		push_error(
			"StellaBootstrap: [overrides].title_scene is not a loadable PackedScene; "
			+ "falling back to the built-in title scene"
		)
		title_scene = _load_title_scene(DEFAULT_TITLE_SCENE)
		StellaRuntime.title_scene_path = DEFAULT_TITLE_SCENE

	if title_scene == null:
		push_error("StellaBootstrap: built-in title scene is unavailable")
		get_tree().quit(1)
		return

	# The bootstrap itself is still entering the tree while _ready runs. Deferring
	# avoids asking SceneTree to remove that busy node during the same traversal.
	_enter_title_scene.call_deferred(title_scene, configured_path)


func _enter_title_scene(title_scene: PackedScene, configured_path: String) -> void:
	var error := get_tree().change_scene_to_packed(title_scene)
	if error == OK:
		return

	push_error(
		"StellaBootstrap: failed to enter the resolved title scene (%s)"
		% error_string(error)
	)
	if configured_path != DEFAULT_TITLE_SCENE:
		var fallback := _load_title_scene(DEFAULT_TITLE_SCENE)
		if fallback != null:
			var fallback_error := get_tree().change_scene_to_packed(fallback)
			if fallback_error == OK:
				StellaRuntime.title_scene_path = DEFAULT_TITLE_SCENE
				return
	get_tree().quit(1)


func _load_title_scene(path: String) -> PackedScene:
	var normalized_path := path.simplify_path()
	if normalized_path == "" or normalized_path == BOOTSTRAP_SCENE:
		return null
	if not ResourceLoader.exists(normalized_path, "PackedScene"):
		return null
	return load(normalized_path) as PackedScene


func _is_bootstrap_scene(scene: PackedScene) -> bool:
	return scene.resource_path.simplify_path() == BOOTSTRAP_SCENE
