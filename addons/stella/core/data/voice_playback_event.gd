## Typed canonical physical voice lifecycle event.
class_name VoicePlaybackEvent extends RefCounted

enum Kind { STARTED, PROGRESS, FINISHED }

var kind: int = Kind.STARTED
var playback_token: int = -1
var character: String = ""
var asset: String = ""
var position: float = 0.0
var duration: float = 0.0
var owner_validator: Callable
var legacy_raw: bool = false


func is_current() -> bool:
	return not owner_validator.is_valid() or bool(owner_validator.call())


static func started(
	p_character: String,
	p_asset: String,
	p_token: int,
	p_owner: Callable = Callable(),
	p_legacy_raw: bool = false,
) -> VoicePlaybackEvent:
	var event := VoicePlaybackEvent.new()
	event.kind = Kind.STARTED
	event.character = p_character
	event.asset = p_asset
	event.playback_token = p_token
	event.owner_validator = p_owner
	event.legacy_raw = p_legacy_raw
	return event


static func progress(
	p_position: float,
	p_duration: float,
	p_token: int,
	p_owner: Callable = Callable(),
	p_legacy_raw: bool = false,
) -> VoicePlaybackEvent:
	var event := VoicePlaybackEvent.new()
	event.kind = Kind.PROGRESS
	event.position = p_position
	event.duration = p_duration
	event.playback_token = p_token
	event.owner_validator = p_owner
	event.legacy_raw = p_legacy_raw
	return event


static func finished(
	p_token: int,
	p_owner: Callable = Callable(),
	p_legacy_raw: bool = false,
) -> VoicePlaybackEvent:
	var event := VoicePlaybackEvent.new()
	event.kind = Kind.FINISHED
	event.playback_token = p_token
	event.owner_validator = p_owner
	event.legacy_raw = p_legacy_raw
	return event
