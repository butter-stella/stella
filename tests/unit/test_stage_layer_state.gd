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
		"duration": 0.0,
	}


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
			"grayscale": 0.25,
			"blur": [2, 3],
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
	assert_eq(state["redraw"]["blur"], [2.0, 3.0])
	assert_ne(JSON.stringify(layers), "", "stage snapshots must serialize as JSON")


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
	invalid_transition["transition"] = "warp"
	assert_false(StageLayerState.validate_operation(invalid_transition, false))

	var negative_duration := valid.duplicate(true)
	negative_duration["duration"] = -0.1
	assert_false(StageLayerState.validate_operation(negative_duration, false))


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

	assert_eq(layers["hero"]["position"], [100.0, 999.0])
	assert_eq(layers["hero"]["scale"], [0.5, 0.75])
	assert_almost_eq(layers["hero"]["opacity"], 0.8, 0.001)
	assert_true(layers["hero"]["visible"])
	var encoded := JSON.stringify(layers).to_lower()
	assert_false(encoded.contains("nan"))
	assert_false(encoded.contains("inf"))


func test_stage_layer_handler_emits_one_atomic_operation():
	var received: Array = []
	var callback = func(operations, force_cut):
		received.append({"operations": operations, "force_cut": force_cut})
	SignalBus.stage_operations_requested.connect(callback)

	var command := CommandData.new()
	command.type = "stage_layer"
	command.params = {
		"action": "show",
		"id": "hero",
		"properties": {"face": "stage:sad"},
		"transition": "fade",
		"duration": 0.25,
	}
	await StageLayerHandler.new().execute(command, null)

	assert_eq(received.size(), 1)
	assert_false(received[0]["force_cut"])
	assert_eq(received[0]["operations"][0]["id"], "hero")
	assert_eq(received[0]["operations"][0]["properties"]["face"], "stage:sad")
	SignalBus.stage_operations_requested.disconnect(callback)
	StellaRuntime.clear_stage_layers()


func test_runtime_registers_stage_layer_handler():
	assert_true(StellaRuntime.registry.has_handler("stage_layer"))
	assert_true(
		StellaRuntime.registry.get_handler("stage_layer") is StageLayerHandler,
	)
