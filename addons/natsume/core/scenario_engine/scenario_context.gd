## Runtime context for scenario execution.
## Tracks current position and jump requests.
class_name ScenarioContext extends RefCounted

var scenario_data: ScenarioData
var current_scene_index: int = 0
var current_command_index: int = 0
var pending_jump: String = ""
var is_finished: bool = false


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


func advance() -> void:
	current_command_index += 1


func set_scene(scene_id: String) -> bool:
	var index = scenario_data.get_scene_index(scene_id)
	if index == -1:
		return false
	current_scene_index = index
	current_command_index = 0
	return true
