extends GutTest

const NESTED_PATH = "user://text_inspector_nested.tscn"
const OUTER_PATH = "user://text_inspector_outer.tscn"
const INVALID_PATH = "user://text_inspector_invalid.tscn"

var _inspector := TextResourceInspector.new()


func after_each():
	for path: String in [NESTED_PATH, OUTER_PATH, INVALID_PATH]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_typed_api_accepts_numeric_ids_and_effective_nested_overrides():
	_write_text(
		NESTED_PATH,
		(
			"[gd_scene format=3]\n\n"
			+ "[node name=\"NestedRoot\" type=\"Node\"]\n\n"
			+ "[node name=\"Child\" type=\"Node\" parent=\".\"]\n"
		),
	)
	_write_text(
		OUTER_PATH,
		(
			"[gd_scene load_steps=2 format=3]\n\n"
			+ "[ext_resource type=\"PackedScene\" path=\"%s\" id=1]\n\n"
			% NESTED_PATH
			+ "[node name=\"Outer\" type=\"Node\"]\n\n"
			+ "[node name=\"Nested\" parent=\".\" instance=ExtResource(\"1\")]\n\n"
			+ "[node name=\"Child\" parent=\"Nested\" index=\"0\"]\n"
			+ "script = null\n\n"
			+ "[editable path=\"Nested\"]\n"
		),
	)

	var result: TextResourceInspector.InspectionResult = _inspector.inspect(
		OUTER_PATH,
		"PackedScene",
	)

	assert_true(result.ok)
	assert_true(result.matches_expected_type)
	assert_true(result.node_paths.has("Nested/Child"))
	assert_eq(result.dependencies.size(), 1)
	var scene := ResourceLoader.load(OUTER_PATH, "PackedScene") as PackedScene
	assert_not_null(scene)
	var instance := scene.instantiate() if scene != null else null
	assert_not_null(instance)
	if instance != null:
		assert_not_null(instance.get_node_or_null("Nested/Child"))
		instance.free()
	assert_engine_error_count(0)


func test_numeric_and_quoted_ids_share_only_their_unambiguous_key():
	_write_text(
		OUTER_PATH,
		(
			"[gd_scene load_steps=3 format=3]\n\n"
			+ "[ext_resource type=\"Texture2D\" "
			+ "path=\"res://examples/demo/art/backgrounds/bg_cafe.png\" id=1]\n"
			+ "[ext_resource type=\"Texture2D\" "
			+ "path=\"res://examples/demo/art/backgrounds/bg_school_gate.png\" "
			+ "id=\"01\"]\n\n"
			+ "[node name=\"ResourceIds\" type=\"Node\"]\n"
			+ "metadata/numeric = ExtResource(\"1\")\n"
			+ "metadata/quoted = ExtResource(\"01\")\n"
		),
	)
	var result := _inspector.inspect(OUTER_PATH, "PackedScene")
	assert_true(result.ok)
	assert_eq(result.dependencies.size(), 2)
	var scene := ResourceLoader.load(OUTER_PATH, "PackedScene") as PackedScene
	assert_not_null(scene)
	var instance := scene.instantiate() if scene != null else null
	assert_not_null(instance)
	if instance != null:
		assert_not_null(instance.get_meta("numeric"))
		assert_not_null(instance.get_meta("quoted"))
		instance.free()
	assert_engine_error_count(0)


func test_semantic_degradation_is_rejected_without_engine_diagnostics():
	var invalid_sources := PackedStringArray([
		(
			"[gd_scene format=3]\n\n"
			+ "[node name=\"Root\" type=\"PRIVATE_NODE_TYPE_SENTINEL\"]\n"
		),
		(
			"[gd_scene load_steps=2 format=3]\n\n"
			+ "[sub_resource type=\"PRIVATE_SUBRESOURCE_TYPE_SENTINEL\" id=\"One\"]\n\n"
			+ "[node name=\"Root\" type=\"Node\"]\n"
		),
		(
			"[gd_scene format=3]\n\n"
			+ "[node name=\"Root\" type=\"Node\"]\n\n"
			+ "[node name=\"Child\" type=\"Node\" "
			+ "parent=\"PRIVATE_PARENT_PATH_SENTINEL\"]\n"
		),
		(
			"[gd_scene format=3]\n\n"
			+ "[node name=\"Root\" type=\"Node\" "
			+ "PRIVATE$ATTRIBUTE$SENTINEL=\"secret\"]\n"
		),
	])
	for source: String in invalid_sources:
		_write_text(INVALID_PATH, source)
		assert_false(_inspector.inspect(INVALID_PATH).ok)
	assert_engine_error_count(0)


func test_missing_owner_and_connection_paths_are_rejected():
	var invalid_sources := PackedStringArray([
		(
			"[gd_scene format=3]\n\n"
			+ "[node name=\"Root\" type=\"Node\"]\n\n"
			+ "[node name=\"Child\" type=\"Node\" parent=\".\" "
			+ "owner=\"PRIVATE_OWNER_PATH_SENTINEL\"]\n"
		),
		(
			"[gd_scene format=3]\n\n"
			+ "[node name=\"Root\" type=\"Node\"]\n\n"
			+ "[connection signal=\"ready\" from=\".\" "
			+ "to=\"PRIVATE_CONNECTION_PATH_SENTINEL\" method=\"queue_free\"]\n"
		),
	])
	for source: String in invalid_sources:
		_write_text(INVALID_PATH, source)
		assert_false(_inspector.inspect(INVALID_PATH).ok)
	assert_engine_error_count(0)


func test_attribute_token_fuzz_corpus_fails_closed_without_engine_diagnostics():
	var rejected_count := 0
	for codepoint in range(0x20, 0x7F):
		var character := String.chr(codepoint)
		if (
			character == "_"
			or character >= "0" and character <= "9"
			or character >= "A" and character <= "Z"
			or character >= "a" and character <= "z"
		):
			continue
		_write_text(
			INVALID_PATH,
			(
				"[gd_scene format=3]\n\n"
				+ "[node name=\"Root\" type=\"Node\" "
				+ "private%ssentinel=\"secret\"]\n" % character
			),
		)
		assert_false(_inspector.inspect(INVALID_PATH).ok)
		rejected_count += 1
	assert_gt(rejected_count, 20)
	assert_engine_error_count(0)


func test_canonical_framework_and_demo_resources_match_godot_loader():
	var paths := PackedStringArray()
	_collect_text_resources("res://addons/stella/scenes", paths)
	_collect_text_resources("res://examples/demo/scenes", paths)
	assert_gt(paths.size(), 0)
	for path: String in paths:
		var expected_type := "PackedScene" if path.ends_with(".tscn") else ""
		var result := _inspector.inspect(path, expected_type)
		assert_true(result.ok, path)
		if not expected_type.is_empty():
			assert_true(result.matches_expected_type, path)
		assert_not_null(ResourceLoader.load(path), path)
	assert_engine_error_count(0)


func _write_text(path: String, source: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert_not_null(file)
	if file != null:
		file.store_string(source)
		file.close()


func _collect_text_resources(
	directory_path: String,
	result: PackedStringArray,
) -> void:
	var directory := DirAccess.open(directory_path)
	assert_not_null(directory)
	if directory == null:
		return
	directory.list_dir_begin()
	var entry := directory.get_next()
	while not entry.is_empty():
		var path := directory_path.path_join(entry)
		if directory.current_is_dir():
			_collect_text_resources(path, result)
		elif entry.ends_with(".tscn") or entry.ends_with(".tres"):
			result.append(path)
		entry = directory.get_next()
	directory.list_dir_end()
