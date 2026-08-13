extends Node

const BUILT_IN_TITLE_SCENE = "res://addons/stella/scenes/title.tscn"
const EXPECTED_TITLE = "Synthetic Custom Main Probe"


func verify_after_return(initial_failures: PackedStringArray) -> void:
	var failures := initial_failures.duplicate()
	await get_tree().scene_changed

	var current_scene := get_tree().current_scene
	if current_scene == null or current_scene.scene_file_path != BUILT_IN_TITLE_SCENE:
		var current_path := "<null>" if current_scene == null else current_scene.scene_file_path
		failures.append("return_to_title ended on %s" % current_path)
	if StellaRuntime.title_scene_path != BUILT_IN_TITLE_SCENE:
		failures.append("invalid title override was not normalized to the fallback")
	if (
		StellaRuntime.game_state == null
		or StellaRuntime.game_state.current_state != GameStateMachine.State.TITLE
	):
		failures.append("runtime did not commit TITLE after accepting the fallback")

	var title_label: Label = null
	if current_scene != null:
		title_label = current_scene.get_node_or_null(
			"TitleScreen/Panel/CenterContainer/VBox/TitleLabel"
		) as Label
	if title_label == null or title_label.text != EXPECTED_TITLE:
		failures.append("fallback title consumer did not receive resolved game.title")

	_finish(failures)


func _finish(failures: PackedStringArray) -> void:
	if not failures.is_empty():
		for failure: String in failures:
			push_error("Custom main probe: " + failure)
		get_tree().quit(1)
		return

	var marker_path := OS.get_environment("STELLA_CUSTOM_MAIN_PROBE_MARKER")
	if marker_path == "":
		push_error("Custom main probe: marker environment variable is not set")
		get_tree().quit(1)
		return
	var marker := FileAccess.open(marker_path, FileAccess.WRITE)
	if marker == null:
		push_error("Custom main probe: cannot create the requested marker")
		get_tree().quit(1)
		return
	marker.store_string("ok\n")
	marker.close()
	get_tree().quit()
