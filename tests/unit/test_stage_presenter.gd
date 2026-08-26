extends GutTest

const DEFAULT_GAME_SCENE := preload("res://addons/stella/scenes/game.tscn")
const DEMO_GAME_SCENE := preload("res://examples/demo/scenes/game.tscn")
const BACKGROUNDS_PATH := "res://examples/demo/art/backgrounds/"
const CHARACTERS_PATH := "res://examples/demo/art/characters/"

var _game_scene: Node
var _presenter: StagePresenter
var _original_backgrounds_path: String
var _original_characters_path: String
var _original_stage_assets_path: String
var _original_presentation_snapshot: Dictionary
var _started_transitions: Array = []


func before_each() -> void:
	_started_transitions.clear()
	if not SignalBus.stage_transition_started.is_connected(_on_stage_transition_started):
		SignalBus.stage_transition_started.connect(_on_stage_transition_started)
	_original_presentation_snapshot = StellaRuntime.presentation_state.capture_snapshot()
	StellaRuntime.presentation_state.clear()
	_original_backgrounds_path = StellaRuntime.backgrounds_path
	_original_characters_path = StellaRuntime.characters_path
	_original_stage_assets_path = StellaRuntime.stage_assets_path
	StellaRuntime.backgrounds_path = BACKGROUNDS_PATH
	StellaRuntime.characters_path = CHARACTERS_PATH
	StellaRuntime.stage_assets_path = BACKGROUNDS_PATH
	StellaRuntime.character_config_loader.set_base_path(CHARACTERS_PATH)
	StellaRuntime.character_config_loader.clear_cache()

	_game_scene = DEFAULT_GAME_SCENE.instantiate()
	add_child_autoqfree(_game_scene)
	_presenter = _game_scene.get_node("StageLayer") as StagePresenter
	await get_tree().process_frame


func after_each() -> void:
	if SignalBus.stage_transition_started.is_connected(_on_stage_transition_started):
		SignalBus.stage_transition_started.disconnect(_on_stage_transition_started)
	StellaRuntime.backgrounds_path = _original_backgrounds_path
	StellaRuntime.characters_path = _original_characters_path
	StellaRuntime.stage_assets_path = _original_stage_assets_path
	StellaRuntime.character_config_loader.set_base_path(_original_characters_path)
	StellaRuntime.character_config_loader.clear_cache()
	StellaRuntime.presentation_state.restore_snapshot(_original_presentation_snapshot)


func _on_stage_transition_started(
	presenter_instance_id: int,
	layer_id: String,
	token: int,
	operation_request_id: int,
) -> void:
	_started_transitions.append({
		"presenter_instance_id": presenter_instance_id,
		"layer_id": layer_id,
		"token": token,
		"operation_request_id": operation_request_id,
	})


func _latest_transition(layer_id: String) -> Dictionary:
	for index in range(_started_transitions.size() - 1, -1, -1):
		var transition: Dictionary = _started_transitions[index]
		if String(transition.get("layer_id", "")) == layer_id:
			return transition.duplicate(true)
	return {}


func _operation(
	action: String,
	layer_id: String = "",
	properties: Dictionary = {},
	transition: String = "cut",
	duration: float = 0.0,
) -> Dictionary:
	return {
		"action": action,
		"id": layer_id,
		"properties": properties,
		"transition_params": {},
		"transition": transition,
		"duration": duration,
	}


func _emit_operations(operations: Array, force_cut: bool = true) -> void:
	SignalBus.emit_stage_operations(operations, force_cut)


func _sprite(layer: Node2D, channel: String) -> Sprite2D:
	return layer.find_child(
		"%sSprite" % channel.capitalize(),
		true,
		false,
	) as Sprite2D


func test_default_and_demo_scenes_have_one_dynamic_stage_layer() -> void:
	_assert_scene_layering(_game_scene)
	var demo_scene := DEMO_GAME_SCENE.instantiate()
	add_child_autoqfree(demo_scene)
	_assert_scene_layering(demo_scene)


func _assert_scene_layering(scene: Node) -> void:
	assert_null(scene.get_node_or_null("CharacterLayer"))
	assert_null(scene.get_node_or_null("StageLayer/ShakeRoot/SlotLeft"))
	assert_null(scene.get_node_or_null("StageLayer/ShakeRoot/SlotCenter"))
	assert_null(scene.get_node_or_null("StageLayer/ShakeRoot/SlotRight"))
	assert_eq((scene.get_node("BackgroundLayer") as CanvasLayer).layer, 0)
	assert_eq((scene.get_node("StageLayer") as CanvasLayer).layer, 1)
	assert_eq((scene.get_node("FadeLayer") as CanvasLayer).layer, 2)
	assert_eq((scene.get_node("UILayer") as CanvasLayer).layer, 3)
	var shake_root := scene.get_node("StageLayer/ShakeRoot") as Control
	assert_eq(shake_root.mouse_filter, Control.MOUSE_FILTER_IGNORE)
	assert_eq(shake_root.size, scene.get_viewport().get_visible_rect().size)


func test_named_layer_mounts_under_shake_root_and_projects_state() -> void:
	var layer_id := "hero/unsafe:name"
	_emit_operations([_operation("show", layer_id, {
		"asset": "stage:bg_school_gate",
		"body": "stage:bg_cafe",
		"face": "stage:bg_hallway",
		"asset_offset": [1.0, 2.0],
		"body_offset": [3.0, 4.0],
		"face_offset": [5.0, 6.0],
		"position": [123.0, 234.0],
		"origin": [8.0, 9.0],
		"scale": [2.0, 3.0],
		"zoom": [0.5, 0.25],
		"depth_scale": 2.0,
		"rotation": 37.0,
		"z_index": 12,
		"depth_origin": 0.75,
		"opacity": 0.45,
		"flip_x": true,
		"redraw": [
			{"type": "grayscale", "amount": 0.4},
			{"type": "blur", "radius": [2, 3]},
			{"type": "tint", "color": "#80ffffff"},
		],
	})])

	var layer: Node2D = _presenter.get_layer_node(layer_id)
	assert_not_null(layer)
	assert_same(layer.get_parent(), _game_scene.get_node("StageLayer/ShakeRoot"))
	assert_eq(String(layer.get_meta("stage_layer_id")), layer_id)
	assert_ne(String(layer.name), layer_id, "public ids must not become node paths")
	assert_eq(layer.position, Vector2(123.0, 234.0))
	assert_eq(layer.scale, Vector2(2.0, 1.5))
	assert_almost_eq(layer.rotation_degrees, 37.0, 0.001)
	assert_eq(layer.z_index, 12)
	assert_almost_eq(
		float(_presenter._layers[layer_id]["depth_sort_key"]), 12.75, 0.001)

	var composite := layer.get_node("Composite") as CanvasGroup
	assert_eq(composite.position, Vector2(8.0, -9.0))
	assert_eq(composite.scale, Vector2(-1.0, 1.0))
	assert_almost_eq(composite.self_modulate.a, 0.45, 0.001)
	assert_null(composite.material)
	var record: Dictionary = _presenter._layers[layer_id]
	var output := record["redraw_pipeline_output"] as Sprite2D
	assert_not_null(output)
	assert_same(output.material, record["redraw_material"])
	assert_eq(_sprite(layer, "asset").position, Vector2(1.0, 2.0))
	assert_eq(_sprite(layer, "body").position, Vector2(3.0, 4.0))
	assert_eq(_sprite(layer, "face").position, Vector2(5.0, 6.0))


func test_depth_origin_sorts_independently_from_transform_and_channels() -> void:
	_emit_operations([
		_operation("show", "effect", {
			"asset": "stage:bg_school_gate",
			"position": [0.0, 0.0],
			"origin": [3.0, 4.0],
			"scale": [1.25, 0.75],
			"depth_scale": 0.8,
			"z_index": 25,
			"depth_origin": -8000.0,
		}),
		_operation("show", "character", {
			"body": "stage:bg_cafe",
			"face": "stage:bg_hallway",
			"position": [0.0, -150.0],
			"origin": [7.0, 9.0],
			"scale": [0.5, 0.75],
			"depth_scale": 1.2,
			"z_index": 25,
			"depth_origin": -9000.0,
			"redraw": [{
				"type": "clip",
				"asset": "res://tests/fixtures/stage/redraw_mask.png",
				"offset": [11.0, 13.0],
				"fit": "native",
			}],
		}),
	])
	var effect := _presenter.get_layer_node("effect")
	var character := _presenter.get_layer_node("character")
	assert_gt(effect.get_index(), character.get_index())
	assert_eq(effect.position, Vector2.ZERO)
	assert_eq(character.position, Vector2(0.0, -150.0))
	assert_eq(effect.scale, Vector2(1.0, 0.6))
	assert_almost_eq(character.scale.x, 0.6, 0.001)
	assert_almost_eq(character.scale.y, 0.9, 0.001)
	assert_eq((effect.get_node("Composite") as CanvasGroup).position, Vector2(-3.0, -4.0))
	assert_eq((character.get_node("Composite") as CanvasGroup).position, Vector2(-7.0, -9.0))
	assert_not_null(_sprite(character, "body").texture)
	assert_not_null(_sprite(character, "face").texture)
	assert_eq(
		(_presenter._states["character"]["redraw"] as Array)[0]["offset"],
		[11.0, 13.0],
	)

	_emit_operations([_operation("update", "character", {
		"depth_origin": -7000.0,
	})])
	assert_gt(character.get_index(), effect.get_index())
	assert_eq(character.position, Vector2(0.0, -150.0))
	assert_almost_eq(character.scale.x, 0.6, 0.001)
	assert_almost_eq(character.scale.y, 0.9, 0.001)


func test_move_interpolates_full_depth_key_and_force_finish_snaps_exactly() -> void:
	_emit_operations([_operation("show", "moving_depth", {
		"z_index": 25,
		"depth_origin": -9000.0,
	})])
	_emit_operations([_operation("update", "moving_depth", {
		"depth_origin": -8000.0,
	}, "move", 2.0)], false)
	var tween: Tween = _presenter._layer_tweens["moving_depth"]
	tween.custom_step(1.0)
	assert_almost_eq(
		float(_presenter._layers["moving_depth"]["depth_sort_key"]),
		-8475.0,
		0.01,
	)
	var transition := _latest_transition("moving_depth")
	SignalBus.stage_transitions_finish_requested.emit([transition])
	assert_false(_presenter._layer_tweens.has("moving_depth"))
	assert_almost_eq(
		float(_presenter._layers["moving_depth"]["depth_sort_key"]),
		-7975.0,
		0.001,
	)
	assert_eq(
		_presenter.get_layer_node("moving_depth").z_index,
		RenderingServer.CANVAS_ITEM_Z_MIN,
		"the CanvasItem bucket may clamp without losing the authored float key",
	)


func test_extreme_finite_depth_origin_clamps_only_the_canvas_bucket() -> void:
	_emit_operations([
		_operation("show", "far_back", {"depth_origin": -1.0e100}),
		_operation("show", "far_front", {"depth_origin": 1.0e100}),
	])
	assert_eq(
		_presenter._layers["far_back"]["depth_sort_key"], -1.0e100)
	assert_eq(
		_presenter._layers["far_front"]["depth_sort_key"], 1.0e100)
	assert_eq(
		_presenter.get_layer_node("far_back").z_index,
		RenderingServer.CANVAS_ITEM_Z_MIN,
	)
	assert_eq(
		_presenter.get_layer_node("far_front").z_index,
		RenderingServer.CANVAS_ITEM_Z_MAX,
	)
	assert_lt(
		_presenter.get_layer_node("far_back").get_index(),
		_presenter.get_layer_node("far_front").get_index(),
	)


func test_resource_prefixes_and_bare_ids_use_runtime_paths() -> void:
	_emit_operations([
		_operation("show", "stage", {"asset": "stage:bg_cafe"}),
		_operation("show", "bare", {"asset": "bg_hallway"}),
		_operation("show", "background", {"asset": "background:bg_outside"}),
		_operation("show", "character", {"asset": "character:sakura/smile"}),
		_operation("show", "direct", {
			"asset": "res://examples/demo/art/backgrounds/bg_school_gate.png",
		}),
	])

	assert_true(_sprite(_presenter.get_layer_node("stage"), "asset") \
		.texture.resource_path.ends_with("bg_cafe.png"))
	assert_true(_sprite(_presenter.get_layer_node("bare"), "asset") \
		.texture.resource_path.ends_with("bg_hallway.png"))
	assert_true(_sprite(_presenter.get_layer_node("background"), "asset") \
		.texture.resource_path.ends_with("bg_outside.png"))
	assert_true(_sprite(_presenter.get_layer_node("character"), "asset") \
		.texture.resource_path.ends_with("sakura/smile.png"))


func test_hundreds_of_face_updates_preserve_resident_nodes_and_textures() -> void:
	_emit_operations([
		_operation("show", "base", {"asset": "stage:bg_school_gate"}),
		_operation("show", "hero", {
			"body": "stage:bg_cafe",
			"face": "res://addons/gut/icon.png",
		}),
		_operation("show", "event", {"asset": "stage:bg_outside"}),
	])
	var base_layer := _presenter.get_layer_node("base")
	var base_sprite := _sprite(base_layer, "asset")
	var base_texture := base_sprite.texture
	var hero_layer := _presenter.get_layer_node("hero")
	var body_sprite := _sprite(hero_layer, "body")
	var body_texture := body_sprite.texture
	var face_sprite := _sprite(hero_layer, "face")

	for index in range(300):
		var face_asset := (
			"res://addons/gut/images/yellow.png"
			if index % 2 == 0
			else "res://addons/gut/images/green.png"
		)
		_emit_operations([
			_operation("update", "hero", {"face": face_asset}),
			_operation("update", "event", {
				"opacity": 0.25 if index % 2 == 0 else 0.75,
			}),
		])

	assert_same(_presenter.get_layer_node("base"), base_layer)
	assert_same(_sprite(base_layer, "asset"), base_sprite)
	assert_same(base_sprite.texture, base_texture)
	assert_same(_presenter.get_layer_node("hero"), hero_layer)
	assert_same(_sprite(hero_layer, "body"), body_sprite)
	assert_same(body_sprite.texture, body_texture)
	assert_same(_sprite(hero_layer, "face"), face_sprite)


func test_face_only_update_reuses_redraw_material_and_mask_texture() -> void:
	var mask_path := "res://tests/fixtures/stage/redraw_mask.png"
	_emit_operations([_operation("show", "hero", {
		"body": "stage:bg_cafe",
		"face": "res://addons/gut/images/yellow.png",
		"redraw": [
			{
				"type": "color_overlay",
				"color": "#2a5c8e40",
				"blend": "soft_light",
			},
			{"type": "brightness_contrast", "brightness": 17, "contrast": -24},
			{"type": "blur", "radius": [1, 1]},
			{
				"type": "clip",
				"asset": mask_path,
				"offset": [2.0, 1.0],
				"fit": "native",
			},
		],
	})])

	var layer := _presenter.get_layer_node("hero")
	var body_sprite := _sprite(layer, "body")
	var body_texture := body_sprite.texture
	var source := layer.find_child("Source", true, false)
	var record: Dictionary = _presenter._layers["hero"]
	var material := record["redraw_material"] as ShaderMaterial
	var mask_texture := record["redraw_mask_texture"] as Texture2D
	var pipeline_root := record["redraw_pipeline_root"] as SubViewport
	var pipeline_output := record["redraw_pipeline_output"] as Sprite2D
	var pipeline_passes := record["redraw_pipeline_passes"] as Array
	var horizontal_material := (
		(pipeline_passes[0] as Dictionary)["horizontal_material"] as ShaderMaterial
	)
	var vertical_material := (
		(pipeline_passes[0] as Dictionary)["vertical_material"] as ShaderMaterial
	)
	assert_not_null(mask_texture)
	assert_same(
		material.get_shader_parameter("clip_texture"),
		mask_texture,
	)

	_emit_operations([_operation("update", "hero", {
		"face": "res://addons/gut/images/green.png",
	})])

	assert_same(_presenter.get_layer_node("hero"), layer)
	assert_same(layer.find_child("Source", true, false), source)
	assert_same(_sprite(layer, "body"), body_sprite)
	assert_same(body_sprite.texture, body_texture)
	var updated_record: Dictionary = _presenter._layers["hero"]
	assert_same(updated_record["redraw_material"], material)
	assert_same(updated_record["redraw_mask_texture"], mask_texture)
	assert_same(updated_record["redraw_pipeline_root"], pipeline_root)
	assert_same(updated_record["redraw_pipeline_output"], pipeline_output)
	var updated_passes := updated_record["redraw_pipeline_passes"] as Array
	assert_same(
		(updated_passes[0] as Dictionary)["horizontal_material"],
		horizontal_material,
	)
	assert_same(
		(updated_passes[0] as Dictionary)["vertical_material"],
		vertical_material,
	)
	assert_same(
		material.get_shader_parameter("clip_texture"),
		mask_texture,
	)


func test_repeated_blurs_build_an_ordered_stable_viewport_pipeline() -> void:
	_emit_operations([_operation("show", "blurred", {
		"asset": "stage:bg_cafe",
		"redraw": [
			{"type": "grayscale", "amount": 1.0},
			{"type": "blur", "radius": [2, 3]},
			{"type": "tint", "color": "#ffffffff"},
			{"type": "blur", "radius": [1, 0]},
			{"type": "brightness_contrast", "brightness": 2, "contrast": -3},
		],
	})])
	var record: Dictionary = _presenter._layers["blurred"]
	var layer := _presenter.get_layer_node("blurred")
	var composite := layer.get_node("Composite") as CanvasGroup
	var source := layer.find_child("Source", true, false) as Node2D
	var material := record["redraw_material"] as ShaderMaterial
	var output := record["redraw_pipeline_output"] as Sprite2D
	var pipeline_root := record["redraw_pipeline_root"] as SubViewport
	var passes := record["redraw_pipeline_passes"] as Array
	assert_null(composite.material)
	assert_same(output.material, material)
	assert_same(output.get_parent(), composite)
	assert_same(pipeline_root.get_parent(), composite)
	assert_eq(passes.size(), 2)

	var first_pass := passes[0] as Dictionary
	var second_pass := passes[1] as Dictionary
	var source_viewport := first_pass["input_viewport"] as SubViewport
	assert_eq(String(source_viewport.name), "RedrawSource")
	assert_same(source.get_parent(), source_viewport)
	assert_same(
		source_viewport.get_parent(),
		first_pass["horizontal_viewport"],
	)
	assert_same(
		(first_pass["horizontal_viewport"] as SubViewport).get_parent(),
		first_pass["vertical_viewport"],
	)
	assert_same(
		(first_pass["vertical_viewport"] as SubViewport).get_parent(),
		second_pass["horizontal_viewport"],
	)
	assert_same(
		(second_pass["horizontal_viewport"] as SubViewport).get_parent(),
		second_pass["vertical_viewport"],
	)
	assert_same(second_pass["vertical_viewport"], pipeline_root)

	var first_horizontal := first_pass["horizontal_material"] as ShaderMaterial
	var first_parameters := first_horizontal.get_shader_parameter(
		"effect_parameters"
	) as PackedVector4Array
	assert_eq(first_horizontal.get_shader_parameter("effect_count"), 1)
	assert_eq(first_parameters[0].x, 3.0)
	assert_eq(first_horizontal.get_shader_parameter("blur_radius"), 2)
	assert_eq(
		(first_pass["vertical_material"] as ShaderMaterial).get_shader_parameter(
			"blur_radius"
		),
		3,
	)
	var second_horizontal := second_pass["horizontal_material"] as ShaderMaterial
	var second_parameters := second_horizontal.get_shader_parameter(
		"effect_parameters"
	) as PackedVector4Array
	assert_eq(second_horizontal.get_shader_parameter("effect_count"), 1)
	assert_eq(second_parameters[0].x, 4.0)
	assert_eq(second_horizontal.get_shader_parameter("blur_radius"), 1)
	assert_eq(material.get_shader_parameter("effect_count"), 1)
	var suffix_parameters := material.get_shader_parameter(
		"effect_parameters"
	) as PackedVector4Array
	assert_eq(suffix_parameters[0].x, 2.0)


func test_transform_only_update_reuses_local_blur_pipeline() -> void:
	var redraw := [{"type": "blur", "radius": [2, 0]}]
	_emit_operations([_operation("show", "scaled_blur", {
		"asset": "stage:bg_cafe",
		"redraw": redraw,
	})])
	var layer := _presenter.get_layer_node("scaled_blur")
	var composite := layer.get_node("Composite") as CanvasGroup
	var record: Dictionary = _presenter._layers["scaled_blur"]
	var material := record["redraw_material"] as ShaderMaterial
	var pipeline_root := record["redraw_pipeline_root"] as SubViewport
	var pipeline_output := record["redraw_pipeline_output"] as Sprite2D
	var render_bounds := record["redraw_render_bounds"] as Rect2
	var passes := record["redraw_pipeline_passes"] as Array
	var horizontal_material := (
		(passes[0] as Dictionary)["horizontal_material"] as ShaderMaterial
	)
	var vertical_material := (
		(passes[0] as Dictionary)["vertical_material"] as ShaderMaterial
	)
	assert_almost_eq(composite.fit_margin, 1.0, 0.001)

	_emit_operations([_operation("update", "scaled_blur", {
		"scale": [3.0, 3.0],
	})])
	assert_same(record["redraw_material"], material)
	assert_same(record["redraw_pipeline_root"], pipeline_root)
	assert_same(record["redraw_pipeline_output"], pipeline_output)
	assert_eq(record["redraw_render_bounds"], render_bounds)
	var updated_passes := record["redraw_pipeline_passes"] as Array
	assert_same(
		(updated_passes[0] as Dictionary)["horizontal_material"],
		horizontal_material,
	)
	assert_same(
		(updated_passes[0] as Dictionary)["vertical_material"],
		vertical_material,
	)
	assert_almost_eq(composite.fit_margin, 1.0, 0.001)


func test_viewport_resize_finishes_stale_tweens_and_reprojects_fit_and_clip() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(200, 100)
	add_child_autoqfree(viewport)
	var presenter := StagePresenter.new()
	viewport.add_child(presenter)
	await get_tree().process_frame

	presenter._apply_operations([_operation("show", "resized", {
		"asset": "res://tests/fixtures/stage/redraw_source.png",
		"fit": "stretch",
		"redraw": [{
			"type": "clip",
			"asset": "res://tests/fixtures/stage/redraw_mask.png",
			"offset": [0.0, 0.0],
			"fit": "stretch",
		}],
	})], true)
	var initial_record: Dictionary = presenter._layers["resized"]
	var initial_material := initial_record["redraw_material"] as ShaderMaterial
	var initial_mask := initial_record["redraw_mask_texture"] as Texture2D
	presenter._apply_operations([_operation("update", "resized", {
		"opacity": 0.5,
	}, "fade", 10.0)], false)
	assert_true(presenter._layer_tweens.has("resized"))

	var completions: Array = []
	presenter.layer_transition_finished.connect(
		func(layer_id: String) -> void: completions.append(layer_id)
	)
	viewport.size = Vector2i(100, 50)
	presenter._on_viewport_size_changed()

	var layer := presenter.get_layer_node("resized")
	var asset := _sprite(layer, "asset")
	var record: Dictionary = presenter._layers["resized"]
	var material := record["redraw_material"] as ShaderMaterial
	assert_false(presenter._layer_tweens.has("resized"))
	assert_eq(completions, ["resized"])
	assert_same(material, initial_material)
	assert_same(record["redraw_mask_texture"], initial_mask)
	assert_eq(asset.position, Vector2(50.0, 25.0))
	assert_eq(asset.scale, Vector2(6.25, 6.25))
	assert_eq(
		material.get_shader_parameter("clip_rect"),
		Vector4(0.0, 0.0, 100.0, 50.0),
	)
	assert_almost_eq(
		(layer.get_node("Composite") as CanvasGroup).self_modulate.a,
		0.5,
		0.001,
	)

	# Pending removes have no canonical target to re-layout and must complete.
	presenter._apply_operations([_operation("show", "removed", {
		"asset": "res://tests/fixtures/stage/redraw_source.png",
	})], true)
	presenter._apply_operations([
		_operation("remove", "removed", {}, "fade", 10.0),
	], false)
	assert_true(presenter._layer_tweens.has("removed"))
	presenter._on_viewport_size_changed()
	assert_null(presenter.get_layer_node("removed"))
	assert_false(presenter._layer_tweens.has("removed"))


func test_changing_and_clearing_clip_releases_the_old_record_reference() -> void:
	var first_path := "res://tests/fixtures/stage/redraw_mask.png"
	var second_path := "res://tests/fixtures/stage/redraw_source.png"
	_emit_operations([_operation("show", "masked", {
		"asset": "stage:bg_cafe",
		"redraw": [{
			"type": "clip",
			"asset": first_path,
			"offset": [0.0, 0.0],
			"fit": "native",
		}],
	})])
	var record: Dictionary = _presenter._layers["masked"]
	var material := record["redraw_material"] as ShaderMaterial
	var first_texture := record["redraw_mask_texture"] as Texture2D
	assert_not_null(first_texture)

	_emit_operations([_operation("update", "masked", {"redraw": [{
		"type": "clip",
		"asset": second_path,
		"offset": [0.0, 0.0],
		"fit": "native",
	}]})])
	record = _presenter._layers["masked"]
	assert_eq(record["redraw_mask_asset"], second_path)
	assert_not_same(record["redraw_mask_texture"], first_texture)
	assert_same(record["redraw_material"], material)

	_emit_operations([_operation("update", "masked", {"redraw": []})])
	record = _presenter._layers["masked"]
	assert_eq(record["redraw_mask_asset"], "")
	assert_null(record["redraw_mask_texture"])
	assert_same(record["redraw_material"], material)
	assert_null((_presenter.get_layer_node("masked").get_node(
		"Composite"
	) as CanvasGroup).material)


func test_missing_clip_texture_configures_a_fail_closed_pass() -> void:
	var missing_path := "res://tests/fixtures/stage/does_not_exist.png"
	_emit_operations([_operation("show", "missing_mask", {
		"asset": "stage:bg_cafe",
		"redraw": [{
			"type": "clip",
			"asset": missing_path,
			"offset": [0.0, 0.0],
			"fit": "native",
		}],
	})])
	assert_push_warning(
		"StagePresenter: redraw texture not found: %s" % missing_path
	)
	var record: Dictionary = _presenter._layers["missing_mask"]
	var material := record["redraw_material"] as ShaderMaterial
	assert_false(bool(material.get_shader_parameter("clip_available")))
	assert_null(material.get_shader_parameter("clip_texture"))


func test_hide_retains_layer_while_remove_and_clear_release_it() -> void:
	_emit_operations([
		_operation("show", "hero", {
			"asset": "res://tests/fixtures/stage/redraw_source.png",
			"redraw": [{"type": "blur", "radius": [1, 1]}],
		}),
		_operation("show", "event", {"asset": "stage:bg_outside"}),
	])
	var hero := _presenter.get_layer_node("hero")
	var hero_texture := _sprite(hero, "asset").texture
	var record: Dictionary = _presenter._layers["hero"]
	assert_not_null(record["redraw_pipeline_root"])

	_emit_operations([_operation("hide", "hero")])
	assert_same(_presenter.get_layer_node("hero"), hero)
	assert_same(_sprite(hero, "asset").texture, hero_texture)
	assert_false(hero.visible)
	assert_null(record["redraw_pipeline_root"], "hidden layers release derived targets")
	var hidden_redraw := [
		{"type": "grayscale", "amount": 0.5},
		{"type": "blur", "radius": [2, 1]},
	]
	_emit_operations([_operation("update", "hero", {"redraw": hidden_redraw})])
	assert_null(
		record["redraw_pipeline_root"],
		"a hidden-to-hidden update must not allocate derived targets",
	)
	assert_eq(record["redraw"], hidden_redraw)

	_emit_operations([_operation("show", "hero")])
	assert_same(_presenter.get_layer_node("hero"), hero)
	assert_same(_sprite(hero, "asset").texture, hero_texture)
	assert_not_null(record["redraw_pipeline_root"])
	assert_eq((record["redraw_pipeline_passes"] as Array).size(), 1)
	_emit_operations([_operation("hide", "hero", {}, "fade", 1.0)], false)
	assert_not_null(record["redraw_pipeline_root"], "animated hide renders until completion")
	var hide_tween: Tween = _presenter._layer_tweens["hero"]
	hide_tween.custom_step(2.0)
	assert_false(hero.visible)
	assert_null(record["redraw_pipeline_root"])
	assert_same(_sprite(hero, "asset").texture, hero_texture)

	_emit_operations([_operation("remove", "hero")])
	assert_null(_presenter.get_layer_node("hero"))
	_emit_operations([_operation("clear")])
	assert_null(_presenter.get_layer_node("event"))


func test_arbitrary_named_character_layers_have_no_slot_limit() -> void:
	var operations: Array = []
	for index in range(6):
		operations.append(_operation(
			"show",
			"actor_%d" % index,
			{"kind": "character", "asset": "stage:bg_cafe"},
		))
	_emit_operations(operations)
	assert_eq(_presenter.get_layer_ids().size(), 6)
	assert_false(_game_scene.has_node("CharacterLayer"))
	for index in range(6):
		var layer := _presenter.get_layer_node("actor_%d" % index)
		assert_not_null(layer)
		assert_same(layer.get_parent(), _game_scene.get_node("StageLayer/ShakeRoot"))


func test_complete_snapshot_projection_removes_stale_layers_synchronously() -> void:
	_emit_operations([
		_operation("show", "stale", {"asset": "stage:bg_outside"}),
		_operation("show", "keep", {"asset": "stage:bg_cafe"}),
	])
	var kept_before := _presenter.get_layer_node("keep")
	var kept_texture_before := _sprite(kept_before, "asset").texture
	SignalBus.stage_state_apply_requested.emit({
		"keep": StageLayerState.normalize_full({
			"asset": "stage:bg_cafe",
			"position": [10.0, 20.0],
		}),
	})

	assert_null(_presenter.get_layer_node("stale"))
	var kept := _presenter.get_layer_node("keep")
	assert_not_null(kept)
	assert_same(kept, kept_before, "exact projection should reuse a matching layer")
	assert_same(_sprite(kept, "asset").texture, kept_texture_before)
	assert_eq(kept.position, Vector2(10.0, 20.0))
	assert_true(_sprite(kept, "asset").texture.resource_path.ends_with("bg_cafe.png"))


func test_force_cut_reduces_batch_before_loading_intermediate_assets() -> void:
	_emit_operations([
		_operation("show", "hero", {"face": "stage:missing_1"}),
		_operation("update", "hero", {"face": "stage:missing_2"}),
		_operation("update", "hero", {"face": "stage:bg_cafe"}),
	], true)
	var layer := _presenter.get_layer_node("hero")
	assert_not_null(layer)
	assert_true(_sprite(layer, "face").texture.resource_path.ends_with("bg_cafe.png"))


func test_non_cut_batch_defers_completion_callbacks_until_atomic_commit() -> void:
	var callback_events: Array = []
	var callback := func(layer_id: String):
		callback_events.append(layer_id)
		if layer_id == "a":
			_emit_operations([_operation("clear")], true)
	_presenter.layer_transition_finished.connect(callback)

	_emit_operations([
		_operation("show", "a", {"asset": "stage:bg_cafe"}),
		_operation("show", "b", {"asset": "stage:bg_outside"}),
	], false)

	assert_true(callback_events.has("a"))
	assert_null(_presenter.get_layer_node("a"))
	assert_null(_presenter.get_layer_node("b"))
	assert_true(StellaRuntime.presentation_state.stage_layers.is_empty())


func test_custom_scene_without_shake_root_falls_back_to_presenter() -> void:
	var presenter := StagePresenter.new()
	add_child_autoqfree(presenter)
	await get_tree().process_frame
	presenter._on_stage_operations_requested([
		_operation("show", "custom", {"asset": "stage:bg_cafe"}),
	], true)
	assert_same(presenter.get_layer_node("custom").get_parent(), presenter)


func test_animated_update_of_hidden_layer_stays_synchronously_hidden() -> void:
	_emit_operations([_operation("show", "hidden", {"face": "stage:bg_cafe"})])
	_emit_operations([_operation("hide", "hidden")])
	var layer := _presenter.get_layer_node("hidden")
	_emit_operations([_operation("update", "hidden", {
		"face": "stage:bg_hallway",
		"position": [200.0, 300.0],
		"opacity": 0.4,
	}, "fade", 1.0)], false)
	assert_false(layer.visible, "a hidden-to-hidden update must never flash")
	assert_false(_presenter._layer_tweens.has("hidden"))
	assert_eq(layer.position, Vector2(200.0, 300.0))
	assert_true(_sprite(layer, "face").texture.resource_path.ends_with("bg_hallway.png"))


func test_cut_show_cancels_stale_fade_hide() -> void:
	_emit_operations([_operation("show", "hero", {"asset": "stage:bg_cafe"})])
	var layer := _presenter.get_layer_node("hero")
	_emit_operations([_operation("hide", "hero", {}, "fade", 0.08)], false)
	_emit_operations([_operation("show", "hero")], true)
	await get_tree().create_timer(0.12).timeout
	assert_same(_presenter.get_layer_node("hero"), layer)
	assert_true(layer.visible)
	assert_almost_eq((layer.get_node("Composite") as CanvasGroup).self_modulate.a, 1.0, 0.001)


func test_fade_crossfades_textures_and_hides_by_opacity() -> void:
	_emit_operations([_operation("show", "hero", {"asset": "stage:bg_cafe"})])
	var layer := _presenter.get_layer_node("hero")
	var composite := layer.get_node("Composite") as CanvasGroup
	var asset_sprite := _sprite(layer, "asset")
	_emit_operations([_operation("update", "hero", {
		"asset": "stage:bg_hallway",
	}, "fade", 0.08)], false)
	var source := layer.find_child("Source", true, false)
	assert_eq(source.get_child_count(), 4, "outgoing texture remains for crossfade")
	assert_almost_eq(asset_sprite.modulate.a, 0.0, 0.001)
	var tween: Tween = _presenter._layer_tweens["hero"]
	tween.custom_step(1.0)
	assert_false(_presenter._layer_transition_tokens.has("hero"))
	assert_eq(source.get_child_count(), 3)
	assert_almost_eq(asset_sprite.modulate.a, 1.0, 0.001)
	assert_true(asset_sprite.texture.resource_path.ends_with("bg_hallway.png"))


func test_blurred_crossfade_shrinks_render_target_and_stops_continuous_updates() -> void:
	var redraw := [{"type": "blur", "radius": [1, 1]}]
	_emit_operations([_operation("show", "hero", {
		"asset": "res://tests/fixtures/stage/redraw_source.png",
		"redraw": redraw,
	})])
	var record: Dictionary = _presenter._layers["hero"]
	var source := record["source"] as Node2D
	var pipeline_root := record["redraw_pipeline_root"] as SubViewport
	var initial_bounds := record["redraw_render_bounds"] as Rect2

	_emit_operations([_operation("update", "hero", {
		"asset": "res://tests/fixtures/stage/redraw_mask.png",
	}, "fade", 0.08)], false)
	var transition_bounds := record["redraw_render_bounds"] as Rect2
	assert_same(record["redraw_pipeline_root"], pipeline_root)
	assert_true(transition_bounds.size.x >= initial_bounds.size.x)
	assert_eq(pipeline_root.render_target_update_mode, SubViewport.UPDATE_ALWAYS)
	assert_eq(source.get_child_count(), 4, "crossfade source includes one outgoing sprite")

	var tween: Tween = _presenter._layer_tweens["hero"]
	tween.custom_step(1.0)
	var final_bounds := record["redraw_render_bounds"] as Rect2
	assert_true(final_bounds.size.x < transition_bounds.size.x)
	assert_eq(source.get_child_count(), 3)
	assert_true(_sprite(_presenter.get_layer_node("hero"), "asset") \
		.texture.resource_path.ends_with("redraw_mask.png"))
	assert_eq(
		(record["redraw_pipeline_root"] as SubViewport).render_target_update_mode,
		SubViewport.UPDATE_ONCE,
	)


func test_oversized_blur_target_fails_closed_and_valid_update_recovers() -> void:
	var fixture := "res://tests/fixtures/stage/redraw_source.png"
	_presenter._on_stage_operations_requested([_operation("show", "hero", {
		"asset": fixture,
		"body": fixture,
		"body_offset": [9000.0, 0.0],
		"redraw": [{"type": "blur", "radius": [1, 1]}],
	})], true)
	assert_push_error("redraw target")
	var layer := _presenter.get_layer_node("hero")
	var composite := layer.get_node("Composite") as CanvasGroup
	var record: Dictionary = _presenter._layers["hero"]
	assert_false(composite.visible)
	assert_null(record["redraw_pipeline_root"])

	_presenter._on_stage_operations_requested([_operation("update", "hero", {
		"body_offset": [4.0, 0.0],
	})], true)
	assert_true(composite.visible)
	assert_not_null(record["redraw_pipeline_root"])
	assert_true((record["redraw_render_bounds"] as Rect2).size.x < 100.0)


func test_blurred_transform_tween_does_not_continuously_redraw_static_source() -> void:
	_emit_operations([_operation("show", "hero", {
		"asset": "res://tests/fixtures/stage/redraw_source.png",
		"redraw": [{"type": "blur", "radius": [2, 2]}],
	})])
	var record: Dictionary = _presenter._layers["hero"]
	_emit_operations([_operation("update", "hero", {
		"position": [400.0, 240.0],
		"rotation": 25.0,
	}, "move", 1.0)], false)
	assert_true(_presenter._layer_tweens.has("hero"))
	assert_eq(
		(record["redraw_pipeline_root"] as SubViewport).render_target_update_mode,
		SubViewport.UPDATE_ONCE,
	)
	_emit_operations([_operation("hide", "hero", {}, "fade", 1.0)], false)
	assert_true(_presenter._layer_tweens.has("hero"))
	assert_eq(
		(record["redraw_pipeline_root"] as SubViewport).render_target_update_mode,
		SubViewport.UPDATE_ONCE,
	)


func test_force_cut_batch_projects_only_the_final_state_once() -> void:
	var operations: Array = [_operation("show", "atomic", {"face": "stage:bg_cafe"})]
	for index in range(100):
		operations.append(_operation("update", "atomic", {
			"face": "stage:not_loaded_%03d" % index,
		}))
	operations.append(_operation("update", "atomic", {"face": "stage:bg_outside"}))
	var completions: Array = []
	_presenter.layer_transition_finished.connect(func(layer_id: String): completions.append(layer_id))
	_emit_operations(operations, true)
	assert_eq(completions, ["atomic"])
	assert_true(_sprite(_presenter.get_layer_node("atomic"), "face") \
		.texture.resource_path.ends_with("bg_outside.png"))


func test_force_cut_on_one_layer_does_not_cancel_another_layer_tween() -> void:
	_emit_operations([
		_operation("show", "moving", {"asset": "stage:bg_cafe"}),
		_operation("show", "patched", {"asset": "stage:bg_hallway"}),
	])
	var moving := _presenter.get_layer_node("moving")
	_emit_operations([_operation("update", "moving", {
		"position": [600.0, 100.0],
	}, "move", 0.08)], false)
	var active_tween: Tween = _presenter._layer_tweens["moving"]
	_emit_operations([_operation("update", "patched", {"opacity": 0.5})], true)
	assert_same(_presenter._layer_tweens["moving"], active_tween)
	assert_ne(moving.position, Vector2(600.0, 100.0))
	active_tween.custom_step(1.0)
	assert_eq(moving.position, Vector2(600.0, 100.0))


func test_finish_request_only_snaps_the_requested_layer_transition() -> void:
	_emit_operations([
		_operation("show", "hero", {"asset": "stage:bg_cafe"}),
		_operation("show", "rain", {"asset": "stage:bg_hallway"}),
	])
	_emit_operations([
		_operation("update", "hero", {"position": [500.0, 100.0]}, "move", 1.0),
		_operation("update", "rain", {"position": [900.0, 200.0]}, "move", 1.0),
	], false)
	var rain_tween: Tween = _presenter._layer_tweens["rain"]
	var hero_transition := _latest_transition("hero")
	assert_eq(
		int(hero_transition.get("presenter_instance_id", -1)),
		_presenter.get_instance_id(),
	)

	var foreign_transition := hero_transition.duplicate(true)
	foreign_transition["presenter_instance_id"] = 0
	SignalBus.stage_transitions_finish_requested.emit([foreign_transition])
	assert_true(_presenter._layer_tweens.has("hero"))
	SignalBus.stage_transitions_finish_requested.emit([hero_transition])

	assert_false(_presenter._layer_tweens.has("hero"))
	assert_eq(_presenter.get_layer_node("hero").position, Vector2(500.0, 100.0))
	assert_same(_presenter._layer_tweens["rain"], rain_tween)
	assert_ne(_presenter.get_layer_node("rain").position, Vector2(900.0, 200.0))
	rain_tween.custom_step(1.0)
	assert_eq(_presenter.get_layer_node("rain").position, Vector2(900.0, 200.0))


func test_stale_finish_record_does_not_cancel_newer_transition_on_same_id() -> void:
	_emit_operations([_operation("show", "hero", {"asset": "stage:bg_cafe"})])
	_emit_operations([_operation("update", "hero", {
		"position": [400.0, 100.0],
	}, "move", 1.0)], false)
	var old_transition := _latest_transition("hero")

	_emit_operations([_operation("update", "hero", {
		"position": [800.0, 200.0],
	}, "move", 1.0)], false)
	var new_transition := _latest_transition("hero")
	var new_tween: Tween = _presenter._layer_tweens["hero"]
	assert_ne(int(old_transition.get("token", -1)), int(new_transition.get("token", -1)))

	SignalBus.stage_transitions_finish_requested.emit([old_transition])
	assert_same(_presenter._layer_tweens["hero"], new_tween)
	assert_ne(_presenter.get_layer_node("hero").position, Vector2(800.0, 200.0))

	SignalBus.stage_transitions_finish_requested.emit([new_transition])
	assert_false(_presenter._layer_tweens.has("hero"))
	assert_eq(_presenter.get_layer_node("hero").position, Vector2(800.0, 200.0))


func test_animated_clear_acknowledges_pending_remove_and_live_layers() -> void:
	_emit_operations([
		_operation("show", "ghost", {"asset": "stage:bg_cafe"}),
		_operation("show", "rain", {"asset": "stage:bg_hallway"}),
	])
	_emit_operations([_operation("remove", "ghost", {}, "fade", 1.0)], false)
	var pending_remove_transition := _latest_transition("ghost")
	var started_before_clear := _started_transitions.size()

	_emit_operations([_operation("clear", "", {}, "fade", 1.0)], false)
	var clear_transitions: Array = _started_transitions.slice(started_before_clear)
	var clear_ids: Array = clear_transitions.map(
		func(transition: Dictionary) -> String:
			return String(transition.get("layer_id", ""))
	)
	assert_has(clear_ids, "ghost")
	assert_has(clear_ids, "rain")
	assert_ne(
		int(pending_remove_transition.get("token", -1)),
		int(_latest_transition("ghost").get("token", -1)),
	)

	SignalBus.stage_transitions_finish_requested.emit([pending_remove_transition])
	assert_true(_presenter._layer_tweens.has("ghost"))
	SignalBus.stage_transitions_finish_requested.emit(clear_transitions)
	assert_null(_presenter.get_layer_node("ghost"))
	assert_null(_presenter.get_layer_node("rain"))


func test_force_cut_clear_releases_a_pending_fade_remove() -> void:
	_emit_operations([_operation("show", "ghost", {"asset": "stage:bg_cafe"})])
	_emit_operations([_operation("remove", "ghost", {}, "fade", 1.0)], false)
	assert_not_null(_presenter.get_layer_node("ghost"))
	assert_true(_presenter.get_layer_state("ghost").is_empty())
	_emit_operations([_operation("clear")], true)
	assert_null(_presenter.get_layer_node("ghost"))


func test_unknown_update_and_hide_do_not_interrupt_pending_remove() -> void:
	_emit_operations([_operation("show", "ghost", {"asset": "stage:bg_cafe"})])
	_emit_operations([_operation("remove", "ghost", {}, "fade", 10.0)], false)
	var ghost := _presenter.get_layer_node("ghost")
	var fade_tween: Tween = _presenter._layer_tweens["ghost"]
	var transition := _latest_transition("ghost")
	var started_count := _started_transitions.size()

	for force_cut in [false, true]:
		_emit_operations([
			_operation("update", "ghost", {"position": [700.0, 300.0]}),
			_operation("hide", "ghost"),
			_operation("remove", "ghost"),
		], force_cut)
		assert_same(_presenter.get_layer_node("ghost"), ghost)
		assert_same(_presenter._layer_tweens["ghost"], fade_tween)
		assert_eq(_started_transitions.size(), started_count)

	SignalBus.stage_transitions_finish_requested.emit([transition])
	assert_null(_presenter.get_layer_node("ghost"))


func test_clear_and_show_order_is_preserved_in_force_cut_batches() -> void:
	_emit_operations([_operation("show", "hero", {"position": [10.0, 20.0]})])
	_emit_operations([
		_operation("clear"),
		_operation("show", "hero", {"position": [700.0, 300.0]}),
	], true)
	assert_eq(_presenter.get_layer_node("hero").position, Vector2(700.0, 300.0))

	_emit_operations([
		_operation("show", "event", {"position": [100.0, 200.0]}),
		_operation("clear"),
	], true)
	assert_true(_presenter.get_layer_ids().is_empty())
	assert_null(_presenter.get_layer_node("hero"))
	assert_null(_presenter.get_layer_node("event"))


func test_abort_snaps_in_flight_transition_to_canonical_target() -> void:
	_emit_operations([_operation("show", "hero", {"asset": "stage:bg_cafe"})])
	_emit_operations([_operation("update", "hero", {
		"position": [900.0, 300.0],
		"rotation": 24.0,
		"opacity": 0.6,
		"depth_origin": -8000.25,
	}, "move", 1.0)], false)
	SignalBus.engine_abort_requested.emit()
	var layer := _presenter.get_layer_node("hero")
	assert_eq(layer.position, Vector2(900.0, 300.0))
	assert_almost_eq(layer.rotation_degrees, 24.0, 0.001)
	assert_almost_eq((layer.get_node("Composite") as CanvasGroup).self_modulate.a, 0.6, 0.001)
	assert_almost_eq(
		float(_presenter._layers["hero"]["depth_sort_key"]), -8000.25, 0.001)


func test_stage_restore_replaces_the_complete_named_layer_set() -> void:
	_emit_operations([_operation("show", "old", {"asset": "stage:bg_cafe"})])
	SignalBus.stage_state_apply_requested.emit({
		"restored": {"asset": "stage:bg_hallway"},
	})
	assert_null(_presenter.get_layer_node("old"))
	assert_not_null(_presenter.get_layer_node("restored"))


func test_full_visual_reset_removes_named_layers_and_pending_tweens() -> void:
	_emit_operations([_operation("show", "event", {"asset": "stage:bg_cafe"})])
	_emit_operations([_operation("remove", "event", {}, "fade", 1.0)], false)
	SignalBus.reset_stage_visuals()
	assert_null(_presenter.get_layer_node("event"))
	assert_true(_presenter._states.is_empty())
	assert_true(_presenter._layers.is_empty())
	assert_true(_presenter._layer_tweens.is_empty())
	assert_true(_presenter._layer_transition_tokens.is_empty())


func test_non_cut_operation_canonicalizes_whitespace_in_layer_id() -> void:
	_emit_operations([_operation("show", "  spaced  ", {
		"asset": "stage:bg_cafe",
	}, "fade", 0.1)], false)
	assert_not_null(_presenter.get_layer_node("spaced"))
	assert_null(_presenter.get_layer_node("  spaced  "))


func test_reentrant_stage_requests_keep_state_and_visual_order_identical() -> void:
	var state_callback := Callable(
		StellaRuntime.presentation_state, "_on_stage_operations"
	)
	var presenter_callback := Callable(_presenter, "_on_stage_operations_requested")
	SignalBus.stage_operations_requested.disconnect(state_callback)
	SignalBus.stage_operations_requested.disconnect(presenter_callback)
	SignalBus.stage_operations_requested.connect(state_callback)
	var requested_nested := [false]
	var early_callback := func(operations: Array, _force_cut: bool) -> void:
		if requested_nested[0] or operations.is_empty():
			return
		requested_nested[0] = true
		SignalBus.emit_stage_operations([
			_operation("update", "hero", {"opacity": 0.25}),
		], true)
	SignalBus.stage_operations_requested.connect(early_callback)
	SignalBus.stage_operations_requested.connect(presenter_callback)

	SignalBus.emit_stage_operations([
		_operation("show", "hero", {"asset": "stage:bg_cafe"}),
	], true)

	SignalBus.stage_operations_requested.disconnect(early_callback)
	assert_true(requested_nested[0])
	assert_almost_eq(
		StellaRuntime.presentation_state.stage_layers["hero"]["opacity"],
		0.25,
		0.001,
	)
	var composite := _presenter.get_layer_node("hero").get_node("Composite") as CanvasGroup
	assert_almost_eq(composite.self_modulate.a, 0.25, 0.001)


func test_invalid_clear_keeps_canonical_and_visible_state_identical() -> void:
	_emit_operations([
		_operation("show", "hero", {"asset": "stage:bg_cafe"}),
	], true)
	var expected := StellaRuntime.presentation_state.stage_layers.duplicate(true)
	SignalBus.emit_stage_operations([{
		"action": "clear",
		"id": "",
		"properties": {"asset": "stage:unused"},
		"transition_params": {},
		"transition": "cut",
		"duration": 0.0,
	}], true)
	assert_eq(StellaRuntime.presentation_state.stage_layers, expected)
	assert_not_null(_presenter.get_layer_node("hero"))


func test_visual_reset_between_stage_consumers_invalidates_current_batch() -> void:
	var state_callback := Callable(
		StellaRuntime.presentation_state, "_on_stage_operations"
	)
	var presenter_callback := Callable(_presenter, "_on_stage_operations_requested")
	SignalBus.stage_operations_requested.disconnect(state_callback)
	SignalBus.stage_operations_requested.disconnect(presenter_callback)
	SignalBus.stage_operations_requested.connect(state_callback)
	var reset_once := [false]
	var reset_callback = func(_operations: Array, _force_cut: bool):
		if reset_once[0]:
			return
		reset_once[0] = true
		SignalBus.reset_stage_visuals()
		StellaRuntime.presentation_state.clear()
	SignalBus.stage_operations_requested.connect(reset_callback)
	SignalBus.stage_operations_requested.connect(presenter_callback)

	SignalBus.emit_stage_operations([
		_operation("show", "stale", {"asset": "stage:bg_cafe"}),
	], true)

	SignalBus.stage_operations_requested.disconnect(reset_callback)
	assert_true(reset_once[0])
	assert_true(StellaRuntime.presentation_state.stage_layers.is_empty())
	assert_null(_presenter.get_layer_node("stale"))


func test_unknown_transition_is_rejected_without_state_or_visual_mutation() -> void:
	_emit_operations([_operation("show", "unknown", {
		"position": [123.0, 456.0],
	}, "not-a-transition", 1.0)], false)
	assert_false(StellaRuntime.presentation_state.stage_layers.has("unknown"))
	assert_null(_presenter.get_layer_node("unknown"))
	assert_false(_presenter._layer_tweens.has("unknown"))


func test_missing_texture_clears_channel_consistently_across_restore() -> void:
	var state := PresentationState.new()
	state.connect_signals()
	_emit_operations([_operation("show", "missing", {"asset": "stage:bg_cafe"})])
	_emit_operations([_operation("update", "missing", {"asset": "stage:does_not_exist"})])
	assert_null(_sprite(_presenter.get_layer_node("missing"), "asset").texture)
	var snapshot = JSON.parse_string(JSON.stringify(state.capture_snapshot()))
	SignalBus.reset_stage_visuals()
	state.restore_snapshot(snapshot)
	state.apply_to_presenters()
	assert_null(_sprite(_presenter.get_layer_node("missing"), "asset").texture)
	state.disconnect_signals()


func test_presentation_state_json_roundtrip_rebuilds_complete_stage() -> void:
	var state := PresentationState.new()
	state.connect_signals()
	_emit_operations([
		_operation("show", "base", {
			"asset": "stage:bg_school_gate", "fit": "cover", "z_index": -2,
		}),
		_operation("show", "roundtrip", {
			"body": "stage:bg_cafe", "face": "stage:bg_hallway",
			"position": [321.0, 432.0], "origin": [12.0, 34.0],
			"scale": [0.75, 0.8], "zoom": [1.2, 1.1],
			"depth_scale": 0.9, "rotation": 17.0, "opacity": 0.65,
			"z_index": 8, "depth_origin": -8000.25,
		}),
		_operation("hide", "roundtrip"),
	])
	var snapshot = JSON.parse_string(JSON.stringify(state.capture_snapshot()))
	_emit_operations([_operation("clear")])
	state.restore_snapshot(snapshot)
	state.apply_to_presenters()
	var hero := _presenter.get_layer_node("roundtrip")
	assert_not_null(_presenter.get_layer_node("base"))
	assert_not_null(hero)
	assert_false(hero.visible)
	assert_eq(hero.position, Vector2(321.0, 432.0))
	assert_eq((hero.get_node("Composite") as CanvasGroup).position, Vector2(-12.0, -34.0))
	assert_almost_eq(hero.scale.x, 0.81, 0.001)
	assert_almost_eq(hero.scale.y, 0.792, 0.001)
	assert_almost_eq(
		float(_presenter._layers["roundtrip"]["depth_sort_key"]),
		-7992.25,
		0.001,
	)
	assert_true(_sprite(hero, "body").texture.resource_path.ends_with("bg_cafe.png"))
	assert_true(_sprite(hero, "face").texture.resource_path.ends_with("bg_hallway.png"))
	state.disconnect_signals()


func test_blur_workload_limits_distinguish_static_and_continuous_updates() -> void:
	var radius_32: Array = (
		_presenter._split_redraw([
			{"type": "blur", "radius": [32, 32]},
		])["blur_passes"] as Array
	)
	var static_error: String = _presenter._redraw_pipeline_allocation_error(
		Rect2(Vector2.ZERO, Vector2(2048.0, 1024.0)),
		radius_32,
		false,
	)
	assert_string_contains(static_error, "static limit")

	var radius_16: Array = (
		_presenter._split_redraw([
			{"type": "blur", "radius": [16, 16]},
		])["blur_passes"] as Array
	)
	var continuous_bounds := Rect2(Vector2.ZERO, Vector2(1024.0, 1024.0))
	assert_eq(
		_presenter._redraw_pipeline_allocation_error(
			continuous_bounds,
			radius_16,
			false,
		),
		"",
		"the same projection remains valid as a one-shot update",
	)
	var continuous_error: String = _presenter._redraw_pipeline_allocation_error(
		continuous_bounds,
		radius_16,
		true,
	)
	assert_string_contains(continuous_error, "continuous limit")


func test_blur_pipeline_inherits_source_and_output_texture_filtering() -> void:
	_emit_operations([_operation("show", "filtered", {
		"asset": "res://tests/fixtures/stage/redraw_source.png",
		"redraw": [{"type": "blur", "radius": [1, 1]}],
	})])
	var record: Dictionary = _presenter._layers["filtered"]
	var first_pass := (record["redraw_pipeline_passes"] as Array)[0] as Dictionary
	var source_viewport := first_pass["input_viewport"] as SubViewport
	var output := record["redraw_pipeline_output"] as Sprite2D
	assert_eq(
		source_viewport.canvas_item_default_texture_filter,
		_presenter.get_viewport().canvas_item_default_texture_filter,
		"authored source scaling must inherit the scene texture filter",
	)
	assert_ne(
		output.texture_filter,
		CanvasItem.TEXTURE_FILTER_NEAREST,
		"the final stage transform must not force nearest-neighbor sampling",
	)


func test_dynamic_texture_resize_rebuilds_bounds_and_hide_releases_targets() -> void:
	_emit_operations([_operation("show", "dynamic", {
		"asset": "res://tests/fixtures/stage/redraw_source.png",
		"redraw": [{"type": "blur", "radius": [1, 1]}],
	})])
	var layer := _presenter.get_layer_node("dynamic")
	var record: Dictionary = _presenter._layers["dynamic"]
	var state: Dictionary = _presenter._states["dynamic"]
	var asset_sprite := _sprite(layer, "asset")
	var dynamic_viewport := SubViewport.new()
	dynamic_viewport.size = Vector2i(8, 8)
	dynamic_viewport.transparent_bg = true
	dynamic_viewport.disable_3d = true
	dynamic_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child_autoqfree(dynamic_viewport)
	var dynamic_texture := dynamic_viewport.get_texture()
	asset_sprite.texture = dynamic_texture
	_presenter._apply_redraw(record, state, true)
	var initial_pipeline := record["redraw_pipeline_root"] as SubViewport
	var initial_bounds := record["redraw_render_bounds"] as Rect2
	assert_eq(initial_pipeline.render_target_update_mode, SubViewport.UPDATE_ALWAYS)

	dynamic_viewport.size = Vector2i(24, 8)
	_presenter._process(0.0)
	var resized_pipeline := record["redraw_pipeline_root"] as SubViewport
	var resized_bounds := record["redraw_render_bounds"] as Rect2
	assert_gt(resized_bounds.size.x, initial_bounds.size.x)
	assert_ne(resized_pipeline, initial_pipeline)
	assert_same(asset_sprite.texture, dynamic_texture)
	assert_eq(resized_pipeline.render_target_update_mode, SubViewport.UPDATE_ALWAYS)

	_emit_operations([_operation("hide", "dynamic", {}, "fade", 1.0)], false)
	assert_true(_presenter._layer_tweens.has("dynamic"))
	assert_eq(
		(record["redraw_pipeline_root"] as SubViewport).render_target_update_mode,
		SubViewport.UPDATE_ALWAYS,
		"a dynamic source must keep updating while its hide tween remains visible",
	)
	var hide_tween: Tween = _presenter._layer_tweens["dynamic"]
	hide_tween.custom_step(2.0)
	assert_false(layer.visible)
	assert_null(record["redraw_pipeline_root"])
	assert_same(asset_sprite.texture, dynamic_texture)

	_emit_operations([_operation("show", "dynamic")])
	assert_true(layer.visible)
	assert_not_null(record["redraw_pipeline_root"])
	assert_same(asset_sprite.texture, dynamic_texture)


func test_dynamic_clip_resize_recomputes_native_clip_rect() -> void:
	var mask_path := "res://tests/fixtures/stage/redraw_mask.png"
	_emit_operations([_operation("show", "dynamic_mask", {
		"asset": "res://tests/fixtures/stage/redraw_source.png",
		"redraw": [
			{
				"type": "clip",
				"asset": mask_path,
				"offset": [2.0, 3.0],
				"fit": "native",
			},
			{"type": "blur", "radius": [1, 1]},
		],
	})])
	var record: Dictionary = _presenter._layers["dynamic_mask"]
	var state: Dictionary = _presenter._states["dynamic_mask"]
	var dynamic_viewport := SubViewport.new()
	dynamic_viewport.size = Vector2i(8, 6)
	dynamic_viewport.transparent_bg = true
	dynamic_viewport.disable_3d = true
	dynamic_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child_autoqfree(dynamic_viewport)
	var dynamic_mask := dynamic_viewport.get_texture()
	record["redraw_mask_texture"] = dynamic_mask
	_presenter._apply_redraw(record, state, true)
	var first_pass := (record["redraw_pipeline_passes"] as Array)[0] as Dictionary
	var material := first_pass["horizontal_material"] as ShaderMaterial
	var initial_rect := material.get_shader_parameter("clip_rect") as Vector4
	assert_eq(initial_rect, Vector4(2.0, 3.0, 8.0, 6.0))

	dynamic_viewport.size = Vector2i(20, 12)
	_presenter._process(0.0)
	var resized_rect := material.get_shader_parameter("clip_rect") as Vector4
	assert_eq(resized_rect, Vector4(2.0, 3.0, 20.0, 12.0))
	assert_same(record["redraw_mask_texture"], dynamic_mask)
	assert_eq(
		(record["redraw_pipeline_root"] as SubViewport).render_target_update_mode,
		SubViewport.UPDATE_ALWAYS,
	)
