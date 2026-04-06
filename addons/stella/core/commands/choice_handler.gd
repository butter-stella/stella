## Emits choice_show signal and waits for choice_selected.
## Then applies jump and variable changes from the selected option.
class_name ChoiceHandler extends CommandHandler


func get_command_type() -> String:
	return "choice"


func execute(data: CommandData, context: ScenarioContext) -> void:
	var prompt = data.get_string("prompt", "")
	var options = data.params.get("options", [])

	SignalBus.choice_show.emit(prompt, options)
	var selected_id = await SignalBus.choice_selected

	# Find the selected option and apply its effects
	for opt in options:
		if opt.get("id", "") == selected_id or opt.get("label", "") == selected_id:
			if opt.has("jump"):
				context.pending_jump = opt["jump"]
			if opt.has("set") and context.variable_store:
				var set_data = opt["set"]
				for var_name in set_data:
					var expr = str(set_data[var_name])
					var parts = expr.split(" ")
					if parts.size() == 2:
						var op = parts[0]
						var val = parts[1]
						if val.is_valid_int():
							context.variable_store.set_var(var_name, val.to_int(), VariableStore.Scope.SCENARIO, op)
						else:
							context.variable_store.set_var(var_name, val)
			break
