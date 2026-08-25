extends GutTest


func _op(
	action: String,
	layer_id: String = "",
	properties: Dictionary = {},
) -> Dictionary:
	return {
		"action": action,
		"id": layer_id,
		"properties": properties,
		"transition": "cut",
		"transition_params": {},
		"duration": 0.0,
	}


func _redraw_pipeline() -> Array:
	return [
		{
			"type": "color_overlay",
			"color": "#2A5C8E40",
			"blend": "soft_light",
		},
		{"type": "brightness_contrast", "brightness": 17, "contrast": -24},
		{"type": "grayscale", "amount": 0.25},
		{"type": "tint", "color": "#80ff40"},
		{"type": "blur", "radius": [2, 3]},
		{"type": "blur", "radius": [4, 1]},
		{
			"type": "clip",
			"asset": "stage:synthetic_alpha_mask",
			"offset": [12, 34],
			"fit": "contain",
		},
	]


func test_show_normalizes_complete_json_safe_state():
	var layers := StageLayerState.reduce({}, [
		_op("show", "hero/main", {
			"kind": "character",
			"body": "stage:hero_body",
			"face": "stage:hero_smile",
			"x": 960,
			"y": 120,
			"origin": [500, 1000],
			"scale": 0.75,
			"zoom": [1.1, 1.2],
			"depth_scale": 0.8,
			"z": 12,
			"opacity": 0.6,
			"flip_x": true,
			"redraw": _redraw_pipeline(),
		}),
	])

	assert_true(layers.has("hero/main"))
	var state: Dictionary = layers["hero/main"]
	assert_eq(state["position"], [960.0, 120.0])
	assert_eq(state["origin"], [500.0, 1000.0])
	assert_eq(state["scale"], [0.75, 0.75])
	assert_eq(state["zoom"], [1.1, 1.2])
	assert_almost_eq(state["depth_scale"], 0.8, 0.001)
	assert_eq(state["z_index"], 12)
	assert_almost_eq(state["opacity"], 0.6, 0.001)
	assert_true(state["flip_x"])
	assert_false(state["flip_y"])
	assert_eq(state["redraw"].size(), 7)
	assert_eq(state["redraw"][0], {
		"type": "color_overlay",
		"color": "#2a5c8e40",
		"blend": "soft_light",
	})
	assert_eq(state["redraw"][1], {
		"type": "brightness_contrast",
		"brightness": 17,
		"contrast": -24,
	})
	assert_eq(state["redraw"][3]["color"], "#80ff40ff")
	assert_eq(state["redraw"][4]["radius"], [2, 3])
	assert_eq(state["redraw"][5]["radius"], [4, 1])
	assert_eq(state["redraw"][6]["offset"], [12.0, 34.0])
	var encoded := JSON.stringify(layers)
	assert_ne(encoded, "", "stage snapshots must serialize as JSON")
	var roundtrip_state := StageLayerState.normalize_full(
		JSON.parse_string(encoded)["hero/main"],
		false,
	)
	assert_eq(roundtrip_state["redraw"], state["redraw"])


func test_metadata_is_recursively_normalized_for_json_snapshots():
	var layers := StageLayerState.reduce({}, [
		_op("show", "event", {
			"metadata": {
				"anchor": Vector2(12.0, 34.0),
				"nested": [{"tint": Color(1.0, 0.5, 0.0, 1.0)}],
			},
		}),
	])
	var metadata: Dictionary = layers["event"]["metadata"]
	assert_eq(metadata["anchor"], [12.0, 34.0])
	assert_eq(metadata["nested"][0]["tint"], "ff8000ff")
	var roundtrip = JSON.parse_string(JSON.stringify(layers))
	assert_eq(roundtrip["event"]["metadata"], metadata)


func test_metadata_recursively_replaces_non_finite_values() -> void:
	var layers := StageLayerState.reduce({}, [
		_op("show", "event", {
			"metadata": {
				"scalar": NAN,
				"vector": Vector2(INF, 4.0),
				"nested": [-INF, {"ok": 3.0}],
			},
		}),
	])
	var metadata: Dictionary = layers["event"]["metadata"]
	assert_null(metadata["scalar"])
	assert_eq(metadata["vector"], [0.0, 4.0])
	assert_null(metadata["nested"][0])
	assert_eq(metadata["nested"][1]["ok"], 3.0)
	var encoded := JSON.stringify(layers).to_lower()
	assert_false(encoded.contains("nan"))
	assert_false(encoded.contains("inf"))


func test_face_patch_preserves_body_and_unmentioned_transform():
	var layers := StageLayerState.reduce({}, [
		_op("show", "hero", {
			"body": "stage:body",
			"face": "stage:face_000",
			"position": [100, 200],
		}),
	])
	for index in range(300):
		layers = StageLayerState.reduce(layers, [
			_op("update", "hero", {"face": "stage:face_%03d" % index}),
		])

	assert_eq(layers["hero"]["body"], "stage:body")
	assert_eq(layers["hero"]["face"], "stage:face_299")
	assert_eq(layers["hero"]["position"], [100.0, 200.0])


func test_redraw_patch_replaces_ordered_pipeline_while_omission_preserves_it():
	var original_redraw := [
		{"type": "blur", "radius": [1, 1]},
		{"type": "blur", "radius": [2, 2]},
	]
	var layers := StageLayerState.reduce({}, [
		_op("show", "hero", {"asset": "stage:hero", "redraw": original_redraw}),
	])
	assert_eq(layers["hero"]["redraw"], original_redraw)

	layers = StageLayerState.reduce(layers, [
		_op("update", "hero", {"opacity": 0.5}),
	])
	assert_eq(layers["hero"]["redraw"], original_redraw)

	var replacement := [
		{"type": "grayscale", "amount": 1.0},
		{"type": "grayscale", "amount": 0.25},
	]
	layers = StageLayerState.reduce(layers, [
		_op("update", "hero", {"redraw": replacement}),
	])
	assert_eq(layers["hero"]["redraw"], replacement)

	layers = StageLayerState.reduce(layers, [
		_op("update", "hero", {"redraw": []}),
	])
	assert_true(layers["hero"]["redraw"].is_empty())


func test_redraw_schema_is_closed_and_rejects_the_whole_operation():
	var layers := StageLayerState.reduce({}, [
		_op("show", "hero", {"asset": "stage:hero"}),
	])
	var original := layers.duplicate(true)
	var invalid_redraw_values: Array = [
		{"grayscale": 1.0},
		[{"type": "unknown_effect", "brightness": -17, "contrast": 23}],
		[{"type": "color_overlay", "color": "#2a5c8e40"}],
		[{
			"type": "color_overlay",
			"color": "#2a5c8e40",
			"blend": "normal",
			"opacity": 1.0,
		}],
		[{"type": "color_overlay", "color": 0xff2a5c8e, "blend": "normal"}],
		[{"type": "color_overlay", "color": "#2a5c8e40", "blend": 20}],
		[{"type": "color_overlay", "color": "#2a5c8e40", "blend": "screen"}],
		[{"type": "brightness_contrast", "brightness": -256, "contrast": 0}],
		[{"type": "brightness_contrast", "brightness": 0, "contrast": 101}],
		[{"type": "grayscale", "amount": NAN}],
		[{"type": "tint", "color": "red"}],
		[{"type": "blur", "radius": [1.5, 2]}],
		[
			{
				"type": "clip",
				"asset": "stage:synthetic_alpha_mask_a",
				"offset": [0.0, 0.0],
				"fit": "native",
			},
			{
				"type": "clip",
				"asset": "stage:synthetic_alpha_mask_b",
				"offset": [0.0, 0.0],
				"fit": "native",
			},
		],
		[{
			"type": "clip",
			"asset": "",
			"offset": [0.0, 0.0],
			"fit": "native",
		}],
		[{
			"type": "clip",
			"asset": "stage:synthetic_alpha_mask",
			"offset": [0.0, INF],
			"fit": "native",
		}],
		[{
			"type": "clip",
			"asset": "stage:synthetic_alpha_mask",
			"offset": [0.0, 0.0],
			"fit": "tile",
		}],
	]
	for invalid_redraw in invalid_redraw_values:
		var operation := _op("update", "hero", {
			"opacity": 0.25,
			"redraw": invalid_redraw,
		})
		assert_false(StageLayerState.validate_operation(operation, false))
		layers = StageLayerState.reduce(layers, [operation], false)
		assert_eq(layers, original)

	var too_many: Array = []
	for _index in range(StageLayerState.MAX_REDRAW_EFFECTS):
		too_many.append({"type": "grayscale", "amount": 0.5})
	assert_true(StageLayerState.validate_operation(
		_op("update", "hero", {"redraw": too_many}),
		false,
	))
	too_many.append({"type": "blur", "radius": [1, 1]})
	assert_false(StageLayerState.validate_operation(
		_op("update", "hero", {"redraw": too_many}),
		false,
	))

	var too_many_blurs: Array = []
	for _index in range(StageLayerState.MAX_BLUR_PASSES):
		too_many_blurs.append({"type": "blur", "radius": [1, 1]})
	assert_true(StageLayerState.validate_operation(
		_op("update", "hero", {"redraw": too_many_blurs}),
		false,
	))
	too_many_blurs.append({"type": "blur", "radius": [1, 1]})
	var invalid_blur_update := _op("update", "hero", {
		"opacity": 0.25,
		"redraw": too_many_blurs,
	})
	assert_false(StageLayerState.validate_operation(
		invalid_blur_update,
		false,
	))
	layers = StageLayerState.reduce(layers, [invalid_blur_update], false)
	assert_eq(layers, original, "the fifth blur rejects the whole update")


func test_redraw_boundary_values_and_soft_light_are_valid():
	var operation := _op("show", "hero", {"redraw": [
		{"type": "color_overlay", "color": "#00000000", "blend": "normal"},
		{"type": "color_overlay", "color": "#ffffffff", "blend": "soft_light"},
		{"type": "brightness_contrast", "brightness": -255, "contrast": -100},
		{"type": "brightness_contrast", "brightness": 255, "contrast": 100},
		{"type": "grayscale", "amount": 0.0},
		{"type": "grayscale", "amount": 1.0},
		{
			"type": "blur",
			"radius": [0, StageLayerState.MAX_BLUR_RADIUS],
		},
		{
			"type": "blur",
			"radius": [StageLayerState.MAX_BLUR_RADIUS, 0],
		},
		{
			"type": "clip",
			"asset": "background:synthetic_alpha_mask",
			"offset": [-100.5, 200.25],
			"fit": "stretch",
		},
	]})
	assert_true(StageLayerState.validate_operation(operation, false))
	var layers := StageLayerState.reduce({}, [operation], false)
	assert_eq(layers["hero"]["redraw"].size(), 9)
	assert_eq(layers["hero"]["redraw"][8]["offset"], [-100.5, 200.25])


func test_hide_retains_resources_while_remove_and_clear_release_state():
	var layers := StageLayerState.reduce({}, [
		_op("show", "hero", {"body": "stage:body"}),
		_op("show", "event", {"asset": "stage:event"}),
	])
	layers = StageLayerState.reduce(layers, [_op("hide", "hero")])
	assert_true(layers.has("hero"))
	assert_false(layers["hero"]["visible"])
	assert_eq(layers["hero"]["body"], "stage:body")

	layers = StageLayerState.reduce(layers, [_op("remove", "hero")])
	assert_false(layers.has("hero"))
	layers = StageLayerState.reduce(layers, [_op("clear")])
	assert_true(layers.is_empty())


func test_hide_remove_and_clear_reject_layer_properties_atomically():
	var layers := StageLayerState.reduce({}, [
		_op("show", "hero", {"asset": "stage:hero"}),
	])
	var original := layers.duplicate(true)
	for operation in [
		_op("hide", "hero", {"opacity": 0.5}),
		_op("remove", "hero", {"face": "stage:sad"}),
		_op("clear", "", {"asset": "stage:unused"}),
	]:
		layers = StageLayerState.reduce(layers, [operation], false)
		assert_eq(layers, original)


func test_operation_envelope_is_closed_and_rejects_invalid_timing():
	var valid := _op("show", "hero", {"asset": "stage:hero"})
	assert_true(StageLayerState.validate_operation(valid, false))

	var misspelled_transition := valid.duplicate(true)
	misspelled_transition["transiton"] = "fade"
	assert_false(StageLayerState.validate_operation(misspelled_transition, false))

	var unknown_property := valid.duplicate(true)
	unknown_property["properties"] = {"positon": [1.0, 2.0]}
	assert_false(StageLayerState.validate_operation(unknown_property, false))

	var invalid_transition := valid.duplicate(true)
	invalid_transition["transition"] = "9warp"
	assert_false(StageLayerState.validate_operation(invalid_transition, false))

	var missing_transition_params := valid.duplicate(true)
	missing_transition_params.erase("transition_params")
	assert_false(StageLayerState.validate_operation(
		missing_transition_params, false))

	for noncanonical_transition in ["none", "CUT", " cut", "cut "]:
		var noncanonical := valid.duplicate(true)
		noncanonical["transition"] = noncanonical_transition
		assert_false(StageLayerState.validate_operation(noncanonical, false),
			noncanonical_transition)

	var negative_duration := valid.duplicate(true)
	negative_duration["duration"] = -0.1
	assert_false(StageLayerState.validate_operation(negative_duration, false))


func test_canonical_stage_properties_use_one_spelling_and_typed_booleans():
	var operation := _op("show", "hero", {
		"depth_scale": 0.8,
		"rotation": 15.0,
		"asset": "none",
		"body": "none",
		"face": "none",
		"visible": true,
		"flip_x": false,
		"flip_y": true,
	})
	assert_true(StageLayerState.validate_operation(operation, false))
	var layers := StageLayerState.reduce({}, [operation], false)
	assert_almost_eq(layers["hero"]["depth_scale"], 0.8, 0.001)
	assert_almost_eq(layers["hero"]["rotation"], 15.0, 0.001)
	assert_eq(layers["hero"]["asset"], "")
	assert_eq(layers["hero"]["body"], "")
	assert_eq(layers["hero"]["face"], "")
	assert_true(layers["hero"]["visible"])
	assert_false(layers["hero"]["flip_x"])
	assert_true(layers["hero"]["flip_y"])


func test_undocumented_aliases_reject_the_whole_state_operation():
	var layers := StageLayerState.reduce({}, [
		_op("show", "hero", {
			"face": "stage:original",
			"opacity": 0.8,
		}),
	], false)
	var original := layers.duplicate(true)
	var invalid_properties := [
		{"depth": 0.8},
		{"rotation_degrees": 15.0},
		{"z": 1.5},
		{"z": 1.5, "z_index": 2},
		{"z": 99999, "z_index": 2},
		{"z": 1, "z_index": 2},
		{"asset": "null"},
		{"asset": "off"},
		{"body": "null"},
		{"body": "off"},
		{"face": "null"},
		{"face": "off"},
		{"visible": "true"},
		{"visible": "false"},
		{"visible": "yes"},
		{"visible": "on"},
		{"visible": "1"},
		{"visible": "no"},
		{"visible": "off"},
		{"visible": "0"},
		{"visible": 1},
		{"visible": 0},
		{"flip_x": "yes"},
		{"flip_y": 0},
	]
	for invalid_property in invalid_properties:
		var mixed_patch := {"opacity": 0.25}
		mixed_patch.merge(invalid_property, true)
		var operation := _op("update", "hero", mixed_patch)
		assert_false(
			StageLayerState.validate_operation(operation, false),
			str(invalid_property),
		)
		layers = StageLayerState.reduce(layers, [operation], false)
		assert_eq(
			layers,
			original,
			"valid fields must not survive an invalid alias: %s"
			% [invalid_property],
		)


func test_layer_ids_have_no_hidden_reserved_namespace():
	var layers := StageLayerState.reduce({}, [
		_op("show", "actor:sakura", {"asset": "stage:actor"}),
		_op("show", "event", {"asset": "stage:event"}),
	])
	assert_true(layers.has("actor:sakura"))
	assert_true(layers.has("event"))

	layers = StageLayerState.reduce(layers, [_op("clear")])
	assert_true(layers.is_empty())


func test_invalid_and_non_finite_values_preserve_json_safe_state():
	var layers := StageLayerState.reduce({}, [
		_op("show", "hero", {
			"position": [100.0, 200.0],
			"scale": [0.5, 0.75],
			"opacity": 0.8,
			"visible": true,
		}),
	])
	layers = StageLayerState.reduce(layers, [
		_op("update", "hero", {
			"position": [NAN, 999.0],
			"scale": "not-a-number",
			"opacity": INF,
			"visible": "maybe",
		}),
	])

	assert_eq(layers["hero"]["position"], [100.0, 200.0])
	assert_eq(layers["hero"]["scale"], [0.5, 0.75])
	assert_almost_eq(layers["hero"]["opacity"], 0.8, 0.001)
	assert_true(layers["hero"]["visible"])
	var encoded := JSON.stringify(layers).to_lower()
	assert_false(encoded.contains("nan"))
	assert_false(encoded.contains("inf"))


func test_stage_layer_handler_emits_one_typed_atomic_operation():
	var presenter := StagePresenter.new()
	add_child_autoqfree(presenter)
	var received: Array = []
	var callback = func(operations, force_cut):
		received.append({"operations": operations, "force_cut": force_cut})
	SignalBus.stage_operations_requested.connect(callback)

	var command := CommandData.new()
	command.type = "stage_layer"
	command.params = {
		"action": "show",
		"id": "hero",
		"properties": {
			"face": "background:bg_cafe",
			"redraw": [{
				"type": "brightness_contrast",
				"brightness": 17,
				"contrast": -24,
			}],
		},
		"transition": "fade",
		"transition_params": {},
		"duration": 0.25,
	}
	var scenario := ScenarioData.new()
	scenario.id = "stage_handler_test"
	var context := ScenarioContext.new(scenario)
	await StageLayerHandler.new(
		StellaRuntime.presentation_director).execute(command, context)

	assert_eq(received.size(), 1)
	assert_false(received[0]["force_cut"])
	assert_eq(received[0]["operations"][0]["id"], "hero")
	assert_eq(
		received[0]["operations"][0]["properties"]["face"],
		"background:bg_cafe",
	)
	assert_eq(
		received[0]["operations"][0]["properties"]["redraw"][0]["brightness"],
		17,
	)
	SignalBus.stage_operations_requested.disconnect(callback)
	StellaRuntime.clear_stage_layers()
	await get_tree().process_frame


func test_runtime_registers_stage_layer_handler():
	assert_true(StellaRuntime.registry.has_handler("stage_layer"))
	assert_true(
		StellaRuntime.registry.get_handler("stage_layer") is StageLayerHandler,
	)
