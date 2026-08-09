## Evaluates a condition expression and jumps to then_jump or else_jump.
class_name ConditionHandler extends CommandHandler

var _evaluator: ExpressionEvaluator = ExpressionEvaluator.new()


func get_command_type() -> String:
	return "condition"


func execute(data: CommandData, context: ScenarioContext) -> void:
	var expr = data.get_string("if", "")
	var then_jump = data.get_string("then_jump", "")
	var else_jump = data.get_string("else_jump", "")

	if context.variable_store and _evaluator.evaluate(expr, context.variable_store):
		context.apply_dialogue_mode_events(
			data.dialogue_mode_events_on_true_branch)
		context.pending_jump = then_jump
	else:
		context.apply_dialogue_mode_events(
			data.dialogue_mode_events_on_false_branch)
		context.pending_jump = else_jump
