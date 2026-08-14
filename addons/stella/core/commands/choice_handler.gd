## Emits choice_show signal and waits for choice_selected.
## Then applies jump and variable changes from the selected option.
class_name ChoiceHandler extends CommandHandler


## Internal waiter — choice_selected carries a payload (the option id) so
## we need a custom race signal that propagates BOTH the abort flag and
## the selected id, instead of using CommandHandler.await_with_abort
## (which only returns a bool).
class _AbortChoiceRace extends RefCounted:
	signal done(was_aborted: bool, id: String)
	var _resolved: bool = false

	func resolve(was_aborted: bool, id: String) -> void:
		if _resolved:
			return
		_resolved = true
		done.emit(was_aborted, id)


func get_command_type() -> String:
	return "choice"


func execute(data: CommandData, context: ScenarioContext) -> void:
	var prompt = data.get_string("prompt", "")
	var options = data.params.get("options", [])

	SignalBus.choice_show.emit(prompt, options)
	# Race the selection against the owning execution generation. The global
	# abort signal is retained as a compatibility input and folded into that same
	# context cancellation, matching CommandHandler.await_with_abort.
	var waiter = _AbortChoiceRace.new()
	var on_choice := func(id: String):
		waiter.resolve(false, id)
	var on_context_cancel := func():
		waiter.resolve(true, "")
	var on_abort := func():
		if context != null:
			context.request_cancellation()
		waiter.resolve(true, "")
	if context != null and context.is_cancellation_requested():
		return
	SignalBus.choice_selected.connect(on_choice, CONNECT_ONE_SHOT)
	if context != null:
		context.cancellation_requested.connect(
			on_context_cancel, CONNECT_ONE_SHOT)
	SignalBus.engine_abort_requested.connect(on_abort, CONNECT_ONE_SHOT)
	var result: Array = await waiter.done
	if SignalBus.choice_selected.is_connected(on_choice):
		SignalBus.choice_selected.disconnect(on_choice)
	if (
		context != null
		and context.cancellation_requested.is_connected(on_context_cancel)
	):
		context.cancellation_requested.disconnect(on_context_cancel)
	if SignalBus.engine_abort_requested.is_connected(on_abort):
		SignalBus.engine_abort_requested.disconnect(on_abort)
	if (
		result[0]
		or (context != null and context.is_cancellation_requested())
	):
		SignalBus.choice_hide.emit()
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
