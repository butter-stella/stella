## Built-in luminance rule-mask transition provider.
class_name RuleStageTransitionProvider extends StageTransitionProvider

const SHADER_PATH := (
	"res://addons/stella/presentation/stage/shaders/stage_transition_rule.gdshader"
)

var _shader: Shader


func _init() -> void:
	_shader = load(SHADER_PATH) as Shader


func get_transition_kind() -> StringName:
	return &"rule"


func validate_transition(
	params: Dictionary,
	texture_resolver: Callable,
) -> Dictionary:
	var canonical := StageTransitionSpec.canonicalize("rule", params)
	if not bool(canonical.get("valid", false)):
		return canonical
	if _shader == null:
		return {"valid": false, "error": "rule transition shader is unavailable"}
	if not texture_resolver.is_valid():
		return {"valid": false, "error": "Stage texture resolver is unavailable"}
	var canonical_params: Dictionary = canonical["params"]
	var mask_id := String(canonical_params["mask"])
	var mask: Texture2D = texture_resolver.call(mask_id) as Texture2D
	if mask == null:
		return {
			"valid": false,
			"error": "rule transition mask could not be resolved: %s" % mask_id,
		}
	var size := mask.get_size()
	if not size.is_finite() or size.x <= 0.0 or size.y <= 0.0:
		return {
			"valid": false,
			"error": "rule transition mask must have finite positive dimensions",
		}
	return {
		"valid": true,
		"plan": {
			"kind": "rule",
			"params": canonical_params.duplicate(true),
			"mask": mask,
		},
	}


func create_material(
	plan: Dictionary,
	source_texture: Texture2D,
	target_texture: Texture2D,
	_viewport_size: Vector2,
) -> ShaderMaterial:
	if _shader == null or source_texture == null or target_texture == null:
		return null
	var mask: Texture2D = plan.get("mask") as Texture2D
	var params: Dictionary = plan.get("params", {})
	if mask == null:
		return null
	var material := ShaderMaterial.new()
	material.shader = _shader
	material.set_shader_parameter("source_texture", source_texture)
	material.set_shader_parameter("target_texture", target_texture)
	material.set_shader_parameter("mask_texture", mask)
	material.set_shader_parameter("softness", float(params.get("softness", 0.0)))
	material.set_shader_parameter("invert_mask", bool(params.get("invert", false)))
	material.set_shader_parameter("progress", 0.0)
	return material
