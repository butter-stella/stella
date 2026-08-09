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
## Runtime dialogue mode follows the actually executed control-flow path.
## nvl_page_epoch increments only when that path enters NVL from another mode.
var current_dialogue_mode: String = "adv"
var nvl_page_epoch: int = 0


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
		"dialogue_mode": current_dialogue_mode,
		"nvl_page_epoch": nvl_page_epoch,
	}


func restore_snapshot(snapshot: Dictionary) -> void:
	current_scene_index = int(snapshot.get("scene_index", 0))
	current_command_index = int(snapshot.get("command_index", 0))
	is_finished = snapshot.get("is_finished", false)
	var stack = snapshot.get("return_stack", [])
	return_stack.clear()
	for entry in stack:
		return_stack.append(entry)
	current_dialogue_mode = str(snapshot.get("dialogue_mode", "adv"))
	if current_dialogue_mode not in ["adv", "nvl", "overlay", "monologue"]:
		current_dialogue_mode = "adv"
	nvl_page_epoch = maxi(0, int(snapshot.get("nvl_page_epoch", 0)))


## Apply a source-authored dialogue mode directive on the current runtime path.
## Repeating @nvl while already in NVL keeps the current page; leaving and later
## re-entering creates a new epoch even if execution jumps back to the same
## source block.
func apply_dialogue_mode(mode: String) -> void:
	if mode == current_dialogue_mode:
		return
	current_dialogue_mode = mode
	if mode == "nvl":
		nvl_page_epoch += 1


func apply_dialogue_mode_events(events: Array[String]) -> void:
	for mode in events:
		apply_dialogue_mode(mode)


func advance() -> void:
	current_command_index += 1


func set_scene(scene_id: String) -> bool:
	var index = scenario_data.get_scene_index(scene_id)
	if index == -1:
		return false
	current_scene_index = index
	current_command_index = 0
	return true
