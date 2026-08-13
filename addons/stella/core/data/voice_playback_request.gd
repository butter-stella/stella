## Typed synchronous request from DialoguePresenter to AudioPresenter.
## AudioPresenter resolves it exactly once through SignalBus. The request has
## no mutable response fields; callers receive a separate VoicePlaybackResponse.
class_name VoicePlaybackRequest extends RefCounted

var _asset: String = ""
var _character: String = ""
var _owner_validator: Callable


func _init(
	p_asset: String = "",
	p_character: String = "",
	p_owner_validator: Callable = Callable(),
) -> void:
	_asset = p_asset
	_character = p_character
	_owner_validator = p_owner_validator


func get_asset() -> String:
	return _asset


func get_character() -> String:
	return _character


func has_owner_validator() -> bool:
	return _owner_validator.is_valid()


func is_current() -> bool:
	return not _owner_validator.is_valid() or bool(_owner_validator.call())
