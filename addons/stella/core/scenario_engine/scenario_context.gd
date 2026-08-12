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
## Canonical authored entries for the active NVL page. Saving these inputs (and
## never RichTextLabel's rendered string) lets restore rebuild the same page
## after presentation nodes have been hard-reset.
var nvl_page_entries: Array = []
var _nvl_snapshot_replay_pending: bool = false
## Named presentation selection on the actual runtime path. Profiles themselves
## live on ScenarioData; snapshots only persist these JSON-safe references.
var current_dialogue_profile_name: String = ""
var current_dialogue_uses_declarative_presentation: bool = false
var adv_dialogue_profile_name: String = ""
var adv_dialogue_uses_declarative_presentation: bool = false


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
		"nvl_page_entries": nvl_page_entries.duplicate(true),
		"dialogue_profile_name": current_dialogue_profile_name,
		"dialogue_declarative_presentation": (
			current_dialogue_uses_declarative_presentation
		),
		"adv_dialogue_profile_name": adv_dialogue_profile_name,
		"adv_dialogue_declarative_presentation": (
			adv_dialogue_uses_declarative_presentation
		),
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
	# Monologue is a one-command presentation style and is never persistent
	# ScenarioContext state. Treat hand-authored/legacy snapshots that contain it
	# like an unknown mode so the next ordinary dialogue cannot inherit it.
	if current_dialogue_mode not in ["adv", "nvl", "overlay"]:
		current_dialogue_mode = "adv"
	nvl_page_epoch = maxi(0, int(snapshot.get("nvl_page_epoch", 0)))
	nvl_page_entries.clear()
	if current_dialogue_mode == "nvl":
		for raw_entry in snapshot.get("nvl_page_entries", []):
			if raw_entry is Dictionary:
				nvl_page_entries.append(_sanitize_nvl_page_entry(raw_entry))
	_nvl_snapshot_replay_pending = not nvl_page_entries.is_empty()
	current_dialogue_profile_name = _validated_profile_name(
		str(snapshot.get("dialogue_profile_name", "")), "current")
	current_dialogue_uses_declarative_presentation = bool(snapshot.get(
		"dialogue_declarative_presentation", false))
	adv_dialogue_profile_name = _validated_profile_name(
		str(snapshot.get("adv_dialogue_profile_name", "")), "ADV")
	adv_dialogue_uses_declarative_presentation = bool(snapshot.get(
		"adv_dialogue_declarative_presentation", false))


## Apply a source-authored dialogue mode directive on the current runtime path.
## Repeating @nvl while already in NVL keeps the current page; leaving and later
## re-entering creates a new epoch even if execution jumps back to the same
## source block.
func apply_dialogue_mode(mode: String) -> void:
	if mode == current_dialogue_mode:
		return
	nvl_page_entries.clear()
	_nvl_snapshot_replay_pending = false
	current_dialogue_mode = mode
	if mode == "nvl":
		nvl_page_epoch += 1


## Record the authored input for an NVL entry. Ordinary live playback returns an
## empty Array so each SHOW can use the Presenter's incremental accumulator.
## Only the first command re-executed after snapshot restore returns the complete
## authored page for a one-time deterministic rebuild; its saved tail is not
## appended twice. This avoids copying and reparsing the growing page per entry.
func record_nvl_page_entry(
	command_uid: int,
	character: String,
	segments: Array,
) -> Array:
	var entry := _sanitize_nvl_page_entry({
		"command_uid": command_uid,
		"scene_index": current_scene_index,
		"command_index": current_command_index,
		"character": character,
		"segments": segments,
	})
	if _nvl_snapshot_replay_pending:
		_nvl_snapshot_replay_pending = false
		if not nvl_page_entries.is_empty():
			var tail: Dictionary = nvl_page_entries[-1]
			if (
				int(tail.get("command_uid", -2)) == command_uid
				and int(tail.get("scene_index", -2)) == current_scene_index
				and int(tail.get("command_index", -2)) == current_command_index
			):
				return nvl_page_entries.duplicate(true)
		nvl_page_entries.append(entry)
		return nvl_page_entries.duplicate(true)
	nvl_page_entries.append(entry)
	return []


func _sanitize_nvl_page_entry(raw_entry: Dictionary) -> Dictionary:
	var clean_segments: Array = []
	for raw_segment in raw_entry.get("segments", []):
		if raw_segment is Dictionary:
			clean_segments.append({
				"text": String(raw_segment.get("text", "")),
				"voice": String(raw_segment.get("voice", "")),
			})
	return {
		"command_uid": int(raw_entry.get("command_uid", -1)),
		"scene_index": int(raw_entry.get("scene_index", -1)),
		"command_index": int(raw_entry.get("command_index", -1)),
		"character": String(raw_entry.get("character", "")),
		"segments": clean_segments,
	}


## A programmatic/legacy command carries its own one-shot profile Dictionary.
## Its mode remains persistent for compatibility, but it must clear a previous
## parser-owned named selection so the next runtime-selected command cannot pair
## the static command's mode with a stale unrelated profile.
func apply_static_dialogue_presentation(mode: String) -> void:
	apply_dialogue_mode(mode)
	current_dialogue_profile_name = ""
	current_dialogue_uses_declarative_presentation = false


func apply_dialogue_mode_events(events: Array) -> void:
	for event in events:
		if event is Dictionary:
			_apply_dialogue_presentation_event(event)
		else:
			# Compatibility for programmatically constructed commands and compiled
			# scenarios predating presentation-selection sidecars. A legacy event has
			# no Profile reference, so it must not retain an unrelated named selection.
			apply_static_dialogue_presentation(str(event))


func resolve_current_dialogue_profile() -> Dictionary:
	if scenario_data == null or current_dialogue_profile_name.is_empty():
		return {}
	return scenario_data.get_dialogue_profile(current_dialogue_profile_name)


func resolve_current_dialogue_profile_provenance() -> Dictionary:
	if scenario_data == null or current_dialogue_profile_name.is_empty():
		return {}
	return scenario_data.get_dialogue_profile_provenance(
		current_dialogue_profile_name)


func _apply_dialogue_presentation_event(event: Dictionary) -> void:
	var action := str(event.get("action", ""))
	var mode := str(event.get("mode", "adv"))
	match action:
		"select_adv":
			var profile_name := _validated_profile_name(
				str(event.get("profile_name", "")), "ADV")
			adv_dialogue_profile_name = profile_name
			adv_dialogue_uses_declarative_presentation = true
			current_dialogue_profile_name = profile_name
			current_dialogue_uses_declarative_presentation = true
			apply_dialogue_mode("adv")
		"select_mode":
			var profile_name := _validated_profile_name(
				str(event.get("profile_name", "")), mode)
			current_dialogue_profile_name = profile_name
			current_dialogue_uses_declarative_presentation = not profile_name.is_empty()
			apply_dialogue_mode(mode)
		"restore_adv":
			# Leaving a named declarative profile must restore the captured authored
			# baseline even when that baseline is the unnamed default ADV layout.
			var restore_authored_baseline := (
				adv_dialogue_uses_declarative_presentation
				or current_dialogue_uses_declarative_presentation
				or not current_dialogue_profile_name.is_empty()
			)
			current_dialogue_profile_name = adv_dialogue_profile_name
			current_dialogue_uses_declarative_presentation = restore_authored_baseline
			apply_dialogue_mode("adv")
		_:
			# A sidecar with no selection action has no Profile reference.
			apply_static_dialogue_presentation(mode)


func _validated_profile_name(profile_name: String, selection: String) -> String:
	if profile_name.is_empty() or scenario_data == null:
		return profile_name
	if scenario_data.dialogue_profiles.has(profile_name):
		return profile_name
	push_warning(
		(
			"ScenarioContext: %s dialogue profile '%s' is unavailable; using the "
			+ "unnamed presentation"
		) % [selection, profile_name]
	)
	return ""


func advance() -> void:
	current_command_index += 1


func set_scene(scene_id: String) -> bool:
	var index = scenario_data.get_scene_index(scene_id)
	if index == -1:
		return false
	current_scene_index = index
	current_command_index = 0
	return true
