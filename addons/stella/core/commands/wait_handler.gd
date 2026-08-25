## Pauses engine for a duration or until player advance.
class_name WaitHandler extends CommandHandler

enum _WaitOutcome {
	TIMER,
	ADVANCE,
	CANCELLED,
}


class _WaitRace extends RefCounted:
	signal settled(outcome: int)
	var _is_settled := false

	func settle(outcome: int) -> void:
		if _is_settled:
			return
		_is_settled = true
		settled.emit(outcome)


var _skip_controller: SkipController


func _init(skip_controller: SkipController = null) -> void:
	_skip_controller = skip_controller


func get_command_type() -> String:
	return "wait"


func execute(data: CommandData, context: ScenarioContext) -> void:
	if not _validate_command(data, context):
		return
	var mode := data.get_string("mode")
	if mode == "click":
		await _await_race(Signal(), context, true, false)
		return

	var skippable := data.get_bool("skippable")
	if skippable and _skip_controller != null and _skip_controller.is_active:
		return
	var timer: Variant = _create_timer(data.get_float("duration"))
	await _await_race(timer.timeout, context, skippable, skippable)


## Kept virtual for deterministic focused tests; production uses exactly one
## SceneTreeTimer and never polls wall-clock time.
func _create_timer(duration: float) -> Variant:
	return Engine.get_main_loop().create_timer(duration)


func _await_race(
	timer_signal: Signal,
	context: ScenarioContext,
	accept_advance: bool,
	accept_skip: bool,
) -> int:
	if context != null and context.is_cancellation_requested():
		return _WaitOutcome.CANCELLED
	var race := _WaitRace.new()
	var accept_advance_serial := SignalBus.current_advance_dispatch_serial()

	var on_timer := func():
		race.settle(_WaitOutcome.TIMER)
	var on_advance := func():
		# The dispatch hook increments before ordinary listeners. A waiter created
		# by the previous command's signal tail records that same serial and must
		# not consume the old input.
		if SignalBus.current_advance_dispatch_serial() <= accept_advance_serial:
			return
		race.settle(_WaitOutcome.ADVANCE)
	var on_context_cancel := func():
		race.settle(_WaitOutcome.CANCELLED)
	var on_abort := func():
		if context != null:
			context.request_cancellation()
		race.settle(_WaitOutcome.CANCELLED)
	var on_skip_changed := func(active: bool):
		if active:
			race.settle(_WaitOutcome.ADVANCE)

	if not timer_signal.is_null():
		timer_signal.connect(on_timer)
	if accept_advance:
		SignalBus.advance_requested.connect(on_advance)
	if context != null:
		context.cancellation_requested.connect(on_context_cancel)
	SignalBus.engine_abort_requested.connect(on_abort)
	if accept_skip and _skip_controller != null:
		_skip_controller.active_changed.connect(on_skip_changed)

	var outcome: int = await race.settled

	if not timer_signal.is_null() and timer_signal.is_connected(on_timer):
		timer_signal.disconnect(on_timer)
	if SignalBus.advance_requested.is_connected(on_advance):
		SignalBus.advance_requested.disconnect(on_advance)
	if (
		context != null
		and context.cancellation_requested.is_connected(on_context_cancel)
	):
		context.cancellation_requested.disconnect(on_context_cancel)
	if SignalBus.engine_abort_requested.is_connected(on_abort):
		SignalBus.engine_abort_requested.disconnect(on_abort)
	if (
		_skip_controller != null
		and _skip_controller.active_changed.is_connected(on_skip_changed)
	):
		_skip_controller.active_changed.disconnect(on_skip_changed)
	return outcome


func _validate_command(data: CommandData, context: ScenarioContext) -> bool:
	if data == null:
		_fail_context(data, context, "missing command data")
		return false
	var mode_value: Variant = data.params.get("mode")
	if not mode_value is String or mode_value not in ["click", "timer"]:
		_fail_context(data, context, "mode must be click or timer")
		return false
	var expected_keys := ["mode"]
	if mode_value == "timer":
		expected_keys = ["duration", "mode", "skippable"]
		var duration_value: Variant = data.params.get("duration")
		if (
			not (duration_value is int or duration_value is float)
			or not is_finite(float(duration_value))
			or float(duration_value) < 0.0
		):
			_fail_context(data, context, "timer duration must be finite and non-negative")
			return false
		if not data.params.get("skippable") is bool:
			_fail_context(data, context, "timer skippable must be a bool")
			return false
	var keys := data.params.keys()
	keys.sort()
	if keys != expected_keys:
		_fail_context(data, context, "invalid canonical wait payload")
		return false
	return true


func _fail_context(
	data: CommandData,
	context: ScenarioContext,
	message: String,
) -> void:
	var scenario_data := context.scenario_data if context != null else null
	var source_path := scenario_data.source_path if scenario_data != null else ""
	var scenario_id := scenario_data.id if scenario_data != null else ""
	var label := source_path if not source_path.is_empty() else scenario_id
	var line := data.declared_line if data != null else 0
	if not label.is_empty() and line > 0:
		label = "%s:%d" % [label, line]
	elif label.is_empty() and line > 0:
		label = "line %d" % line
	elif label.is_empty():
		label = "runtime"
	push_error("[%s] WaitHandler: %s" % [label, message])
	if context != null and context.is_runtime_owner_current():
		context.is_finished = true
