## Built-in source-pixelate/target-depixelate mosaic transition provider.
class_name MosaicStageTransitionProvider extends StageTransitionProvider

const SHADER_PATH := (
	"res://addons/stella/presentation/stage/shaders/stage_transition_mosaic.gdshader"
)

var _shader: Shader


func _init() -> void:
	_shader = load(SHADER_PATH) as Shader


func get_transition_kind() -> StringName:
	return &"mosaic"


func validate_transition(
	params: Dictionary,
	_texture_resolver: Callable,
) -> Dictionary:
	var canonical := StageTransitionSpec.canonicalize("mosaic", params)
	if not bool(canonical.get("valid", false)):
		return canonical
	if _shader == null:
		return {"valid": false, "error": "mosaic transition shader is unavailable"}
	return {
		"valid": true,
		"plan": {
			"kind": "mosaic",
			"params": (canonical["params"] as Dictionary).duplicate(true),
		},
	}


func create_material(
	plan: Dictionary,
	source_texture: Texture2D,
	target_texture: Texture2D,
	viewport_size: Vector2,
) -> ShaderMaterial:
	if _shader == null or source_texture == null or target_texture == null:
		return null
	var params: Dictionary = plan.get("params", {})
	var material := ShaderMaterial.new()
	material.shader = _shader
	material.set_shader_parameter("source_texture", source_texture)
	material.set_shader_parameter("target_texture", target_texture)
	material.set_shader_parameter("viewport_size", viewport_size)
	material.set_shader_parameter("max_cell", float(params.get(
		"cell", StageTransitionSpec.DEFAULT_MOSAIC_CELL)))
	material.set_shader_parameter("progress", 0.0)
	return material
