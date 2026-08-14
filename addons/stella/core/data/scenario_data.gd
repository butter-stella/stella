## Top-level scenario structure containing metadata and an ordered list of scenes.
class_name ScenarioData extends RefCounted

const SOURCE_IDENTITY_VERSION := 1
const AUTHORED_IDENTITY_VERSION := 1

var id: String = ""
## Versioned identity of the authored source location. Runtime derives this
## from the normalized scenario path and stores only its SHA-256 digest, so two
## files with the same basename cannot share saves while private paths are not
## copied into save JSON. An empty value means the ScenarioData was constructed
## programmatically and is not eligible for scenario-aware disk restore until
## the author assigns a stable key with set_authored_identity().
var source_identity: String = ""
var title: String = ""
## Canonical authored source used by persistent command identities. Parsed
## scenarios keep their full resource path so equal basenames in different
## directories never share read history.
var source_path: String = ""
## Normalized semantic-IR fingerprint for fail-closed read history. Command
## UIDs are deterministic only within one parsed behavior version; comments and
## equivalent spelling retain history while authored behavior changes do not.
var content_fingerprint: String = ""
var scenes: Array = []  # Array[SceneData]
## Chapters in declaration order (issue #97). Each chapter owns one or more
## scenes. Populated by DslParser; empty for scenarios constructed manually
## (e.g. in tests that bypass the parser).
var chapters: Array = []  # Array[ChapterData]
## Runtime dialogue profiles compiled from @dialogue_profile declarations.
## Commands refer to these by name through ScenarioContext so the selected
## control-flow path, rather than parser source order, owns presentation state.
## Provenance is kept separately because it is diagnostic metadata and must not
## enter save snapshots.
var dialogue_profiles: Dictionary = {}
var dialogue_profile_provenance: Dictionary = {}
## Parser diagnostics — used for testable error/warning reporting.
## Each entry is {level: "error"|"warning", message: String, line: int}.
## StellaRuntime surfaces these messages through push_error / push_warning after
## parsing; the parser itself remains silent so tests can assert against this list.
var diagnostics: Array = []


static func make_source_identity(source_path: String) -> String:
	var normalized_path := source_path.replace("\\", "/")
	if normalized_path.is_empty():
		return ""
	normalized_path = normalized_path.simplify_path()
	return "stella-source-v%d:sha256:%s" % [
		SOURCE_IDENTITY_VERSION,
		normalized_path.sha256_text(),
	]


## Assign a stable, author-controlled identity to ScenarioData constructed by
## an extension instead of DslParser. The authored key is hashed before it is
## persisted; callers must keep the same non-secret key across releases that
## should share saves and deliberately change it for incompatible content.
func set_authored_identity(authored_key: String) -> Error:
	var normalized_key := authored_key.strip_edges()
	if normalized_key.is_empty():
		return ERR_INVALID_PARAMETER
	source_identity = "stella-authored-v%d:sha256:%s" % [
		AUTHORED_IDENTITY_VERSION,
		normalized_key.sha256_text(),
	]
	return OK


func get_dialogue_profile(profile_name: String) -> Dictionary:
	var profile: Dictionary = dialogue_profiles.get(profile_name, {})
	return profile.duplicate(true)


func get_dialogue_profile_provenance(profile_name: String) -> Dictionary:
	var provenance: Dictionary = dialogue_profile_provenance.get(profile_name, {})
	return provenance.duplicate(true)


func get_read_identity() -> String:
	var source_identity := "id:%s" % id
	if not source_path.is_empty():
		source_identity = "path:%s" % source_path.simplify_path()
	if not content_fingerprint.is_empty():
		return "%s#content:%s" % [source_identity, content_fingerprint]
	return source_identity


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
	var next_uid := [0]
	for scene in scenes:
		for cmd in scene.commands:
			_assign_command_uid_recursive(cmd, next_uid)


func _assign_command_uid_recursive(cmd: CommandData, next_uid: Array) -> void:
	if cmd == null:
		return
	if cmd.uid == -1:
		cmd.uid = int(next_uid[0])
	# Always advance the counter so explicit uids don't collide with assigned
	# top-level or nested commands.
	next_uid[0] = maxi(int(next_uid[0]), cmd.uid) + 1
	for child in cmd.params.get("commands", []):
		if child is CommandData:
			_assign_command_uid_recursive(child, next_uid)
