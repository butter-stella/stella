extends GutTest
## Canonical DSL and exact timer/input/cancellation ownership for issue #163.


const SOURCE_PATH := "res://synthetic/skippable_wait.stla"


class ManualTimer extends RefCounted:
	signal timeout()


class ManualWaitHandler extends WaitHandler:
	var timers: Array[ManualTimer] = []

	func _init(skip_controller: SkipController = null) -> void:
		super(skip_controller)

	func _create_timer(_duration: float) -> Variant:
		var timer := ManualTimer.new()
		timers.append(timer)
		return timer


var _contexts: Array[ScenarioContext] = []


func after_each() -> void:
	for context in _contexts:
		if context != null and not context.is_cancellation_requested():
			context.request_cancellation()
	_contexts.clear()
	await get_tree().process_frame


func test_parser_keeps_plain_timed_wait_non_skippable_by_default() -> void:
	var command := _parse_wait("@wait 1.5")
	assert_not_null(command)
	assert_eq(command.params, {
		"duration": 1.5,
		"mode": "timer",
		"skippable": false,
	})


func test_parser_canonicalizes_explicit_skippable_modes() -> void:
	var skippable := _parse_wait("@wait 0.25 skippable=true")
	var fixed := _parse_wait("@wait 0.25 skippable=false")
	assert_true(skippable.get_bool("skippable"))
	assert_false(fixed.get_bool("skippable"))
	assert_eq(skippable.get_string("mode"), "timer")
	assert_eq(fixed.get_string("mode"), "timer")


func test_skippable_changes_semantic_identity_while_explicit_false_is_canonical() -> void:
	var default_wait := _parse_source("@wait 0.25")
	var explicit_false := _parse_source("@wait 0.25 skippable=false")
	var explicit_true := _parse_source("@wait 0.25 skippable=true")
	assert_eq(default_wait.content_fingerprint, explicit_false.content_fingerprint)
	assert_ne(default_wait.content_fingerprint, explicit_true.content_fingerprint,
		"changing authored player-skip behavior must invalidate saved/read identity")


func test_parser_keeps_click_as_a_distinct_option_free_mode() -> void:
	var command := _parse_wait("@wait click")
	assert_not_null(command)
	assert_eq(command.params, {"mode": "click"})


func test_public_example_parses_to_the_three_canonical_wait_modes() -> void:
	var file := FileAccess.open(
		"res://examples/demo/scenarios/skippable_wait.stla", FileAccess.READ)
	assert_not_null(file)
	if file == null:
		return
	var data := DslParser.parse(
		DslLexer.tokenize(file.get_as_text()),
		"skippable_wait_example",
		"res://examples/demo/scenarios/skippable_wait.stla",
	)
	file.close()
	assert_eq(data.diagnostics, [])
	var waits: Array[CommandData] = []
	for command: CommandData in data.scenes[0].commands:
		if command.type == "wait":
			waits.append(command)
	assert_eq(waits.size(), 3)
	assert_eq(waits[0].params, {
		"duration": 0.5,
		"mode": "timer",
		"skippable": false,
	})
	assert_true(waits[1].get_bool("skippable"))
	assert_eq(waits[2].params, {"mode": "click"})


func test_parser_rejects_invalid_wait_forms_at_the_source_line() -> void:
	var cases := [
		{"line": "@wait", "message": "requires a duration or click"},
		{"line": "@wait click skippable=true", "message": "does not accept options"},
		{"line": "@wait later", "message": "duration must be finite"},
		{"line": "@wait -0.1", "message": "duration must be finite"},
		{"line": "@wait INF", "message": "duration must be finite"},
		{"line": "@wait 1 NaN", "message": "use skippable=true|false"},
		{"line": "@wait 1 canskip=true", "message": "unknown @wait option 'canskip'"},
		{"line": "@wait 1 policy=join", "message": "unknown @wait option 'policy'"},
		{"line": "@wait 1 Skippable=true", "message": "unknown @wait option 'Skippable'"},
		{"line": "@wait 1 skippable=yes", "message": "must be true or false"},
		{
			"line": "@wait 1 skippable=true skippable=false",
			"message": "duplicate @wait option 'skippable'",
		},
	]
	for case in cases:
		var data := _parse_source(String(case["line"]))
		assert_true(data.scenes[0].commands.is_empty(), case["line"])
		var diagnostic := _find_diagnostic(data, String(case["message"]))
		assert_false(diagnostic.is_empty(), case["line"])
		assert_eq(diagnostic.get("line"), 3, case["line"])
		assert_true(
			String(diagnostic.get("message", "")).contains("%s:3" % SOURCE_PATH),
			case["line"],
		)


func test_timer_completion_releases_every_listener() -> void:
	var handler := ManualWaitHandler.new()
	var context := _context()
	var completed := [false]
	var before := _connection_counts(context, null)
	_run_wait(handler, _timer_command(false), context, completed)
	assert_eq(_connection_counts(context, null), {
		"abort": before["abort"] + 1,
		"advance": before["advance"],
		"cancel": before["cancel"] + 1,
		"skip": 0,
	})

	handler.timers[0].timeout.emit()
	assert_true(completed[0])
	assert_eq(_connection_counts(context, null), before)


func test_skippable_wait_ends_on_one_advance_and_retires_its_timer() -> void:
	var handler := ManualWaitHandler.new()
	var context := _context()
	var completed := [false]
	var before := _connection_counts(context, null)
	_run_wait(handler, _timer_command(true), context, completed)
	assert_eq(SignalBus.advance_requested.get_connections().size(), before["advance"] + 1)

	SignalBus.emit_advance_requested()
	assert_true(completed[0])
	assert_eq(_connection_counts(context, null), before)
	handler.timers[0].timeout.emit()
	assert_true(completed[0], "the retired timer has no continuation")


func test_non_skippable_wait_ignores_normal_advance_and_skip() -> void:
	var skip := SkipController.new()
	var handler := ManualWaitHandler.new(skip)
	var context := _context()
	var completed := [false]
	var before := _connection_counts(context, skip)
	_run_wait(handler, _timer_command(false), context, completed)
	assert_eq(SignalBus.advance_requested.get_connections().size(), before["advance"])
	assert_eq(skip.active_changed.get_connections().size(), before["skip"])

	SignalBus.emit_advance_requested()
	skip.is_active = true
	assert_false(completed[0])
	handler.timers[0].timeout.emit()
	assert_true(completed[0])
	assert_eq(_connection_counts(context, skip), before)


func test_skip_activation_and_persistent_skip_complete_only_skippable_waits() -> void:
	var skip := SkipController.new()
	var handler := ManualWaitHandler.new(skip)
	var context := _context()
	var completed := [false]
	_run_wait(handler, _timer_command(true), context, completed)
	assert_false(completed[0])

	skip.is_active = true
	assert_true(completed[0])
	assert_eq(handler.timers.size(), 1)

	var immediate := [false]
	_run_wait(handler, _timer_command(true), context, immediate)
	assert_true(immediate[0], "persistent Skip cuts a newly reached skippable wait")
	assert_eq(handler.timers.size(), 1, "no timer is allocated for persistent Skip")


func test_same_advance_dispatch_cannot_complete_a_chained_wait() -> void:
	var handler := ManualWaitHandler.new()
	var context := _context()
	var first_done := [false]
	var second_done := [false]
	var run_both := func() -> void:
		await handler.execute(_timer_command(true), context)
		first_done[0] = true
		await handler.execute(_timer_command(true), context)
		second_done[0] = true
	run_both.call()

	SignalBus.emit_advance_requested()
	assert_true(first_done[0])
	assert_false(second_done[0], "the old signal tail cannot claim the new owner")
	SignalBus.emit_advance_requested()
	assert_true(second_done[0])


func test_old_timer_cannot_complete_the_next_wait() -> void:
	var handler := ManualWaitHandler.new()
	var context := _context()
	var first_done := [false]
	var second_done := [false]
	var run_both := func() -> void:
		await handler.execute(_timer_command(true), context)
		first_done[0] = true
		await handler.execute(_timer_command(true), context)
		second_done[0] = true
	run_both.call()

	SignalBus.emit_advance_requested()
	assert_true(first_done[0])
	assert_eq(handler.timers.size(), 2)
	handler.timers[0].timeout.emit()
	assert_false(second_done[0], "a retired timer cannot advance a fresh command")
	handler.timers[1].timeout.emit()
	assert_true(second_done[0])


func test_context_cancellation_releases_timer_advance_skip_and_abort_connections() -> void:
	var skip := SkipController.new()
	var handler := ManualWaitHandler.new(skip)
	var context := _context()
	var completed := [false]
	var before := _connection_counts(context, skip)
	_run_wait(handler, _timer_command(true), context, completed)

	context.request_cancellation()
	assert_true(completed[0], "cancellation promptly unwinds the handler")
	assert_eq(_connection_counts(context, skip), before)
	SignalBus.emit_advance_requested()
	handler.timers[0].timeout.emit()
	assert_true(context.is_cancellation_requested())


func test_global_abort_cancels_context_and_releases_the_exact_wait() -> void:
	var handler := ManualWaitHandler.new()
	var context := _context()
	var completed := [false]
	var before := _connection_counts(context, null)
	_run_wait(handler, _timer_command(true), context, completed)

	SignalBus.engine_abort_requested.emit()
	assert_true(completed[0])
	assert_true(context.is_cancellation_requested())
	assert_eq(_connection_counts(context, null), before)


func test_auto_state_does_not_reclassify_authored_wait_ownership() -> void:
	var auto := AutoPlayController.new()
	var handler := ManualWaitHandler.new()
	var context := _context()
	var completed := [false]
	auto.is_active = true
	_run_wait(handler, _timer_command(true), context, completed)
	assert_false(completed[0], "Auto is not normal player advance or persistent Skip")
	auto.is_active = false
	assert_false(completed[0])
	handler.timers[0].timeout.emit()
	assert_true(completed[0])


func test_runtime_fail_closes_noncanonical_payload_with_source_location() -> void:
	var handler := ManualWaitHandler.new()
	var context := _context()
	context.scenario_data.source_path = SOURCE_PATH
	var command := _timer_command(true)
	command.declared_line = 17
	command.params["canskip"] = true

	await handler.execute(command, context)
	assert_push_error(SOURCE_PATH + ":17")
	assert_true(context.is_finished)
	assert_eq(handler.timers.size(), 0)


func _parse_source(wait_line: String) -> ScenarioData:
	return DslParser.parse(
		DslLexer.tokenize("@chapter c\n@scene s\n%s\n" % wait_line),
		"wait_test",
		SOURCE_PATH,
	)


func _parse_wait(wait_line: String) -> CommandData:
	var data := _parse_source(wait_line)
	assert_eq(data.diagnostics, [])
	return data.scenes[0].commands[0] if not data.scenes[0].commands.is_empty() else null


func _find_diagnostic(data: ScenarioData, text: String) -> Dictionary:
	for diagnostic: Dictionary in data.diagnostics:
		if String(diagnostic.get("message", "")).contains(text):
			return diagnostic
	return {}


func _context() -> ScenarioContext:
	var scenario := ScenarioData.new()
	scenario.id = "wait_test"
	var context := ScenarioContext.new(scenario)
	_contexts.append(context)
	return context


func _timer_command(skippable: bool) -> CommandData:
	var command := CommandData.new()
	command.type = "wait"
	command.params = {
		"duration": 30.0,
		"mode": "timer",
		"skippable": skippable,
	}
	return command


func _run_wait(
	handler: WaitHandler,
	command: CommandData,
	context: ScenarioContext,
	completed: Array,
) -> void:
	var run := func() -> void:
		await handler.execute(command, context)
		completed[0] = true
	run.call()


func _connection_counts(
	context: ScenarioContext,
	skip: SkipController,
) -> Dictionary:
	return {
		"abort": SignalBus.engine_abort_requested.get_connections().size(),
		"advance": SignalBus.advance_requested.get_connections().size(),
		"cancel": context.cancellation_requested.get_connections().size(),
		"skip": skip.active_changed.get_connections().size() if skip != null else 0,
	}
