## Top-level scenario structure containing metadata and an ordered list of scenes.
class_name ScenarioData extends RefCounted

var id: String = ""
var title: String = ""
var scenes: Array = []  # Array[SceneData]


func get_scene(scene_id: String) -> SceneData:
	for scene in scenes:
		if scene.id == scene_id:
			return scene
	return null


func get_scene_index(scene_id: String) -> int:
	for i in range(scenes.size()):
		if scenes[i].id == scene_id:
			return i
	return -1


## Assign a monotonic uid to every command in every scene. Called by
## ScenarioEngine.load_scenario, so any code path that goes through the
## engine gets stable command identities for free.
##
## Idempotent: if a command already has uid != -1 it is left alone, so
## tests that construct CommandData with explicit uids work too.
func assign_command_uids() -> void:
	var next_uid := 0
	for scene in scenes:
		for cmd in scene.commands:
			if cmd.uid == -1:
				cmd.uid = next_uid
			# Always advance the counter so explicit uids don't collide
			# with auto-assigned ones.
			next_uid = max(next_uid, cmd.uid) + 1
