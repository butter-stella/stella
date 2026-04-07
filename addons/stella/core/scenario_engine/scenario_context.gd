## Runtime context for scenario execution.
## Tracks current position and jump requests.
class_name ScenarioContext extends RefCounted

var scenario_data: ScenarioData
var current_scene_index: int = 0
var current_command_index: int = 0
var pending_jump: String = ""
var is_finished: bool = false
var variable_store: VariableStore
var return_stack: Array = []  # Array of {scene_index, command_index} for @call returns

## Replay mode (used by backlog jump). Runtime-only — never serialized.
## When `is_replay` is true, handlers skip awaits / audio / dialogue display
## but still mutate state (variables, presentation_state via emitted signals).
## The engine's main loop clears `is_replay` once execution reaches the
## target position, so the target command itself runs in normal mode.
var is_replay: bool = false
var replay_target_scene: int = -1
var replay_target_command: int = -1
## Reference to PresentationState — used by visual handlers in replay mode
## to mutate state directly without emitting visual signals. Set by the
## runtime after loading a scenario; null in pure unit tests.
## Typed as Variant to avoid a forward-class dependency.
var presentation_state: Variant = null


func _init(data: ScenarioData = null):
	if data:
		scenario_data = data


func current_scene() -> SceneData:
	if scenario_data == null or current_scene_index >= scenario_data.scenes.size():
		return null
	return scenario_data.scenes[current_scene_index]


func current_command() -> CommandData:
	var scene = current_scene()
	if scene == null or current_command_index >= scene.commands.size():
		return null
	return scene.commands[current_command_index]


func get_provider_id() -> String:
	return "scenario_context"


func capture_snapshot() -> Dictionary:
	return {
		"scenario_id": scenario_data.id if scenario_data else "",
		"scene_index": current_scene_index,
		"command_index": current_command_index,
		"is_finished": is_finished,
		"return_stack": return_stack.duplicate(true),
	}


func restore_snapshot(snapshot: Dictionary) -> void:
	current_scene_index = int(snapshot.get("scene_index", 0))
	current_command_index = int(snapshot.get("command_index", 0))
	is_finished = snapshot.get("is_finished", false)
	var stack = snapshot.get("return_stack", [])
	return_stack.clear()
	for entry in stack:
		return_stack.append(entry)


func advance() -> void:
	current_command_index += 1


func set_scene(scene_id: String) -> bool:
	var index = scenario_data.get_scene_index(scene_id)
	if index == -1:
		return false
	current_scene_index = index
	current_command_index = 0
	return true
