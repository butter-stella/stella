## Immutable typed presentation operation shared by composition adapters.
@abstract
class_name PresentationOperation extends RefCounted

var _kind: StringName
var _channel: StringName
var _payload: Dictionary
var _source: Dictionary


func _init(
	kind: StringName = &"",
	channel: StringName = &"",
	payload: Dictionary = {},
	source: Dictionary = {},
) -> void:
	_kind = kind
	_channel = channel
	_payload = payload.duplicate(true)
	_source = source.duplicate(true)


func get_kind() -> StringName:
	return _kind


func get_channel() -> StringName:
	return _channel


func get_payload() -> Dictionary:
	return _payload.duplicate(true)


func get_source() -> Dictionary:
	return _source.duplicate(true)
