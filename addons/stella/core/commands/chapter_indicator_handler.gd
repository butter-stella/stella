## Applies an authored current-chapter indicator visibility operation.
##
## The complete operation is validated before ScenarioContext changes. Accepted
## presenter fades join one exact, abortable barrier; headless/cut operations
## complete synchronously.
class_name ChapterIndicatorHandler extends CommandHandler

const ChapterIndicatorRequest = preload(
	"res://addons/stella/core/data/chapter_indicator_request.gd")


func get_command_type() -> String:
	return "chapter_indicator"


func execute(data: CommandData, context: ScenarioContext) -> void:
	if context == null:
		push_error("ChapterIndicatorHandler: missing ScenarioContext")
		return
	if data == null:
		_fail_context(data, context, "missing CommandData")
		return
	var validation := _validate_command(data)
	if not bool(validation.get("valid", false)):
		_fail_context(data, context, String(validation.get("error", "invalid command")))
		return

	var target_visible := String(validation["action"]) == "show"
	# Save-during-transition restores the already-committed target at the same
	# cursor. Re-dispatch must neither replay a tween nor create a new barrier.
	if context.chapter_indicator_visible == target_visible:
		return
	var previous_visible := context.chapter_indicator_visible
	var source := _source(data, context)
	var request: ChapterIndicatorRequest = SignalBus.request_chapter_indicator_visibility(
		target_visible,
		String(validation["transition"]),
		float(validation["duration"]),
		source,
		func():
			if context.is_runtime_owner_current():
				context.chapter_indicator_visible = target_visible,
	)
	if request.was_cancelled():
		return
	if request.get_request_id() <= 0:
		context.is_finished = true
		return

	while not request.is_finished():
		if not await CommandHandler.await_with_abort(
			SignalBus.chapter_indicator_request_finished,
			context,
		):
			SignalBus.cancel_chapter_indicator_request(request.get_request_id())
			return

	if request.was_cancelled():
		return
	if request.was_successful():
		return
	# Completion listeners are synchronously reentrant. A listener may replace
	# the ScenarioContext and project a fresh owner before this coroutine resumes;
	# the stale failure tail must not roll back or cut over that newer projection.
	if not context.is_runtime_owner_current():
		return
	# A joined presenter disappeared or explicitly failed after acceptance.
	# Revert the exact authored request, cut-project surviving presenters, and
	# stop only the owning context.
	context.chapter_indicator_visible = previous_visible
	SignalBus.apply_chapter_indicator_state(previous_visible)
	if context.is_runtime_owner_current():
		context.is_finished = true


func _validate_command(data: CommandData) -> Dictionary:
	if data.type != "chapter_indicator":
		return {"valid": false, "error": "command type must be chapter_indicator"}
	var keys: Array = data.params.keys()
	keys.sort()
	if keys != ["action", "duration", "transition"]:
		return {
			"valid": false,
			"error": "params must contain exactly action, transition, and duration",
		}
	if not data.params["action"] is String:
		return {"valid": false, "error": "action must be a String"}
	var action := String(data.params["action"]).to_lower()
	if action not in ["show", "hide"]:
		return {"valid": false, "error": "action must be 'show' or 'hide'"}
	if not data.params["transition"] is String:
		return {"valid": false, "error": "transition must be a String"}
	var transition := String(data.params["transition"]).to_lower()
	if transition == "none":
		transition = "cut"
	if transition not in ["cut", "fade"]:
		return {"valid": false, "error": "transition must be cut, none, or fade"}
	var raw_duration: Variant = data.params["duration"]
	if not raw_duration is float:
		return {"valid": false, "error": "duration must be a float"}
	var duration := float(raw_duration)
	if not is_finite(duration):
		return {"valid": false, "error": "duration must be finite"}
	if duration < 0.0:
		return {"valid": false, "error": "duration must be non-negative"}
	if transition == "cut" and duration != 0.0:
		return {"valid": false, "error": "cut/none transition requires duration=0"}
	return {
		"valid": true,
		"action": action,
		"transition": transition,
		"duration": duration,
	}


func _fail_context(
	data: CommandData,
	context: ScenarioContext,
	message: String,
) -> void:
	push_error("%s ChapterIndicatorHandler: %s" % [
		_source_label(_source(data, context)),
		message,
	])
	context.is_finished = true


func _source(data: CommandData, context: ScenarioContext) -> Dictionary:
	var scenario_data := context.scenario_data if context != null else null
	return {
		"source_path": scenario_data.source_path if scenario_data != null else "",
		"scenario_id": scenario_data.id if scenario_data != null else "",
		"line": data.declared_line if data != null else 0,
	}


func _source_label(source: Dictionary) -> String:
	var source_path := String(source.get("source_path", "")).strip_edges()
	var scenario_id := String(source.get("scenario_id", "")).strip_edges()
	var label := source_path if not source_path.is_empty() else scenario_id
	var line := int(source.get("line", 0))
	if not label.is_empty() and line > 0:
		return "[%s:%d]" % [label, line]
	if not label.is_empty():
		return "[%s]" % label
	if line > 0:
		return "[line %d]" % line
	return "[runtime]"
