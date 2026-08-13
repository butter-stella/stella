## Typed logical dialogue voice lifecycle consumed by built-in UI.
class_name DialogueVoicePlaybackEvent extends RefCounted

enum Kind { STARTED, PROGRESS, FINISHED }

var _kind: int = Kind.STARTED
var _position: float = 0.0
var _total_duration: float = 0.0
var _owner_validator: Callable
var _legacy_raw: bool = false


func get_kind() -> int:
	return _kind


func get_position() -> float:
	return _position


func get_total_duration() -> float:
	return _total_duration


func is_current() -> bool:
	return not _owner_validator.is_valid() or bool(_owner_validator.call())


func is_legacy_raw() -> bool:
	return _legacy_raw


static func started(
	total_duration: float,
	owner: Callable = Callable(),
	legacy_raw: bool = false,
) -> DialogueVoicePlaybackEvent:
	var event := DialogueVoicePlaybackEvent.new()
	event._kind = Kind.STARTED
	event._total_duration = total_duration
	event._owner_validator = owner
	event._legacy_raw = legacy_raw
	return event


static func progress(
	position: float,
	total_duration: float,
	owner: Callable = Callable(),
	legacy_raw: bool = false,
) -> DialogueVoicePlaybackEvent:
	var event := DialogueVoicePlaybackEvent.new()
	event._kind = Kind.PROGRESS
	event._position = position
	event._total_duration = total_duration
	event._owner_validator = owner
	event._legacy_raw = legacy_raw
	return event


static func finished(
	owner: Callable = Callable(),
	legacy_raw: bool = false,
) -> DialogueVoicePlaybackEvent:
	var event := DialogueVoicePlaybackEvent.new()
	event._kind = Kind.FINISHED
	event._owner_validator = owner
	event._legacy_raw = legacy_raw
	return event
