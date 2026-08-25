## Typed synchronous request from DialoguePresenter to AudioPresenter.
## AudioPresenter resolves it exactly once through SignalBus. The request has
## no mutable response fields; callers receive a separate VoicePlaybackResponse.
class_name VoicePlaybackRequest extends RefCounted

var _asset: String = ""
var _character: String = ""
var _dsp_preset: String = ""
var _source: Dictionary = {}
var _owner_validator: Callable
var _has_owner_validator: bool = false


func _init(
	p_asset: String = "",
	p_character: String = "",
	p_owner_validator: Callable = Callable(),
	p_dsp_preset: String = "",
	p_source: Dictionary = {},
) -> void:
	_asset = p_asset
	_character = p_character
	_dsp_preset = p_dsp_preset
	_source = p_source.duplicate(true)
	_owner_validator = p_owner_validator
	_has_owner_validator = not p_owner_validator.is_null()


func get_asset() -> String:
	return _asset


func get_character() -> String:
	return _character


func get_dsp_preset() -> String:
	return _dsp_preset


func get_source() -> Dictionary:
	return _source.duplicate(true)


func has_owner_validator() -> bool:
	return _has_owner_validator


func is_current() -> bool:
	if not _has_owner_validator:
		return true
	return _owner_validator.is_valid() and bool(_owner_validator.call())
