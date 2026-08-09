## Main scenario engine — loads and executes scenario data.
## Dispatches commands to registered handlers via CommandRegistry.
class_name ScenarioEngine extends RefCounted

signal scenario_started(scenario_id: String)
signal scenario_ended(scenario_id: String)
signal scene_changed(scene_id: String)
signal command_executed(command_data: CommandData)

var context: ScenarioContext
var registry: CommandRegistry


func stop() -> void:
	if context != null:
		context.is_finished = true


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

	var ctx = context  # Bind local ref — if context is replaced, this run aborts

	if ctx.scenario_data.scenes.is_empty():
		ctx.is_finished = true
		scenario_started.emit(ctx.scenario_data.id)
		scenario_ended.emit(ctx.scenario_data.id)
		return

	scenario_started.emit(ctx.scenario_data.id)
	scene_changed.emit(ctx.current_scene().id)

	while not ctx.is_finished:
		# Handle pending jump
		if ctx.pending_jump != "":
			var jump_target = ctx.pending_jump
			ctx.pending_jump = ""
			if not ctx.set_scene(jump_target):
				push_warning("ScenarioEngine: jump target '%s' not found" % jump_target)
				ctx.is_finished = true
				break
			scene_changed.emit(ctx.current_scene().id)
			continue

		# Get current command
		var cmd = ctx.current_command()
		if cmd == null:
			var exhausted_scene := ctx.current_scene()
			if exhausted_scene != null:
				ctx.apply_dialogue_mode_events(
					exhausted_scene.dialogue_mode_events_on_exit)
			# Current scene exhausted, try next scene
			if not _advance_to_next_scene():
				ctx.is_finished = true
				break
			continue

		# Dispatch to handler
		ctx.apply_dialogue_mode_events(cmd.dialogue_mode_events_before)
		var handler = registry.get_handler(cmd.type) if registry else null
		if handler:
			await handler.execute(cmd, ctx)
			# After await: abort if context was replaced (load/restart)
			if ctx != context:
				return
		ctx.apply_dialogue_mode_events(cmd.dialogue_mode_events_after)
		if handler:
			command_executed.emit(cmd)

		# If the handler set a jump, don't advance — let the loop handle it
		if ctx.pending_jump == "":
			ctx.advance()

	scenario_ended.emit(ctx.scenario_data.id)


func _advance_to_next_scene() -> bool:
	# Check return stack first (for @call returns)
	if context.return_stack.size() > 0:
		var return_point = context.return_stack.pop_back()
		context.current_scene_index = return_point["scene_index"]
		context.current_command_index = return_point["command_index"]
		scene_changed.emit(context.current_scene().id)
		return true

	context.current_scene_index += 1
	context.current_command_index = 0
	if context.current_scene_index >= context.scenario_data.scenes.size():
		return false
	scene_changed.emit(context.current_scene().id)
	return true
