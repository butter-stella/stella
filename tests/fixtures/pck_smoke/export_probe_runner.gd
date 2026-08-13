extends Node

const BOOTSTRAP_SCENE = "res://addons/stella/scenes/bootstrap.tscn"
const BUILT_IN_TITLE_SCENE = "res://addons/stella/scenes/title.tscn"
const CONFIGURED_TITLE_SCENE = "res://examples/demo/scenes/title.tscn"
const READY_RETURN_SCENE = "res://tests/fixtures/startup/ready_return.tscn"
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
		"degraded-title-fallback":
			await _probe_degraded_title_fallbacks()
		"ready-return":
			await _probe_ready_return()
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


func _probe_degraded_title_fallbacks() -> void:
	var fixtures := _write_degraded_title_fixtures()
	if fixtures.is_empty():
		_fail("could not create degraded title fixtures")
		return

	var failures := PackedStringArray()
	for degraded_path: String in fixtures:
		# Normal startup must reject each degraded PackedScene before it can
		# become current_scene.
		StellaRuntime.title_scene_path = degraded_path
		if not await _enter_bootstrap_and_wait_for(BUILT_IN_TITLE_SCENE):
			_cleanup_degraded_title_fixtures(fixtures)
			return
		if StellaRuntime.title_scene_path != BUILT_IN_TITLE_SCENE:
			failures.append("startup did not normalize a degraded title path")

		# The in-game return path uses the same resolver and must commit TITLE
		# only after the built-in scene is confirmed as current.
		StellaRuntime.title_scene_path = degraded_path
		StellaRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)
		StellaRuntime.return_to_title()
		if not StellaRuntime._return_to_title_pending:
			failures.append("return transaction was not scheduled")
			continue
		await get_tree().scene_changed
		if not await _wait_for_return_completion():
			failures.append("return transaction did not complete")
			continue
		var current_scene := get_tree().current_scene
		if (
			current_scene == null
			or current_scene.scene_file_path != BUILT_IN_TITLE_SCENE
		):
			failures.append("return entered a degraded title scene")
		if StellaRuntime.game_state.current_state != GameStateMachine.State.TITLE:
			failures.append("return did not commit TITLE on the built-in scene")

	_cleanup_degraded_title_fixtures(fixtures)
	_finish("degraded-fallback-ok", failures)


func _probe_ready_return() -> void:
	StellaRuntime.title_scene_path = BUILT_IN_TITLE_SCENE
	var change_error := get_tree().change_scene_to_file(READY_RETURN_SCENE)
	if change_error != OK:
		_fail("cannot enter ready-return fixture: %s" % error_string(change_error))
		return

	# The fixture calls return_to_title() synchronously from its root _ready().
	# The request must be pending, with PLAYING state untouched, until a later
	# lifecycle turn can safely replace that busy root.
	await get_tree().scene_changed
	var failures := PackedStringArray()
	var ready_scene := get_tree().current_scene
	if ready_scene == null or ready_scene.scene_file_path != READY_RETURN_SCENE:
		failures.append("ready-return fixture was not current after its _ready")
	if StellaRuntime.game_state.current_state != GameStateMachine.State.PLAYING:
		failures.append("return committed TITLE before confirming scene_changed")
	if not StellaRuntime._return_to_title_pending:
		failures.append("return request was not deferred from _ready")

	await get_tree().scene_changed
	if not await _wait_for_return_completion():
		failures.append("deferred return transaction did not complete")
	var current_scene := get_tree().current_scene
	if (
		current_scene == null
		or current_scene.scene_file_path != BUILT_IN_TITLE_SCENE
	):
		failures.append("deferred return did not finish on the built-in title")
	if StellaRuntime.game_state.current_state != GameStateMachine.State.TITLE:
		failures.append("deferred return did not commit TITLE after scene_changed")

	_finish("ready-return-ok", failures)


func _write_degraded_title_fixtures() -> PackedStringArray:
	var missing_script_path := "user://stella_probe_missing_script_title.tscn"
	var missing_nested_path := "user://stella_probe_missing_nested_title.tscn"
	var wrong_base_path := "user://stella_probe_wrong_script_base_title.tscn"
	var sources := {
		missing_script_path: (
			"[gd_scene load_steps=2 format=3]\n\n"
			+ "[ext_resource type=\"Script\" "
			+ "path=\"user://PRIVATE_DEGRADED_TITLE_DEPENDENCY.gd\" "
			+ "id=\"1_missing\"]\n\n"
			+ "[node name=\"MissingScriptTitle\" type=\"Node\"]\n"
			+ "script = ExtResource(\"1_missing\")\n"
		),
		missing_nested_path: (
			"[gd_scene load_steps=2 format=3]\n\n"
			+ "[ext_resource type=\"PackedScene\" "
			+ "path=\"user://PRIVATE_DEGRADED_TITLE_DEPENDENCY.tscn\" "
			+ "id=\"1_missing\"]\n\n"
			+ "[node name=\"MissingNestedTitle\" type=\"Node\"]\n\n"
			+ "[node name=\"MissingChild\" parent=\".\" "
			+ "instance=ExtResource(\"1_missing\")]\n"
		),
		wrong_base_path: (
			"[gd_scene load_steps=2 format=3]\n\n"
			+ "[ext_resource type=\"Script\" "
			+ "path=\"res://addons/stella/presentation/dialogue/"
			+ "dialogue_mode_profile.gd\" id=\"1_resource\"]\n\n"
			+ "[node name=\"WrongScriptBaseTitle\" type=\"Node\"]\n"
			+ "script = ExtResource(\"1_resource\")\n"
		),
	}
	var paths := PackedStringArray()
	for path: String in sources:
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file == null:
			_cleanup_degraded_title_fixtures(paths)
			return PackedStringArray()
		file.store_string(sources[path])
		file.close()
		paths.append(path)
	return paths


func _cleanup_degraded_title_fixtures(paths: PackedStringArray) -> void:
	for path: String in paths:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _wait_for_return_completion() -> bool:
	for _frame_index in range(120):
		if not StellaRuntime._return_to_title_pending:
			return true
		await get_tree().process_frame
	return false


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
