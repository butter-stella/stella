## Read-only completion handle for one accepted physical voice playback.
class_name VoicePlaybackCompletion extends RefCounted

var _finished: bool = false


func is_finished() -> bool:
	return _finished


func _mark_finished() -> void:
	_finished = true
