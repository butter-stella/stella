## Main scenario engine — loads and executes scenario data.
## Dispatches commands to registered handlers via CommandRegistry.
class_name ScenarioEngine extends RefCounted

signal scenario_started(scenario_id: String)
signal scenario_ended(scenario_id: String)
signal scene_changed(scene_id: String)
signal command_executed(command_data: CommandData)

var _context_owner_state: Dictionary = {}
var context: ScenarioContext:
	set(value):
		if context == value:
			return
		_discard_run_suspension_state()
		var previous_context := context
		if not _context_owner_state.is_empty():
			_context_owner_state["current"] = false
		if previous_context != null:
			previous_context.is_finished = true
		context = value
		_context_owner_state = {"current": context != null}
		if context != null:
			context.bind_runtime_owner(_context_owner_state)
		# Resolve the old waiter only after the new property value is visible. Its
		# synchronous continuation then observes both ownership guards as stale.
		# ScenarioContext is the execution-generation token, so this one request
		# cancels dialogue, wait, choice, and extension handlers that joined it.
		if previous_context != null:
			previous_context.request_cancellation()
var registry: CommandRegistry
var _run_generation: int = 0
var _emitting_scenario_end_generation: int = -1
var _emitting_scenario_end_context: ScenarioContext = null
var _run_suspension_token: RefCounted
var _run_suspension_context: ScenarioContext
var _run_suspension_previous_generation: int = -1
var _run_suspension_generation: int = -1
var _run_suspension_retired: bool = false


func stop() -> void:
	_set_context_execution_owner(false)
	_advance_run_generation()
	if context != null:
		context.request_cancellation()


## Invalidate synchronous or suspended control flow while retaining the active
## context snapshot. Runtime calls this only after a replacement navigation has
## passed side-effect-free validation; final detachment happens after the new
## scene is confirmed.
func invalidate_current_run() -> void:
	_set_context_execution_owner(false)
	_advance_run_generation()


## Temporarily make the current run lose ownership before a SceneTree request
## can synchronously remove scene-owned presenters. The opaque token is a
## single-use compare-and-swap capability: it can restore only the exact
## retained Context and generation, and any nested run mutation invalidates it.
func suspend_current_run() -> RefCounted:
	_discard_run_suspension_state()
	if context == null:
		return null
	var token := RefCounted.new()
	_run_suspension_token = token
	_run_suspension_context = context
	_run_suspension_previous_generation = _run_generation
	_run_generation += 1
	_run_suspension_generation = _run_generation
	_run_suspension_retired = false
	_set_context_execution_owner(false)
	return token


## Resume the original coroutine only when nothing changed after suspension.
## A caller that woke the suspended command must discard instead and start one
## fresh run at the unchanged cursor; resume and run are mutually exclusive.
func resume_suspended_run(token: RefCounted) -> bool:
	if (
		token == null
		or token != _run_suspension_token
		or _run_suspension_retired
		or context != _run_suspension_context
		or _run_generation != _run_suspension_generation
	):
		return false
	var previous_generation := _run_suspension_previous_generation
	_set_context_execution_owner(true)
	_discard_run_suspension_state()
	_run_generation = previous_generation
	return true


## Permanently retire one exact suspension without reviving its old coroutine.
func discard_suspended_run(token: RefCounted) -> bool:
	if (
		token == null
		or token != _run_suspension_token
		or _run_suspension_retired
		or context != _run_suspension_context
		or _run_generation != _run_suspension_generation
	):
		return false
	# The original coroutine stays retired and Context execution ownership stays
	# revoked. Keep the exact token as a one-shot capability so a rejected,
	# already-accepted SceneTree handoff can reactivate this Context for one fresh
	# run without reviving the old generation.
	_run_suspension_retired = true
	context.retire_runtime_execution_session()
	# Session retirement is synchronously reentrant (choice_hide, dialogue abort,
	# extension cancellation listeners). A nested owner may replace Context or
	# consume this capability; never report acceptance for a stale token.
	return (
		token == _run_suspension_token
		and _run_suspension_retired
		and context == _run_suspension_context
		and _run_generation == _run_suspension_generation
	)


## Reactivate a permanently retired suspension for a fresh run. This does not
## restore the old run generation; callers must invoke run() exactly once after
## a successful CAS (or omit run for an already-finished retained Context).
func reactivate_retired_run(token: RefCounted) -> bool:
	if (
		token == null
		or token != _run_suspension_token
		or not _run_suspension_retired
		or context != _run_suspension_context
		or _run_generation != _run_suspension_generation
	):
		return false
	# Bind a new owner dictionary rather than reviving the retired session's
	# shared token. All old waiter callbacks observed the old dictionary as false
	# while the session-scoped cancellation signal drained them.
	_context_owner_state = {"current": true}
	context.bind_runtime_owner(_context_owner_state)
	_discard_run_suspension_state()
	return true


## Permanently abandon an accepted handoff's reactivation capability. Context
## replacement normally does this through its setter; Runtime uses the explicit
## form when a terminal transaction retains no execution owner.
func discard_retired_run(token: RefCounted) -> bool:
	if (
		token == null
		or token != _run_suspension_token
		or not _run_suspension_retired
	):
		return false
	_discard_run_suspension_state()
	return true


func _advance_run_generation() -> void:
	_discard_run_suspension_state()
	_run_generation += 1


func _discard_run_suspension_state() -> void:
	_run_suspension_token = null
	_run_suspension_context = null
	_run_suspension_previous_generation = -1
	_run_suspension_generation = -1
	_run_suspension_retired = false


func _set_context_execution_owner(current: bool) -> void:
	if not _context_owner_state.is_empty():
		_context_owner_state["current"] = current


## Detach and invalidate the active run without reporting normal completion.
## Runtime navigation and test isolation use this before waking abortable
## handlers so no suspended continuation can emit lifecycle events afterward.
func cancel_current_run() -> ScenarioContext:
	_advance_run_generation()
	var old_context := context
	context = null
	if old_context != null:
		old_context.is_finished = true
	return old_context


func replace_context(new_context: ScenarioContext) -> ScenarioContext:
	_advance_run_generation()
	var old_context := context
	if old_context != null:
		old_context.is_finished = true
	context = new_context
	return old_context


## True only while this engine is synchronously emitting scenario_ended for the
## context and run generation that still own the engine. Signal consumers use
## this to ignore forged or stale lifecycle emissions.
func is_emitting_active_scenario_end() -> bool:
	return (
		_emitting_scenario_end_generation == _run_generation
		and _emitting_scenario_end_context != null
		and _emitting_scenario_end_context == context
	)


func load_scenario(data: ScenarioData) -> void:
	# Assign stable per-command uids so BacklogManager's divergence
	# detection works against a position-stable identity (issue #88).
	data.assign_command_uids()
	context = ScenarioContext.new(data)
	if context.variable_store == null:
		context.variable_store = VariableStore.new()


func run() -> void:
	if context == null or context.scenario_data == null:
		return
	# A suspended or accepted-retired Context may only be reactivated through its
	# exact opaque capability. An arbitrary run() call cannot forge ownership.
	if not context.is_runtime_owner_current():
		return

	# Every invocation owns a unique generation. A replacement scenario, stop(),
	# cancellation, or a second run() invalidates all suspended/synchronous work
	# from the previous owner.
	_advance_run_generation()
	var generation := _run_generation
	var ctx := context

	if ctx.scenario_data.scenes.is_empty():
		ctx.is_finished = true
		scenario_started.emit(ctx.scenario_data.id)
		if not _owns_run(ctx, generation):
			return
		_emit_scenario_ended(ctx, generation)
		return

	scenario_started.emit(ctx.scenario_data.id)
	if not _owns_run(ctx, generation):
		return
	scene_changed.emit(ctx.current_scene().id)
	if not _owns_run(ctx, generation):
		return

	while not ctx.is_finished:
		if not _owns_run(ctx, generation):
			return
		# Handle pending jump
		if ctx.pending_jump != "":
			var jump_target = ctx.pending_jump
			ctx.pending_jump = ""
			if not ctx.set_scene(jump_target):
				push_warning("ScenarioEngine: jump target '%s' not found" % jump_target)
				ctx.is_finished = true
				break
			scene_changed.emit(ctx.current_scene().id)
			if not _owns_run(ctx, generation):
				return
			continue

		# Get current command
		var cmd = ctx.current_command()
		if cmd == null:
			var exhausted_scene := ctx.current_scene()
			if exhausted_scene != null:
				ctx.apply_dialogue_mode_events(
					exhausted_scene.dialogue_mode_events_on_exit)
			# Current scene exhausted, try next scene
			if not _advance_to_next_scene(ctx):
				ctx.is_finished = true
				break
			if not _owns_run(ctx, generation):
				return
			continue

		# Dispatch to handler
		ctx.apply_dialogue_mode_events(cmd.dialogue_mode_events_before)
		var handler = registry.get_handler(cmd.type) if registry else null
		if handler:
			await handler.execute(cmd, ctx)
			if not _owns_run(ctx, generation):
				return
			if ctx.is_finished:
				break
		ctx.apply_dialogue_mode_events(cmd.dialogue_mode_events_after)
		if handler:
			command_executed.emit(cmd)
			if not _owns_run(ctx, generation):
				return

		# If the handler set a jump, don't advance — let the loop handle it
		if ctx.pending_jump == "":
			ctx.advance()

	_emit_scenario_ended(ctx, generation)


func _owns_run(ctx: ScenarioContext, generation: int) -> bool:
	return context == ctx and _run_generation == generation


func _emit_scenario_ended(ctx: ScenarioContext, generation: int) -> void:
	if not _owns_run(ctx, generation):
		return
	_emitting_scenario_end_context = ctx
	_emitting_scenario_end_generation = generation
	scenario_ended.emit(ctx.scenario_data.id)
	_emitting_scenario_end_context = null
	_emitting_scenario_end_generation = -1


func _advance_to_next_scene(ctx: ScenarioContext) -> bool:
	# Check return stack first (for @call returns)
	if ctx.return_stack.size() > 0:
		var return_point = ctx.return_stack.pop_back()
		ctx.current_scene_index = return_point["scene_index"]
		ctx.current_command_index = return_point["command_index"]
		scene_changed.emit(ctx.current_scene().id)
		return true

	ctx.current_scene_index += 1
	ctx.current_command_index = 0
	if ctx.current_scene_index >= ctx.scenario_data.scenes.size():
		return false
	scene_changed.emit(ctx.current_scene().id)
	return true
