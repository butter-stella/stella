## Main scenario engine — loads and executes scenario data.
## Dispatches commands to registered handlers via CommandRegistry.
class_name ScenarioEngine extends RefCounted

signal scenario_started(scenario_id: String)
signal scenario_ended(scenario_id: String)
signal scene_changed(scene_id: String)
signal command_executed(command_data: CommandData)

var context: ScenarioContext
var registry: CommandRegistry
var _run_generation: int = 0
var _emitting_scenario_end_generation: int = -1
var _emitting_scenario_end_context: ScenarioContext = null


func stop() -> void:
	_run_generation += 1
	if context != null:
		context.is_finished = true


## Invalidate synchronous or suspended control flow while retaining the active
## context snapshot. Runtime calls this only after a replacement navigation has
## passed side-effect-free validation; final detachment happens after the new
## scene is confirmed.
func invalidate_current_run() -> void:
	_run_generation += 1


## Detach and invalidate the active run without reporting normal completion.
## Runtime navigation and test isolation use this before waking abortable
## handlers so no suspended continuation can emit lifecycle events afterward.
func cancel_current_run() -> ScenarioContext:
	_run_generation += 1
	var old_context := context
	context = null
	if old_context != null:
		old_context.is_finished = true
	return old_context


func replace_context(new_context: ScenarioContext) -> ScenarioContext:
	_run_generation += 1
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
	stop()
	# Assign stable per-command uids so BacklogManager's divergence
	# detection works against a position-stable identity (issue #88).
	data.assign_command_uids()
	context = ScenarioContext.new(data)
	if context.variable_store == null:
		context.variable_store = VariableStore.new()


func run() -> void:
	if context == null or context.scenario_data == null:
		return

	# Every invocation owns a unique generation. A replacement scenario, stop(),
	# cancellation, or a second run() invalidates all suspended/synchronous work
	# from the previous owner.
	_run_generation += 1
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
