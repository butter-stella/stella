## Conditional terminal command for a scenario shared by story and gallery
## playback. Story execution is a synchronous no-op. A recollection execution
## marks the current context terminal; StellaRuntime owns the subsequent exact
## return, presentation cleanup, and caller continuation.
class_name RecollectionExitHandler extends CommandHandler


func get_command_type() -> String:
	return "recollection_exit"


func execute(data: CommandData, context: ScenarioContext) -> void:
	if context == null:
		return
	context.request_recollection_exit(data.declared_line)
