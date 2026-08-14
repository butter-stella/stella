extends GutTest
## Tests for POC command handlers — verifying signal emission and behavior.


var _registry: CommandRegistry
var _context: ScenarioContext
var _bus: Node
var _read_flags: ReadFlagManager


func before_each():
	_registry = CommandRegistry.new()
	# Create a minimal scenario for context
	var scenario = ScenarioData.new()
	scenario.id = "test"
	var scene = SceneData.new()
	scene.id = "start"
	scenario.scenes.append(scene)
	_context = ScenarioContext.new(scenario)
	_read_flags = ReadFlagManager.new()
	# Get the autoloaded SignalBus
	_bus = get_tree().root.get_node("SignalBus")


func _build_cmd(type: String, params: Dictionary = {}) -> CommandData:
	var cmd = CommandData.new()
	cmd.type = type
	cmd.params = params
	return cmd


func _advance_next_dialogue() -> void:
	_bus.dialogue_requested.connect(
		func(request: DialogueRequest): request.advance(),
		CONNECT_ONE_SHOT,
	)


func _dialogue_is_read(
	scenario_identity: String = "id:test",
	legacy_scenario_id: String = "test",
	scene_id: String = "start",
	command_uid: int = 0,
	legacy_command_index: int = 0,
) -> bool:
	return _read_flags.is_dialogue_read(
		scenario_identity,
		legacy_scenario_id,
		scene_id,
		command_uid,
		legacy_command_index,
	)


# --- DialogueHandler ---

func test_dialogue_handler_emits_signal():
	var handler = DialogueHandler.new(_read_flags)
	var received: Array = []
	_bus.show_dialogue.connect(func(c, segs, m):
		received.append({"character": c, "segments": segs, "mode": m})
	)

	var cmd = _build_cmd("dialogue", {
		"character": "sakura",
		"text": "Hello!",
		"voice": "voice_001",
		"mode": "adv",
	})

	# Complete synchronously from SHOW so an acknowledgement cannot be lost
	# between emission and waiter installation.
	_advance_next_dialogue()
	await handler.execute(cmd, _context)

	assert_eq(received.size(), 1)
	assert_eq(received[0]["character"], "sakura")
	assert_eq(received[0]["segments"].size(), 1)
	assert_eq(received[0]["segments"][0]["text"], "Hello!")
	assert_eq(received[0]["segments"][0]["voice"], "voice_001")
	assert_true(_dialogue_is_read(),
		"normal dialogue completion records the current command")


func test_dialogue_handler_abort_does_not_mark_read() -> void:
	var handler := DialogueHandler.new(_read_flags)
	var cmd := _build_cmd("dialogue", {"text": "Interrupted"})

	_bus.dialogue_requested.connect(
		func(request: DialogueRequest): request.abort(),
		CONNECT_ONE_SHOT,
	)
	await handler.execute(cmd, _context)

	assert_false(_dialogue_is_read(),
		"an aborted dialogue has not advanced and must stay unread")
	assert_true(_context.is_finished,
		"request.abort() cancels the authored command instead of skipping it")


func test_dialogue_commit_precedes_compatibility_advance_notification() -> void:
	var handler := DialogueHandler.new(_read_flags)
	var cmd := _build_cmd("dialogue", {"text": "Committed first"})
	cmd.uid = 17
	var read_during_notification := [false]
	var on_advance := func() -> void:
		read_during_notification[0] = _read_flags.is_dialogue_read(
			"id:test", "test", "start", 17, 0)
	_bus.advance_requested.connect(on_advance)
	_bus.dialogue_requested.connect(
		func(request: DialogueRequest): request.advance(),
		CONNECT_ONE_SHOT,
	)

	await handler.execute(cmd, _context)
	_bus.advance_requested.disconnect(on_advance)

	assert_true(read_during_notification[0],
		"legacy listeners may run only after owner validation and durable commit")


func test_compatibility_listener_reentry_cannot_steal_first_commit() -> void:
	var handler := DialogueHandler.new(_read_flags)
	var first := _build_cmd("dialogue", {"text": "First"})
	first.uid = 20
	var second := _build_cmd("dialogue", {"text": "Second"})
	second.uid = 21
	var requests: Array[DialogueRequest] = []
	var on_request := func(request: DialogueRequest) -> void:
		requests.append(request)
		if requests.size() == 1:
			request.advance()
	var reentered := [false]
	var on_advance := func() -> void:
		if reentered[0]:
			return
		reentered[0] = true
		handler.execute(second, _context)
	_bus.dialogue_requested.connect(on_request)
	_bus.advance_requested.connect(on_advance)

	await handler.execute(first, _context)

	assert_true(_read_flags.is_dialogue_read(
		"id:test", "test", "start", 20, 0))
	assert_eq(requests.size(), 2)
	assert_true(requests[1].get_activation().is_pending())
	requests[1].abort()
	_bus.dialogue_requested.disconnect(on_request)
	_bus.advance_requested.disconnect(on_advance)


func test_dialogue_handler_marks_the_position_captured_before_await() -> void:
	var handler := DialogueHandler.new(_read_flags)
	var cmd := _build_cmd("dialogue", {"text": "Original"})
	var second_scene := SceneData.new()
	second_scene.id = "later"
	_context.scenario_data.scenes.append(second_scene)
	var move_then_advance := func(request: DialogueRequest) -> void:
		_context.current_scene_index = 1
		_context.current_command_index = 7
		request.advance()
	_bus.dialogue_requested.connect(move_then_advance, CONNECT_ONE_SHOT)

	await handler.execute(cmd, _context)

	assert_true(_dialogue_is_read(),
		"the accepted command identity is stable across an awaited signal")
	assert_false(_dialogue_is_read("id:test", "test", "later", 7, 7))


func test_dialogue_handler_ignores_advance_after_context_was_abandoned() -> void:
	var handler := DialogueHandler.new(_read_flags)
	var cmd := _build_cmd("dialogue", {"text": "Abandoned"})
	var abandon_then_advance := func(request: DialogueRequest) -> void:
		_context.is_finished = true
		request.advance()
	_bus.dialogue_requested.connect(abandon_then_advance, CONNECT_ONE_SHOT)

	await handler.execute(cmd, _context)

	assert_false(_dialogue_is_read(),
		"a later scenario's advance cannot complete an abandoned context")


func test_dialogue_handler_context_replacement_aborts_request_before_late_ack() -> void:
	var handler := DialogueHandler.new(_read_flags)
	var engine := ScenarioEngine.new()
	engine.context = _context
	var captured: Array[DialogueRequest] = []
	var replace_context := func(request: DialogueRequest):
		captured.append(request)
		engine.context = ScenarioContext.new(_context.scenario_data)
	_bus.dialogue_requested.connect(replace_context, CONNECT_ONE_SHOT)

	await handler.execute(_build_cmd("dialogue", {"text": "Old"}), _context)

	assert_eq(captured.size(), 1)
	assert_false(captured[0].advance(),
		"a replaced context's request stays aborted after a late ack")
	assert_false(_dialogue_is_read())


func test_global_advance_notification_cannot_complete_concurrent_dialogues() -> void:
	var first_data := ScenarioData.new()
	first_data.id = "first"
	var first_scene := SceneData.new()
	first_scene.id = "start"
	first_data.scenes = [first_scene]
	var second_data := ScenarioData.new()
	second_data.id = "second"
	var second_scene := SceneData.new()
	second_scene.id = "start"
	second_data.scenes = [second_scene]
	var first_context := ScenarioContext.new(first_data)
	var second_context := ScenarioContext.new(second_data)
	var first_command := _build_cmd("dialogue", {"text": "First"})
	first_command.uid = 5
	var second_command := _build_cmd("dialogue", {"text": "Second"})
	second_command.uid = 6
	var requests: Array[DialogueRequest] = []
	var capture := func(request: DialogueRequest): requests.append(request)
	_bus.dialogue_requested.connect(capture)
	var handler := DialogueHandler.new(_read_flags)
	handler.execute(first_command, first_context)
	handler.execute(second_command, second_context)
	assert_eq(requests.size(), 2)

	_bus.advance_requested.emit()
	await get_tree().process_frame
	assert_false(_read_flags.is_dialogue_read(
		"id:first", "first", "start", 5, 0))
	assert_false(_read_flags.is_dialogue_read(
		"id:second", "second", "start", 6, 0))

	assert_true(requests[1].advance())
	await get_tree().process_frame
	assert_false(_read_flags.is_dialogue_read(
		"id:first", "first", "start", 5, 0))
	assert_true(_read_flags.is_dialogue_read(
		"id:second", "second", "start", 6, 0),
		"only the explicitly acknowledged request may commit read state")
	requests[0].abort()
	_bus.dialogue_requested.disconnect(capture)


func test_dialogue_handler_defaults():
	var handler = DialogueHandler.new(_read_flags)
	var received: Array = []
	_bus.show_dialogue.connect(func(_c, segs, m):
		received.append({
			"mode": m,
			"voice": segs[0]["voice"],
			"nvl_page_key": _bus.current_dialogue_nvl_page_key(),
		})
	)

	var cmd = _build_cmd("dialogue", {"text": "Narration"})
	_advance_next_dialogue()
	await handler.execute(cmd, _context)

	assert_eq(received[0]["mode"], "adv")
	assert_eq(received[0]["voice"], "")
	assert_eq(received[0]["nvl_page_key"], "")


func test_dialogue_handler_wraps_single_dialogue_stage_operations():
	var handler = DialogueHandler.new(_read_flags)
	var received: Array = []
	_bus.show_dialogue.connect(func(_c, segments, _m): received.append(segments))
	var stage_ops := [{
		"action": "show",
		"id": "event",
		"properties": {"asset": "stage:flash"},
	}]
	var cmd = _build_cmd("dialogue", {
		"text": "Cue",
		"stage_ops": stage_ops,
	})

	_advance_next_dialogue()
	await handler.execute(cmd, _context)
	stage_ops[0]["properties"]["asset"] = "mutated"

	assert_eq(
		received[0][0]["stage_ops"][0]["properties"]["asset"],
		"stage:flash",
	)


func test_dialogue_handler_passes_segments_through():
	var handler = DialogueHandler.new(_read_flags)
	var received: Array = []
	_bus.show_dialogue.connect(func(_c, segs, _m): received.append(segs))

	var segments = [
		{"text": "一", "voice": "v1", "stage_ops": []},
		{"text": "二", "voice": "v2", "stage_ops": []},
	]
	var cmd = _build_cmd("dialogue", {
		"character": "sakura",
		"text": "一二",
		"voice": "v1",
		"mode": "adv",
		"segments": segments,
	})

	_advance_next_dialogue()
	await handler.execute(cmd, _context)

	assert_eq(received.size(), 1)
	assert_eq(received[0].size(), 2)
	assert_eq(received[0][0]["voice"], "v1")
	assert_eq(received[0][1]["stage_ops"], [])


func test_dialogue_handler_scopes_compiled_presentation_without_changing_signal_shape():
	var handler = DialogueHandler.new(_read_flags)
	var received: Array = []
	_bus.show_dialogue.connect(func(_c, _segments, mode):
			received.append({
				"mode": mode,
				"profile": _bus.current_dialogue_presentation_profile(),
				"provenance": _bus.current_dialogue_presentation_provenance(),
				"declarative": _bus.current_dialogue_uses_declarative_presentation(),
				"nvl_page_key": _bus.current_dialogue_nvl_page_key(),
			})
	)
	var cmd = _build_cmd("dialogue", {
		"text": "Configured",
		"mode": "nvl",
		"declarative_presentation": true,
		"presentation_profile": {"line_spacing": 8},
		"presentation_profile_provenance": {
			"kind": "stla",
			"profile_name": "novel",
			"source_path": "res://story/main.stla",
			"field_lines": {"line_spacing": 4},
		},
	})

	_advance_next_dialogue()
	await handler.execute(cmd, _context)

	assert_eq(received.size(), 1)
	assert_eq(received[0]["mode"], "nvl")
	assert_eq(received[0]["profile"], {"line_spacing": 8})
	assert_eq(received[0]["provenance"].get("profile_name"), "novel")
	assert_eq(received[0]["provenance"].get("source_path"),
		"res://story/main.stla")
	assert_true(received[0]["declarative"])
	var expected_page_key := "%d:1" % _context.get_instance_id()
	assert_eq(received[0]["nvl_page_key"], expected_page_key)
	assert_eq(_bus.current_dialogue_presentation_profile(), {},
		"profile metadata must not leak past synchronous signal dispatch")
	assert_eq(_bus.current_dialogue_nvl_page_key(), "",
		"NVL page metadata must not leak past synchronous signal dispatch")
	assert_eq(_bus.current_dialogue_presentation_provenance(), {},
		"diagnostic provenance must not leak past synchronous signal dispatch")
	assert_false(_context.capture_snapshot().has("presentation_profile_provenance"),
		"diagnostic provenance must not enter scenario save snapshots")


func test_dialogue_handler_keys_nvl_pages_by_runtime_activation() -> void:
	var handler := DialogueHandler.new(_read_flags)
	var page_keys: Array[String] = []
	_bus.show_dialogue.connect(func(_c, _segments, mode):
		if mode == "nvl":
			page_keys.append(_bus.current_dialogue_nvl_page_key())
	)

	for mode in ["nvl", "nvl", "adv", "nvl"]:
		var cmd := _build_cmd("dialogue", {"text": mode, "mode": mode})
		_advance_next_dialogue()
		await handler.execute(cmd, _context)

	var scenario_key := str(_context.get_instance_id())
	assert_eq(page_keys, ["%s:1" % scenario_key, "%s:1" % scenario_key, "%s:2" % scenario_key],
		"repeating NVL keeps a page while leaving and re-entering advances it")


# --- StageLayerHandler ---

func test_stage_layer_handler_emits_canonical_operation_batch():
	var handler = StageLayerHandler.new()
	var received: Array = []
	var callback = func(operations, force_cut):
		received.append([operations.duplicate(true), force_cut])
	_bus.stage_operations_requested.connect(callback)
	var cmd = _build_cmd("stage_layer", {
		"action": "show",
		"id": " hero ",
		"properties": {"asset": "stage:hero"},
		"transition": "fade",
		"duration": 0.25,
	})

	await handler.execute(cmd, _context)

	assert_eq(received.size(), 1)
	assert_eq(received[0][0][0]["id"], "hero")
	assert_eq(received[0][0][0]["properties"]["asset"], "stage:hero")
	assert_eq(received[0][0][0]["transition"], "fade")
	assert_almost_eq(received[0][0][0]["duration"], 0.25, 0.001)
	assert_false(received[0][1])
	_bus.stage_operations_requested.disconnect(callback)


func test_nested_raw_show_does_not_inherit_outer_presentation_metadata() -> void:
	var inner_metadata: Array[Dictionary] = []
	var inner_legacy_metadata: Array[Dictionary] = []
	var outer_metadata_after_inner: Array[Dictionary] = []
	var nested := false
	_bus.show_dialogue.connect(func(character, segments, _mode):
		if character == "outer" and not nested:
			nested = true
			_bus.show_dialogue.emit(
				"inner", [{
					"text": "inner", "voice": "", "expression": "",
				}], "adv")
		elif character == "inner":
			inner_metadata.append(_bus.current_dialogue_metadata(segments))
			inner_legacy_metadata.append(_bus.current_dialogue_metadata())
	)
	# This listener receives the outer callback only after the nested raw emit
	# returns. Payload-keyed lookup must still recover the outer sidecar.
	_bus.show_dialogue.connect(func(character, segments, _mode):
		if character == "outer":
			outer_metadata_after_inner.append(
				_bus.current_dialogue_metadata(segments))
	)

	_bus.emit_show_dialogue(
		"outer",
		[{"text": "outer", "voice": "", "expression": ""}],
		"nvl",
		{"line_spacing": 9},
		true,
		"page:7",
		{"kind": "stla", "profile_name": "outer_profile"},
	)

	assert_eq(inner_metadata, [{}],
		"a raw nested three-argument SHOW must keep legacy empty metadata")
	assert_eq(inner_legacy_metadata, [{}],
		"no-argument getters must not expose the outer wrapper to a raw nested SHOW")
	assert_eq(outer_metadata_after_inner.size(), 1)
	assert_eq(outer_metadata_after_inner[0].get("profile"), {"line_spacing": 9})
	assert_eq(outer_metadata_after_inner[0].get("nvl_page_key"), "page:7")
	assert_eq(outer_metadata_after_inner[0].get("provenance", {}).get(
		"profile_name"), "outer_profile")
	assert_eq(_bus.current_dialogue_metadata(), {},
		"nested dispatch metadata must not leak after the wrapper returns")


func test_wrapper_metadata_survives_listener_mutating_segments() -> void:
	var received_metadata: Array[Dictionary] = []
	_bus.show_dialogue.connect(func(character, segments, _mode):
		if character != "outer":
			return
		segments[0]["text"] = "filtered"
		segments.append({
			"text": "appended", "voice": "", "expression": "",
		})
	)
	_bus.show_dialogue.connect(func(character, segments, _mode):
		if character != "outer":
			return
		received_metadata.append(_bus.current_dialogue_metadata(segments))
	)

	_bus.emit_show_dialogue(
		"outer",
		[{"text": "original", "voice": "", "expression": ""}],
		"nvl",
		{"line_spacing": 11},
		true,
		"page:mutated",
		{"kind": "stla", "profile_name": "mutable_profile"},
	)

	assert_eq(received_metadata.size(), 1)
	assert_eq(received_metadata[0].get("profile"), {"line_spacing": 11},
		"an earlier public listener may filter the mutable segments payload")
	assert_eq(received_metadata[0].get("nvl_page_key"), "page:mutated")
	assert_eq(received_metadata[0].get("provenance", {}).get(
		"profile_name"), "mutable_profile")
	assert_eq(_bus.current_dialogue_metadata(), {},
		"mutated wrapper metadata must still remain synchronous")


func test_mutated_nested_raw_payload_cannot_match_outer_metadata_by_value() -> void:
	var outer_segments := [{
		"text": "outer", "voice": "", "expression": "",
	}]
	var nested_metadata: Array[Dictionary] = []
	var nesting := [false]
	var emit_nested := func(character, _segments, _mode):
		if character != "identity_outer" or nesting[0]:
			return
		nesting[0] = true
		_bus.show_dialogue.emit("identity_inner", [{
			"text": "inner", "voice": "", "expression": "",
		}], "nvl")
		nesting[0] = false
	var mutate_nested := func(character, segments, _mode):
		if character == "identity_inner":
			segments[0]["text"] = "outer"
	var capture_nested := func(character, segments, _mode):
		if character == "identity_inner":
			nested_metadata.append(_bus.current_dialogue_metadata(segments))
	_bus.show_dialogue.connect(emit_nested)
	_bus.show_dialogue.connect(mutate_nested)
	_bus.show_dialogue.connect(capture_nested)

	_bus.emit_show_dialogue(
		"identity_outer",
		outer_segments,
		"nvl",
		{"line_spacing": 13},
		true,
		"page:outer",
		{"kind": "stla", "profile_name": "outer_profile"},
	)

	assert_eq(nested_metadata, [{}],
		"a raw dispatch must not inherit outer metadata after becoming value-equal")
	assert_false(is_same(outer_segments, _bus._last_raw_show_segments),
		"raw dispatch identity, not mutable Array value, owns the guard")
	_bus.show_dialogue.disconnect(emit_nested)
	_bus.show_dialogue.disconnect(mutate_nested)
	_bus.show_dialogue.disconnect(capture_nested)


# --- Context-scoped blocking cancellation ---

func test_context_replacement_cancels_click_wait_connections() -> void:
	var handler := WaitHandler.new()
	var command := _build_cmd("wait", {"mode": "click"})
	var advance_connections := SignalBus.advance_requested.get_connections().size()
	var abort_connections := SignalBus.engine_abort_requested.get_connections().size()
	var engine := ScenarioEngine.new()
	engine.context = _context

	handler.execute(command, _context)
	assert_eq(SignalBus.advance_requested.get_connections().size(),
		advance_connections + 1)
	assert_eq(SignalBus.engine_abort_requested.get_connections().size(),
		abort_connections + 1)
	assert_eq(_context.cancellation_requested.get_connections().size(), 1)

	engine.context = ScenarioContext.new(_context.scenario_data)
	await get_tree().process_frame

	assert_true(_context.is_cancellation_requested())
	assert_eq(SignalBus.advance_requested.get_connections().size(),
		advance_connections,
		"the retired click wait cannot consume a later run's advance")
	assert_eq(SignalBus.engine_abort_requested.get_connections().size(),
		abort_connections)
	assert_eq(_context.cancellation_requested.get_connections().size(), 0)


func test_context_replacement_cancels_timer_wait_before_timeout() -> void:
	var handler := WaitHandler.new()
	var command := _build_cmd("wait", {"mode": "timer", "duration": 10.0})
	var abort_connections := SignalBus.engine_abort_requested.get_connections().size()
	var engine := ScenarioEngine.new()
	engine.context = _context

	handler.execute(command, _context)
	assert_eq(SignalBus.engine_abort_requested.get_connections().size(),
		abort_connections + 1)
	assert_eq(_context.cancellation_requested.get_connections().size(), 1)

	engine.context = ScenarioContext.new(_context.scenario_data)
	await get_tree().process_frame

	assert_true(_context.is_cancellation_requested())
	assert_eq(SignalBus.engine_abort_requested.get_connections().size(),
		abort_connections,
		"a retired timer must release its global abort listener immediately")
	assert_eq(_context.cancellation_requested.get_connections().size(), 0)


func test_context_replacement_cancels_choice_and_rejects_late_selection() -> void:
	_context.variable_store = VariableStore.new()
	var handler := ChoiceHandler.new()
	var command := _build_cmd("choice", {
		"prompt": "Old choice",
		"options": [{
			"id": "old",
			"label": "Old",
			"jump": "must_not_apply",
			"set": {"leaked": "= 1"},
		}],
	})
	var choice_connections := SignalBus.choice_selected.get_connections().size()
	var abort_connections := SignalBus.engine_abort_requested.get_connections().size()
	var engine := ScenarioEngine.new()
	engine.context = _context

	handler.execute(command, _context)
	assert_eq(SignalBus.choice_selected.get_connections().size(),
		choice_connections + 1)
	assert_eq(SignalBus.engine_abort_requested.get_connections().size(),
		abort_connections + 1)
	assert_eq(_context.cancellation_requested.get_connections().size(), 1)

	engine.context = ScenarioContext.new(_context.scenario_data)
	await get_tree().process_frame
	SignalBus.choice_selected.emit("old")
	await get_tree().process_frame

	assert_true(_context.is_cancellation_requested())
	assert_eq(SignalBus.choice_selected.get_connections().size(),
		choice_connections,
		"a retired choice cannot consume a later selection")
	assert_eq(SignalBus.engine_abort_requested.get_connections().size(),
		abort_connections)
	assert_eq(_context.cancellation_requested.get_connections().size(), 0)
	assert_eq(_context.pending_jump, "")
	assert_null(_context.variable_store.get_var("leaked"),
		"a late selection cannot mutate the retired VariableStore")


# --- BgHandler ---

func test_bg_handler_emits_signal():
	var handler = BgHandler.new()
	var received: Array = []
	_bus.bg_changed.connect(func(a, t, d): received.append({"asset": a, "transition": t, "duration": d}))

	var cmd = _build_cmd("bg", {"asset": "bg_school", "transition": "fade", "duration": 0.8})
	await handler.execute(cmd, _context)

	assert_eq(received.size(), 1)
	assert_eq(received[0]["asset"], "bg_school")
	assert_eq(received[0]["transition"], "fade")
	assert_almost_eq(received[0]["duration"], 0.8, 0.001)


func test_bg_handler_defaults():
	var handler = BgHandler.new()
	var received: Array = []
	_bus.bg_changed.connect(func(a, t, d): received.append({"transition": t, "duration": d}))

	var cmd = _build_cmd("bg", {"asset": "bg_school"})
	await handler.execute(cmd, _context)

	assert_eq(received[0]["transition"], "fade")
	assert_almost_eq(received[0]["duration"], 0.5, 0.001)


# --- JumpHandler ---

func test_jump_handler_sets_pending_jump():
	var handler = JumpHandler.new()
	var cmd = _build_cmd("jump", {"target": "ending"})
	await handler.execute(cmd, _context)
	assert_eq(_context.pending_jump, "ending")


# --- SetHandler ---

func test_set_handler_assigns_variable():
	var store = VariableStore.new()
	_context.variable_store = store
	var handler = SetHandler.new()

	var cmd = _build_cmd("set", {"var": "talked", "value": true})
	await handler.execute(cmd, _context)

	assert_true(store.get_var("talked"))


func test_set_handler_increment():
	var store = VariableStore.new()
	store.set_var("score", 10)
	_context.variable_store = store
	var handler = SetHandler.new()

	var cmd = _build_cmd("set", {"var": "score", "value": 5, "op": "+="})
	await handler.execute(cmd, _context)

	assert_eq(store.get_var("score"), 15)


# --- ConditionHandler ---

func test_condition_handler_jumps_to_then():
	var store = VariableStore.new()
	store.set_var("affection", 10)
	_context.variable_store = store
	var handler = ConditionHandler.new()

	var cmd = _build_cmd("condition", {"if": "affection >= 10", "then_jump": "good_end", "else_jump": "bad_end"})
	await handler.execute(cmd, _context)

	assert_eq(_context.pending_jump, "good_end")


func test_condition_handler_jumps_to_else():
	var store = VariableStore.new()
	store.set_var("affection", 5)
	_context.variable_store = store
	var handler = ConditionHandler.new()

	var cmd = _build_cmd("condition", {"if": "affection >= 10", "then_jump": "good_end", "else_jump": "bad_end"})
	await handler.execute(cmd, _context)

	assert_eq(_context.pending_jump, "bad_end")


func test_condition_handler_applies_only_the_selected_branch_mode_events():
	var store := VariableStore.new()
	store.set_var("flag", false)
	_context.variable_store = store
	_context.current_dialogue_mode = "nvl"
	_context.nvl_page_epoch = 4
	var handler := ConditionHandler.new()
	var cmd := _build_cmd("condition", {
		"if": "flag",
		"then_jump": "then_scene",
		"else_jump": "else_scene",
	})
	cmd.dialogue_mode_events_on_true_branch.assign(["adv", "nvl", "adv", "nvl"])
	cmd.dialogue_mode_events_on_false_branch.assign(["adv", "nvl"])

	await handler.execute(cmd, _context)

	assert_eq(_context.pending_jump, "else_scene")
	assert_eq(_context.current_dialogue_mode, "nvl")
	assert_eq(_context.nvl_page_epoch, 5,
		"only the selected false edge may leave and re-enter NVL")
