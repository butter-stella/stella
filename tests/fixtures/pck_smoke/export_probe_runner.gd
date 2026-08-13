extends Node

const BOOTSTRAP_SCENE = "res://addons/stella/scenes/bootstrap.tscn"
const BUILT_IN_TITLE_SCENE = "res://addons/stella/scenes/title.tscn"
const CONFIGURED_TITLE_SCENE = "res://examples/demo/scenes/title.tscn"
const EXPECTED_GAME_TITLE = "Stella Demo"
const EXPECTED_SCENARIO = "res://examples/demo/scenarios/demo.stla"
const EXPECTED_BACKGROUNDS = "res://examples/demo/art/backgrounds/"
const EXPECTED_CONFIG_SOURCE = "res://stella.cfg"


func run() -> void:
	var probe_mode := OS.get_environment("STELLA_EXPORT_PROBE_MODE")
	if probe_mode in ["config", "fallback"] and FileAccess.file_exists(
		"res://stella.local.cfg"
	):
		_fail("export contains the excluded stella.local.cfg")
		return
	match probe_mode:
		"config":
			await _probe_exported_config()
		"fallback":
			await _probe_selected_scenes_fallback()
		"source-fallback":
			await _probe_source_fallback()
		var unsupported_mode:
			_fail("unsupported probe mode: %s" % unsupported_mode)


func _probe_exported_config() -> void:
	if not await _enter_bootstrap_and_wait_for(CONFIGURED_TITLE_SCENE):
		return

	var failures := PackedStringArray()
	if StellaRuntime.config == null:
		failures.append("StellaRuntime config is null")
	else:
		if StellaRuntime.config.game_title != EXPECTED_GAME_TITLE:
			failures.append("exported game title was not parsed")
		if StellaRuntime.config.scenario_path != EXPECTED_SCENARIO:
			failures.append("exported scenario path was not parsed")
	if StellaRuntime.backgrounds_path != EXPECTED_BACKGROUNDS:
		failures.append("exported backgrounds path was not applied")
	var sources := StellaRuntime.get_applied_config_sources()
	if sources.size() != 1 or sources[0] != EXPECTED_CONFIG_SOURCE:
		failures.append("exported base config was not recorded as applied")

	var title_label := _get_title_label()
	if title_label == null or title_label.text != EXPECTED_GAME_TITLE:
		failures.append("the exported title consumer did not receive game.title")

	_finish("config-ok", failures)


func _probe_selected_scenes_fallback() -> void:
	# This preset deliberately omits the dynamically configured demo title.
	# The built-in fallback must arrive through bootstrap's static dependency.
	if ResourceLoader.exists(CONFIGURED_TITLE_SCENE, "PackedScene"):
		_fail("selected-scenes fixture unexpectedly contains the configured title")
		return
	if not await _enter_bootstrap_and_wait_for(BUILT_IN_TITLE_SCENE):
		return

	var failures := PackedStringArray()
	var current_scene := get_tree().current_scene
	if current_scene == null or current_scene.scene_file_path != BUILT_IN_TITLE_SCENE:
		failures.append("fallback did not finish on the built-in title scene")
	if StellaRuntime.title_scene_path != BUILT_IN_TITLE_SCENE:
		failures.append("runtime title path was not normalized to the fallback")
	var title_label := _get_title_label()
	if title_label == null or title_label.text != EXPECTED_GAME_TITLE:
		failures.append("the fallback title consumer did not receive game.title")

	_finish("fallback-ok", failures)


func _probe_source_fallback() -> void:
	if not await _enter_bootstrap_and_wait_for(BUILT_IN_TITLE_SCENE):
		return

	var expected_title := OS.get_environment("STELLA_EXPORT_PROBE_EXPECTED_TITLE")
	var failures := PackedStringArray()
	var current_scene := get_tree().current_scene
	if current_scene == null or current_scene.scene_file_path != BUILT_IN_TITLE_SCENE:
		failures.append("fallback did not finish on the built-in title scene")
	if StellaRuntime.title_scene_path != BUILT_IN_TITLE_SCENE:
		failures.append("runtime title path was not normalized to the fallback")
	if StellaRuntime.config == null or StellaRuntime.config.game_title != expected_title:
		failures.append("fallback did not preserve the resolved config value")
	var title_label := _get_title_label()
	if title_label == null or title_label.text != expected_title:
		failures.append("the fallback title consumer did not receive game.title")

	_finish("fallback-ok", failures)


func _enter_bootstrap_and_wait_for(expected_scene: String) -> bool:
	var change_error := get_tree().change_scene_to_file(BOOTSTRAP_SCENE)
	if change_error != OK:
		_fail("cannot enter bootstrap: %s" % error_string(change_error))
		return false

	# A successful path has two deterministic transitions: first into bootstrap,
	# then into the resolved title. One extra transition makes failures explicit
	# without relying on wall-clock sleeps; the outer process has a watchdog too.
	for _transition_index in range(3):
		var current_scene := get_tree().current_scene
		if current_scene != null and current_scene.scene_file_path == expected_scene:
			return true
		await get_tree().scene_changed

	var final_scene := get_tree().current_scene
	var final_path := "<null>" if final_scene == null else final_scene.scene_file_path
	_fail("expected current_scene %s, got %s" % [expected_scene, final_path])
	return false


func _get_title_label() -> Label:
	var current_scene := get_tree().current_scene
	if current_scene == null:
		return null
	return current_scene.get_node_or_null(
		"TitleScreen/Panel/CenterContainer/VBox/TitleLabel"
	) as Label


func _finish(marker_value: String, failures: PackedStringArray) -> void:
	if not failures.is_empty():
		_fail("; ".join(failures))
		return

	var marker_path := OS.get_environment("STELLA_EXPORT_PROBE_MARKER")
	if marker_path == "":
		_fail("STELLA_EXPORT_PROBE_MARKER is not set")
		return
	var marker := FileAccess.open(marker_path, FileAccess.WRITE)
	if marker == null:
		_fail("cannot create the requested marker")
		return
	marker.store_string(marker_value + "\n")
	marker.close()
	get_tree().quit()


func _fail(message: String) -> void:
	push_error("Export probe: " + message)
	get_tree().quit(1)
