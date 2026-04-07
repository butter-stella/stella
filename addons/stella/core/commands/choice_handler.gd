## Emits choice_show signal and waits for choice_selected.
## Then applies jump and variable changes from the selected option.
class_name ChoiceHandler extends CommandHandler


## Internal waiter — choice_selected carries a payload (the option id) so
## we need a custom race signal that propagates BOTH the abort flag and
## the selected id, instead of using CommandHandler.await_with_abort
## (which only returns a bool).
class _AbortChoiceRace extends RefCounted:
	signal done(was_aborted: bool, id: String)


func get_command_type() -> String:
	return "choice"


func execute(data: CommandData, context: ScenarioContext) -> void:
	var prompt = data.get_string("prompt", "")
	var options = data.params.get("options", [])

	SignalBus.choice_show.emit(prompt, options)
	# Race against engine_abort_requested. If aborted, return early; the
	# engine loop will see ctx != context and exit cleanly without
	# applying any selection.
	var waiter = _AbortChoiceRace.new()
	var on_choice := func(id: String):
		waiter.done.emit(false, id)
	var on_abort := func():
		waiter.done.emit(true, "")
	SignalBus.choice_selected.connect(on_choice, CONNECT_ONE_SHOT)
	SignalBus.engine_abort_requested.connect(on_abort, CONNECT_ONE_SHOT)
	var result: Array = await waiter.done
	if SignalBus.choice_selected.is_connected(on_choice):
		SignalBus.choice_selected.disconnect(on_choice)
	if SignalBus.engine_abort_requested.is_connected(on_abort):
		SignalBus.engine_abort_requested.disconnect(on_abort)
	if result[0]:  # aborted
		return
	var selected_id = result[1]

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
