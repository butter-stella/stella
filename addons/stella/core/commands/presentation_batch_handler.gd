## Validates and submits one authored mixed Stage/dialogue/chapter batch.
class_name PresentationBatchHandler extends CommandHandler

const EXACT_PARAM_KEYS := ["operation_lines", "operations", "policy"]
const EXACT_ENVELOPE_KEYS := ["kind", "payload"]
const EXACT_STAGE_PAYLOAD_KEYS := [
	"action", "duration", "id", "properties", "transition", "transition_params",
]
const EXACT_VISIBILITY_PAYLOAD_KEYS := [
	"action", "duration", "target", "transition",
]
const EXACT_DIALOGUE_AVATAR_PAYLOAD_KEYS := [
	"action", "duration", "properties", "transition",
]
const EXACT_DIALOGUE_CLEAR_PAYLOAD_KEYS := ["scope"]
const EXACT_CHAPTER_INDICATOR_PAYLOAD_KEYS := [
	"action", "duration", "transition",
]
const EXACT_LOOP_SE_PAYLOAD_KEYS := [
	"action", "asset", "channel", "fade_duration", "resume_position", "volume",
]
const EXACT_BGM_PAYLOAD_KEYS := [
	"action", "asset", "cue", "fade_duration", "resume_position", "stem_mix",
	"volume",
]
const EXACT_MOVIE_PAYLOAD_KEYS := ["action", "asset", "loop", "skippable"]

var _director: PresentationDirector
var _presentation_state: PresentationState


func _init(
	director: PresentationDirector = null,
	presentation_state: PresentationState = null,
) -> void:
	_director = director
	_presentation_state = presentation_state


func get_command_type() -> String:
	return "presentation_batch"


func execute(data: CommandData, context: ScenarioContext) -> void:
	if (
		context == null
		or context.is_cancellation_requested()
		or not context.is_runtime_owner_current()
	):
		_fail_context(
			data,
			context,
			"ScenarioContext is missing, cancelled, or not current",
		)
		return
	var validation := _validate_and_reduce(data)
	if not bool(validation.get("valid", false)):
		_fail_context(
			data,
			context,
			String(validation.get("error", "invalid presentation batch")),
			int(validation.get("line", data.declared_line if data != null else 0)),
		)
		return
	if _director == null:
		_fail_context(data, context, "PresentationDirector is unavailable")
		return

	var typed_operations: Array[PresentationOperation] = []
	var runtime_binding := StellaRuntime._runtime_dialogue_visibility_binding(
		context
	)
	for operation_value: Variant in validation["operations"]:
		var operation_index := typed_operations.size()
		var operation: Dictionary = operation_value
		var kind := String(operation.get("kind", ""))
		var payload: Dictionary = (operation.get("payload", {}) as Dictionary).duplicate(true)
		var operation_source := _source(data, context)
		operation_source["line"] = int(
			(data.params.get("operation_lines", []) as Array)[operation_index]
		)
		match kind:
			"stage":
				typed_operations.append(StagePresentationOperation.new(
					payload, operation_source))
			"dialogue_avatar":
				typed_operations.append(DialogueAvatarPresentationOperation.new(
					payload,
					validation["before_dialogue_avatar"],
					validation["target_dialogue_avatar"],
					operation_source,
				))
			"dialogue_visibility":
				typed_operations.append(
					DialogueVisibilityPresentationOperation.new(
						payload,
						runtime_binding,
						operation_source,
					)
				)
			"dialogue_clear":
				typed_operations.append(
					DialogueClearPresentationOperation.new(
						payload,
						PresentationState.cleared_dialogue_content(context),
						runtime_binding,
						operation_source,
					)
				)
			"chapter_indicator":
				typed_operations.append(
					ChapterIndicatorPresentationOperation.new(
						payload, operation_source))
			"loop_se":
				typed_operations.append(
					LoopSePresentationOperation.new(payload, operation_source))
			"bgm":
				typed_operations.append(
					BgmPresentationOperation.new(payload, operation_source))
			"movie":
				typed_operations.append(
					MoviePresentationOperation.new(payload, operation_source))
	var policy := (
		PresentationBatchRequest.Policy.JOIN
		if String(validation["policy"]) == "join"
		else PresentationBatchRequest.Policy.FIRE_AND_FORGET
	)
	var request := _director.submit(
		typed_operations,
		policy,
		context,
		_source(data, context),
	)
	if request.is_settled():
		_finish_request(request, context)
		return
	if not await CommandHandler.await_with_abort(request.settled, context):
		return
	_finish_request(request, context)


func _finish_request(
	request: PresentationBatchRequest,
	context: ScenarioContext,
) -> void:
	if (
		request.get_outcome() in [
			PresentationBatchRequest.Outcome.FAILED,
			PresentationBatchRequest.Outcome.CANCELLED,
		]
		and context != null
		and context.is_runtime_owner_current()
	):
		context.is_finished = true


func _validate_and_reduce(data: CommandData) -> Dictionary:
	if data == null:
		return {"valid": false, "error": "missing CommandData", "line": 0}
	if data.type != "presentation_batch":
		return {
			"valid": false,
			"error": "command type must be presentation_batch",
			"line": data.declared_line,
		}
	var param_keys := data.params.keys()
	param_keys.sort()
	if param_keys != EXACT_PARAM_KEYS:
		return {
			"valid": false,
			"error": "params must contain exactly policy, operations, and operation_lines",
			"line": data.declared_line,
		}
	if not data.params.get("policy", null) is String:
		return {"valid": false, "error": "policy must be a String", "line": data.declared_line}
	if not data.params.get("operations", null) is Array:
		return {"valid": false, "error": "operations must be an Array", "line": data.declared_line}
	if not data.params.get("operation_lines", null) is Array:
		return {"valid": false, "error": "operation_lines must be an Array", "line": data.declared_line}
	var policy := String(data.params["policy"])
	if policy not in ["join", "fire_and_forget"]:
		return {"valid": false, "error": "invalid batch policy", "line": data.declared_line}
	var operations: Array = data.params["operations"]
	var operation_lines: Array = data.params["operation_lines"]
	if operations.is_empty():
		return {"valid": false, "error": "operations must not be empty", "line": data.declared_line}
	if operation_lines.size() != operations.size():
		return {"valid": false, "error": "operation_lines must match operations one-for-one", "line": data.declared_line}

	var seen_stage_layers: Dictionary = {}
	var seen_targets: Dictionary = {}
	var canonical_operations: Array = []
	var stage_operations: Array = []
	var visibility_operations: Array = []
	var avatar_operations: Array = []
	var saw_dialogue_avatar := false
	var avatar_line := data.declared_line
	var saw_dialogue_clear := false
	var saw_chapter_indicator := false
	var seen_loop_se_channels: Dictionary = {}
	var loop_se_operations: Array = []
	var saw_bgm := false
	var bgm_operations: Array = []
	var bgm_line := data.declared_line
	var saw_movie := false
	var movie_operations: Array = []
	var movie_line := data.declared_line
	for index in range(operations.size()):
		if not operation_lines[index] is int or int(operation_lines[index]) <= 0:
			return {"valid": false, "error": "operation line must be a positive integer", "line": data.declared_line}
		if not operations[index] is Dictionary:
			return {"valid": false, "error": "operation must be a Dictionary", "line": int(operation_lines[index])}
		var envelope: Dictionary = operations[index]
		var envelope_keys := envelope.keys()
		envelope_keys.sort()
		if envelope_keys != EXACT_ENVELOPE_KEYS:
			return {"valid": false, "error": "operation envelope must use exactly kind and payload", "line": int(operation_lines[index])}
		var kind := String(envelope.get("kind", ""))
		if not envelope.get("payload", null) is Dictionary:
			return {"valid": false, "error": "operation payload must be a Dictionary", "line": int(operation_lines[index])}
		var payload: Dictionary = (envelope["payload"] as Dictionary).duplicate(true)
		match kind:
			"stage":
				var stage_keys := payload.keys()
				stage_keys.sort()
				if stage_keys != EXACT_STAGE_PAYLOAD_KEYS:
					return {"valid": false, "error": "stage payload must use the canonical six-field schema", "line": int(operation_lines[index])}
				if not StageLayerState.validate_operation(payload, false):
					return {"valid": false, "error": "stage payload failed canonical validation", "line": int(operation_lines[index])}
				var action := String(payload.get("action", ""))
				var layer_id := String(payload.get("id", "")).strip_edges()
				if action != "clear" and seen_stage_layers.has(layer_id):
					return {"valid": false, "error": "duplicate stage layer '%s'" % layer_id, "line": int(operation_lines[index])}
				if action == "clear":
					for prior_value: Variant in stage_operations:
						var prior: Dictionary = prior_value
						if String(prior.get("action", "")) != "clear":
							return {"valid": false, "error": "stage clear conflicts with another Stage sibling", "line": int(operation_lines[index])}
				else:
					for prior_value: Variant in stage_operations:
						var prior: Dictionary = prior_value
						if String(prior.get("action", "")) == "clear":
							return {"valid": false, "error": "stage clear conflicts with another Stage sibling", "line": int(operation_lines[index])}
					seen_stage_layers[layer_id] = true
				stage_operations.append(payload.duplicate(true))
			"dialogue_avatar":
				var avatar_keys := payload.keys()
				avatar_keys.sort()
				if avatar_keys != EXACT_DIALOGUE_AVATAR_PAYLOAD_KEYS:
					return {"valid": false, "error": "dialogue avatar payload must use the canonical four-field schema", "line": int(operation_lines[index])}
				if saw_dialogue_avatar:
					return {"valid": false, "error": "duplicate dialogue avatar channel", "line": int(operation_lines[index])}
				if not DialogueAvatarState.validate_operation(payload, false):
					return {"valid": false, "error": "dialogue avatar payload failed canonical validation", "line": int(operation_lines[index])}
				saw_dialogue_avatar = true
				avatar_line = int(operation_lines[index])
				avatar_operations.append(payload.duplicate(true))
			"dialogue_visibility":
				var visibility_keys := payload.keys()
				visibility_keys.sort()
				if visibility_keys != EXACT_VISIBILITY_PAYLOAD_KEYS:
					return {"valid": false, "error": "dialogue visibility payload must use the canonical four-field schema", "line": int(operation_lines[index])}
				if not DialogueVisibilityState.validate_operation(payload, false):
					return {"valid": false, "error": "dialogue visibility payload failed canonical validation", "line": int(operation_lines[index])}
				var target := String(payload.get("target", ""))
				if seen_targets.has(target):
					return {"valid": false, "error": "duplicate dialogue visibility target '%s'" % target, "line": int(operation_lines[index])}
				seen_targets[target] = true
				visibility_operations.append(payload.duplicate(true))
			"dialogue_clear":
				var clear_keys := payload.keys()
				clear_keys.sort()
				if clear_keys != EXACT_DIALOGUE_CLEAR_PAYLOAD_KEYS:
					return {"valid": false, "error": "dialogue clear payload must use the canonical one-field schema", "line": int(operation_lines[index])}
				if saw_dialogue_clear or payload.get("scope", null) != "page":
					return {"valid": false, "error": "invalid or duplicate dialogue clear channel", "line": int(operation_lines[index])}
				saw_dialogue_clear = true
			"chapter_indicator":
				var chapter_keys := payload.keys()
				chapter_keys.sort()
				if chapter_keys != EXACT_CHAPTER_INDICATOR_PAYLOAD_KEYS:
					return {"valid": false, "error": "chapter indicator payload must use the canonical three-field schema", "line": int(operation_lines[index])}
				if saw_chapter_indicator:
					return {"valid": false, "error": "duplicate chapter indicator channel", "line": int(operation_lines[index])}
				var action := String(payload.get("action", ""))
				var transition := String(payload.get("transition", ""))
				var duration_value: Variant = payload.get("duration", null)
				if (
					action not in ["show", "hide"]
					or transition not in ["cut", "fade"]
					or not duration_value is float
					or not is_finite(float(duration_value))
					or float(duration_value) < 0.0
					or (transition == "cut" and float(duration_value) != 0.0)
				):
					return {"valid": false, "error": "chapter indicator payload failed canonical validation", "line": int(operation_lines[index])}
				saw_chapter_indicator = true
			"loop_se":
				var loop_se_keys := payload.keys()
				loop_se_keys.sort()
				if loop_se_keys != EXACT_LOOP_SE_PAYLOAD_KEYS:
					return {"valid": false, "error": "loop-SE payload must use the canonical six-field schema", "line": int(operation_lines[index])}
				if not LoopSeChannelState.validate_operation(payload, false):
					return {"valid": false, "error": "loop-SE payload failed canonical validation", "line": int(operation_lines[index])}
				var channel_id := String(payload.get("channel", ""))
				if seen_loop_se_channels.has(channel_id):
					return {"valid": false, "error": "duplicate loop-SE channel '%s'" % channel_id, "line": int(operation_lines[index])}
				seen_loop_se_channels[channel_id] = true
				loop_se_operations.append(payload.duplicate(true))
			"bgm":
				var bgm_keys := payload.keys()
				bgm_keys.sort()
				if bgm_keys != EXACT_BGM_PAYLOAD_KEYS:
					return {"valid": false, "error": "BGM payload must use the canonical seven-field schema", "line": int(operation_lines[index])}
				if not BgmChannelState.validate_operation(payload, false):
					return {"valid": false, "error": "BGM payload failed canonical validation", "line": int(operation_lines[index])}
				if saw_bgm:
					return {"valid": false, "error": "duplicate BGM channel", "line": int(operation_lines[index])}
				saw_bgm = true
				bgm_line = int(operation_lines[index])
				bgm_operations.append(payload.duplicate(true))
			"movie":
				var movie_keys := payload.keys()
				movie_keys.sort()
				if movie_keys != EXACT_MOVIE_PAYLOAD_KEYS:
					return {"valid": false, "error": "movie payload must use the canonical four-field schema", "line": int(operation_lines[index])}
				if not MovieChannelState.validate_operation(payload, false):
					return {"valid": false, "error": "movie payload failed canonical validation", "line": int(operation_lines[index])}
				if saw_movie:
					return {"valid": false, "error": "duplicate movie channel", "line": int(operation_lines[index])}
				if policy == "join" and bool(payload["loop"]):
					return {"valid": false, "error": "looped movie requires fire_and_forget policy", "line": int(operation_lines[index])}
				saw_movie = true
				movie_line = int(operation_lines[index])
				movie_operations.append(payload.duplicate(true))
			_:
				return {"valid": false, "error": "unsupported presentation operation kind '%s'" % kind, "line": int(operation_lines[index])}
		canonical_operations.append({
			"kind": kind,
			"payload": payload.duplicate(true),
		})

	var stage_before := (
		_presentation_state.stage_layers.duplicate(true)
		if _presentation_state != null
		else {}
	)
	var visibility_before := (
		_presentation_state.dialogue_visibility.duplicate(true)
		if _presentation_state != null
		else DialogueVisibilityState.default_state()
	)
	var stage_target := StageLayerState.reduce(stage_before, stage_operations, false)
	var visibility_target := DialogueVisibilityState.reduce(visibility_before, visibility_operations, false)
	var avatar_before := (
		_presentation_state.dialogue_avatar.duplicate(true)
		if _presentation_state != null
		else DialogueAvatarState.default_state()
	)
	if (
		not avatar_operations.is_empty()
		and not DialogueAvatarState.operation_is_supported(
			avatar_before, avatar_operations[0])
	):
		return {
			"valid": false,
			"error": "dialogue avatar action is not valid for the current state",
			"line": avatar_line,
		}
	var avatar_target := DialogueAvatarState.reduce(
		avatar_before, avatar_operations, false)
	var loop_se_before := (
		_presentation_state.loop_se_channels.duplicate(true)
		if _presentation_state != null
		else {}
	)
	var loop_se_target := LoopSeChannelState.reduce(
		loop_se_before, loop_se_operations, false)
	var bgm_before := (
		_presentation_state.current_bgm.duplicate(true)
		if _presentation_state != null
		else {}
	)
	if (
		not bgm_operations.is_empty()
		and not BgmChannelState.operation_is_supported(
			bgm_before, bgm_operations[0])
	):
		return {
			"valid": false,
			"error": "BGM lifecycle action requires an active track",
			"line": bgm_line,
		}
	return {
		"valid": true,
		"policy": policy,
		"operations": canonical_operations,
		"before_stage": stage_before,
		"before_visibility": visibility_before,
		"before_dialogue_avatar": avatar_before,
		"target_stage": stage_target,
		"target_visibility": visibility_target,
		"target_dialogue_avatar": avatar_target,
		"before_loop_se": loop_se_before,
		"target_loop_se": loop_se_target,
		"before_bgm": bgm_before,
		"movie_line": movie_line,
		"no_work": (
			stage_operations.is_empty()
			and stage_target == stage_before
			and visibility_target == visibility_before
			and loop_se_operations.is_empty()
			and bgm_operations.is_empty()
			and movie_operations.is_empty()
			and visibility_operations.is_empty()
			and avatar_operations.is_empty()
			and not saw_dialogue_clear
			and not saw_chapter_indicator
		),
	}


func _fail_context(
	data: CommandData,
	context: ScenarioContext,
	message: String,
	line_override: int = -1,
) -> void:
	var source := _source(data, context)
	if line_override >= 0:
		source["line"] = line_override
	push_error("%s PresentationBatchHandler: %s" % [
		_source_label(source),
		message,
	])
	if context != null and context.is_runtime_owner_current():
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
