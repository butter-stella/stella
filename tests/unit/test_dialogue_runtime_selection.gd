extends GutTest
## Runtime dialogue presentation selection and static-monologue boundaries.

var _bus: Node
var _connections: Array[Callable] = []


func before_each() -> void:
	_bus = get_tree().root.get_node("SignalBus")


func after_each() -> void:
	for callback in _connections:
		if _bus.show_dialogue.is_connected(callback):
			_bus.show_dialogue.disconnect(callback)
	_connections.clear()


func _capture_dialogue(target: Array) -> void:
	var callback := func(_character, _segments, mode):
		target.append({
			"mode": mode,
			"profile": _bus.current_dialogue_presentation_profile(),
			"provenance": _bus.current_dialogue_presentation_provenance(),
			"declarative": _bus.current_dialogue_uses_declarative_presentation(),
		})
	_connections.append(callback)
	_bus.show_dialogue.connect(callback)


func _command(params: Dictionary) -> CommandData:
	var command := CommandData.new()
	command.type = "dialogue"
	command.params = params
	return command


func test_dialogue_handler_resolves_runtime_profile_and_provenance_by_name() -> void:
	var scenario := ScenarioData.new()
	scenario.dialogue_profiles["novel"] = {"line_spacing": 6}
	scenario.dialogue_profile_provenance["novel"] = {
		"kind": "stla",
		"profile_name": "novel",
		"source_path": "res://story/main.stla",
		"field_lines": {"line_spacing": 7},
	}
	var context := ScenarioContext.new(scenario)
	context.apply_dialogue_mode_events([{
		"action": "select_mode",
		"mode": "nvl",
		"profile_name": "novel",
	}])
	var received: Array = []
	_capture_dialogue(received)

	_bus.advance_requested.emit.call_deferred()
	await DialogueHandler.new().execute(_command({
		"text": "runtime",
		"presentation_from_context": true,
	}), context)

	assert_eq(received.size(), 1)
	assert_eq(received[0]["mode"], "nvl")
	assert_eq(received[0]["profile"], {"line_spacing": 6})
	assert_eq(received[0]["provenance"].get("profile_name"), "novel")
	assert_eq(received[0]["provenance"].get("field_lines", {}).get(
		"line_spacing"), 7)
	assert_true(received[0]["declarative"])


func test_monologue_is_static_without_inheriting_or_mutating_runtime_profile() -> void:
	var scenario := ScenarioData.new()
	scenario.dialogue_profiles["novel"] = {"line_spacing": 6}
	var context := ScenarioContext.new(scenario)
	context.apply_dialogue_mode_events([{
		"action": "select_mode",
		"mode": "nvl",
		"profile_name": "novel",
	}])
	var received: Array = []
	_capture_dialogue(received)

	_bus.advance_requested.emit.call_deferred()
	await DialogueHandler.new().execute(_command({
		"text": "thought",
		"mode": "monologue",
	}), context)
	assert_eq(received[0], {
		"mode": "monologue",
		"profile": {},
		"provenance": {},
		"declarative": false,
	})
	assert_eq(context.current_dialogue_mode, "nvl")
	assert_eq(context.current_dialogue_profile_name, "novel")

	_bus.advance_requested.emit.call_deferred()
	await DialogueHandler.new().execute(_command({
		"text": "after",
		"presentation_from_context": true,
	}), context)
	assert_eq(received[1]["mode"], "nvl")
	assert_eq(received[1]["profile"], {"line_spacing": 6})
	assert_true(received[1]["declarative"])


func test_static_command_clears_stale_runtime_profile_before_context_resumes() -> void:
	var scenario := ScenarioData.new()
	scenario.dialogue_profiles["novel"] = {"line_spacing": 6}
	var context := ScenarioContext.new(scenario)
	context.apply_dialogue_mode_events([{
		"action": "select_mode",
		"mode": "nvl",
		"profile_name": "novel",
	}])
	var received: Array = []
	_capture_dialogue(received)

	_bus.advance_requested.emit.call_deferred()
	await DialogueHandler.new().execute(_command({
		"text": "static",
		"mode": "overlay",
		"presentation_profile": {"line_spacing": 9},
		"declarative_presentation": true,
	}), context)
	assert_eq(received[0]["profile"], {"line_spacing": 9})
	assert_eq(context.current_dialogue_mode, "overlay")
	assert_eq(context.current_dialogue_profile_name, "")
	assert_false(context.current_dialogue_uses_declarative_presentation)

	_bus.advance_requested.emit.call_deferred()
	await DialogueHandler.new().execute(_command({
		"text": "runtime after static",
		"presentation_from_context": true,
	}), context)
	assert_eq(received[1]["mode"], "overlay")
	assert_eq(received[1]["profile"], {},
		"runtime selection must not resurrect the profile from before static data")
	assert_false(received[1]["declarative"])


func test_legacy_string_mode_sidecar_clears_named_runtime_selection() -> void:
	var scenario := ScenarioData.new()
	scenario.dialogue_profiles["message"] = {"line_spacing": 4}
	var context := ScenarioContext.new(scenario)
	context.apply_dialogue_mode_events([{
		"action": "select_adv",
		"mode": "adv",
		"profile_name": "message",
	}])

	context.apply_dialogue_mode_events(["nvl"])

	assert_eq(context.current_dialogue_mode, "nvl")
	assert_eq(context.current_dialogue_profile_name, "")
	assert_false(context.current_dialogue_uses_declarative_presentation)


func test_mode_only_dictionary_sidecar_clears_named_runtime_selection() -> void:
	var scenario := ScenarioData.new()
	scenario.dialogue_profiles["message"] = {"line_spacing": 4}
	var context := ScenarioContext.new(scenario)
	context.apply_dialogue_mode_events([{
		"action": "select_adv",
		"mode": "adv",
		"profile_name": "message",
	}])

	context.apply_dialogue_mode_events([{"mode": "overlay"}])

	assert_eq(context.current_dialogue_mode, "overlay")
	assert_eq(context.current_dialogue_profile_name, "")
	assert_false(context.current_dialogue_uses_declarative_presentation)
