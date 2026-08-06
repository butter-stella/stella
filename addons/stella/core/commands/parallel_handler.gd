## Executes multiple sub-commands in parallel.
## Note: In GDScript, true parallel await is limited. We execute all
## non-blocking commands first, then handle any that need await.
class_name ParallelHandler extends CommandHandler

## CommandRegistry owns this handler, so the back-reference must stay weak.
## A strong reference here creates an uncollectable RefCounted cycle.
var _registry_ref: WeakRef


func set_registry(command_registry: CommandRegistry) -> void:
	_registry_ref = weakref(command_registry) if command_registry != null else null


func get_command_type() -> String:
	return "parallel"


func execute(data: CommandData, context: ScenarioContext) -> void:
	var sub_commands = data.params.get("commands", [])
	var command_registry: CommandRegistry = null
	if _registry_ref != null:
		command_registry = _registry_ref.get_ref() as CommandRegistry
	if command_registry == null:
		push_warning("ParallelHandler: no registry set, cannot dispatch sub-commands")
		return

	for sub_cmd in sub_commands:
		# A runtime reset or rollback can abort the currently awaited child. Do
		# not start a later child after that one-shot abort signal has fired, or
		# the new child could wait forever on a signal it already missed.
		if context.is_finished:
			return
		var handler = command_registry.get_handler(sub_cmd.type)
		if handler:
			await handler.execute(sub_cmd, context)
			if context.is_finished:
				return
