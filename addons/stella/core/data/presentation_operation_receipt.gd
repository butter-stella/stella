## Immutable exact identity for one presenter-owned transition.
class_name PresentationOperationReceipt extends RefCounted

var _batch_id: int
var _presenter_instance_id: int
var _channel: StringName
var _token: int
var _generation: int


func _init(
	batch_id_value: int = 0,
	presenter_instance_id_value: int = 0,
	channel_value: StringName = &"",
	token_value: int = 0,
	generation_value: int = 0,
) -> void:
	_batch_id = batch_id_value
	_presenter_instance_id = presenter_instance_id_value
	_channel = channel_value
	_token = token_value
	_generation = generation_value


func get_batch_id() -> int:
	return _batch_id


func get_presenter_instance_id() -> int:
	return _presenter_instance_id


func get_channel() -> StringName:
	return _channel


func get_token() -> int:
	return _token


func get_generation() -> int:
	return _generation
