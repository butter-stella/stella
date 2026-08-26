extends GutTest
## Public synthetic parser, Resource, and typed request contract for issue #198.

const SOURCE_PATH := "res://tests/fixtures/scenarios/presentation_clip/contract.stla"
const CLIP_PATH := "res://tests/fixtures/presentation_clips/synthetic_clip.tres"
const PARTICLE_CLIP_PATH := (
	"res://tests/fixtures/presentation_clips/synthetic_particle_clip.tres")


func _parse(source: String) -> ScenarioData:
	return DslParser.parse(DslLexer.tokenize(source), "clip_contract", SOURCE_PATH)


func _commands(data: ScenarioData) -> Array[CommandData]:
	var result: Array[CommandData] = []
	for scene_value: Variant in data.scenes:
		var scene: SceneData = scene_value
		for command_value: Variant in scene.commands:
			result.append(command_value as CommandData)
	return result


func _errors(data: ScenarioData) -> Array:
	return data.diagnostics.filter(
		func(value: Dictionary) -> bool:
			return String(value.get("level", "")) == "error")


func _operation(asset: String = "synthetic_clip") -> PresentationClipPresentationOperation:
	return PresentationClipPresentationOperation.new(
		{"asset": asset}, {"source_path": SOURCE_PATH, "line": 3})


func _valid_definition() -> PresentationClipDefinition:
	return load(CLIP_PATH) as PresentationClipDefinition


func _particle_layer(
	id: StringName,
	emission_mode: StringName,
) -> PresentationClipParticleLayer:
	var layer := PresentationClipParticleLayer.new()
	layer.id = id
	layer.texture = ImageTexture.create_from_image(
		Image.create(4, 4, false, Image.FORMAT_RGBA8))
	layer.texture_filter = &"linear"
	layer.mask_mode = &"none"
	layer.mask_filter = &"nearest"
	layer.blend_mode = &"mix"
	layer.emission_mode = emission_mode
	layer.emission_start_seconds = 0.0
	layer.emission_end_seconds = 0.0 if emission_mode == &"burst" else 0.1
	layer.lifetime_seconds = 0.1
	layer.maximum_live_particles = 4
	layer.seed = 17
	layer.spawn_rect = Rect2(16, 16, 4, 4)
	layer.projection_bounds = Rect2(0, 0, 64, 64)
	layer.offset_motion_keys = PackedVector3Array([
		Vector3(0, 0, 0), Vector3(0.5, 2, 0), Vector3(1, 0, 0),
	])
	layer.scaled_motion_keys = PackedVector3Array([
		Vector3(0, 0, 0), Vector3(1, 8, -4),
	])
	layer.opacity_keys = PackedVector2Array([
		Vector2(0, 1), Vector2(1, 0),
	])
	layer.scale_keys = PackedVector2Array([
		Vector2(0, 1), Vector2(1, 0.5),
	])
	layer.rotation_keys = PackedVector2Array([
		Vector2(0, 0), Vector2(1, 1),
	])
	if emission_mode == &"burst":
		layer.spawn_rate_min = 0.0
		layer.spawn_rate_max = 0.0
		layer.burst_count_min = 2
		layer.burst_count_max = 3
	else:
		layer.spawn_rate_min = 10.0
		layer.spawn_rate_max = 20.0
		layer.burst_count_min = 0
		layer.burst_count_max = 0
	return layer


func _packed_scene_with(
	extra_node: Node = null,
	track_type: Animation.TrackType = Animation.TYPE_VALUE,
	track_path: NodePath = NodePath("Visual:modulate"),
) -> PackedScene:
	var root := Node2D.new()
	root.name = "Clip"
	var visual := ColorRect.new()
	visual.name = "Visual"
	root.add_child(visual)
	visual.owner = root
	if extra_node != null:
		root.add_child(extra_node)
		extra_node.owner = root
	var player := AnimationPlayer.new()
	player.name = "AnimationPlayer"
	root.add_child(player)
	player.owner = root
	var animation := Animation.new()
	animation.length = 0.2
	var track := animation.add_track(track_type)
	animation.track_set_path(track, track_path)
	if track_type == Animation.TYPE_VALUE:
		animation.track_insert_key(track, 0.0, Color.WHITE)
	var library := AnimationLibrary.new()
	library.add_animation(&"clip", animation)
	player.add_animation_library(&"", library)
	var packed := PackedScene.new()
	assert_eq(packed.pack(root), OK)
	root.free()
	return packed


func _definition_for(scene: PackedScene) -> PresentationClipDefinition:
	var definition := PresentationClipDefinition.new()
	definition.scene = scene
	definition.animation_player_path = NodePath("AnimationPlayer")
	definition.animation_name = &"clip"
	definition.entry_transition = &"cut"
	definition.entry_duration = 0.0
	definition.exit_transition = &"cut"
	definition.exit_duration = 0.0
	definition.suppress_dialogue_surface = false
	definition.suppress_quick_menu = false
	return definition


func _prepare(definition: PresentationClipDefinition) -> Dictionary:
	var presenter := PresentationClipPresenter.new()
	var result: Dictionary = presenter.call("_prepare_plan", definition)
	presenter.free()
	return result


func _release_plan(plan: Dictionary) -> void:
	var root: Node = plan.get("scene_root")
	if root != null and is_instance_valid(root):
		root.free()


func test_short_dsl_defaults_to_one_join_clip_command() -> void:
	var data := _parse("@chapter clip \"Clip\"\n@scene start\n@presentation_clip synthetic_clip\n")
	assert_eq(_errors(data), [], str(data.diagnostics))
	var commands := _commands(data)
	assert_eq(commands.size(), 1)
	if commands.size() != 1:
		return
	assert_eq(commands[0].type, "presentation_clip")
	assert_eq(commands[0].params, {
		"asset": "synthetic_clip",
		"policy": "join",
	})
	assert_eq(commands[0].declared_line, 3)


func test_short_dsl_supports_only_one_optional_policy() -> void:
	var fnf := _parse(
		"@chapter clip \"Clip\"\n@scene start\n"
		+ "@presentation_clip ui/eyecatch policy=fire_and_forget\n")
	assert_eq(_errors(fnf), [])
	assert_eq(_commands(fnf)[0].params, {
		"asset": "ui/eyecatch", "policy": "fire_and_forget",
	})
	for authored: String in [
		"@presentation_clip",
		"@presentation_clip ../clip",
		"@presentation_clip clip transition=turn",
		"@presentation_clip clip policy=join policy=fire_and_forget",
		"@presentation_clip clip policy=parallel",
	]:
		var data := _parse("@chapter clip \"Clip\"\n@scene start\n%s\n" % authored)
		assert_eq(_commands(data).size(), 0, authored)
		assert_eq(_errors(data).size(), 1, authored)
		if not _errors(data).is_empty():
			assert_eq(int(_errors(data)[0].get("line", 0)), 3)
			assert_true(SOURCE_PATH + ":3" in String(
				_errors(data)[0].get("message", "")))


func test_definition_preserves_stable_authored_cue_order_and_bounds() -> void:
	var definition := _valid_definition()
	assert_not_null(definition)
	assert_true(definition.validation_errors().is_empty())
	assert_eq(definition.cues.map(
		func(cue: PresentationClipCue) -> String:
			if cue is PresentationClipStateCue:
				return "state:" + String(
					(cue as PresentationClipStateCue).animation_name)
			return "audio:" + (cue as PresentationClipAudioCue).asset
	), ["state:left", "audio:synthetic_loop_region", "state:right"])
	var reversed := definition.duplicate(true) as PresentationClipDefinition
	var first := PresentationClipStateCue.new()
	first.offset_seconds = 0.2
	first.animation_player_path = NodePath("StatePlayer")
	first.animation_name = &"left"
	var second := PresentationClipStateCue.new()
	second.offset_seconds = 0.1
	second.animation_player_path = NodePath("StatePlayer")
	second.animation_name = &"right"
	reversed.cues = [first, second]
	assert_true("ascending authored offsets" in "\n".join(reversed.validation_errors()))


func test_particle_layers_are_typed_ordered_and_defensively_snapshotted() -> void:
	var definition := _valid_definition().duplicate(true) as PresentationClipDefinition
	definition.particle_layers = [
		_particle_layer(&"burst_front", &"burst"),
		_particle_layer(&"rate_back", &"rate"),
	]
	assert_true(definition.validation_errors().is_empty(),
		"\n".join(definition.validation_errors()))
	var fingerprint := definition.semantic_fingerprint()
	var snapshot := definition.canonical_value_snapshot()
	var layers: Array = snapshot.get("particle_layers", [])
	assert_eq(layers.size(), 2)
	assert_eq((layers[0] as Dictionary).get("id"), "burst_front")
	assert_eq((layers[0] as Dictionary).get("emission_mode"), "burst")
	assert_eq((layers[0] as Dictionary).get("burst_count_min"), 2)
	assert_eq((layers[0] as Dictionary).get("texture_filter"), "linear")
	assert_eq((layers[1] as Dictionary).get("id"), "rate_back")
	assert_eq((layers[1] as Dictionary).get("emission_mode"), "rate")
	assert_eq((layers[1] as Dictionary).get("spawn_rate_max"), 20.0)
	(layers[0] as Dictionary)["id"] = "mutated"
	assert_eq(String(definition.particle_layers[0].id), "burst_front",
		"public canonical values cannot mutate the sealed Resource")
	assert_eq(definition.semantic_fingerprint(), fingerprint,
		"defensive snapshot mutation cannot change valid order or fingerprint")
	var duplicate := definition.duplicate(true) as PresentationClipDefinition
	duplicate.particle_layers[1].id = &"burst_front"
	assert_string_contains(
		"\n".join(duplicate.validation_errors()), "duplicate id 'burst_front'")


func test_embedded_particle_validation_identifies_layer_provenance_and_field() -> void:
	var definition := _definition_for(_packed_scene_with())
	var layer := _particle_layer(&"invalid_rate", &"rate")
	layer.authored_source_path = SOURCE_PATH
	layer.authored_source_line = 91
	layer.spawn_rate_min = 0.0
	definition.particle_layers = [layer]
	var plan := _prepare(definition)
	assert_false(bool(plan.get("valid", false)), str(plan))
	assert_eq(
		String(plan.get("error", "")),
		("<embedded PresentationClipDefinition> particle_layers[0] authored at "
		+ SOURCE_PATH + ":91: spawn_rate_min/max must be finite ascending values "
		+ "in (0,240]"),
	)


func test_canonical_snapshot_preserves_null_cue_and_particle_ordinals() -> void:
	var definition := _definition_for(_packed_scene_with())
	definition.cues = [null]
	definition.particle_layers = [null]
	var snapshot := definition.canonical_value_snapshot()
	var cues: Array = snapshot.get("cues", [])
	var layers: Array = snapshot.get("particle_layers", [])
	var presenter := PresentationClipPresenter.new()
	assert_true(presenter.call("_definition_resource_scripts_are_exact", definition),
		"null ordinals contain no executable script and defer to schema validation")
	presenter.free()
	assert_eq(cues.size(), 1)
	assert_null(cues[0], "null cue remains at authored ordinal zero")
	assert_eq(layers.size(), 1)
	assert_null(layers[0], "null particle remains at authored ordinal zero")


func test_particle_emission_modes_fail_close_instead_of_averaging_authored_ranges() -> void:
	var burst := _particle_layer(&"burst", &"burst")
	assert_eq(burst.maximum_spawn_event_count(), 3)
	burst.spawn_rate_min = 10.0
	assert_string_contains(
		"\n".join(burst.validation_errors()),
		"burst emission requires zero spawn_rate_min/max",
	)
	burst.spawn_rate_min = 0.0
	burst.emission_end_seconds = 0.1
	assert_string_contains(
		"\n".join(burst.validation_errors()),
		"burst emission requires end_seconds equal to start_seconds",
	)
	var rate := _particle_layer(&"rate", &"rate")
	rate.emission_end_seconds = 0.2
	assert_eq(rate.maximum_spawn_event_count(), 4)
	var presenter := PresentationClipPresenter.new()
	var sealed_rate: Dictionary = presenter.call(
		"_seal_particle_event_arrays", rate, 0)
	var sealed_times: PackedFloat64Array = sealed_rate.get("spawn_times")
	assert_eq(sealed_times.size(), 3)
	assert_almost_eq(sealed_times[0], 0.06574375226628035, 0.000000000001,
		"rate mode samples the authored 1/fmin..1/fmax interval endpoints")
	assert_almost_eq(sealed_times[1], 0.14873008953873068, 0.000000000001)
	assert_almost_eq(sealed_times[2], 0.19895901181735097, 0.000000000001)
	presenter.free()
	rate.burst_count_max = 2
	assert_string_contains(
		"\n".join(rate.validation_errors()),
		"rate emission requires zero burst_count_min/max",
	)
	rate.burst_count_max = 0
	rate.spawn_rate_max = 80.0
	assert_string_contains(
		"\n".join(rate.validation_errors()),
		"maximum_live_particles must cover the worst-case rate/lifetime window",
	)
	var shared_direction := _particle_layer(&"direction", &"burst")
	shared_direction.motion_scale_min = 0.5
	shared_direction.motion_scale_max = 2.0
	assert_true(shared_direction.validation_errors().is_empty(),
		"one scalar preserves the authored motion direction")
	shared_direction.texture_filter = &"project_default"
	shared_direction.mask_filter = &"project_default"
	assert_string_contains(
		"\n".join(shared_direction.validation_errors()),
		"texture_filter must be nearest or linear",
	)
	assert_string_contains(
		"\n".join(shared_direction.validation_errors()),
		"mask_filter must be nearest or linear",
	)
	var live_source := _particle_layer(&"live_source", &"burst")
	live_source.texture = ViewportTexture.new()
	assert_string_contains(
		"\n".join(live_source.validation_errors()),
		"texture must not use live, external, procedural, or render-target",
	)
	var live_mask := _particle_layer(&"live_mask", &"burst")
	live_mask.mask_mode = &"alpha"
	live_mask.mask_rect = Rect2(0, 0, 64, 64)
	live_mask.mask_texture = CameraTexture.new()
	assert_string_contains(
		"\n".join(live_mask.validation_errors()),
		"mask_texture must not use live, external, procedural, or render-target",
	)
	var wrapped_live := AtlasTexture.new()
	wrapped_live.atlas = Texture2DRD.new()
	live_source.texture = wrapped_live
	assert_string_contains(
		"\n".join(live_source.validation_errors()), "Texture2DRD")


func test_particle_plan_preflights_exact_resources_and_native_particle_nodes_stay_forbidden() -> void:
	var definition := _valid_definition().duplicate(true) as PresentationClipDefinition
	definition.particle_layers = [_particle_layer(&"rate", &"rate")]
	var plan := _prepare(definition)
	assert_true(bool(plan.get("valid", false)), str(plan))
	if bool(plan.get("valid", false)):
		assert_eq(
			(plan.get("particle_schedules", []) as Array).size(), 1,
			"typed particle work is sealed before apply",
		)
		assert_gt(int(plan.get("particle_instance_bytes", 0)), 0)
		_release_plan(plan)
	for forbidden: Node in [GPUParticles2D.new(), CPUParticles2D.new()]:
		forbidden.name = "ForbiddenNativeParticle"
		var forbidden_class := forbidden.get_class()
		var native_plan := _prepare(_definition_for(_packed_scene_with(forbidden)))
		assert_false(bool(native_plan.get("valid", false)), forbidden_class)
		assert_eq(
			String(native_plan.get("error", "")),
			"clip scene contains forbidden data owner '%s' before instantiation" % forbidden_class,
		)


func test_particle_schedule_is_seeded_ordered_and_bounded_by_the_main_clock() -> void:
	var definition := load(PARTICLE_CLIP_PATH) as PresentationClipDefinition
	assert_not_null(definition)
	if definition == null:
		return
	var first := _prepare(definition)
	var second := _prepare(definition)
	assert_true(bool(first.get("valid", false)), str(first))
	assert_true(bool(second.get("valid", false)), str(second))
	if not bool(first.get("valid", false)) or not bool(second.get("valid", false)):
		_release_plan(first)
		_release_plan(second)
		return
	var first_schedules: Array = first.get("particle_schedules", [])
	var second_schedules: Array = second.get("particle_schedules", [])
	assert_eq(first_schedules.size(), 2)
	assert_eq((first_schedules[0] as Dictionary).get("id"), &"burst_front")
	assert_eq((first_schedules[1] as Dictionary).get("id"), &"rate_back")
	var first_signature := JSON.stringify(first_schedules.map(
		func(schedule: Dictionary) -> Array:
			return [
				Array(schedule.get("spawn_times", PackedFloat64Array())),
				Array(schedule.get("spawn_x", PackedFloat64Array())),
				Array(schedule.get("spawn_y", PackedFloat64Array())),
				Array(schedule.get("motion_scales", PackedFloat64Array())),
				Array(schedule.get("initial_scales", PackedFloat64Array())),
				Array(schedule.get("initial_rotations", PackedFloat64Array())),
			]
	))
	var second_signature := JSON.stringify(second_schedules.map(
		func(schedule: Dictionary) -> Array:
			return [
				Array(schedule.get("spawn_times", PackedFloat64Array())),
				Array(schedule.get("spawn_x", PackedFloat64Array())),
				Array(schedule.get("spawn_y", PackedFloat64Array())),
				Array(schedule.get("motion_scales", PackedFloat64Array())),
				Array(schedule.get("initial_scales", PackedFloat64Array())),
				Array(schedule.get("initial_rotations", PackedFloat64Array())),
			]
	))
	assert_eq(first_signature, second_signature,
		"same definition and seed seal the same authored-order schedule")
	assert_gt(int(first.get("particle_event_bytes", 0)), 0)
	assert_gt(int(first.get("particle_instance_bytes", 0)), 0)
	assert_gt(int(first.get("particle_curve_bytes", 0)), 0)
	_release_plan(first)
	_release_plan(second)


func test_particle_schedule_and_geometry_fail_before_budget_claim() -> void:
	var sparse_rate := _valid_definition().duplicate(true) as PresentationClipDefinition
	var sparse_layer := _particle_layer(&"sparse", &"rate")
	sparse_layer.emission_end_seconds = 0.19
	sparse_layer.spawn_rate_min = 10.0
	sparse_layer.spawn_rate_max = 10.0
	sparse_layer.lifetime_seconds = 0.05
	sparse_rate.particle_layers = [sparse_layer]
	var sparse_plan := _prepare(sparse_rate)
	assert_true(bool(sparse_plan.get("valid", false)), str(sparse_plan))
	if bool(sparse_plan.get("valid", false)):
		var sparse_schedule: Dictionary = (
			sparse_plan.get("particle_schedules", []) as Array)[0]
		assert_eq(
			(sparse_schedule.get("spawn_times") as PackedFloat64Array).size(), 1,
			"unused tail window does not reject an exact sealed rate schedule",
		)
		_release_plan(sparse_plan)
	var duration_overflow := _valid_definition().duplicate(true) as PresentationClipDefinition
	var late_layer := _particle_layer(&"late", &"burst")
	late_layer.emission_start_seconds = 0.15
	late_layer.emission_end_seconds = 0.15
	duration_overflow.particle_layers = [late_layer]
	var duration_plan := _prepare(duration_overflow)
	assert_false(bool(duration_plan.get("valid", false)), str(duration_plan))
	assert_string_contains(
		String(duration_plan.get("error", "")),
		"particle_layers[0]",
	)
	assert_string_contains(
		String(duration_plan.get("error", "")),
		"last sealed spawn plus lifetime exceeds",
	)
	var geometry_overflow := _valid_definition().duplicate(true) as PresentationClipDefinition
	var escaped := _particle_layer(&"escaped", &"burst")
	escaped.projection_bounds = Rect2(16, 16, 4, 4)
	escaped.authored_source_path = SOURCE_PATH
	escaped.authored_source_line = 27
	geometry_overflow.particle_layers = [escaped]
	var geometry_plan := _prepare(geometry_overflow)
	assert_false(bool(geometry_plan.get("valid", false)), str(geometry_plan))
	assert_string_contains(
		String(geometry_plan.get("error", "")),
		SOURCE_PATH + ":27",
	)
	assert_string_contains(
		String(geometry_plan.get("error", "")),
		"projection_bounds do not enclose",
	)


func test_particle_work_budget_reserves_and_releases_exactly() -> void:
	var definition := load(PARTICLE_CLIP_PATH) as PresentationClipDefinition
	var presenter := PresentationClipPresenter.new()
	var original_budget := StellaRuntime.presentation_clip_resource_budget_bytes
	var plan: Dictionary = presenter.call("_prepare_plan", definition)
	assert_true(bool(plan.get("valid", false)), str(plan))
	if not bool(plan.get("valid", false)):
		presenter.free()
		return
	var exact_bytes := int(plan.get("resource_bytes", 0))
	assert_gt(int(plan.get("particle_layer_owner_bytes", 0)), 0)
	assert_eq(int(presenter.get("_reserved_resource_bytes")), exact_bytes)
	presenter.call("_release_plan", plan)
	assert_eq(int(presenter.get("_reserved_resource_bytes")), 0,
		"successful plan release returns the whole particle reservation")
	StellaRuntime.presentation_clip_resource_budget_bytes = exact_bytes - 1
	var rejected: Dictionary = presenter.call("_prepare_plan", definition)
	StellaRuntime.presentation_clip_resource_budget_bytes = original_budget
	assert_false(bool(rejected.get("valid", false)), str(rejected))
	assert_string_contains(
		String(rejected.get("error", "")), "particle work exceed")
	assert_eq(int(presenter.get("_reserved_resource_bytes")), 0,
		"budget rejection leaves no reservation")
	presenter.free()


func test_definition_rejects_unknown_or_incoherent_transition_contracts() -> void:
	var unknown := _valid_definition().duplicate(true) as PresentationClipDefinition
	unknown.entry_transition = &"fade"
	assert_true("entry_transition must be cut or turn" in "\n".join(
		unknown.validation_errors()))
	var cut_duration := _valid_definition().duplicate(true) as PresentationClipDefinition
	cut_duration.entry_transition = &"cut"
	cut_duration.entry_duration = 0.1
	assert_true("entry cut transition requires duration=0" in "\n".join(
		cut_duration.validation_errors()))
	var turn_duration := _valid_definition().duplicate(true) as PresentationClipDefinition
	turn_duration.exit_transition = &"turn"
	turn_duration.exit_duration = 0.0
	assert_true("exit turn transition requires duration>0" in "\n".join(
		turn_duration.validation_errors()))


func test_request_requires_exact_live_semantic_quorum() -> void:
	var authority := RefCounted.new()
	var request := PresentationClipOperationRequest.new(_operation(), false)
	assert_true(request._bind_authority(authority))
	assert_true(request._set_definition(_valid_definition(), authority))
	assert_true(request._finish_prepare(authority))
	var visual := RefCounted.new()
	var dialogue := RefCounted.new()
	var audio := RefCounted.new()
	var caps := [RefCounted.new(), RefCounted.new(), RefCounted.new()]
	for entry: Array in [
		[PresentationClipOperationRequest.ROLE_VISUAL, visual, caps[0]],
		[PresentationClipOperationRequest.ROLE_DIALOGUE, dialogue, caps[1]],
		[PresentationClipOperationRequest.ROLE_AUDIO, audio, caps[2]],
	]:
		assert_true(request._snapshot_participant(
			entry[0], entry[1], entry[2],
			func(candidate: Object, capability: RefCounted) -> bool:
				return candidate == entry[1] and capability == entry[2],
			func(
				_request: PresentationClipOperationRequest,
				_capability: RefCounted,
				_phase: StringName,
			) -> bool:
				return true,
			authority,
		))
		assert_true(request._validate(entry[1], entry[0], authority))
	assert_true(request._seal_validation(42, authority))
	for entry: Array in [
		[PresentationClipOperationRequest.ROLE_VISUAL, visual],
		[PresentationClipOperationRequest.ROLE_DIALOGUE, dialogue],
		[PresentationClipOperationRequest.ROLE_AUDIO, audio],
	]:
		assert_true(request._accept(entry[1], entry[0], authority))
	assert_true(request._seal_accept(authority))
	for entry: Array in [
		[PresentationClipOperationRequest.ROLE_VISUAL, visual],
		[PresentationClipOperationRequest.ROLE_DIALOGUE, dialogue],
		[PresentationClipOperationRequest.ROLE_AUDIO, audio],
	]:
		assert_true(request._mark_ready(entry[1], entry[0], authority))
	assert_true(request._seal_readiness(authority))
	assert_false(request.all_participants_applied())


func test_main_and_state_track_targets_are_real_and_visual() -> void:
	var plan := _prepare(_valid_definition())
	assert_true(bool(plan.get("valid", false)), str(plan))
	if not bool(plan.get("valid", false)):
		return
	var root: Node = plan["scene_root"]
	var main := root.get_node("AnimationPlayer") as AnimationPlayer
	main.play(&"clip")
	main.seek(0.2, true)
	assert_eq((root.get_node("Visual") as ColorRect).modulate, Color(0, 0, 1, 1))
	var state := root.get_node("StatePlayer") as AnimationPlayer
	state.play(&"right")
	state.seek(0.0, true)
	assert_eq((root.get_node("Visual") as ColorRect).position, Vector2(16, 8))
	_release_plan(plan)


func test_data_only_scene_rejects_independent_tracks_and_resources() -> void:
	for case_value: Variant in [
		[Animation.TYPE_METHOD, NodePath("Visual")],
		[Animation.TYPE_AUDIO, NodePath("Visual")],
		[Animation.TYPE_ANIMATION, NodePath("AnimationPlayer")],
		[Animation.TYPE_POSITION_3D, NodePath("Visual")],
		[Animation.TYPE_ROTATION_3D, NodePath("Visual")],
		[Animation.TYPE_SCALE_3D, NodePath("Visual")],
		[Animation.TYPE_BLEND_SHAPE, NodePath("Visual")],
		[Animation.TYPE_VALUE, NodePath("AnimationPlayer:speed_scale")],
	]:
		var case: Array = case_value
		var plan := _prepare(_definition_for(_packed_scene_with(
			null, case[0], case[1])))
		assert_false(bool(plan.get("valid", false)), str(case))
		assert_true(
			"track" in String(plan.get("error", "")).to_lower()
			or "clock" in String(plan.get("error", "")).to_lower(),
			str(plan))
	var sprite := Sprite2D.new()
	sprite.name = "AnimatedTextureProbe"
	sprite.texture = AnimatedTexture.new()
	var animated_plan := _prepare(_definition_for(_packed_scene_with(sprite)))
	assert_false(bool(animated_plan.get("valid", false)))
	assert_true("self-advancing" in String(animated_plan.get("error", "")))
	for invalid_path: NodePath in [
		NodePath("Missing:modulate"),
		NodePath("../../Host:visible"),
		NodePath("Visual:not_a_property"),
	]:
		var invalid_plan := _prepare(_definition_for(_packed_scene_with(
			null, Animation.TYPE_VALUE, invalid_path)))
		assert_false(bool(invalid_plan.get("valid", false)), str(invalid_path))
		assert_true(
			"target" in String(invalid_plan.get("error", "")).to_lower()
			or "property" in String(invalid_plan.get("error", "")).to_lower(),
			str(invalid_plan))
	for forbidden_surface: Node in [
		SubViewport.new(), CanvasGroup.new(), BackBufferCopy.new(), Node3D.new(),
	]:
		var forbidden_class := forbidden_surface.get_class()
		var surface_plan := _prepare(_definition_for(
			_packed_scene_with(forbidden_surface)))
		assert_false(bool(surface_plan.get("valid", false)),
			forbidden_class)
		assert_eq(
			String(surface_plan.get("error", "")),
			(
				"clip SceneState contains forbidden render-surface or 3D owner '%s' before instantiation"
				% forbidden_class
			),
			str(surface_plan),
		)


func test_scene_state_rejects_nested_surface_before_instantiation() -> void:
	var presenter := PresentationClipPresenter.new()
	var previous_root := StellaRuntime.presentation_clips_path
	StellaRuntime.presentation_clips_path = (
		"res://tests/fixtures/presentation_clips/")
	var result: Dictionary = presenter.call(
		"_resolve_definition_result", "forbidden_surface_clip")
	StellaRuntime.presentation_clips_path = previous_root
	var definition: PresentationClipDefinition = result.get("definition")
	assert_not_null(definition, str(result))
	if definition == null:
		presenter.free()
		return
	var plan: Dictionary = presenter.call("_prepare_plan", definition)
	assert_false(bool(plan.get("valid", false)), str(plan))
	assert_true("SceneState" in String(plan.get("error", "")), str(plan))
	assert_true("SubViewport" in String(plan.get("error", "")), str(plan))
	assert_eq(int(presenter.get("_reserved_resource_bytes")), 0,
		"the forbidden allocation is rejected before any plan budget is claimed")
	presenter.free()


func test_scene_state_node_budget_counts_direct_and_repeated_instances_before_instantiation() -> void:
	var presenter := PresentationClipPresenter.new()
	var previous_root := StellaRuntime.presentation_clips_path
	StellaRuntime.presentation_clips_path = (
		"res://tests/fixtures/presentation_clips/")
	for asset: String in [
		"direct_budget_overflow_clip",
		"nested_budget_overflow_clip",
	]:
		var result: Dictionary = presenter.call(
			"_resolve_definition_result", asset)
		var definition: PresentationClipDefinition = result.get("definition")
		assert_not_null(definition, "%s: %s" % [asset, result])
		if definition == null:
			continue
		var plan: Dictionary = presenter.call("_prepare_plan", definition)
		assert_false(bool(plan.get("valid", false)), "%s: %s" % [asset, plan])
		assert_eq(
			String(plan.get("error", "")),
			"clip SceneState exceeds the 512-node budget before instantiation",
			asset,
		)
		assert_eq(
			int(presenter.get("_reserved_resource_bytes")),
			0,
			"%s must fail before a detached instance or surface reserves bytes" % asset,
		)
	var valid_scene := _valid_definition().scene
	var deep_ancestry: Dictionary = {}
	for depth_index in 128:
		deep_ancestry["res://synthetic/depth_%03d.tscn" % depth_index] = true
	var deep_result: Dictionary = presenter.call(
		"_validate_packed_scene_state_model",
		valid_scene,
		deep_ancestry,
		{"visits": 0, "node_entries": 0},
	)
	assert_eq(
		String(deep_result.get("error", "")),
		"clip SceneState exceeds the bounded nesting depth before instantiation",
	)
	var cycle_ancestry: Dictionary = {}
	cycle_ancestry[valid_scene.resource_path] = true
	var cycle_result: Dictionary = presenter.call(
		"_validate_packed_scene_state_model",
		valid_scene,
		cycle_ancestry,
		{"visits": 0, "node_entries": 0},
	)
	assert_eq(
		String(cycle_result.get("error", "")),
		"clip SceneState contains a cyclic scene instance",
	)
	var dependency_depth_error: String = presenter.call(
		"_validate_resource_dependency_tree",
		CLIP_PATH,
		true,
		{},
		deep_ancestry,
		{"visits": 0},
	)
	assert_eq(
		dependency_depth_error,
		"clip data dependency graph exceeds the bounded nesting depth",
	)
	var dependency_work_error: String = presenter.call(
		"_validate_resource_dependency_tree",
		CLIP_PATH,
		true,
		{},
		{},
		{"visits": 1024},
	)
	assert_eq(
		dependency_work_error,
		"clip data dependency graph exceeds the bounded resource work budget",
	)
	StellaRuntime.presentation_clips_path = previous_root
	presenter.free()


func test_texture_budget_counts_atlas_backing_once_and_rejects_zero_size() -> void:
	var presenter := PresentationClipPresenter.new()
	var root := Node2D.new()
	var backing := ImageTexture.create_from_image(
		Image.create(256, 128, false, Image.FORMAT_RGBA8))
	for child_index in 2:
		var atlas := AtlasTexture.new()
		atlas.atlas = backing
		atlas.region = Rect2(child_index * 8, 0, 8, 8)
		var sprite := Sprite2D.new()
		sprite.texture = atlas
		root.add_child(sprite)
	assert_eq(
		int(presenter.call("_estimate_scene_texture_bytes", root)),
		256 * 128 * 4,
		"small regions cannot hide their backing atlas and shared backing counts once",
	)
	var empty_texture := ImageTexture.new()
	assert_gt(
		int(presenter.call(
			"_estimate_variant_texture_bytes", empty_texture, {})),
		StellaRuntime.presentation_clip_resource_budget_bytes,
		"zero-sized dynamic Texture2D resources fail the resource budget closed",
	)
	root.free()
	presenter.free()


func test_main_clock_is_bounded_and_positive() -> void:
	var loop_definition := _definition_for(_packed_scene_with())
	var loop_root := loop_definition.scene.instantiate()
	var loop_player := loop_root.get_node("AnimationPlayer") as AnimationPlayer
	loop_player.get_animation(&"clip").loop_mode = Animation.LOOP_LINEAR
	var repacked := PackedScene.new()
	assert_eq(repacked.pack(loop_root), OK)
	loop_root.free()
	loop_definition.scene = repacked
	var loop_plan := _prepare(loop_definition)
	assert_false(bool(loop_plan.get("valid", false)))
	assert_true("must not loop" in String(loop_plan.get("error", "")))
	var short_entry_definition := _definition_for(_packed_scene_with())
	short_entry_definition.entry_transition = &"turn"
	short_entry_definition.entry_duration = 0.3
	var short_entry_plan := _prepare(short_entry_definition)
	assert_false(bool(short_entry_plan.get("valid", false)))
	assert_true("must not be shorter" in String(
		short_entry_plan.get("error", "")))
	for scale_value: float in [0.5, 2.0]:
		var scaled_definition := _definition_for(_packed_scene_with())
		var scaled_root := scaled_definition.scene.instantiate()
		(scaled_root.get_node("AnimationPlayer") as AnimationPlayer).speed_scale = (
			scale_value)
		var scaled_scene := PackedScene.new()
		assert_eq(scaled_scene.pack(scaled_root), OK)
		scaled_root.free()
		scaled_definition.scene = scaled_scene
		var scaled_plan := _prepare(scaled_definition)
		assert_false(bool(scaled_plan.get("valid", false)), str(scale_value))
		assert_true("speed_scale must be exactly 1.0" in String(
			scaled_plan.get("error", "")), str(scaled_plan))
	var state_player := AnimationPlayer.new()
	state_player.name = "StatePlayer"
	state_player.speed_scale = 2.0
	var state_animation := Animation.new()
	state_animation.length = 0.1
	var state_library := AnimationLibrary.new()
	state_library.add_animation(&"state", state_animation)
	state_player.add_animation_library(&"", state_library)
	var state_definition := _definition_for(_packed_scene_with(state_player))
	var state_cue := PresentationClipStateCue.new()
	state_cue.offset_seconds = 0.0
	state_cue.animation_player_path = NodePath("StatePlayer")
	state_cue.animation_name = &"state"
	state_definition.cues = [state_cue]
	var state_scale_plan := _prepare(state_definition)
	assert_false(bool(state_scale_plan.get("valid", false)))
	assert_true("speed_scale must be exactly 1.0" in String(
		state_scale_plan.get("error", "")), str(state_scale_plan))


func test_resolver_rejects_scripted_scene_before_node_init() -> void:
	var presenter := PresentationClipPresenter.new()
	var previous_root := StellaRuntime.presentation_clips_path
	StellaRuntime.presentation_clips_path = (
		"res://tests/fixtures/presentation_clips/")
	for case_value: Variant in [
		[
			"forbidden_script_clip",
			"stella/tests/presentation_clip_forbidden_init_count",
			"must not depend on script",
		],
		[
			"forbidden_embedded_clip",
			"stella/tests/presentation_clip_embedded_init_count",
			"embedded Script",
		],
		[
			"forbidden_nested_resource_clip",
			"stella/tests/presentation_clip_nested_resource_init_count",
			"data dependency must not contain embedded Script",
		],
	]:
		var case: Array = case_value
		var sentinel_key := String(case[1])
		ProjectSettings.set_setting(sentinel_key, 0)
		var result: Dictionary = presenter.call(
			"_resolve_definition_result", String(case[0]))
		assert_null(result.get("definition"))
		assert_string_contains(String(result.get("error", "")), String(case[2]))
		assert_eq(int(ProjectSettings.get_setting(sentinel_key, 0)), 0,
			"data-only inspection rejects before node _init can execute")
		ProjectSettings.clear(sentinel_key)
	var nested_script_result: Dictionary = presenter.call(
		"_resolve_definition_result", "forbidden_nested_allowed_script_clip")
	assert_null(nested_script_result.get("definition"))
	assert_string_contains(
		String(nested_script_result.get("error", "")),
		"data-only clip resources must not depend on script",
	)
	StellaRuntime.presentation_clips_path = previous_root
	presenter.free()


func test_resolver_accepts_the_complete_public_data_only_definition() -> void:
	var inspection := TextResourceInspector.new().inspect(
		CLIP_PATH, "PresentationClipDefinition")
	assert_true(inspection.ok)
	assert_true(inspection.matches_expected_type)
	var presenter := PresentationClipPresenter.new()
	var previous_root := StellaRuntime.presentation_clips_path
	StellaRuntime.presentation_clips_path = (
		"res://tests/fixtures/presentation_clips/")
	var result: Dictionary = presenter.call(
		"_resolve_definition_result", "synthetic_clip")
	assert_not_null(result.get("definition"), String(result.get("error", "")))
	StellaRuntime.presentation_clips_path = previous_root
	presenter.free()
