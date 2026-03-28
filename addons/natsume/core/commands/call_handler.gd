## Calls a sub-scene — pushes return point to stack, then jumps.
## When the sub-scene ends, engine pops the return stack and resumes.
class_name CallHandler extends CommandHandler


func get_command_type() -> String:
	return "call"


func execute(data: CommandData, context: ScenarioContext) -> void:
	var target = data.get_string("target", "")

	if target == "":
		push_warning("CallHandler: empty target, skipping")
		return

	# Push return point (next command after this call)
	context.return_stack.append({
		"scene_index": context.current_scene_index,
		"command_index": context.current_command_index + 1,
	})

	context.pending_jump = target
