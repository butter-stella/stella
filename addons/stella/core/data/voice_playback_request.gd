## Typed synchronous request from DialoguePresenter to AudioPresenter.
## AudioPresenter resolves it exactly once; only accepted requests receive a
## canonical playback token and completion state.
class_name VoicePlaybackRequest extends RefCounted

var asset: String = ""
var character: String = ""
var owner_validator: Callable
var handled: bool = false
var accepted: bool = false
var playback_token: int = -1
var completion_state: Dictionary = {}


func _init(
	p_asset: String = "",
	p_character: String = "",
	p_owner_validator: Callable = Callable(),
) -> void:
	asset = p_asset
	character = p_character
	owner_validator = p_owner_validator


func is_current() -> bool:
	return not owner_validator.is_valid() or bool(owner_validator.call())
