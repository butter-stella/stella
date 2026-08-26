extends GutTest


func _operation(
	action: String,
	properties: Dictionary = {},
	transition: String = "cut",
	duration: float = 0.0,
) -> Dictionary:
	return {
		"action": action,
		"properties": properties,
		"transition": transition,
		"duration": duration,
	}


func test_default_state_is_stable_absent_avatar() -> void:
	var state := DialogueAvatarState.default_state()
	assert_true(DialogueAvatarState.validate_snapshot_state(state, false))
	var decoded: Variant = JSON.parse_string(JSON.stringify(state))
	assert_true(DialogueAvatarState.validate_snapshot_state(decoded, false),
		"JSON numeric z_index remains an exact integer value")
	assert_false(state["present"])
	assert_false(state["visible"])
	assert_eq(state["position"], [0.0, 0.0])
	assert_eq(state["scale"], [1.0, 1.0])


func test_set_can_create_hidden_asset_state_with_canonical_transforms() -> void:
	var operation := _operation("set", {
		"asset": "character:portraits/red.png",
		"visible": false,
		"position": [-280.0, -140.0],
		"origin": [65056.0, 320.0],
		"scale": [0.45, 0.45],
		"z_index": 12,
		"opacity": 0.8,
	})
	assert_true(DialogueAvatarState.validate_operation(operation, false))
	var target := DialogueAvatarState.reduce(
		DialogueAvatarState.default_state(), [operation], false)
	assert_true(target["present"])
	assert_false(target["visible"])
	assert_eq(target["source_kind"], "asset")
	assert_eq(target["position"], [-280.0, -140.0])
	assert_eq(target["origin"], [65056.0, 320.0])
	assert_eq(target["scale"], [0.45, 0.45])


func test_show_character_then_replace_expression_preserves_transform() -> void:
	var shown := DialogueAvatarState.reduce(
		DialogueAvatarState.default_state(),
		[_operation("show", {
			"character": "hero",
			"expression": "neutral",
			"position": [12.0, 34.0],
		})],
		false,
	)
	var replaced := DialogueAvatarState.reduce(
		shown,
		[_operation("set", {"expression": "smile"}, "fade", 0.3)],
		false,
	)
	assert_true(replaced["visible"])
	assert_eq(replaced["character"], "hero")
	assert_eq(replaced["expression"], "smile")
	assert_eq(replaced["position"], [12.0, 34.0])


func test_hide_preserves_source_and_remove_erases_stable_state() -> void:
	var shown := DialogueAvatarState.reduce(
		DialogueAvatarState.default_state(),
		[_operation("show", {"asset": "stage:red.png"})],
		false,
	)
	var hidden := DialogueAvatarState.reduce(
		shown, [_operation("hide", {}, "fade", 0.5)], false)
	assert_true(hidden["present"])
	assert_false(hidden["visible"])
	assert_eq(hidden["asset"], "stage:red.png")
	assert_eq(
		DialogueAvatarState.reduce(hidden, [_operation("remove")], false),
		DialogueAvatarState.default_state(),
	)


func test_unknown_source_alias_is_rejected_atomically() -> void:
	assert_false(DialogueAvatarState.validate_operation(
		_operation("set", {"xpos": -280.0}), false))
	assert_false(DialogueAvatarState.validate_operation(
		_operation("set", {"zoom": 45.0}), false))
	assert_false(DialogueAvatarState.validate_operation(
		_operation("set", {"showmode": 0}), false))


func test_source_forms_are_mutually_exclusive() -> void:
	assert_false(DialogueAvatarState.validate_operation(_operation("show", {
		"asset": "stage:red.png",
		"character": "hero",
		"expression": "smile",
	}), false))


func test_noncanonical_and_invalid_transform_values_fail_close() -> void:
	assert_false(DialogueAvatarState.validate_operation(
		_operation("Show", {"asset": "stage:red.png"}), false))
	assert_false(DialogueAvatarState.validate_operation(
		_operation("show", {"asset": " stage:red.png"}), false))
	assert_false(DialogueAvatarState.validate_operation(
		_operation("show", {"asset": "stage:red.png", "scale": [0.0, 1.0]}), false))
	assert_false(DialogueAvatarState.validate_operation(
		_operation("show", {"asset": "stage:red.png", "opacity": 1.1}), false))
	assert_false(DialogueAvatarState.validate_operation(
		_operation("show", {"asset": "stage:red.png", "position": [NAN, 0.0]}), false))


func test_cut_requires_zero_duration_and_fade_is_finite() -> void:
	assert_false(DialogueAvatarState.validate_operation(
		_operation("show", {"asset": "stage:red.png"}, "cut", 0.1), false))
	assert_false(DialogueAvatarState.validate_operation(
		_operation("show", {"asset": "stage:red.png"}, "fade", NAN), false))
	assert_true(DialogueAvatarState.validate_operation(
		_operation("show", {"asset": "stage:red.png"}, "fade", 0.3), false))


func test_state_dependent_actions_fail_without_source() -> void:
	var absent := DialogueAvatarState.default_state()
	assert_false(DialogueAvatarState.operation_is_supported(
		absent, _operation("show")))
	assert_false(DialogueAvatarState.operation_is_supported(
		absent, _operation("hide")))
	assert_false(DialogueAvatarState.operation_is_supported(
		absent, _operation("remove")))
	assert_false(DialogueAvatarState.operation_is_supported(
		absent, _operation("set", {"expression": "smile"})))


func test_snapshot_requires_exact_json_safe_schema() -> void:
	var state := DialogueAvatarState.default_state()
	state["source_alias"] = "face"
	assert_false(DialogueAvatarState.validate_snapshot_state(state, false))
	state.erase("source_alias")
	state["position"] = Vector2.ZERO
	assert_false(DialogueAvatarState.validate_snapshot_state(state, false))
