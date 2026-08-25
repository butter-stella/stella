## Presenter-local bounded registry for named-stage transition providers.
##
## There is intentionally no global static registry: custom providers cannot
## leak between scenes/tests, and every participant proves its exact provider
## set during the typed preflight transaction.
class_name StageTransitionRegistry extends RefCounted

const MAX_PROVIDERS := 32

var _providers: Dictionary = {}


func _init() -> void:
	_register_builtin(RuleStageTransitionProvider.new())
	_register_builtin(MosaicStageTransitionProvider.new())


func register_provider(provider: StageTransitionProvider) -> bool:
	if provider == null or _providers.size() >= MAX_PROVIDERS:
		return false
	var kind := String(provider.get_transition_kind())
	var canonical := StageTransitionSpec.canonicalize(kind, {})
	if (
		not bool(canonical.get("valid", false))
		or String(canonical.get("kind", "")) != kind
		or StageTransitionSpec.is_builtin(kind)
		or _providers.has(kind)
	):
		return false
	_providers[kind] = provider
	return true


func unregister_provider(kind_value: StringName) -> bool:
	var kind := String(kind_value)
	if StageTransitionSpec.is_builtin(kind) or not _providers.has(kind):
		return false
	_providers.erase(kind)
	return true


func has_provider(kind_value: StringName) -> bool:
	var kind := String(kind_value)
	return kind in StageTransitionSpec.SIMPLE_KINDS or _providers.has(kind)


func provider_count() -> int:
	return _providers.size()


func owns_provider(kind_value: StringName, provider: StageTransitionProvider) -> bool:
	var kind := String(kind_value)
	return (
		provider != null
		and _providers.has(kind)
		and _providers[kind] == provider
	)


func validate_transition(
	kind_value: String,
	params: Dictionary,
	texture_resolver: Callable,
) -> Dictionary:
	var canonical := StageTransitionSpec.canonicalize(kind_value, params)
	if not bool(canonical.get("valid", false)):
		return canonical
	var kind := String(canonical["kind"])
	if kind in StageTransitionSpec.SIMPLE_KINDS:
		return {
			"valid": true,
			"plan": {"kind": kind, "params": {}},
			"provider": null,
		}
	if not _providers.has(kind):
		return {
			"valid": false,
			"error": "unknown registered Stage transition kind '%s'" % kind,
		}
	var provider: StageTransitionProvider = _providers[kind]
	var validated := provider.validate_transition(
		canonical["params"], texture_resolver)
	if not bool(validated.get("valid", false)):
		return validated
	return {
		"valid": true,
		"plan": (validated.get("plan", {}) as Dictionary).duplicate(true),
		"provider": provider,
	}


func _register_builtin(provider: StageTransitionProvider) -> void:
	if provider == null or _providers.size() >= MAX_PROVIDERS:
		return
	var kind := String(provider.get_transition_kind())
	if kind.is_empty() or _providers.has(kind):
		return
	_providers[kind] = provider
