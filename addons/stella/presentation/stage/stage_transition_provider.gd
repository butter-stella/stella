## Extensible renderer contract for projection-based named-stage transitions.
##
## Providers are presenter-local and never own scheduling. They synchronously
## validate immutable typed params/resources, then create one ShaderMaterial
## driven by StagePresenter's existing Tween/receipt generation.
class_name StageTransitionProvider extends RefCounted


func get_transition_kind() -> StringName:
	return &""


func validate_transition(
	_params: Dictionary,
	_texture_resolver: Callable,
) -> Dictionary:
	return {"valid": false, "error": "transition provider is not implemented"}


func create_material(
	_plan: Dictionary,
	_source_texture: Texture2D,
	_target_texture: Texture2D,
	_viewport_size: Vector2,
) -> ShaderMaterial:
	return null
