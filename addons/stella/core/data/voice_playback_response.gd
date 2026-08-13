## Bus-owned response handle for a synchronous VoicePlaybackRequest.
class_name VoicePlaybackResponse extends RefCounted

var _handled: bool = false
var _accepted: bool = false
var _playback_token: int = -1
var _completion: VoicePlaybackCompletion


func was_handled() -> bool:
	return _handled


func was_accepted() -> bool:
	return _accepted


func get_playback_token() -> int:
	return _playback_token


func get_completion() -> VoicePlaybackCompletion:
	return _completion


func _resolve(
	accepted: bool,
	playback_token: int = -1,
	completion: VoicePlaybackCompletion = null,
) -> void:
	if _handled:
		return
	_handled = true
	_accepted = accepted
	_playback_token = playback_token
	_completion = completion
