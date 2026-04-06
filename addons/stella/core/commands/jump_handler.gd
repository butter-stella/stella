## Sets pending_jump on the context to trigger a scene jump.
class_name JumpHandler extends CommandHandler


func get_command_type() -> String:
	return "jump"


func execute(data: CommandData, context: ScenarioContext) -> void:
	context.pending_jump = data.get_string("target", "")
