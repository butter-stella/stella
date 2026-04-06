## Writes a variable to the VariableStore.
## Supports =, +=, -= operators.
class_name SetHandler extends CommandHandler


func get_command_type() -> String:
	return "set"


func execute(data: CommandData, context: ScenarioContext) -> void:
	var var_name = data.get_string("var", "")
	var value = data.params.get("value")
	var op = data.get_string("op", "=")

	if context.variable_store:
		context.variable_store.set_var(var_name, value, VariableStore.Scope.SCENARIO, op)
