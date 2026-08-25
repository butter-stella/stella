extends GutTest
## Frozen typed-state and stable Dialogue projection contract for issue #166.
##
## New classes are discovered through Godot's global-class registry so the red
## baseline remains importable and fails only at explicit capability assertions.


const REQUIRED_CLASSES := [
	"DialogueVisibilityState",
	"DialogueVisibilityPresentationOperation",
	"PresentationBatchHandler",
]

const DEFAULT_VISIBILITY := {
	"surface": true,
	"quick_menu": true,
}

const INACTIVE_CONTENT := {
	"version": 2,
	"active": false,
	"cleared": false,
	"mode": "adv",
	"profile_name": "",
	"declarative_presentation": false,
	"character": "",
	"segments": [],
	"avatar_expression": "",
	"nvl_entries": [],
}


func _global_class_script(class_name_value: String) -> Script:
	for entry_value: Variant in ProjectSettings.get_global_class_list():
		var entry: Dictionary = entry_value
		if String(entry.get("class", "")) != class_name_value:
			continue
		var path := String(entry.get("path", ""))
		if not path.is_empty() and ResourceLoader.exists(path, "Script"):
			return load(path) as Script
	return null


func _method_names(object_or_script: Object) -> Array[String]:
	var names: Array[String] = []
	if object_or_script == null:
		return names
	for method_value: Variant in object_or_script.get_method_list():
		var method: Dictionary = method_value
		names.append(String(method.get("name", "")))
	return names


func _script_method(script: Script, method_name: String) -> Dictionary:
	if script == null:
		return {}
	for method_value: Variant in script.get_script_method_list():
		var method: Dictionary = method_value
		if String(method.get("name", "")) == method_name:
			return method
	return {}


func _argument_names(method: Dictionary) -> Array[String]:
	var names: Array[String] = []
	for argument_value: Variant in method.get("args", []):
		var argument: Dictionary = argument_value
		names.append(String(argument.get("name", "")))
	return names


func _contains_object(value: Variant) -> bool:
	if value is Object:
		return true
	if value is Dictionary:
		for child: Variant in (value as Dictionary).values():
			if _contains_object(child):
				return true
	if value is Array:
		for child: Variant in value:
			if _contains_object(child):
				return true
	return false


func _snapshot_with_dialogue(
	visibility: Dictionary,
	content: Dictionary,
) -> Dictionary:
	return {
		"bg": "",
		"stage_layers": {},
		"bgm": {},
		"loop_se_channels": {},
		"dialogue_visibility": visibility.duplicate(true),
		"dialogue_content": content.duplicate(true),
	}


func _adv_content() -> Dictionary:
	return {
		"version": 2,
		"active": true,
		"cleared": false,
		"mode": "adv",
		"profile_name": "message",
		"declarative_presentation": true,
		"character": "sakura",
		"segments": [{"text": "Stable [expr:happy]ADV"}],
		"avatar_expression": "happy",
		"nvl_entries": [],
	}


func _nvl_content() -> Dictionary:
	return {
		"version": 2,
		"active": true,
		"cleared": false,
		"mode": "nvl",
		"profile_name": "novel_second",
		"declarative_presentation": true,
		"character": "senpai",
		"segments": [{"text": "Second entry[expr:smile]"}],
		"avatar_expression": "smile",
		"nvl_entries": [
			{
				"profile_name": "novel_first",
				"character": "sakura",
				"segments": [{"text": "First entry"}],
			},
			{
				"profile_name": "novel_second",
				"character": "senpai",
				"segments": [{"text": "Second entry[expr:smile]"}],
			},
		],
	}


func _dialogue_keys() -> Array[String]:
	return [
		"active",
		"avatar_expression",
		"character",
		"cleared",
		"declarative_presentation",
		"mode",
		"nvl_entries",
		"profile_name",
		"segments",
		"version",
	]


func _sorted_keys(value: Dictionary) -> Array:
	var keys := value.keys()
	keys.sort()
	return keys


func _assert_dialogue_defaults(snapshot: Dictionary) -> void:
	assert_eq(snapshot.get("dialogue_visibility", {}), DEFAULT_VISIBILITY)
	assert_eq(snapshot.get("dialogue_content", {}), INACTIVE_CONTENT)


func _assert_runtime_profile_binding(profile: Dictionary) -> void:
	var keys := profile.keys()
	keys.sort()
	assert_eq(keys, [
		"profile", "profile_name", "provenance", "quick_menu_groups",
		"surface_groups",
	])
	assert_true(profile.get("profile_name") is String)
	assert_true(profile.get("profile") is Dictionary)
	assert_true(profile.get("provenance") is Dictionary)
	for field: String in ["surface_groups", "quick_menu_groups"]:
		assert_true(profile.get(field) is Array)
		if profile.get(field) is Array:
			assert_true((profile.get(field) as Array).all(
				func(group: Variant) -> bool: return group is String))


func test_required_typed_visibility_classes_are_registered() -> void:
	var missing: Array[String] = []
	for class_name_value: String in REQUIRED_CLASSES:
		if _global_class_script(class_name_value) == null:
			missing.append(class_name_value)
	assert_eq(missing, [], "missing issue #166 typed visibility/state surface")


func test_visibility_operation_is_typed_channel_exact_and_deep_defensive() -> void:
	var base_script := _global_class_script("PresentationOperation")
	var operation_script := _global_class_script(
		"DialogueVisibilityPresentationOperation")
	assert_not_null(base_script)
	assert_not_null(operation_script,
		"missing issue #166 DialogueVisibilityPresentationOperation")
	if base_script == null or operation_script == null:
		return
	assert_same(operation_script.get_base_script(), base_script)
	var payload := {
		"target": "surface",
		"action": "hide",
		"transition": "fade",
		"duration": 0.25,
	}
	var operation: Object = operation_script.new(payload)
	assert_eq(operation.call("get_kind"), &"dialogue_visibility")
	assert_eq(operation.call("get_channel"), &"dialogue:surface")
	var first_payload: Dictionary = operation.call("get_payload")
	assert_eq(first_payload, payload)
	first_payload["target"] = "quick_menu"
	first_payload["duration"] = 999.0
	assert_eq(operation.call("get_payload"), payload,
		"operation payload is a deep defensive snapshot")
	var quick_menu: Object = operation_script.new({
		"target": "quick_menu",
		"action": "show",
		"transition": "cut",
		"duration": 0.0,
	})
	assert_eq(quick_menu.call("get_channel"), &"dialogue:quick_menu")


func test_visibility_state_exact_static_api_validates_and_reduces_atomically() -> void:
	var state_script := _global_class_script("DialogueVisibilityState")
	assert_not_null(state_script, "missing issue #166 DialogueVisibilityState")
	if state_script == null:
		return
	var expected_methods := {
		"default_state": [],
		"validate_snapshot_state": ["raw_state", "report_warnings"],
		"validate_operation": ["raw_operation", "report_warnings"],
		"reduce": ["current", "operations", "report_warnings"],
	}
	for method_name: String in expected_methods:
		var method := _script_method(state_script, method_name)
		assert_false(method.is_empty(), "missing exact state API: %s" % method_name)
		if not method.is_empty():
			assert_eq(_argument_names(method), expected_methods[method_name],
				"state API argument contract: %s" % method_name)
	if expected_methods.keys().any(func(method_name: String) -> bool:
		return _script_method(state_script, method_name).is_empty()
	):
		return

	var canonical: Dictionary = state_script.call("default_state")
	assert_eq(canonical, DEFAULT_VISIBILITY)
	assert_true(bool(state_script.call(
		"validate_snapshot_state", canonical, false)))
	for invalid_state: Variant in [
		{},
		{"surface": true},
		{"surface": true, "quick_menu": true, "extra": false},
		{"surface": 1, "quick_menu": true},
		{"surface": true, "quick_menu": "true"},
	]:
		assert_false(bool(state_script.call(
			"validate_snapshot_state", invalid_state, false)), str(invalid_state))

	var hide_surface := {
		"target": "surface", "action": "hide",
		"transition": "fade", "duration": 0.25,
	}
	var show_quick := {
		"target": "quick_menu", "action": "show",
		"transition": "cut", "duration": 0.0,
	}
	assert_true(bool(state_script.call(
		"validate_operation", hide_surface, false)))
	for invalid_operation: Variant in [
		{},
		{"target": "surface", "action": "hide", "transition": "fade"},
		{
			"target": "panel", "action": "hide",
			"transition": "fade", "duration": 0.25,
		},
		{
			"target": "surface", "action": "toggle",
			"transition": "fade", "duration": 0.25,
		},
		{
			"target": "surface", "action": "hide",
			"transition": "move", "duration": 0.25,
		},
		{
			"target": "surface", "action": "hide",
			"transition": "fade", "duration": NAN,
		},
		{
			"target": "surface", "action": "hide",
			"transition": "fade", "duration": -0.25,
		},
		{
			"target": "surface", "action": "hide",
			"transition": "fade", "duration": INF,
		},
		{
			"target": "surface", "action": "hide",
			"transition": "cut", "duration": 0.1,
		},
		{
			"target": "surface", "action": "hide",
			"transition": "fade", "duration": 0.25, "extra": true,
		},
	]:
		assert_false(bool(state_script.call(
			"validate_operation", invalid_operation, false)),
			str(invalid_operation))

	var current := {"surface": true, "quick_menu": false}
	var current_before := current.duplicate(true)
	var operations := [hide_surface.duplicate(true), show_quick.duplicate(true)]
	var operations_before := operations.duplicate(true)
	assert_eq(state_script.call("reduce", current, operations, false), {
		"surface": false, "quick_menu": true,
	})
	var show_surface := {
		"target": "surface", "action": "show",
		"transition": "cut", "duration": 0.0,
	}
	assert_eq(state_script.call("reduce", current, [
		hide_surface, show_surface,
	], false), {"surface": true, "quick_menu": false},
		"ordered visibility operations use the authored last action")
	assert_eq(current, current_before, "reduce cannot mutate current state")
	assert_eq(operations, operations_before, "reduce cannot mutate operations")
	var invalid_tail := operations.duplicate(true)
	invalid_tail.append({"target": "surface"})
	assert_eq(state_script.call("reduce", current, invalid_tail, false), current,
		"one invalid operation rejects the whole reduction")
	assert_eq(state_script.call("reduce", {"surface": true}, [], false),
		DEFAULT_VISIBILITY,
		"invalid current state reduces to the exact safe default")


func test_visibility_operation_runtime_binding_is_exact_deep_defensive_and_nonsemantic() -> void:
	var operation_script := _global_class_script(
		"DialogueVisibilityPresentationOperation")
	assert_not_null(operation_script,
		"missing issue #166 DialogueVisibilityPresentationOperation")
	if operation_script == null:
		return
	var getter := _script_method(operation_script, "get_runtime_binding")
	assert_false(getter.is_empty(), "typed operation exposes runtime binding getter")
	var init_method := _script_method(operation_script, "_init")
	assert_eq(_argument_names(init_method), ["payload", "runtime_binding", "source"])
	if getter.is_empty() or _argument_names(init_method) != [
		"payload", "runtime_binding", "source",
	]:
		return
	var profile := {
		"profile_name": "message",
		"profile": {"show": PackedStringArray(["text"])},
		"provenance": {"source_path": "res://synthetic/binding.stla", "line": 4},
		"surface_groups": ["dialogue_surface"],
		"quick_menu_groups": ["quick_menu"],
	}
	var runtime_binding := {
		"current": profile.duplicate(true),
		"nvl_entries": [profile.duplicate(true)],
	}
	var payload := {
		"target": "surface", "action": "hide",
		"transition": "fade", "duration": 0.25,
	}
	var operation: Object = operation_script.new(payload, runtime_binding)
	runtime_binding["current"]["profile_name"] = "mutated_input"
	runtime_binding["nvl_entries"][0]["surface_groups"].append("mutated")
	var first: Dictionary = operation.call("get_runtime_binding")
	var binding_keys := first.keys()
	binding_keys.sort()
	assert_eq(binding_keys, ["current", "nvl_entries"])
	_assert_runtime_profile_binding(first["current"])
	assert_eq((first["nvl_entries"] as Array).size(), 1)
	_assert_runtime_profile_binding(first["nvl_entries"][0])
	assert_false(_contains_object(first),
		"runtime binding is JSON-safe and contains no runtime Object authority")
	assert_eq(first["current"]["profile_name"], "message")
	assert_eq(first["nvl_entries"][0]["surface_groups"], ["dialogue_surface"])
	first["current"]["profile_name"] = "mutated_output"
	assert_eq(operation.call("get_runtime_binding")["current"]["profile_name"],
		"message", "runtime binding getter is deep defensive")
	assert_eq(operation.call("get_payload"), payload,
		"runtime binding never contaminates semantic payload")
	assert_false("runtime_binding" in JSON.stringify(operation.call("get_payload")))
	assert_false("binding.stla" in JSON.stringify(
		PresentationState.new().capture_snapshot()),
		"runtime binding never enters canonical save state")


func test_presentation_state_default_snapshot_has_exact_dialogue_projection() -> void:
	var state := PresentationState.new()
	var snapshot := state.capture_snapshot()
	assert_eq(_sorted_keys(snapshot), [
		"bg", "bgm", "dialogue_content", "dialogue_visibility",
		"loop_se_channels", "stage_layers",
	])
	_assert_dialogue_defaults(snapshot)


func test_adv_projection_round_trips_json_with_exact_keys_and_values() -> void:
	var authored := _snapshot_with_dialogue(
		{"surface": false, "quick_menu": true},
		_adv_content(),
	)
	var state := PresentationState.new()
	state.restore_snapshot(authored)
	var encoded := JSON.stringify(state.capture_snapshot())
	var decoded: Variant = JSON.parse_string(encoded)
	var expected_json: Variant = JSON.parse_string(JSON.stringify(authored))
	assert_true(decoded is Dictionary)
	if not decoded is Dictionary:
		return
	assert_true(expected_json is Dictionary)
	if not expected_json is Dictionary:
		return
	assert_eq(decoded, expected_json)
	if decoded != expected_json:
		return
	assert_eq(_sorted_keys(decoded["dialogue_content"]), _dialogue_keys())


func test_nvl_projection_round_trips_ordered_entries_and_profile_names() -> void:
	var authored := _snapshot_with_dialogue(
		{"surface": false, "quick_menu": false},
		_nvl_content(),
	)
	var state := PresentationState.new()
	state.restore_snapshot(authored)
	var snapshot := state.capture_snapshot()
	assert_eq(snapshot, authored)
	var entries: Array = snapshot.get("dialogue_content", {}).get(
		"nvl_entries", [])
	assert_eq(entries.map(
		func(entry: Dictionary) -> String:
			return String(entry.get("profile_name", ""))
	), ["novel_first", "novel_second"])
	assert_eq(entries.map(
		func(entry: Dictionary) -> String:
			return String((entry.get("segments", []) as Array)[0].get("text", ""))
	), ["First entry", "Second entry[expr:smile]"])


func test_snapshot_getters_are_deep_defensive_for_dialogue_projection() -> void:
	var authored := _snapshot_with_dialogue(
		{"surface": false, "quick_menu": true},
		_nvl_content(),
	)
	var state := PresentationState.new()
	state.restore_snapshot(authored)
	var first := state.capture_snapshot()
	assert_eq(first, authored,
		"first snapshot preserves the exact Dialogue projection")
	if first != authored:
		return
	first["dialogue_visibility"]["surface"] = true
	first["dialogue_content"]["segments"][0]["text"] = "mutated"
	first["dialogue_content"]["nvl_entries"][0]["segments"][0]["text"] = (
		"mutated entry"
	)
	var second := state.capture_snapshot()
	var expected := _snapshot_with_dialogue(
		{"surface": false, "quick_menu": true},
		_nvl_content(),
	)
	assert_eq(second, expected,
		"mutating snapshot output cannot mutate the canonical Dialogue projection")
	if second != expected:
		return
	assert_false(bool(second["dialogue_visibility"]["surface"]))
	assert_eq(second["dialogue_content"]["segments"][0]["text"],
		"Second entry[expr:smile]")
	assert_eq(
		second["dialogue_content"]["nvl_entries"][0]["segments"][0]["text"],
		"First entry",
	)


func test_clear_restores_true_gates_and_inactive_content() -> void:
	var state := PresentationState.new()
	state.restore_snapshot(_snapshot_with_dialogue(
		{"surface": false, "quick_menu": false},
		_adv_content(),
	))
	state.clear()
	_assert_dialogue_defaults(state.capture_snapshot())


func test_old_snapshot_without_dialogue_fields_uses_canonical_defaults() -> void:
	var state := PresentationState.new()
	state.restore_snapshot({
		"bg": "legacy",
		"stage_layers": {},
	})
	var snapshot := state.capture_snapshot()
	_assert_dialogue_defaults(snapshot)
	assert_eq(snapshot.get("bg"), "legacy")


func test_inactive_content_is_normalized_exactly_without_hidden_payload() -> void:
	var invalid_inactive := _adv_content()
	invalid_inactive["active"] = false
	var state := PresentationState.new()
	state.restore_snapshot(_snapshot_with_dialogue(
		{"surface": false, "quick_menu": true},
		invalid_inactive,
	))
	var snapshot := state.capture_snapshot()
	_assert_dialogue_defaults(snapshot)


func test_invalid_direct_restore_zeros_the_whole_dialogue_projection() -> void:
	var invalid_cases: Array[Dictionary] = []
	var extra_key := _adv_content()
	extra_key["unknown"] = true
	invalid_cases.append(extra_key)
	var wrong_version := _adv_content()
	wrong_version["version"] = 3
	invalid_cases.append(wrong_version)
	var wrong_mode := _adv_content()
	wrong_mode["mode"] = "future"
	invalid_cases.append(wrong_mode)
	var empty_active := _adv_content()
	empty_active["segments"] = []
	invalid_cases.append(empty_active)
	var voice_segment := _adv_content()
	voice_segment["segments"] = [{"text": "safe", "voice": "forbidden"}]
	invalid_cases.append(voice_segment)
	var bad_nvl_tail := _nvl_content()
	bad_nvl_tail["segments"] = [{"text": "does not match tail"}]
	invalid_cases.append(bad_nvl_tail)

	for invalid_content: Dictionary in invalid_cases:
		var state := PresentationState.new()
		state.restore_snapshot(_snapshot_with_dialogue(
			{"surface": false, "quick_menu": false},
			invalid_content,
		))
		_assert_dialogue_defaults(state.capture_snapshot())


func test_record_dialogue_content_captures_text_only_and_final_expression() -> void:
	var state := PresentationState.new()
	var methods := _method_names(state)
	assert_has(methods, "record_dialogue_content",
		"PresentationState is the stable Dialogue capture authority")
	if "record_dialogue_content" not in methods:
		return
	var data := ScenarioData.new()
	data.id = "dialogue_projection"
	var context := ScenarioContext.new(data)
	context.current_dialogue_mode = "adv"
	context.current_dialogue_profile_name = "message"
	context.current_dialogue_uses_declarative_presentation = true
	var request := DialogueRequest.new(
		"sakura",
		[{
			"text": "Before[expr:happy]After",
			"voice": "must_not_persist",
			"expression": "",
			"stage": [{"action": "clear"}],
		}],
		"adv",
		{},
		true,
	)
	state.call("record_dialogue_content", request, context)
	var content: Dictionary = state.capture_snapshot().get(
		"dialogue_content", {})
	assert_eq(content.get("character"), "sakura")
	assert_eq(content.get("segments"), [{
		"text": "Before[expr:happy]After",
	}])
	assert_eq(content.get("avatar_expression"), "happy")
	assert_eq(content.get("profile_name"), "message")
	var serialized := JSON.stringify(content)
	for forbidden: String in [
		"voice", "stage", "activation", "token", "tween", "generation",
	]:
		assert_false(forbidden in serialized,
			"stable projection excludes transient field '%s'" % forbidden)


func test_record_nvl_content_uses_context_page_not_presenter_cache() -> void:
	var state := PresentationState.new()
	if "record_dialogue_content" not in _method_names(state):
		assert_true(false,
			"PresentationState is missing record_dialogue_content")
		return
	var data := ScenarioData.new()
	data.id = "dialogue_nvl_projection"
	var context := ScenarioContext.new(data)
	context.current_dialogue_mode = "nvl"
	context.current_dialogue_profile_name = "novel_second"
	context.current_dialogue_uses_declarative_presentation = true
	context.nvl_page_entries = [
		{
			"profile_name": "novel_first",
			"character": "sakura",
			"segments": [{"text": "First entry", "voice": "old_voice"}],
		},
		{
			"profile_name": "novel_second",
			"character": "senpai",
			"segments": [{
				"text": "Second entry[expr:smile]", "voice": "new_voice",
			}],
		},
	]
	var request := DialogueRequest.new(
		"senpai",
		[{"text": "Second entry[expr:smile]", "voice": "new_voice"}],
		"nvl",
		{},
		true,
		"1:1",
		{},
		context.nvl_page_entries,
	)
	state.call("record_dialogue_content", request, context)
	assert_eq(state.capture_snapshot().get("dialogue_content"), _nvl_content())
