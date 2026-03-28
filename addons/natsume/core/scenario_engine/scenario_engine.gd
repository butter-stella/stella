## Main scenario engine — loads and executes scenario data.
## Dispatches commands to registered handlers via CommandRegistry.
class_name ScenarioEngine extends RefCounted

signal scenario_started(scenario_id: String)
signal scenario_ended(scenario_id: String)
signal scene_changed(scene_id: String)
signal command_executed(command_data: CommandData)

var context: ScenarioContext
var registry: CommandRegistry


func load_scenario(data: ScenarioData) -> void:
	context = ScenarioContext.new(data)
	if context.variable_store == null:
		context.variable_store = VariableStore.new()


func run() -> void:
	if context == null or context.scenario_data == null:
		return

	if context.scenario_data.scenes.is_empty():
		context.is_finished = true
		scenario_started.emit(context.scenario_data.id)
		scenario_ended.emit(context.scenario_data.id)
		return

	scenario_started.emit(context.scenario_data.id)
	scene_changed.emit(context.current_scene().id)

	while not context.is_finished:
		# Handle pending jump
		if context.pending_jump != "":
			var jump_target = context.pending_jump
			context.pending_jump = ""
			if not context.set_scene(jump_target):
				push_warning("ScenarioEngine: jump target '%s' not found" % jump_target)
				context.is_finished = true
				break
			scene_changed.emit(context.current_scene().id)
			continue

		# Get current command
		var cmd = context.current_command()
		if cmd == null:
			# Current scene exhausted, try next scene
			if not _advance_to_next_scene():
				context.is_finished = true
				break
			continue

		# Dispatch to handler
		var handler = registry.get_handler(cmd.type) if registry else null
		if handler:
			await handler.execute(cmd, context)
			command_executed.emit(cmd)

		# If the handler set a jump, don't advance — let the loop handle it
		if context.pending_jump == "":
			context.advance()

	scenario_ended.emit(context.scenario_data.id)


func _advance_to_next_scene() -> bool:
	context.current_scene_index += 1
	context.current_command_index = 0
	if context.current_scene_index >= context.scenario_data.scenes.size():
		return false
	scene_changed.emit(context.current_scene().id)
	return true
