extends GutTest
## Tests for NatScript resource and format loader/saver.


func test_nat_script_default_source_code():
	var res = NatScript.new()
	assert_eq(res.source_code, "")


func test_nat_script_stores_source_code():
	var res = NatScript.new()
	res.source_code = "sakura「こんにちは」"
	assert_eq(res.source_code, "sakura「こんにちは」")


func test_format_loader_recognized_extensions():
	var loader = NatFormatLoader.new()
	var exts = loader._get_recognized_extensions()
	assert_true(exts.has("nat"))


func test_format_loader_resource_type():
	var loader = NatFormatLoader.new()
	assert_eq(loader._get_resource_type("res://test.nat"), "NatScript")
	assert_eq(loader._get_resource_type("res://test.gd"), "")


func test_format_loader_handles_type():
	var loader = NatFormatLoader.new()
	assert_true(loader._handles_type(&"NatScript"))
	assert_false(loader._handles_type(&"Texture2D"))


func test_format_loader_loads_nat_file():
	# Write a temp .nat file
	var path = "res://tests/_temp_test.nat"
	var f = FileAccess.open(path, FileAccess.WRITE)
	f.store_string("@scene test\nsakura「テスト」\n")
	f.close()

	var loader = NatFormatLoader.new()
	var result = loader._load(path, path, false, 0)
	assert_is(result, NatScript)
	assert_string_contains(result.source_code, "@scene test")
	assert_string_contains(result.source_code, "sakura「テスト」")

	# Cleanup
	DirAccess.remove_absolute(path)


func test_format_saver_recognized_extensions():
	var saver = NatFormatSaver.new()
	var exts = saver._get_recognized_extensions(NatScript.new())
	assert_true(exts.has("nat"))


func test_format_saver_recognizes_nat_script():
	var saver = NatFormatSaver.new()
	assert_true(saver._recognize(NatScript.new()))
	assert_false(saver._recognize(Resource.new()))


func test_format_saver_saves_nat_file():
	var path = "res://tests/_temp_save_test.nat"
	var res = NatScript.new()
	res.source_code = "@scene save_test\n「保存テスト」\n"

	var saver = NatFormatSaver.new()
	var err = saver._save(res, path, 0)
	assert_eq(err, OK)

	# Verify file content
	var f = FileAccess.open(path, FileAccess.READ)
	assert_not_null(f)
	var content = f.get_as_text()
	assert_eq(content, res.source_code)
	f.close()

	# Cleanup
	DirAccess.remove_absolute(path)
