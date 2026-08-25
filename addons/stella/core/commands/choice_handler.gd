## Emits choice_show signal and waits for choice_selected.
## Then applies jump and variable changes from the selected option.
class_name ChoiceHandler extends CommandHandler

var _begin_choice_policy: Callable
var _resolve_choice_policy: Callable
var _cancel_choice_policy: Callable
var _is_choice_policy_current: Callable
var _publish_choice_policy: Callable


## Internal waiter — choice_selected carries a payload (the option id) so
## we need a custom race signal that propagates BOTH the abort flag and
## the selected option index, instead of using CommandHandler.await_with_abort
## (which only returns a bool).
class _AbortChoiceRace extends RefCounted:
	signal done(was_aborted: bool, selected_index: int)
	var _resolved: bool = false
	var _was_aborted: bool = false
	var _selected_index: int = -1

	func resolve(was_aborted: bool, selected_index: int) -> void:
		if _resolved:
			return
		_resolved = true
		_was_aborted = was_aborted
		_selected_index = selected_index
		done.emit(was_aborted, selected_index)

	func is_resolved() -> bool:
		return _resolved

	func get_result() -> Array:
		return [_was_aborted, _selected_index]


func _init(
	begin_choice_policy: Callable = Callable(),
	resolve_choice_policy: Callable = Callable(),
	cancel_choice_policy: Callable = Callable(),
	is_choice_policy_current: Callable = Callable(),
	publish_choice_policy: Callable = Callable(),
) -> void:
	_begin_choice_policy = begin_choice_policy
	_resolve_choice_policy = resolve_choice_policy
	_cancel_choice_policy = cancel_choice_policy
	_is_choice_policy_current = is_choice_policy_current
	_publish_choice_policy = publish_choice_policy


func get_command_type() -> String:
	return "choice"


func execute(data: CommandData, context: ScenarioContext) -> void:
	var prompt = data.get_string("prompt", "")
	var raw_options = data.params.get("options", [])
	var options: Array = (
		raw_options.duplicate(true) if raw_options is Array else [])

	# Install every completion/cancellation owner before publishing SHOW. A
	# headless or custom consumer may select, abort, or replace the context
	# synchronously from the SHOW callback, so the waiter also caches its result
	# for the pre-await completion case.
	if context != null and not context.is_runtime_owner_current():
		return
	var waiter = _AbortChoiceRace.new()
	var on_choice := func(id: String):
		var selected_index := _find_selected_option_index(options, id)
		if selected_index >= 0:
			waiter.resolve(false, selected_index)
	var on_context_cancel := func():
		waiter.resolve(true, -1)
	var on_abort := func():
		if context != null:
			context.request_cancellation()
		waiter.resolve(true, -1)
	SignalBus.choice_selected.connect(on_choice)
	if context != null:
		context.cancellation_requested.connect(
			on_context_cancel, CONNECT_ONE_SHOT)
	SignalBus.engine_abort_requested.connect(on_abort, CONNECT_ONE_SHOT)

	var policy_session_id := _begin_policy_session()
	var choice_was_published := false
	if _begin_choice_policy.is_valid() and policy_session_id < 0:
		# The composition root rejected a malformed concurrent choice. Do not
		# publish a second modal or let this command continue as if it succeeded.
		if context != null:
			context.request_cancellation()
		waiter.resolve(true, -1)
	if context != null and not context.is_runtime_owner_current():
		waiter.resolve(true, -1)
	if not waiter.is_resolved():
		# Presentation receives its own deep payload: a synchronous custom UI may
		# decorate or reorder options, but cannot rewrite the canonical selection
		# identity/effects retained by Core.
		choice_was_published = _publish_choice(
			policy_session_id, prompt, options.duplicate(true))
	# A synchronous SHOW tail can invalidate ownership without emitting the
	# context signal (for example, a custom consumer setting is_finished).
	if context != null and not context.is_runtime_owner_current():
		waiter.resolve(true, -1)
	var result: Array = waiter.get_result()
	if not waiter.is_resolved():
		result = await waiter.done
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
		or (context != null and not context.is_runtime_owner_current())
	):
		if _cancel_policy_session(policy_session_id) and choice_was_published:
			SignalBus.choice_hide.emit()
		return
	var selected_index: int = int(result[1])
	if selected_index < 0 or selected_index >= options.size():
		if _cancel_policy_session(policy_session_id) and choice_was_published:
			SignalBus.choice_hide.emit()
		return
	if not _policy_session_is_current(policy_session_id):
		return
	_apply_selected_option(options[selected_index], context)
	if context != null and not context.is_runtime_owner_current():
		if _cancel_policy_session(policy_session_id) and choice_was_published:
			SignalBus.choice_hide.emit()
		return
	if _resolve_policy_session(policy_session_id) and choice_was_published:
		SignalBus.choice_hide.emit()


func _find_selected_option_index(options: Array, selected_id: String) -> int:
	for index in range(options.size()):
		var raw_option = options[index]
		if not raw_option is Dictionary:
			continue
		var option: Dictionary = raw_option
		var option_id := String(option.get("id", ""))
		var option_label := String(option.get("label", ""))
		if (
			(not option_id.is_empty() and option_id == selected_id)
			or (not option_label.is_empty() and option_label == selected_id)
		):
			return index
	return -1


func _apply_selected_option(raw_option: Variant, context: ScenarioContext) -> void:
	if not raw_option is Dictionary or context == null:
		return
	var option: Dictionary = raw_option
	if option.has("jump"):
		context.pending_jump = option["jump"]
	if not option.has("set") or context.variable_store == null:
		return
	var set_data = option["set"]
	if not set_data is Dictionary:
		return
	for var_name in set_data:
		var expr = str(set_data[var_name])
		var parts = expr.split(" ")
		if parts.size() != 2:
			continue
		var op = parts[0]
		var val = parts[1]
		if val.is_valid_int():
			context.variable_store.set_var(
				var_name,
				val.to_int(),
				VariableStore.Scope.SCENARIO,
				op,
			)
		else:
			context.variable_store.set_var(var_name, val)


func _begin_policy_session() -> int:
	if not _begin_choice_policy.is_valid():
		return -1
	return int(_begin_choice_policy.call())


func _resolve_policy_session(session_id: int) -> bool:
	if not _resolve_choice_policy.is_valid():
		return true
	return bool(_resolve_choice_policy.call(session_id))


func _cancel_policy_session(session_id: int) -> bool:
	if not _cancel_choice_policy.is_valid():
		return true
	return bool(_cancel_choice_policy.call(session_id))


func _policy_session_is_current(session_id: int) -> bool:
	if not _is_choice_policy_current.is_valid():
		return true
	return bool(_is_choice_policy_current.call(session_id))


func _publish_choice(
	session_id: int,
	prompt: String,
	options: Array,
) -> bool:
	if not _publish_choice_policy.is_valid():
		SignalBus.choice_show.emit(prompt, options)
		return true
	return bool(_publish_choice_policy.call(session_id, prompt, options))
