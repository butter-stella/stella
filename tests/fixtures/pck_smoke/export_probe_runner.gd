extends Node

const BOOTSTRAP_SCENE = "res://addons/stella/scenes/bootstrap.tscn"
const BUILT_IN_TITLE_SCENE = "res://addons/stella/scenes/title.tscn"
const CONFIGURED_TITLE_SCENE = "res://examples/demo/scenes/title.tscn"
const READY_RETURN_SCENE = "res://tests/fixtures/startup/ready_return.tscn"
const EXPECTED_GAME_TITLE = "Stella Demo"
const EXPECTED_SCENARIO = "res://examples/demo/scenarios/demo.stla"
const EXPECTED_BACKGROUNDS = "res://examples/demo/art/backgrounds/"
const EXPECTED_CONFIG_SOURCE = "res://stella.cfg"
const UID_DEPENDENCY_SCRIPT = (
	"res://tests/fixtures/pck_smoke/export_probe_runner.gd"
)
const UID_DEPENDENCY_TEXT = "uid://4elip3ufjpp"
const NAVIGATION_TITLE_SCENE = (
	"res://tests/fixtures/startup/cleared_inherited_script_title.tscn"
)
const NAVIGATION_GAME_SCENE = "res://tests/fixtures/startup/game.tscn"
const UID_GAME_SCENE = "uid://dhvclqgbx6gpb"
const UID_GAME_SCENE_PATH = "res://addons/stella/scenes/game.tscn"
const UID_TITLE_SCENE = "uid://cfdiw46c5l2k"
const UID_OVERLAY_SCENE = "uid://cnltnlv0oq0m0"
const UID_OVERLAY_SCENE_PATH = "res://tests/fixtures/startup/overlay.tscn"
const NAVIGATION_SCENARIO = (
	"res://tests/fixtures/scenarios/dialogue/presentation_profile.stla"
)
const NAVIGATION_SAVE_SLOT = 9173
const SAME_NAME_SCENARIO_A = "user://stella_review_a/shared.stla"
const SAME_NAME_SCENARIO_B = "user://stella_review_b/shared.stla"
const NESTED_EDITABLE_CHILD_TITLE = (
	"res://tests/fixtures/startup/"
	+ "nested_editable_child_cleared_script_title.tscn"
)


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
		"navigation-interleaving":
			await _probe_navigation_interleaving()
		var unsupported_mode:
			_fail("unsupported probe mode: %s" % unsupported_mode)


func _probe_exported_config() -> void:
	if not await _enter_bootstrap_and_wait_for(CONFIGURED_TITLE_SCENE):
		return

	var failures := PackedStringArray()
	_probe_relocated_uid_dependency(failures)
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
	_probe_relocated_uid_dependency(failures)
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
	_probe_nested_editable_child_override(failures)
	_probe_binary_nested_editable_child_override(failures)
	_probe_numeric_resource_ids(failures)
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


func _probe_numeric_resource_ids(failures: PackedStringArray) -> void:
	var scene_path := "user://stella_probe_numeric_resource_id.tscn"
	var file := FileAccess.open(scene_path, FileAccess.WRITE)
	if file == null:
		failures.append("could not create numeric resource-ID fixture")
		return
	file.store_string(
		"[gd_scene load_steps=5 format=3]\n\n"
		+ "[ext_resource type=\"Texture\\U000032D\" "
		+ "path=\"res://examples/demo/art/backgrounds/bg_\\u0063afe.png\" "
		+ "id=-1]\n\n"
		+ "[ext_resource type=\"Texture2D\" "
		+ "path=\"res://examples/demo/art/backgrounds/bg_cafe.png\" "
		+ "id=9223372036854775808]\n\n"
		+ "[ext_resource type=\"Texture2D\" "
		+ "path=\"res://examples/demo/art/backgrounds/bg_cafe.png\" "
		+ "id=1e1]\n\n"
		+ "[ext_resource type=\"Texture2D\" "
		+ "path=\"res://examples/demo/art/backgrounds/bg_cafe.png\" "
		+ "id=1e309]\n\n"
		+ "[node name=\"NumericResourceId\" type=\"Sprite2D\"]\n"
		+ "texture = ExtResource(-1)\n"
		+ "metadata/overflow = ExtResource(-9223372036854775808)\n"
		+ "metadata/exponent = ExtResource(\"10.0\")\n"
		+ "metadata/nonfinite = ExtResource(\"inf\")\n"
	)
	file.close()
	var scene := StellaRuntime._load_title_scene(scene_path)
	if scene == null:
		failures.append("Godot-valid signed resource ID was rejected")
	else:
		var instance := scene.instantiate() as Sprite2D
		if (
			instance == null
			or instance.texture == null
			or instance.get_meta("overflow") == null
			or instance.get_meta("exponent") == null
			or instance.get_meta("nonfinite") == null
		):
			failures.append("numeric/escaped resource reference did not resolve")
		if instance != null:
			instance.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(scene_path))


func _probe_nested_editable_child_override(failures: PackedStringArray) -> void:
	var scene: PackedScene = StellaRuntime._load_title_scene(
		NESTED_EDITABLE_CHILD_TITLE,
	)
	if scene == null:
		failures.append("nested editable child override was rejected")
		return
	var instance := scene.instantiate()
	if instance == null or not instance.has_node("Nested/Child"):
		failures.append("nested editable child override did not instantiate")
	elif instance.get_node("Nested/Child").get_script() != null:
		failures.append("nested editable child script override was not effective")
	if instance != null:
		instance.free()


func _probe_binary_nested_editable_child_override(
	failures: PackedStringArray,
) -> void:
	var nested_path := "user://stella_probe_nested_editable.scn"
	var outer_path := "user://stella_probe_binary_nested_outer.tscn"
	var nested_root := Node.new()
	nested_root.name = "NestedRoot"
	var nested_child := Node.new()
	nested_child.name = "Child"
	nested_root.add_child(nested_child)
	nested_child.owner = nested_root
	var nested_scene := PackedScene.new()
	var pack_error := nested_scene.pack(nested_root)
	var save_error := (
		ResourceSaver.save(nested_scene, nested_path)
		if pack_error == OK
		else pack_error
	)
	nested_root.free()
	if save_error != OK:
		failures.append("could not create binary nested-scene fixture")
		return

	var outer_file := FileAccess.open(outer_path, FileAccess.WRITE)
	if outer_file == null:
		failures.append("could not create binary nested-scene outer fixture")
		DirAccess.remove_absolute(ProjectSettings.globalize_path(nested_path))
		return
	outer_file.store_string(
		"[gd_scene load_steps=2 format=3]\n\n"
		+ "[ext_resource type=\"PackedScene\" path=\"%s\" "
		% nested_path
		+ "id=\"1_nested\"]\n\n"
		+ "[node name=\"Outer\" type=\"Node\"]\n\n"
		+ "[node name=\"Nested\" parent=\".\" "
		+ "instance=ExtResource(\"1_nested\")]\n\n"
		+ "[node name=\"Child\" parent=\"Nested\" index=\"0\"]\n"
		+ "metadata/probe = \"binary-override\"\n\n"
		+ "[editable path=\"Nested\"]\n"
	)
	outer_file.close()

	var outer_scene: PackedScene = StellaRuntime._load_title_scene(outer_path)
	if outer_scene == null:
		failures.append("binary nested editable child override was rejected")
	else:
		var instance := outer_scene.instantiate()
		var child := (
			instance.get_node_or_null("Nested/Child")
			if instance != null
			else null
		)
		if child == null or child.get_meta("probe") != "binary-override":
			failures.append("binary nested child override was not effective")
		if instance != null:
			instance.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(outer_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(nested_path))


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


func _probe_navigation_interleaving() -> void:
	var failures := PackedStringArray()
	var original_save_dir: String = StellaRuntime.save_manager.save_dir
	var original_game_scene: String = StellaRuntime.config.game_scene
	StellaRuntime.save_manager.save_dir = "user://stella_navigation_probe_saves/"
	StellaRuntime.config.game_scene = NAVIGATION_GAME_SCENE
	StellaRuntime.delete_save(NAVIGATION_SAVE_SLOT)
	StellaRuntime.delete_quick_save()
	StellaRuntime.delete_auto_save()
	await _probe_same_basename_save_identity(failures)

	# Produce both manual and continue snapshots from a real parsed scenario.
	# The engine need not run yet; each facade will install and run its own
	# restored context after it wins the navigation generation.
	StellaRuntime._last_scenario_path = NAVIGATION_SCENARIO
	StellaRuntime._prepare_scenario(NAVIGATION_SCENARIO)
	StellaRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)
	StellaRuntime.save(NAVIGATION_SAVE_SLOT)
	StellaRuntime.quick_save()
	StellaRuntime._cancel_active_gameplay()

	await _probe_failed_navigation_preserves_owner(failures)
	if failures.is_empty():
		await _probe_uid_navigation(failures)
	if failures.is_empty():
		await _probe_scenario_signal_reentrancy(failures)
	if failures.is_empty():
		await _probe_start_scenario_ownership(failures)

	var later_gameplay_facades: Array[Dictionary] = [
		{"name": "start_game", "call": _invoke_navigation_start_game},
		{"name": "load_game", "call": _invoke_navigation_load_game},
		{
			"name": "continue_from_save",
			"call": _invoke_navigation_continue_from_save,
		},
		{"name": "quick_load", "call": _invoke_navigation_quick_load},
		{"name": "continue_game", "call": _invoke_navigation_continue_game},
	]
	for facade: Dictionary in later_gameplay_facades:
		# Give return_to_title a live, unfinished outgoing context so its real
		# autosave is also a valid candidate for continue_game.
		StellaRuntime._prepare_scenario(NAVIGATION_SCENARIO)
		StellaRuntime.title_scene_path = NAVIGATION_TITLE_SCENE
		StellaRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)
		StellaRuntime.return_to_title()
		(facade["call"] as Callable).call_deferred()
		if not await _wait_for_navigation_destination(
			NAVIGATION_GAME_SCENE,
			GameStateMachine.State.PLAYING,
			true,
		):
			failures.append(
				"%s did not supersede return_to_title" % facade["name"]
			)
			break
		if StellaRuntime.title_scene_path != NAVIGATION_TITLE_SCENE:
			failures.append(
				"stale return normalized the title path after %s won"
				% facade["name"]
			)
		StellaRuntime._cancel_active_gameplay()

	# Reverse the ordering: a later return owns the final scene and must leave no
	# context from the superseded start_game continuation alive.
	if failures.is_empty():
		StellaRuntime.title_scene_path = NAVIGATION_TITLE_SCENE
		StellaRuntime.start_game(NAVIGATION_SCENARIO, NAVIGATION_GAME_SCENE)
		StellaRuntime.return_to_title()
		if not await _wait_for_navigation_destination(
			NAVIGATION_TITLE_SCENE,
			GameStateMachine.State.TITLE,
			false,
		):
			failures.append("return_to_title did not supersede start_game")

	StellaRuntime._cancel_active_gameplay()
	StellaRuntime.delete_save(NAVIGATION_SAVE_SLOT)
	StellaRuntime.delete_quick_save()
	StellaRuntime.delete_auto_save()
	var probe_save_dir := ProjectSettings.globalize_path(
		StellaRuntime.save_manager.save_dir,
	)
	StellaRuntime.save_manager.save_dir = original_save_dir
	StellaRuntime.config.game_scene = original_game_scene
	if DirAccess.dir_exists_absolute(probe_save_dir):
		DirAccess.remove_absolute(probe_save_dir)
	_finish("navigation-interleaving-ok", failures)


func _probe_same_basename_save_identity(
	failures: PackedStringArray,
) -> void:
	var scenario_paths := [SAME_NAME_SCENARIO_A, SAME_NAME_SCENARIO_B]
	for scenario_path: String in scenario_paths:
		var absolute_dir := ProjectSettings.globalize_path(
			scenario_path.get_base_dir(),
		)
		if DirAccess.make_dir_recursive_absolute(absolute_dir) != OK:
			failures.append("could not create same-name scenario directory")
			_cleanup_same_basename_scenarios()
			return
		var scenario_file := FileAccess.open(scenario_path, FileAccess.WRITE)
		if scenario_file == null:
			failures.append("could not create same-name scenario fixture")
			_cleanup_same_basename_scenarios()
			return
		var suffix := "a" if scenario_path == SAME_NAME_SCENARIO_A else "b"
		scenario_file.store_string(
			"@chapter review_%s \"Review %s\"\n"
			% [suffix, suffix.to_upper()]
			+ "@scene start\n"
			+ "@set branch = \"%s\"\n" % suffix
		)
		scenario_file.close()

	if not StellaRuntime._prepare_scenario(SAME_NAME_SCENARIO_A):
		failures.append("could not prepare first same-name scenario")
		_cleanup_same_basename_scenarios()
		return
	StellaRuntime._last_scenario_path = SAME_NAME_SCENARIO_A
	StellaRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)
	var active_context: ScenarioContext = StellaRuntime.engine.context
	if active_context == null:
		failures.append("same-name scenario did not establish a context")
		_cleanup_same_basename_scenarios()
		return
	var active_scene := get_tree().current_scene
	var active_scene_path := (
		active_scene.scene_file_path if active_scene != null else ""
	)
	var identity_a := active_context.scenario_data.source_identity
	var parsed_b: ScenarioData = StellaRuntime._parse_scenario(
		SAME_NAME_SCENARIO_B,
	)
	if (
		parsed_b == null
		or active_context.scenario_data.id != "shared"
		or parsed_b.id != "shared"
		or identity_a.is_empty()
		or parsed_b.source_identity.is_empty()
		or identity_a == parsed_b.source_identity
	):
		failures.append("same-basename scenarios did not get distinct identities")
		_cleanup_same_basename_scenarios()
		return

	var identity_slot := NAVIGATION_SAVE_SLOT + 10
	StellaRuntime.save(identity_slot)
	StellaRuntime.quick_save()
	StellaRuntime._last_scenario_path = SAME_NAME_SCENARIO_B
	var load_result: Variant = await StellaRuntime.load_game(
		identity_slot,
		SAME_NAME_SCENARIO_B,
		NAVIGATION_GAME_SCENE,
	)
	var quick_result: Variant = await StellaRuntime.quick_load()
	var manual_continue_result: Variant = await StellaRuntime.continue_from_save(
		identity_slot,
	)
	var continue_result: Variant = await StellaRuntime.continue_game()
	if load_result != false:
		failures.append("load_game accepted a save from same-named source A")
	if quick_result != false:
		failures.append("quick_load accepted a save from same-named source A")
	if manual_continue_result != false:
		failures.append("continue_from_save accepted same-named source A")
	if continue_result != false:
		failures.append("continue_game accepted same-named source A")
	if StellaRuntime.engine.context != active_context or active_context.is_finished:
		failures.append("same-name save rejection replaced the active context")
	var final_scene := get_tree().current_scene
	if final_scene == null or final_scene.scene_file_path != active_scene_path:
		failures.append("same-name save rejection replaced the active scene")
	if not StellaRuntime._navigation_kind.is_empty():
		failures.append("same-name save rejection acquired navigation ownership")

	StellaRuntime.delete_save(identity_slot)
	StellaRuntime.delete_quick_save()
	_cleanup_same_basename_scenarios()


func _cleanup_same_basename_scenarios() -> void:
	for scenario_path: String in [SAME_NAME_SCENARIO_A, SAME_NAME_SCENARIO_B]:
		var absolute_path := ProjectSettings.globalize_path(scenario_path)
		if FileAccess.file_exists(scenario_path):
			DirAccess.remove_absolute(absolute_path)
		var absolute_dir := absolute_path.get_base_dir()
		if DirAccess.dir_exists_absolute(absolute_dir):
			DirAccess.remove_absolute(absolute_dir)


func _probe_failed_navigation_preserves_owner(
	failures: PackedStringArray,
) -> void:
	StellaRuntime._prepare_scenario(NAVIGATION_SCENARIO)
	StellaRuntime._last_scenario_path = NAVIGATION_SCENARIO
	StellaRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)
	var active_context: ScenarioContext = StellaRuntime.engine.context
	if active_context == null:
		failures.append("could not establish the active context for failure probes")
		return
	var active_scene := get_tree().current_scene
	var active_scene_path := (
		active_scene.scene_file_path if active_scene != null else ""
	)
	StellaRuntime.start_game(
		NAVIGATION_SCENARIO,
		"res://tests/fixtures/startup/missing_game_target.tscn",
	)
	await get_tree().process_frame
	if StellaRuntime.engine.context != active_context or active_context.is_finished:
		failures.append("missing game target destroyed the active context")
	if get_tree().current_scene.scene_file_path != active_scene_path:
		failures.append("missing game target replaced the active scene")
	if StellaRuntime.game_state.current_state != GameStateMachine.State.PLAYING:
		failures.append("missing game target changed active game state")
	if StellaRuntime._last_scenario_path != NAVIGATION_SCENARIO:
		failures.append("missing game target changed the active scenario path")

	var degraded_game_path := "user://stella_probe_degraded_game.tscn"
	var degraded_game := FileAccess.open(degraded_game_path, FileAccess.WRITE)
	if degraded_game == null:
		failures.append("could not create the degraded game fixture")
	else:
		degraded_game.store_string(
			"[gd_scene load_steps=2 format=3]\n\n"
			+ "[ext_resource type=\"Script\" "
			+ "path=\"user://PRIVATE_DEGRADED_GAME_DEPENDENCY.gd\" "
			+ "id=\"1_missing\"]\n\n"
			+ "[node name=\"DegradedGame\" type=\"Node\"]\n"
			+ "script = ExtResource(\"1_missing\")\n"
		)
		degraded_game.close()
		StellaRuntime.start_game(NAVIGATION_SCENARIO, degraded_game_path)
		await get_tree().process_frame
		if StellaRuntime.engine.context != active_context or active_context.is_finished:
			failures.append("degraded game destroyed the active context")
		if get_tree().current_scene.scene_file_path != active_scene_path:
			failures.append("degraded game replaced the active scene")
	var unknown_tag_game_path := "user://stella_probe_unknown_tag_game.tscn"
	var unknown_tag_game := FileAccess.open(
		unknown_tag_game_path,
		FileAccess.WRITE,
	)
	if unknown_tag_game == null:
		failures.append("could not create the unknown-tag game fixture")
	else:
		unknown_tag_game.store_string(
			"[gd_scene format=3]\n\n"
			+ "[PRIVATE_GAME_BODY_TAG_SENTINEL]\n"
		)
		unknown_tag_game.close()
		StellaRuntime.start_game(NAVIGATION_SCENARIO, unknown_tag_game_path)
		await get_tree().process_frame
		if StellaRuntime.engine.context != active_context or active_context.is_finished:
			failures.append("unknown-tag game destroyed the active context")
		if get_tree().current_scene.scene_file_path != active_scene_path:
			failures.append("unknown-tag game replaced the active scene")
	var semantic_game_path := "user://stella_probe_semantic_game.tscn"
	var semantic_game := FileAccess.open(semantic_game_path, FileAccess.WRITE)
	if semantic_game == null:
		failures.append("could not create the semantic game fixture")
	else:
		semantic_game.store_string(
			"[gd_scene format=3]\n\n"
			+ "[node name=\"SemanticGame\" "
			+ "type=\"PRIVATE_GAME_NODE_TYPE_SENTINEL\"]\n"
		)
		semantic_game.close()
		StellaRuntime.start_game(NAVIGATION_SCENARIO, semantic_game_path)
		await get_tree().process_frame
		if StellaRuntime.engine.context != active_context or active_context.is_finished:
			failures.append("semantic game destroyed the active context")
		if get_tree().current_scene.scene_file_path != active_scene_path:
			failures.append("semantic game replaced the active scene")

	var semantic_overlay_path := "user://stella_probe_semantic_overlay.tscn"
	var semantic_overlay := FileAccess.open(
		semantic_overlay_path,
		FileAccess.WRITE,
	)
	if semantic_overlay == null:
		failures.append("could not create the semantic overlay fixture")
	else:
		semantic_overlay.store_string(
			"[gd_scene format=3]\n\n"
			+ "[node name=\"SemanticOverlay\" type=\"Node\"]\n\n"
			+ "[node name=\"Child\" type=\"Node\" "
			+ "parent=\"PRIVATE_OVERLAY_PARENT_PATH_SENTINEL\"]\n"
		)
		semantic_overlay.close()
		var original_settings_scene: String = StellaRuntime.config.settings_scene
		var original_overlay := StellaRuntime._current_overlay
		var original_state: int = StellaRuntime.game_state.current_state
		StellaRuntime.config.settings_scene = semantic_overlay_path
		StellaRuntime.show_settings()
		StellaRuntime.config.settings_scene = original_settings_scene
		if StellaRuntime._current_overlay != original_overlay:
			failures.append("semantic overlay replaced the active overlay owner")
		if StellaRuntime.game_state.current_state != original_state:
			failures.append("semantic overlay changed the active game state")
		if StellaRuntime.engine.context != active_context:
			failures.append("semantic overlay replaced the active context")
		if get_tree().current_scene.scene_file_path != active_scene_path:
			failures.append("semantic overlay replaced the active scene")
	StellaRuntime.start_game(
		"res://tests/fixtures/scenarios/missing_navigation_scenario.stla",
		NAVIGATION_GAME_SCENE,
	)
	await get_tree().process_frame
	if StellaRuntime.engine.context != active_context or active_context.is_finished:
		failures.append("missing scenario destroyed the active context")

	var invalid_save_slot := NAVIGATION_SAVE_SLOT + 1
	var invalid_save_path := (
		StellaRuntime.save_manager.save_dir
		+ "save_%d.json" % invalid_save_slot
	)
	var invalid_save := FileAccess.open(invalid_save_path, FileAccess.WRITE)
	if invalid_save == null:
		failures.append("could not create the invalid save fixture")
	else:
		invalid_save.store_string('{"scenario_context":"invalid","timestamp":1}')
		invalid_save.close()
		var invalid_load_result: Variant = await StellaRuntime.load_game(
			invalid_save_slot,
			NAVIGATION_SCENARIO,
			NAVIGATION_GAME_SCENE,
		)
		if invalid_load_result != false:
			failures.append("invalid save was accepted by load_game")
		await get_tree().process_frame
		if StellaRuntime.engine.context != active_context or active_context.is_finished:
			failures.append("invalid save destroyed the active context")
		StellaRuntime.delete_save(invalid_save_slot)

	var semantic_save_slot := NAVIGATION_SAVE_SLOT + 2
	var semantic_save_path := (
		StellaRuntime.save_manager.save_dir
		+ "save_%d.json" % semantic_save_slot
	)
	var semantic_save := FileAccess.open(semantic_save_path, FileAccess.WRITE)
	if semantic_save == null:
		failures.append("could not create the semantic save fixture")
	else:
		semantic_save.store_string(JSON.stringify({
			"scenario_context": {
				"scenario_id": "presentation_profile",
				"scene_index": 999999,
				"command_index": 0,
			},
			"timestamp": 1,
		}))
		semantic_save.close()
		var semantic_load_result: Variant = await StellaRuntime.load_game(
			semantic_save_slot,
			NAVIGATION_SCENARIO,
			NAVIGATION_GAME_SCENE,
		)
		if semantic_load_result != false:
			failures.append("semantic save corruption was accepted")
		await get_tree().process_frame
		if StellaRuntime.engine.context != active_context or active_context.is_finished:
			failures.append("semantic save corruption destroyed the active context")
		if get_tree().current_scene.scene_file_path != active_scene_path:
			failures.append("semantic save corruption replaced the active scene")

	StellaRuntime._cancel_active_gameplay()
	StellaRuntime.game_state.transition_to(GameStateMachine.State.TITLE)
	var title_scene := get_tree().current_scene
	var title_scene_path := title_scene.scene_file_path if title_scene != null else ""
	StellaRuntime.start_game(
		NAVIGATION_SCENARIO,
		"res://tests/fixtures/startup/missing_title_side_game.tscn",
	)
	await get_tree().process_frame
	if StellaRuntime.engine.context != null:
		failures.append("failed title-side start created a context")
	if get_tree().current_scene.scene_file_path != title_scene_path:
		failures.append("failed title-side start replaced the title scene")
	if StellaRuntime.game_state.current_state != GameStateMachine.State.TITLE:
		failures.append("failed title-side start left TITLE state")
	if not StellaRuntime._navigation_kind.is_empty():
		failures.append("failed preflight acquired navigation ownership")

	# Repeat the deep-preflight and semantic-save failures from TITLE. Neither
	# path may create a context, replace the title scene, or acquire navigation
	# ownership before validation has completed.
	StellaRuntime.start_game(NAVIGATION_SCENARIO, degraded_game_path)
	await get_tree().process_frame
	if StellaRuntime.engine.context != null:
		failures.append("title-side degraded game created a context")
	if get_tree().current_scene.scene_file_path != title_scene_path:
		failures.append("title-side degraded game replaced the title scene")
	if StellaRuntime.game_state.current_state != GameStateMachine.State.TITLE:
		failures.append("title-side degraded game left TITLE state")
	if not StellaRuntime._navigation_kind.is_empty():
		failures.append("title-side degraded game acquired navigation ownership")
	StellaRuntime.start_game(NAVIGATION_SCENARIO, unknown_tag_game_path)
	await get_tree().process_frame
	if StellaRuntime.engine.context != null:
		failures.append("title-side unknown-tag game created a context")
	if get_tree().current_scene.scene_file_path != title_scene_path:
		failures.append("title-side unknown-tag game replaced the title scene")
	if StellaRuntime.game_state.current_state != GameStateMachine.State.TITLE:
		failures.append("title-side unknown-tag game left TITLE state")
	if not StellaRuntime._navigation_kind.is_empty():
		failures.append("title-side unknown-tag game acquired navigation ownership")
	StellaRuntime.start_game(NAVIGATION_SCENARIO, semantic_game_path)
	await get_tree().process_frame
	if StellaRuntime.engine.context != null:
		failures.append("title-side semantic game created a context")
	if get_tree().current_scene.scene_file_path != title_scene_path:
		failures.append("title-side semantic game replaced the title scene")
	if StellaRuntime.game_state.current_state != GameStateMachine.State.TITLE:
		failures.append("title-side semantic game left TITLE state")
	if not StellaRuntime._navigation_kind.is_empty():
		failures.append("title-side semantic game acquired navigation ownership")

	var title_semantic_result: Variant = await StellaRuntime.load_game(
		semantic_save_slot,
		NAVIGATION_SCENARIO,
		NAVIGATION_GAME_SCENE,
	)
	if title_semantic_result != false:
		failures.append("title-side semantic save corruption was accepted")
	if StellaRuntime.engine.context != null:
		failures.append("title-side semantic save created a context")
	if get_tree().current_scene.scene_file_path != title_scene_path:
		failures.append("title-side semantic save replaced the title scene")
	if StellaRuntime.game_state.current_state != GameStateMachine.State.TITLE:
		failures.append("title-side semantic save left TITLE state")

	DirAccess.remove_absolute(
		ProjectSettings.globalize_path(degraded_game_path),
	)
	if FileAccess.file_exists(unknown_tag_game_path):
		DirAccess.remove_absolute(
			ProjectSettings.globalize_path(unknown_tag_game_path),
		)
	for semantic_path: String in [semantic_game_path, semantic_overlay_path]:
		if FileAccess.file_exists(semantic_path):
			DirAccess.remove_absolute(
				ProjectSettings.globalize_path(semantic_path),
			)
	StellaRuntime.delete_save(semantic_save_slot)


func _probe_uid_navigation(failures: PackedStringArray) -> void:
	if StellaRuntime._canonical_resource_path(UID_GAME_SCENE) != UID_GAME_SCENE_PATH:
		failures.append("game UID did not resolve to its canonical scene")
		return
	if StellaRuntime._canonical_resource_path(UID_TITLE_SCENE) != NAVIGATION_TITLE_SCENE:
		failures.append("title UID did not resolve to its canonical scene")
		return
	if StellaRuntime._canonical_resource_path(UID_OVERLAY_SCENE) != UID_OVERLAY_SCENE_PATH:
		failures.append("overlay UID did not resolve to its canonical scene")
		return

	# Supersede a UID game request before its scene_changed continuation runs.
	# The pending slot must compare canonical paths and release for the title.
	StellaRuntime.title_scene_path = UID_TITLE_SCENE
	StellaRuntime.start_game(NAVIGATION_SCENARIO, UID_GAME_SCENE)
	StellaRuntime.return_to_title()
	if not await _wait_for_navigation_destination(
		NAVIGATION_TITLE_SCENE,
		GameStateMachine.State.TITLE,
		false,
	):
		failures.append("title could not supersede a pending UID game request")
		return

	await StellaRuntime.start_game(NAVIGATION_SCENARIO, UID_GAME_SCENE)
	if not await _wait_for_navigation_destination(
		UID_GAME_SCENE_PATH,
		GameStateMachine.State.PLAYING,
		true,
	):
		failures.append("UID game destination did not start a scenario")
		return

	StellaRuntime.title_scene_path = UID_TITLE_SCENE
	StellaRuntime.return_to_title()
	if not await _wait_for_navigation_destination(
		NAVIGATION_TITLE_SCENE,
		GameStateMachine.State.TITLE,
		false,
	):
		failures.append("UID title destination did not complete")
		return

	var original_settings_scene: String = StellaRuntime.config.settings_scene
	StellaRuntime.config.settings_scene = UID_OVERLAY_SCENE
	StellaRuntime.show_settings()
	var overlay := StellaRuntime._current_overlay
	if overlay == null or overlay.scene_file_path != UID_OVERLAY_SCENE_PATH:
		failures.append("UID overlay destination did not instantiate canonically")
	if StellaRuntime.game_state.current_state != GameStateMachine.State.SETTINGS:
		failures.append("UID overlay did not commit SETTINGS state")
	StellaRuntime.close_overlay()
	StellaRuntime.config.settings_scene = original_settings_scene
	await get_tree().process_frame


func _probe_scenario_signal_reentrancy(
	failures: PackedStringArray,
) -> void:
	var old_scenario_path := "user://stella_reentrant_old.stla"
	var file := FileAccess.open(old_scenario_path, FileAccess.WRITE)
	if file == null:
		failures.append("could not create the reentrant scenario fixture")
		return
	file.store_string("@chapter reentrant\n@scene old_reentrant\n@bg stale\n")
	file.close()

	var old_ended: Array[String] = []
	var old_scene_events: Array[String] = []
	var ended_listener := func(id: String) -> void:
		if id == "stella_reentrant_old":
			old_ended.append(id)
	var scene_listener := func(id: String) -> void:
		if id == "old_reentrant":
			old_scene_events.append(id)
	var started_listener := func(id: String) -> void:
		if id == "stella_reentrant_old":
			StellaRuntime.start_game(NAVIGATION_SCENARIO, NAVIGATION_GAME_SCENE)
	StellaRuntime.engine.scenario_ended.connect(ended_listener)
	StellaRuntime.engine.scene_changed.connect(scene_listener)
	SignalBus.scenario_started_event.connect(started_listener, CONNECT_ONE_SHOT)

	StellaRuntime.start_scenario(old_scenario_path)
	if not await _wait_for_navigation_destination(
		NAVIGATION_GAME_SCENE,
		GameStateMachine.State.PLAYING,
		true,
	):
		failures.append("reentrant scenario_started navigation did not win")
	if not old_ended.is_empty():
		failures.append("cancelled run emitted scenario_ended")
	if not old_scene_events.is_empty():
		failures.append("cancelled run emitted scene_changed after reentrancy")
	if (
		StellaRuntime.engine.context == null
		or StellaRuntime.engine.context.scenario_data.id
			!= NAVIGATION_SCENARIO.get_file().get_basename()
	):
		failures.append("stale lifecycle event replaced the newer context")

	if StellaRuntime.engine.scenario_ended.is_connected(ended_listener):
		StellaRuntime.engine.scenario_ended.disconnect(ended_listener)
	if StellaRuntime.engine.scene_changed.is_connected(scene_listener):
		StellaRuntime.engine.scene_changed.disconnect(scene_listener)
	if SignalBus.scenario_started_event.is_connected(started_listener):
		SignalBus.scenario_started_event.disconnect(started_listener)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(old_scenario_path))


func _probe_start_scenario_ownership(failures: PackedStringArray) -> void:
	var current_scene := get_tree().current_scene
	var current_path := current_scene.scene_file_path if current_scene != null else ""
	StellaRuntime.title_scene_path = NAVIGATION_TITLE_SCENE
	StellaRuntime.return_to_title()
	StellaRuntime.start_scenario(NAVIGATION_SCENARIO)
	for _frame_index in range(120):
		if StellaRuntime._navigation_kind.is_empty():
			break
		await get_tree().process_frame
	if StellaRuntime.engine.context == null:
		failures.append("start_scenario lost to an older return transaction")
	elif StellaRuntime.engine.context.scenario_data.id != (
		NAVIGATION_SCENARIO.get_file().get_basename()
	):
		failures.append("start_scenario installed the wrong context")
	if get_tree().current_scene.scene_file_path != current_path:
		failures.append("stale return replaced start_scenario's current scene")
	if StellaRuntime.game_state.current_state != GameStateMachine.State.PLAYING:
		failures.append("start_scenario did not retain PLAYING state")


func _invoke_navigation_start_game() -> void:
	await StellaRuntime.start_game(NAVIGATION_SCENARIO, NAVIGATION_GAME_SCENE)


func _invoke_navigation_load_game() -> void:
	await StellaRuntime.load_game(
		NAVIGATION_SAVE_SLOT,
		NAVIGATION_SCENARIO,
		NAVIGATION_GAME_SCENE,
	)


func _invoke_navigation_continue_from_save() -> void:
	await StellaRuntime.continue_from_save(NAVIGATION_SAVE_SLOT)


func _invoke_navigation_quick_load() -> void:
	await StellaRuntime.quick_load()


func _invoke_navigation_continue_game() -> void:
	await StellaRuntime.continue_game()


func _wait_for_navigation_destination(
	expected_path: String,
	expected_state: int,
	expect_context: bool,
) -> bool:
	for _frame_index in range(240):
		var current_scene := get_tree().current_scene
		var context_matches := (
			StellaRuntime.engine.context != null
			if expect_context
			else StellaRuntime.engine.context == null
		)
		if (
			StellaRuntime._navigation_kind.is_empty()
			and current_scene != null
			and current_scene.scene_file_path.simplify_path()
				== expected_path.simplify_path()
			and StellaRuntime.game_state.current_state == expected_state
			and context_matches
		):
			return true
		await get_tree().process_frame
	return false


func _write_degraded_title_fixtures() -> PackedStringArray:
	var missing_script_path := "user://stella_probe_missing_script_title.tscn"
	var missing_nested_path := "user://stella_probe_missing_nested_title.tscn"
	var wrong_base_path := "user://stella_probe_wrong_script_base_title.tscn"
	var wrong_texture_path := "user://stella_probe_wrong_texture.tres"
	var wrong_texture_title_path := (
		"user://stella_probe_wrong_texture_title.tscn"
	)
	var malformed_texture_path := "user://stella_probe_malformed_texture.tres"
	var malformed_texture_title_path := (
		"user://stella_probe_malformed_texture_title.tscn"
	)
	var undeclared_ext_path := "user://stella_probe_undeclared_ext_title.tscn"
	var undeclared_sub_path := "user://stella_probe_undeclared_sub_title.tscn"
	var invalid_constructor_path := (
		"user://stella_probe_invalid_constructor_title.tscn"
	)
	var invalid_packed_constructor_path := (
		"user://stella_probe_invalid_packed_constructor_title.tscn"
	)
	var leading_preamble_path := (
		"user://stella_probe_leading_preamble_title.tscn"
	)
	var bom_title_path := "user://PRIVATE_BOM_TITLE_PATH.tscn"
	var bom_dependency_path := "user://PRIVATE_BOM_DEPENDENCY.tres"
	var bom_dependency_title_path := (
		"user://stella_probe_bom_dependency_title.tscn"
	)
	var unknown_body_tag_path := (
		"user://stella_probe_unknown_body_tag_title.tscn"
	)
	var unknown_resource_tag_path := (
		"user://stella_probe_unknown_resource_tag.tres"
	)
	var unknown_resource_tag_title_path := (
		"user://stella_probe_unknown_resource_tag_title.tscn"
	)
	var unknown_node_type_path := (
		"user://stella_probe_unknown_node_type_title.tscn"
	)
	var unknown_subresource_type_path := (
		"user://stella_probe_unknown_subresource_type_title.tscn"
	)
	var missing_parent_path := (
		"user://stella_probe_missing_parent_title.tscn"
	)
	var missing_owner_path := (
		"user://stella_probe_missing_owner_title.tscn"
	)
	var invalid_attribute_path := (
		"user://stella_probe_invalid_attribute_title.tscn"
	)
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
		wrong_texture_path: (
			"[gd_resource type=\"Resource\" format=3]\n\n[resource]\n"
		),
		wrong_texture_title_path: (
			"[gd_scene load_steps=2 format=3]\n\n"
			+ "[ext_resource type=\"Texture2D\" "
			+ "path=\"%s\" id=\"1_texture\"]\n\n" % wrong_texture_path
			+ "[node name=\"WrongTextureTitle\" type=\"Sprite2D\"]\n"
			+ "texture = ExtResource(\"1_texture\")\n"
		),
		malformed_texture_path: (
			"[gd_resource type=\"Texture2D\" format=3]\n\n"
			+ "[resource]\n"
			+ "private_value = PRIVATE_DEGRADED_TITLE_DEPENDENCY_VALUE\n"
		),
		malformed_texture_title_path: (
			"[gd_scene load_steps=2 format=3]\n\n"
			+ "[ext_resource type=\"Texture2D\" "
			+ "path=\"%s\" id=\"1_texture\"]\n\n"
			% malformed_texture_path
			+ "[node name=\"MalformedTextureTitle\" type=\"Sprite2D\"]\n"
			+ "texture = ExtResource(\"1_texture\")\n"
		),
		undeclared_ext_path: (
			"[gd_scene format=3]\n\n"
			+ "[node name=\"UndeclaredExtTitle\" type=\"Node\"]\n"
			+ "metadata/private = ExtResource(\"PRIVATE_EXT_SENTINEL\")\n"
		),
		undeclared_sub_path: (
			"[gd_scene format=3]\n\n"
			+ "[node name=\"UndeclaredSubTitle\" type=\"Node\"]\n"
			+ "metadata/private = SubResource(\"PRIVATE_SUB_SENTINEL\")\n"
		),
		invalid_constructor_path: (
			"[gd_scene format=3]\n\n"
			+ "[node name=\"InvalidConstructorTitle\" type=\"Node\"]\n"
			+ "metadata/private = Vector2(1, 2, PRIVATE_VECTOR_SENTINEL)\n"
		),
		invalid_packed_constructor_path: (
			"[gd_scene format=3]\n\n"
			+ "[node name=\"InvalidPackedTitle\" type=\"Node\"]\n"
			+ "metadata/private = "
			+ "PackedByteArray(\"PRIVATE_PACKED_SENTINEL\")\n"
		),
		leading_preamble_path: (
			"\n; legal leading resource comment\n\n"
			+ "[gd_scene format=3]\n\n"
			+ "[node name=\"LeadingPreambleTitle\" type=\"Node\"]\n"
			+ "metadata/private = PRIVATE_LEADING_PREAMBLE_SENTINEL\n"
		),
		bom_dependency_title_path: (
			"[gd_scene load_steps=2 format=3]\n\n"
			+ "[ext_resource type=\"Texture2D\" path=\"%s\" "
			% bom_dependency_path
			+ "id=\"1_texture\"]\n\n"
			+ "[node name=\"BomDependencyTitle\" type=\"Sprite2D\"]\n"
			+ "texture = ExtResource(\"1_texture\")\n"
		),
		unknown_body_tag_path: (
			"[gd_scene format=3]\n\n"
			+ "[PRIVATE_BODY_TAG_SENTINEL]\n"
		),
		unknown_resource_tag_path: (
			"[gd_resource type=\"Texture2D\" format=3]\n\n"
			+ "[PRIVATE_RESOURCE_TAG_SENTINEL]\n"
		),
		unknown_resource_tag_title_path: (
			"[gd_scene load_steps=2 format=3]\n\n"
			+ "[ext_resource type=\"Texture2D\" path=\"%s\" "
			% unknown_resource_tag_path
			+ "id=\"1_texture\"]\n\n"
			+ "[node name=\"UnknownResourceTagTitle\" type=\"Sprite2D\"]\n"
			+ "texture = ExtResource(\"1_texture\")\n"
		),
		unknown_node_type_path: (
			"[gd_scene format=3]\n\n"
			+ "[node name=\"UnknownNodeType\" "
			+ "type=\"PRIVATE_NODE_TYPE_SENTINEL\"]\n"
		),
		unknown_subresource_type_path: (
			"[gd_scene load_steps=2 format=3]\n\n"
			+ "[sub_resource "
			+ "type=\"PRIVATE_SUBRESOURCE_TYPE_SENTINEL\" id=\"Private\"]\n\n"
			+ "[node name=\"UnknownSubresourceType\" type=\"Node\"]\n"
		),
		missing_parent_path: (
			"[gd_scene format=3]\n\n"
			+ "[node name=\"MissingParent\" type=\"Node\"]\n\n"
			+ "[node name=\"Child\" type=\"Node\" "
			+ "parent=\"PRIVATE_PARENT_PATH_SENTINEL\"]\n"
		),
		missing_owner_path: (
			"[gd_scene format=3]\n\n"
			+ "[node name=\"MissingOwner\" type=\"Node\"]\n\n"
			+ "[node name=\"Child\" type=\"Node\" parent=\".\" "
			+ "owner=\"PRIVATE_OWNER_PATH_SENTINEL\"]\n"
		),
		invalid_attribute_path: (
			"[gd_scene format=3]\n\n"
			+ "[node name=\"InvalidAttribute\" type=\"Node\" "
			+ "PRIVATE$ATTRIBUTE$SENTINEL=\"secret\"]\n"
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
	var binary_sources := {
		bom_title_path: (
			"[gd_scene format=3]\n\n"
			+ "[node name=\"BomTitle\" type=\"Node\"]\n"
		),
		bom_dependency_path: (
			"[gd_resource type=\"Texture2D\" format=3]\n\n"
			+ "[resource]\n"
		),
	}
	for path: String in binary_sources:
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file == null:
			_cleanup_degraded_title_fixtures(paths)
			return PackedStringArray()
		var contents := PackedByteArray([0xEF, 0xBB, 0xBF])
		contents.append_array(String(binary_sources[path]).to_utf8_buffer())
		file.store_buffer(contents)
		file.close()
		paths.append(path)
	return paths


func _cleanup_degraded_title_fixtures(paths: PackedStringArray) -> void:
	for path: String in paths:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _probe_relocated_uid_dependency(failures: PackedStringArray) -> void:
	var scene_path := "user://stella_probe_uid_relocated_title.tscn"
	var file := FileAccess.open(scene_path, FileAccess.WRITE)
	if file == null:
		failures.append("could not create the relocated-UID title fixture")
		return
	file.store_string(
		"[gd_scene load_steps=2 format=3]\n\n"
		+ ("[ext_resource type=\"Script\" uid=\"%s\" "
			% UID_DEPENDENCY_TEXT)
		+ "path=\"user://stale_relocated_dependency.gd\" "
		+ "id=\"1_script\"]\n\n"
		+ "[node name=\"UidRelocatedTitle\" type=\"Node\"]\n"
		+ "script = ExtResource(\"1_script\")\n"
	)
	file.close()

	var dependencies := ResourceLoader.get_dependencies(scene_path)
	if dependencies.size() != 1:
		failures.append("relocated-UID fixture did not expose one dependency")
	elif (
		StellaRuntime._resource_dependency_path(dependencies[0])
		!= UID_DEPENDENCY_SCRIPT
	):
		failures.append("dependency preflight preferred the stale UID fallback")
	var loaded := StellaRuntime._load_title_scene(scene_path)
	if loaded == null:
		failures.append("relocated UID title was rejected")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(scene_path))


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
