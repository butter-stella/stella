## Top-level scenario structure containing metadata and an ordered list of scenes.
class_name ScenarioData extends RefCounted

var id: String = ""
var title: String = ""
var scenes: Array = []  # Array[SceneData]
## Chapters in declaration order (issue #97). Each chapter owns one or more
## scenes. Populated by DslParser; empty for scenarios constructed manually
## (e.g. in tests that bypass the parser).
var chapters: Array = []  # Array[ChapterData]
## Parser diagnostics — used for testable error/warning reporting.
## Each entry is {level: "error"|"warning", message: String, line: int}.
## StellaRuntime surfaces these messages through push_error / push_warning after
## parsing; the parser itself remains silent so tests can assert against this list.
var diagnostics: Array = []


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


func get_chapter(chapter_id: String) -> ChapterData:
	for ch in chapters:
		if ch.id == chapter_id:
			return ch
	return null


func get_chapter_index(chapter_id: String) -> int:
	for i in range(chapters.size()):
		if chapters[i].id == chapter_id:
			return i
	return -1


## Look up the chapter that owns the given scene, via SceneData.chapter_id.
## Returns null if the scene is orphan (chapter_id == "") or not found.
func get_chapter_for_scene(scene_id: String) -> ChapterData:
	var scene = get_scene(scene_id)
	if scene == null or scene.chapter_id == "":
		return null
	return get_chapter(scene.chapter_id)


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
