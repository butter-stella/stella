## Runtime context for scenario execution.
## Tracks current position and jump requests.
class_name ScenarioContext extends RefCounted

signal cancellation_requested()

var scenario_data: ScenarioData
var current_scene_index: int = 0
var current_command_index: int = 0
var pending_jump: String = ""
var is_finished: bool = false
## Runtime-only entry/return contract. It is intentionally not serialized;
## recollection playbacks reject save/rollback at the Runtime facade boundary.
var playback_context: ScenarioPlaybackContext = ScenarioPlaybackContext.story()
var recollection_exit_line: int = 0
## Canonical authored target for the chapter indicator. Chapter metadata and
## presenter state are derived projections and deliberately are not persisted.
var chapter_indicator_visible: bool = false
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
var _dialogue_request_serial: int = 0
var _runtime_owner_state: Dictionary = {}
var _active_dialogue_activation: DialogueActivation
var _cancellation_requested: bool = false


func _init(data: ScenarioData = null):
	if data:
		scenario_data = data


## ScenarioEngine supplies a small shared owner token instead of a Callable so
## the RefCounted engine and context cannot form a reference cycle.
func bind_runtime_owner(owner_state: Dictionary) -> void:
	_runtime_owner_state = owner_state


func is_runtime_owner_current() -> bool:
	return (
		not is_finished
		and (
			_runtime_owner_state.is_empty()
			or bool(_runtime_owner_state.get("current", false))
		)
	)


func set_playback_context(value: ScenarioPlaybackContext) -> bool:
	if value == null or not value.is_valid_for_entry():
		return false
	playback_context = value
	return true


func is_recollection_playback() -> bool:
	return playback_context != null and playback_context.is_recollection()


## The command itself never calls project code. It only makes this exact engine
## generation terminal; ScenarioEngine's canonical end emission hands the same
## Context to Runtime for cleanup and continuation settlement.
func request_recollection_exit(source_line: int) -> bool:
	if not is_recollection_playback():
		return true
	recollection_exit_line = maxi(0, source_line)
	is_finished = true
	return true


## Retire only the current execution session while keeping authored Context
## state available for navigation recovery and autosave. The owner has already
## been revoked by ScenarioEngine.suspend_current_run(), so abort tails cannot
## mark the retained Context finished or apply choice effects. A later exact
## engine capability may bind a fresh owner session to this same Context.
func retire_runtime_execution_session() -> void:
	if not _runtime_owner_state.is_empty():
		_runtime_owner_state["current"] = false
	abort_active_dialogue()
	cancellation_requested.emit()


## Cancel every blocking command owned by this execution generation. A context
## is itself the generation token: replacing it cancels only the retired run,
## while the newly installed context remains available to synchronous tails.
func request_cancellation() -> void:
	if _cancellation_requested:
		return
	_cancellation_requested = true
	is_finished = true
	abort_active_dialogue()
	cancellation_requested.emit()


func is_cancellation_requested() -> bool:
	return _cancellation_requested


## Only one blocking dialogue may own a context at a time. A reentrant or
## malformed second activation is rejected instead of stealing ownership from
## the command that the engine is still executing.
func install_dialogue_activation(activation: DialogueActivation) -> bool:
	if activation == null:
		return false
	if not is_runtime_owner_current():
		activation.abort()
		return false
	if (
		_active_dialogue_activation != null
		and _active_dialogue_activation != activation
	):
		activation.abort()
		return false
	_active_dialogue_activation = activation
	return true


func owns_dialogue_activation(activation: DialogueActivation) -> bool:
	return (
		activation != null
		and _active_dialogue_activation == activation
		and is_runtime_owner_current()
	)


func clear_dialogue_activation(activation: DialogueActivation) -> void:
	if _active_dialogue_activation == activation:
		_active_dialogue_activation = null


func abort_active_dialogue() -> void:
	if _active_dialogue_activation == null:
		return
	var activation := _active_dialogue_activation
	_active_dialogue_activation = null
	activation.abort()


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
		"scenario_source_identity": (
			scenario_data.source_identity if scenario_data else ""
		),
		"scene_index": current_scene_index,
		"command_index": current_command_index,
		"is_finished": is_finished,
		"chapter_indicator_visible": chapter_indicator_visible,
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
	var raw_indicator_visible: Variant = snapshot.get(
		"chapter_indicator_visible", false)
	# SaveManager rejects malformed persisted values before restore. Keep direct
	# programmatic restores fail-closed as well instead of truthiness-coercing.
	chapter_indicator_visible = (
		raw_indicator_visible if raw_indicator_visible is bool else false
	)
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


## Clear only the live authored page. Mode and selected presentation profiles
## remain canonical context; backlog and unrelated presentation domains live
## outside ScenarioContext and are deliberately untouched.
func clear_dialogue_page() -> void:
	nvl_page_entries.clear()
	_nvl_snapshot_replay_pending = false
	if current_dialogue_mode == "nvl":
		nvl_page_epoch += 1


## Director uses this page-scoped checkpoint for atomic mixed-batch rollback.
func capture_dialogue_page_state() -> Dictionary:
	return {
		"nvl_page_epoch": nvl_page_epoch,
		"nvl_page_entries": nvl_page_entries.duplicate(true),
		"nvl_snapshot_replay_pending": _nvl_snapshot_replay_pending,
	}


func restore_dialogue_page_state(snapshot: Dictionary) -> bool:
	var keys := snapshot.keys()
	keys.sort()
	if keys != [
		"nvl_page_entries",
		"nvl_page_epoch",
		"nvl_snapshot_replay_pending",
	]:
		return false
	if (
		not snapshot.get("nvl_page_epoch", null) is int
		or int(snapshot["nvl_page_epoch"]) < 0
		or not snapshot.get("nvl_page_entries", null) is Array
		or not snapshot.get("nvl_snapshot_replay_pending", null) is bool
	):
		return false
	var restored_entries: Array = []
	for entry_value: Variant in snapshot["nvl_page_entries"]:
		if not entry_value is Dictionary:
			return false
		restored_entries.append(_sanitize_nvl_page_entry(entry_value))
	nvl_page_epoch = int(snapshot["nvl_page_epoch"])
	nvl_page_entries = restored_entries
	_nvl_snapshot_replay_pending = bool(snapshot["nvl_snapshot_replay_pending"])
	return true


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
		"profile_name": current_dialogue_profile_name,
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


## Build the runtime-only NVL restoration payload. Snapshots retain only the
## profile name; the current ScenarioData registry supplies the resolved values
## so a script edit cannot leave serialized Resource/Dictionary state behind.
func materialize_nvl_page_entries(entries: Array) -> Array:
	var materialized: Array = []
	for raw_entry in entries:
		if not raw_entry is Dictionary:
			continue
		var entry: Dictionary = raw_entry.duplicate(true)
		var profile_name := String(entry.get("profile_name", ""))
		entry["presentation_profile"] = (
			scenario_data.get_dialogue_profile(profile_name)
			if scenario_data != null and not profile_name.is_empty()
			else {}
		)
		materialized.append(entry)
	return materialized


## Every emitted dialogue owns a stable identity independent of the mutable
## ScenarioContext cursor. The id is session-local and intentionally excluded
## from save data; Backlog uses it only to enrich the exact captured entry.
func next_dialogue_entry_id(command_uid: int) -> String:
	_dialogue_request_serial += 1
	return "%d:%d:%d" % [
		get_instance_id(), command_uid, _dialogue_request_serial,
	]


func _sanitize_nvl_page_entry(raw_entry: Dictionary) -> Dictionary:
	var clean_segments: Array = []
	for raw_segment in raw_entry.get("segments", []):
		if raw_segment is Dictionary:
			clean_segments.append({
				"text": String(raw_segment.get("text", "")),
				"voice_layers": raw_segment.get(
					"voice_layers", []).duplicate(true),
			})
	return {
		"command_uid": int(raw_entry.get("command_uid", -1)),
		"scene_index": int(raw_entry.get("scene_index", -1)),
		"command_index": int(raw_entry.get("command_index", -1)),
		"profile_name": String(raw_entry.get("profile_name", "")),
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
