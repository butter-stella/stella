## Registry of command handlers, keyed by command type string.
class_name CommandRegistry extends RefCounted

var _handlers: Dictionary = {}  # String -> CommandHandler


func register(handler: CommandHandler) -> void:
	_handlers[handler.get_command_type()] = handler


func get_handler(command_type: String) -> CommandHandler:
	return _handlers.get(command_type)


func has_handler(command_type: String) -> bool:
	return _handlers.has(command_type)
