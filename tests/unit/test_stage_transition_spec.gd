extends GutTest


class SyntheticTransitionProvider extends StageTransitionProvider:
	var transition_kind: StringName = &"synthetic_wipe"

	func _init(kind: StringName = &"synthetic_wipe") -> void:
		transition_kind = kind

	func get_transition_kind() -> StringName:
		return transition_kind

	func validate_transition(
		params: Dictionary,
		_texture_resolver: Callable,
	) -> Dictionary:
		var keys := params.keys()
		keys.sort()
		if keys != ["bands"] or not params["bands"] is int:
			return {"valid": false, "error": "synthetic_wipe requires integer bands"}
		return {"valid": true, "plan": {"params": params.duplicate(true)}}

	func create_material(
		_plan: Dictionary,
		_source_texture: Texture2D,
		_target_texture: Texture2D,
		_viewport_size: Vector2,
	) -> ShaderMaterial:
		return ShaderMaterial.new()


func test_rule_defaults_and_parameter_order_are_canonical():
	var first := StageTransitionSpec.canonicalize("rule", {
		"invert": true,
		"mask": "stage:masks/diagonal",
		"softness": 0.25,
	})
	var second := StageTransitionSpec.canonicalize("rule", {
		"softness": 0.25,
		"mask": "stage:masks/diagonal",
		"invert": true,
	})
	assert_true(first["valid"])
	assert_eq(first, second)
	assert_eq(first["params"], {
		"mask": "stage:masks/diagonal",
		"softness": 0.25,
		"invert": true,
	})
	assert_eq(
		StageTransitionSpec.canonicalize(
			"rule", {"mask": "reveal/checker"})["params"],
		{"mask": "reveal/checker", "softness": 0.0, "invert": false},
	)


func test_rule_mask_accepts_only_stella_logical_texture_ids():
	for invalid_id in [
		"res://mask.png",
		"user://mask.png",
		"/tmp/mask.png",
		"stage:../mask.png",
		"stage:masks//rule.png",
		"stage:masks/rule:variant.png",
		"unknown:mask.png",
		" stage:mask.png",
		"stage:mask.png ",
		"\tstage:mask.png",
		"stage:mask.png\n",
	]:
		var result := StageTransitionSpec.canonicalize(
			"rule", {"mask": invalid_id})
		assert_false(result["valid"], invalid_id)
	for valid_id in [
		"stage:masks/rule.png",
		"background:masks/rule",
		"character:effects/rule.webp",
		"masks/rule",
	]:
		assert_true(
			StageTransitionSpec.canonicalize(
				"rule", {"mask": valid_id})["valid"],
			valid_id,
		)


func test_mosaic_defaults_and_bounds_are_closed():
	assert_eq(
		StageTransitionSpec.canonicalize("mosaic", {})["params"],
		{"cell": StageTransitionSpec.DEFAULT_MOSAIC_CELL},
	)
	assert_true(StageTransitionSpec.canonicalize("mosaic", {"cell": 2})["valid"])
	assert_true(StageTransitionSpec.canonicalize("mosaic", {"cell": 256})["valid"])
	assert_false(StageTransitionSpec.canonicalize("mosaic", {"cell": 1})["valid"])
	assert_false(StageTransitionSpec.canonicalize("mosaic", {"cell": 2.0})["valid"])
	assert_false(StageTransitionSpec.canonicalize(
		"mosaic", {"cell": 32, "unknown": true})["valid"])
	assert_false(StageTransitionSpec.canonicalize(
		"mosaic", {" cell": 32})["valid"])


func test_registry_is_presenter_local_bounded_and_unregisters_custom_provider():
	var first := StageTransitionRegistry.new()
	var second := StageTransitionRegistry.new()
	assert_true(first.has_provider(&"rule"))
	assert_true(first.has_provider(&"mosaic"))
	assert_false(second.has_provider(&"synthetic_wipe"))
	var provider := SyntheticTransitionProvider.new()
	assert_true(first.register_provider(provider))
	assert_true(first.has_provider(&"synthetic_wipe"))
	assert_false(second.has_provider(&"synthetic_wipe"))
	assert_false(first.register_provider(provider), "duplicate registration fails closed")
	assert_false(first.register_provider(
		SyntheticTransitionProvider.new(&" synthetic_wipe")),
		"provider kind must already be canonical",
	)
	assert_false(first.register_provider(
		SyntheticTransitionProvider.new(&"none")),
		"provider kind cannot use a DSL-only author spelling",
	)
	assert_true(first.unregister_provider(&"synthetic_wipe"))
	assert_false(first.has_provider(&"synthetic_wipe"))
	assert_false(first.unregister_provider(&"rule"), "built-ins cannot be removed")


func test_registry_requires_runtime_provider_for_custom_kind():
	var registry := StageTransitionRegistry.new()
	var unknown := registry.validate_transition(
		"synthetic_wipe", {"bands": 4}, Callable())
	assert_false(unknown["valid"])
	assert_true(registry.register_provider(SyntheticTransitionProvider.new()))
	var valid := registry.validate_transition(
		"synthetic_wipe", {"bands": 4}, Callable())
	assert_true(valid["valid"])
	assert_eq(valid["plan"]["params"], {"bands": 4})
	var invalid := registry.validate_transition(
		"synthetic_wipe", {"bands": 4.0}, Callable())
	assert_false(invalid["valid"])


func test_registry_has_an_exact_provider_bound_without_global_leakage():
	var full := StageTransitionRegistry.new()
	var isolated := StageTransitionRegistry.new()
	var custom_capacity := (
		StageTransitionRegistry.MAX_PROVIDERS - full.provider_count())
	for index in range(custom_capacity):
		assert_true(full.register_provider(SyntheticTransitionProvider.new(
			StringName("synthetic_%d" % index))))
	assert_eq(full.provider_count(), StageTransitionRegistry.MAX_PROVIDERS)
	assert_false(full.register_provider(
		SyntheticTransitionProvider.new(&"synthetic_overflow")))
	assert_eq(isolated.provider_count(), 2)
	assert_false(isolated.has_provider(&"synthetic_0"),
		"a bounded registry remains Presenter-local across tests and scenes")
