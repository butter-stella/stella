## Async wait/complete mechanism for pausing engine execution.
## Used by handlers that need to wait for player input (dialogue, choice).
class_name WaitController extends RefCounted

var _completed: bool = false


func wait() -> void:
	_completed = false
	while not _completed:
		await Engine.get_main_loop().process_frame


func complete() -> void:
	_completed = true


func reset() -> void:
	_completed = false


func is_completed() -> bool:
	return _completed
