## Typed canonical physical voice lifecycle event.
class_name VoicePlaybackEvent extends RefCounted

enum Kind { STARTED, PROGRESS, FINISHED, LAYER_FINISHED }

var _kind: int = Kind.STARTED
var _playback_token: int = -1
var _character: String = ""
var _asset: String = ""
var _layer_id: String = "main"
var _position: float = 0.0
var _duration: float = 0.0
var _owner_validator: Callable
var _has_owner_validator: bool = false
var _legacy_raw: bool = false
var _compatibility_notification: bool = true


func get_kind() -> int:
	return _kind


func get_playback_token() -> int:
	return _playback_token


func get_character() -> String:
	return _character


func get_asset() -> String:
	return _asset


func get_layer_id() -> String:
	return _layer_id


func get_position() -> float:
	return _position


func get_duration() -> float:
	return _duration


func is_legacy_raw() -> bool:
	return _legacy_raw


func should_emit_compatibility_notification() -> bool:
	return _compatibility_notification


func is_current() -> bool:
	if not _has_owner_validator:
		return true
	return _owner_validator.is_valid() and bool(_owner_validator.call())


static func started(
	p_character: String,
	p_asset: String,
	p_token: int,
	p_owner: Callable = Callable(),
	p_legacy_raw: bool = false,
	p_layer_id: String = "main",
	p_compatibility_notification: bool = true,
) -> VoicePlaybackEvent:
	var event := VoicePlaybackEvent.new()
	event._kind = Kind.STARTED
	event._character = p_character
	event._asset = p_asset
	event._playback_token = p_token
	event._layer_id = p_layer_id
	event._owner_validator = p_owner
	event._has_owner_validator = not p_owner.is_null()
	event._legacy_raw = p_legacy_raw
	event._compatibility_notification = p_compatibility_notification
	return event


static func progress(
	p_position: float,
	p_duration: float,
	p_token: int,
	p_owner: Callable = Callable(),
	p_legacy_raw: bool = false,
	p_layer_id: String = "main",
	p_character: String = "",
	p_asset: String = "",
	p_compatibility_notification: bool = true,
) -> VoicePlaybackEvent:
	var event := VoicePlaybackEvent.new()
	event._kind = Kind.PROGRESS
	event._position = p_position
	event._duration = p_duration
	event._playback_token = p_token
	event._layer_id = p_layer_id
	event._character = p_character
	event._asset = p_asset
	event._owner_validator = p_owner
	event._has_owner_validator = not p_owner.is_null()
	event._legacy_raw = p_legacy_raw
	event._compatibility_notification = p_compatibility_notification
	return event


static func finished(
	p_token: int,
	p_owner: Callable = Callable(),
	p_legacy_raw: bool = false,
	p_compatibility_notification: bool = true,
) -> VoicePlaybackEvent:
	var event := VoicePlaybackEvent.new()
	event._kind = Kind.FINISHED
	event._playback_token = p_token
	event._owner_validator = p_owner
	event._has_owner_validator = not p_owner.is_null()
	event._legacy_raw = p_legacy_raw
	event._compatibility_notification = p_compatibility_notification
	return event


static func layer_finished(
	p_character: String,
	p_asset: String,
	p_token: int,
	p_layer_id: String,
	p_owner: Callable = Callable(),
) -> VoicePlaybackEvent:
	var event := VoicePlaybackEvent.new()
	event._kind = Kind.LAYER_FINISHED
	event._character = p_character
	event._asset = p_asset
	event._playback_token = p_token
	event._layer_id = p_layer_id
	event._owner_validator = p_owner
	event._has_owner_validator = not p_owner.is_null()
	event._compatibility_notification = false
	return event
