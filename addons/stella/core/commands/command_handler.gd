## Base class for all command handlers.
## Subclass this and override get_command_type() and execute().
class_name CommandHandler extends RefCounted


func get_command_type() -> String:
	return ""


func execute(_data: CommandData, _context: ScenarioContext) -> void:
	pass


func rollback(_data: CommandData, _context: ScenarioContext) -> void:
	pass
