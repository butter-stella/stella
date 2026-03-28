extends GutTest
## Tests for CommandData — the instruction data container used by all handlers.
## CommandData is globally registered via class_name, no preload needed.


func _create(type: String, params: Dictionary = {}) -> CommandData:
	var cmd = CommandData.new()
	cmd.type = type
	cmd.params = params
	return cmd


func test_type_is_stored():
	var cmd = _create("dialogue")
	assert_eq(cmd.type, "dialogue")


func test_get_string_returns_value():
	var cmd = _create("bg", {"asset": "bg_school"})
	assert_eq(cmd.get_string("asset"), "bg_school")


func test_get_string_returns_default_when_missing():
	var cmd = _create("bg", {})
	assert_eq(cmd.get_string("asset", "none"), "none")


func test_get_string_returns_empty_default():
	var cmd = _create("bg", {})
	assert_eq(cmd.get_string("asset"), "")


func test_get_float_returns_value():
	var cmd = _create("bg", {"duration": 0.8})
	assert_almost_eq(cmd.get_float("duration"), 0.8, 0.001)


func test_get_float_returns_default_when_missing():
	var cmd = _create("bg", {})
	assert_almost_eq(cmd.get_float("duration", 0.5), 0.5, 0.001)


func test_get_float_converts_string():
	var cmd = _create("bg", {"duration": "1.5"})
	assert_almost_eq(cmd.get_float("duration"), 1.5, 0.001)


func test_get_int_returns_value():
	var cmd = _create("set", {"value": 10})
	assert_eq(cmd.get_int("value"), 10)


func test_get_int_returns_default_when_missing():
	var cmd = _create("set", {})
	assert_eq(cmd.get_int("value", -1), -1)


func test_get_bool_returns_true():
	var cmd = _create("set", {"value": true})
	assert_true(cmd.get_bool("value"))


func test_get_bool_returns_false():
	var cmd = _create("set", {"value": false})
	assert_false(cmd.get_bool("value"))


func test_get_bool_returns_default_when_missing():
	var cmd = _create("set", {})
	assert_false(cmd.get_bool("value"))


func test_get_bool_converts_string_true():
	var cmd = _create("set", {"value": "true"})
	assert_true(cmd.get_bool("value"))


func test_get_bool_converts_string_false():
	var cmd = _create("set", {"value": "false"})
	assert_false(cmd.get_bool("value"))


func test_has_param():
	var cmd = _create("bg", {"asset": "bg_school"})
	assert_true(cmd.has_param("asset"))
	assert_false(cmd.has_param("transition"))


func test_empty_params():
	var cmd = _create("end", {})
	assert_eq(cmd.get_string("anything"), "")
	assert_eq(cmd.get_int("anything"), 0)
	assert_almost_eq(cmd.get_float("anything"), 0.0, 0.001)
	assert_false(cmd.get_bool("anything"))
