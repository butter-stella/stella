extends GutTest

const NESTED_PATH = "user://text_inspector_nested.tscn"
const OUTER_PATH = "user://text_inspector_outer.tscn"
const INVALID_PATH = "user://text_inspector_invalid.tscn"
const BINARY_NESTED_PATH = "user://text_inspector_nested.scn"
const BINARY_OUTER_PATH = "user://text_inspector_binary_outer.tscn"
const ESCAPED_PATH = "user://text_inspector_escaped_tags.tscn"
const NUMERIC_ID_MATRIX_PATH = "user://text_inspector_numeric_id_matrix.tscn"
const REPEATED_PATH_PREFIX = "user://text_inspector_repeated_"
const REPEATED_DEPTH = 16

var _inspector := TextResourceInspector.new()


func after_each():
	var paths := PackedStringArray([
		NESTED_PATH,
		OUTER_PATH,
		INVALID_PATH,
		BINARY_NESTED_PATH,
		BINARY_OUTER_PATH,
		ESCAPED_PATH,
		NUMERIC_ID_MATRIX_PATH,
	])
	for depth in range(REPEATED_DEPTH + 1):
		paths.append(REPEATED_PATH_PREFIX + str(depth) + ".tscn")
	for path: String in paths:
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


func test_binary_nested_scene_exposes_real_child_for_property_override():
	var binary_root := Node.new()
	binary_root.name = "NestedRoot"
	var binary_child := Node.new()
	binary_child.name = "Child"
	binary_root.add_child(binary_child)
	binary_child.owner = binary_root
	var binary_scene := PackedScene.new()
	assert_eq(binary_scene.pack(binary_root), OK)
	assert_eq(ResourceSaver.save(binary_scene, BINARY_NESTED_PATH), OK)
	binary_root.free()

	_write_text(
		BINARY_OUTER_PATH,
		(
			"[gd_scene load_steps=2 format=3]\n\n"
			+ "[ext_resource type=\"PackedScene\" path=\"%s\" "
			% BINARY_NESTED_PATH
			+ "id=\"1_nested\"]\n\n"
			+ "[node name=\"Outer\" type=\"Node\"]\n\n"
			+ "[node name=\"Nested\" parent=\".\" "
			+ "instance=ExtResource(\"1_nested\")]\n\n"
			+ "[node name=\"Child\" parent=\"Nested\" index=\"0\"]\n"
			+ "metadata/probe = \"override\"\n\n"
			+ "[editable path=\"Nested\"]\n"
		),
	)

	var result := _inspector.inspect(BINARY_OUTER_PATH, "PackedScene")
	assert_true(result.ok)
	assert_true(result.matches_expected_type)
	assert_true(result.node_paths.has("Nested/Child"))
	assert_eq(result.visited_resource_count, 2)
	var loaded := ResourceLoader.load(BINARY_OUTER_PATH, "PackedScene") as PackedScene
	assert_not_null(loaded)
	var instance := loaded.instantiate() if loaded != null else null
	assert_not_null(instance)
	if instance != null:
		var child := instance.get_node_or_null("Nested/Child")
		assert_not_null(child)
		if child != null:
			assert_eq(child.get_meta("probe"), "override")
		instance.free()
	assert_engine_error_count(0)


func test_tag_strings_and_signed_numeric_ids_match_godot_loader():
	_write_text(
		ESCAPED_PATH,
		(
			"[gd_scene load_steps=2 format=3]\n\n"
			+ "[ext_resource type=\"Texture\\U000032D\" "
			+ "path=\"res://examples/demo/art/backgrounds/bg_\\u0063afe.png\" "
			+ "id=-1]\n\n"
			+ "[node name=\"Root\\\"Quoted\\\\Path\" type=\"Sprite2D\"]\n"
			+ "texture = ExtResource(-1)\n"
		),
	)

	var result := _inspector.inspect(ESCAPED_PATH, "PackedScene")
	assert_true(result.ok)
	assert_true(result.matches_expected_type)
	assert_eq(result.dependencies.size(), 1)
	if result.dependencies.size() == 1:
		assert_eq(
			result.dependencies[0]["path"],
			"res://examples/demo/art/backgrounds/bg_cafe.png",
		)
		assert_eq(result.dependencies[0]["type"], "Texture2D")
	var scene := ResourceLoader.load(ESCAPED_PATH, "PackedScene") as PackedScene
	assert_not_null(scene)
	var instance := scene.instantiate() if scene != null else null
	assert_true(instance is Sprite2D)
	if instance is Sprite2D:
		assert_eq(instance.name, 'Root"Quoted\\Path')
		assert_not_null(instance.texture)
		instance.free()
	assert_engine_error_count(0)


func test_numeric_resource_id_grammar_matches_godot_loader():
	var cases := [
		{"literal": "+1", "accepted": false},
		{
			"literal": "9223372036854775808",
			"reference": "-9223372036854775808",
			"accepted": true,
		},
		{
			"literal": "-9223372036854775809",
			"reference": "9223372036854775807",
			"accepted": true,
		},
		{"literal": "99999999999999999999", "accepted": true},
		{"literal": "1.0", "reference": '"1.0"', "accepted": true},
		{"literal": "1e1", "reference": "10.0", "accepted": true},
		{"literal": "-1e1", "reference": '"-10.0"', "accepted": true},
		{"literal": "1e309", "reference": '"inf"', "accepted": true},
		{"literal": "-1e309", "reference": '"-inf"', "accepted": true},
		{"literal": '"inf"', "reference": "1e309", "accepted": true},
		{"literal": '"-inf"', "reference": "-1e309", "accepted": true},
		{
			"literal": "1e33",
			"reference": '"1000000000000000089690419062898688.0"',
			"accepted": true,
		},
		{
			"literal": '"1000000000000000089690419062898688.0"',
			"reference": "1e33",
			"accepted": true,
		},
		{"literal": "-1e-20", "reference": '"-0.0"', "accepted": true},
		{"literal": '"-0.0"', "reference": "-1e-20", "accepted": true},
		{"literal": "0x10", "accepted": false},
	]
	for case: Dictionary in cases:
		var literal: String = case["literal"]
		var reference: String = case.get("reference", literal)
		var accepted: bool = case["accepted"]
		_write_text(
			NUMERIC_ID_MATRIX_PATH,
			(
				"[gd_scene load_steps=2 format=3]\n\n"
				+ "[ext_resource type=\"Texture2D\" "
				+ "path=\"res://examples/demo/art/backgrounds/bg_cafe.png\" "
				+ "id=%s]\n\n" % literal
				+ "[node name=\"Root\" type=\"Sprite2D\"]\n"
				+ "texture = ExtResource(%s)\n" % reference
			),
		)

		var result := _inspector.inspect(NUMERIC_ID_MATRIX_PATH, "PackedScene")
		assert_eq(result.ok, accepted, "inspector: %s" % literal)
		assert_eq(
			result.matches_expected_type,
			true,
			"typed result metadata: %s" % literal,
		)

		# These fixtures are handed to Godot only as a differential oracle. The
		# 4.6.1 parser logs its own overflow message for some accepted integer IDs,
		# so keep that oracle output out of the preflight diagnostic assertion.
		var previous_print_errors := Engine.print_error_messages
		Engine.print_error_messages = false
		var scene := ResourceLoader.load(
			NUMERIC_ID_MATRIX_PATH,
			"PackedScene",
			ResourceLoader.CACHE_MODE_IGNORE_DEEP,
		) as PackedScene
		Engine.print_error_messages = previous_print_errors
		assert_eq(scene != null, accepted, "Godot loader: %s" % literal)
		if scene != null:
			var instance := scene.instantiate() as Sprite2D
			assert_not_null(instance, "instance: %s" % literal)
			if instance != null:
				assert_not_null(instance.texture, "reference: %s" % literal)
				instance.free()
	assert_engine_error_count(0)


func test_quoted_resource_ids_share_canonical_domain_without_reparsing():
	assert_eq(
		TextResourceInspector._normalized_resource_id_value("", true),
		"id:",
	)
	assert_eq(
		TextResourceInspector._normalized_resource_id_value("", false),
		"",
	)
	assert_eq(
		TextResourceInspector._normalized_resource_id_value("1", false),
		TextResourceInspector._normalized_resource_id_value("1", true),
	)
	assert_eq(
		TextResourceInspector._normalized_resource_id_value("1e33", false),
		TextResourceInspector._normalized_resource_id_value(
			"1000000000000000089690419062898688.0",
			true,
		),
	)
	assert_eq(
		TextResourceInspector._normalized_resource_id_value("-1e-20", false),
		TextResourceInspector._normalized_resource_id_value("-0.0", true),
	)
	assert_ne(
		TextResourceInspector._normalized_resource_id_value("1", false),
		TextResourceInspector._normalized_resource_id_value("01", true),
	)
	for value in ["INF", "Inf", "-INF", "nan", "NaN", "Infinity", "1e1"]:
		assert_eq(
			TextResourceInspector._normalized_resource_id_value(value, true),
			"id:" + value,
			"ordinary quoted ID: %s" % value,
		)


func test_quoted_empty_ext_and_sub_resource_ids_match_godot_loader():
	_write_text(
		OUTER_PATH,
		(
			"[gd_scene load_steps=3 format=3]\n\n"
			+ "[ext_resource type=\"Texture2D\" "
			+ "path=\"res://examples/demo/art/backgrounds/bg_cafe.png\" "
			+ "id=\"\"]\n\n"
			+ "[sub_resource type=\"Gradient\" id=\"\"]\n\n"
			+ "[node name=\"QuotedEmptyIds\" type=\"Sprite2D\"]\n"
			+ "texture = ExtResource(\"\")\n"
			+ "metadata/empty_sub = SubResource(\"\")\n"
		),
	)

	var result := _inspector.inspect(OUTER_PATH, "PackedScene")
	assert_true(result.ok)
	assert_true(result.matches_expected_type)
	assert_eq(result.dependencies.size(), 1)
	var scene := ResourceLoader.load(
		OUTER_PATH,
		"PackedScene",
		ResourceLoader.CACHE_MODE_IGNORE_DEEP,
	) as PackedScene
	assert_not_null(scene)
	var instance := scene.instantiate() as Sprite2D if scene != null else null
	assert_not_null(instance)
	if instance != null:
		assert_not_null(instance.texture)
		assert_true(instance.get_meta("empty_sub") is Gradient)
		instance.free()
	assert_engine_error_count(0)


func test_repeated_instances_are_memoized_without_materializing_full_tree():
	_write_text(
		REPEATED_PATH_PREFIX + "0.tscn",
		"[gd_scene format=3]\n\n[node name=\"Leaf\" type=\"Node\"]\n",
	)
	for depth in range(1, REPEATED_DEPTH + 1):
		var child_path := REPEATED_PATH_PREFIX + str(depth - 1) + ".tscn"
		_write_text(
			REPEATED_PATH_PREFIX + str(depth) + ".tscn",
			(
				"[gd_scene load_steps=2 format=3]\n\n"
				+ "[ext_resource type=\"PackedScene\" path=\"%s\" id=1]\n\n"
				% child_path
				+ "[node name=\"Level\" type=\"Node\"]\n\n"
				+ "[node name=\"Left\" parent=\".\" instance=ExtResource(1)]\n\n"
				+ "[node name=\"Right\" parent=\".\" instance=ExtResource(1)]\n"
			),
		)

	var started := Time.get_ticks_msec()
	var result := _inspector.inspect(
		REPEATED_PATH_PREFIX + str(REPEATED_DEPTH) + ".tscn",
		"PackedScene",
	)
	var elapsed := Time.get_ticks_msec() - started
	assert_true(result.ok)
	assert_true(result.matches_expected_type)
	assert_lte(result.visited_resource_count, REPEATED_DEPTH + 1)
	assert_eq(result.visited_resource_count, _inspector.get_last_inspection_visit_count())
	assert_lte(result.node_paths.size(), 3)
	assert_lt(elapsed, 2_000, "repeated-instance preflight must stay bounded")
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
