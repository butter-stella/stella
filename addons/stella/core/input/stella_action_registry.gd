## Public catalog and dispatcher for stable UI/input action IDs.
##
## StellaRuntime owns the production instance. Projects may add namespaced
## actions, but built-in definitions and their execution callbacks remain owned
## by the Runtime composition root.
class_name StellaActionRegistry
extends RefCounted

signal catalog_changed
signal action_state_changed(action_id: StringName)
signal confirmation_requested(
	action_id: StringName,
	policy: StringName,
	context: Dictionary,
)

enum ExecuteResult {
	EXECUTED,
	UNAVAILABLE,
	CONFIRMATION_REQUIRED,
	NOT_FOUND,
	FAILED,
}

const CONFIRMATION_NONE := &"none"
const CONFIRMATION_DISRUPTIVE := &"disruptive"
const CONFIRMATION_DESTRUCTIVE := &"destructive"
const ACTION_VOICE_REPLAY := &"voice_replay"
const ACTION_AUTO := &"auto"
const ACTION_SKIP := &"skip"
const ACTION_BACKLOG := &"backlog"
const ACTION_PREV_CHOICE := &"prev_choice"
const ACTION_QUICK_SAVE := &"quick_save"
const ACTION_QUICK_LOAD := &"quick_load"
const ACTION_SAVE := &"save"
const ACTION_LOAD := &"load"
const ACTION_SETTINGS := &"settings"
const ACTION_START_GAME := &"start_game"
const ACTION_CONTINUE_GAME := &"continue_game"
const ACTION_RETURN_TO_TITLE := &"return_to_title"
const ACTION_QUIT := &"quit"
const ACTION_ADVANCE := &"advance"
const ACTION_HIDE_UI := &"hide_ui"
const ACTION_FLOWCHART := &"flowchart"
const ACTION_CANCEL := &"cancel"
const _BUILTIN_IDS := {
	ACTION_VOICE_REPLAY: true,
	ACTION_AUTO: true,
	ACTION_SKIP: true,
	ACTION_BACKLOG: true,
	ACTION_PREV_CHOICE: true,
	ACTION_QUICK_SAVE: true,
	ACTION_QUICK_LOAD: true,
	ACTION_SAVE: true,
	ACTION_LOAD: true,
	ACTION_SETTINGS: true,
	ACTION_START_GAME: true,
	ACTION_CONTINUE_GAME: true,
	ACTION_RETURN_TO_TITLE: true,
	ACTION_QUIT: true,
	ACTION_ADVANCE: true,
	ACTION_HIDE_UI: true,
	ACTION_FLOWCHART: true,
	ACTION_CANCEL: true,
}
const _CONFIRMATION_POLICIES := {
	CONFIRMATION_NONE: true,
	CONFIRMATION_DISRUPTIVE: true,
	CONFIRMATION_DESTRUCTIVE: true,
}
const _MAX_ACTION_ID_LENGTH := 128
const CONFIRMATION_TOKEN_CONTEXT_KEY := &"confirmation_token"
const CONFIRMATION_AUTO_CONFIRM_CONTEXT_KEY := &"confirmation_auto_confirm"

var last_error: String = ""

var _entries: Dictionary = {}
var _builtin_ids: Dictionary = {}
var _owners: Dictionary = {}
var _retiring_owner_ids: Dictionary = {}
var _next_generation: int = 0
var _next_confirmation_token: int = 0
var _accepting_initial_builtins: bool = false
var _construction_valid: bool = true
var _construction_capability_ref: WeakRef


## Runtime construction is one synchronous, sealed operation. The temporary
## capability never becomes a registry field and the returned instance exposes
## no post-construction built-in registration method.
static func _create_runtime_registry(
	builtin_owner: Node,
	definitions: Array[Dictionary],
) -> StellaActionRegistry:
	var construction_capability := RefCounted.new()
	return StellaActionRegistry.new(
		builtin_owner, definitions, construction_capability)


func _init(
	builtin_owner: Node = null,
	definitions: Array[Dictionary] = [],
	construction_capability: RefCounted = null,
) -> void:
	if (
		builtin_owner == null
		and definitions.is_empty()
		and construction_capability == null
	):
		return
	if (
		builtin_owner == null
		or construction_capability == null
		or not is_instance_valid(builtin_owner)
	):
		_fail_construction("runtime action registry construction is invalid")
		return
	if definitions.size() != _BUILTIN_IDS.size():
		_fail_construction(
			"runtime action catalog must define every canonical built-in exactly once")
		return
	var definition_ids: Dictionary = {}
	for definition: Dictionary in definitions:
		var action_id := StringName(definition.get("id", &""))
		if not _BUILTIN_IDS.has(action_id) or definition_ids.has(action_id):
			_fail_construction(
				"runtime action catalog has an unknown or duplicate built-in ID")
			return
		definition_ids[action_id] = true
	for action_id: StringName in _BUILTIN_IDS:
		if not definition_ids.has(action_id):
			_fail_construction(
				"runtime action catalog is missing a canonical built-in ID")
			return
	_accepting_initial_builtins = true
	_construction_capability_ref = weakref(construction_capability)
	for definition: Dictionary in definitions:
		if not _register_initial_builtin_action(
			definition, builtin_owner, construction_capability
		):
			var detail := last_error
			_accepting_initial_builtins = false
			_fail_construction(
				"runtime built-in action registration failed: %s" % detail)
			return
	_accepting_initial_builtins = false
	_construction_capability_ref = null
	if _entries.size() != _BUILTIN_IDS.size():
		_fail_construction("runtime action catalog construction was incomplete")


## Register one project action. Project IDs must be namespaced (for example,
## `my_game.open_codex`) and cannot replace a built-in or another owner's ID.
func register_action(
	action_id: StringName,
	metadata: Dictionary,
	owner: Object,
	execute_callback: Callable,
	can_execute_callback: Callable = Callable(),
	is_active_callback: Callable = Callable(),
) -> bool:
	if not _construction_valid:
		last_error = "action registry construction failed"
		return false
	return _register_action(
		action_id,
		metadata,
		owner,
		execute_callback,
		can_execute_callback,
		is_active_callback,
		false,
	)


func _register_initial_builtin_action(
	definition: Dictionary,
	owner: Node,
	construction_capability: RefCounted,
) -> bool:
	if not _accepting_initial_builtins:
		last_error = "built-in catalog is sealed"
		return false
	var action_id := StringName(definition.get("id", &""))
	if not _BUILTIN_IDS.has(action_id):
		last_error = "unknown built-in action ID"
		return false
	return _register_action(
		action_id,
		definition.get("metadata", {}),
		owner,
		definition.get("execute", Callable()),
		definition.get("can_execute", Callable()),
		definition.get("is_active", Callable()),
		true,
		construction_capability,
	)


func is_ready() -> bool:
	return _construction_valid


func _register_action(
	action_id: StringName,
	metadata: Dictionary,
	owner: Object,
	execute_callback: Callable,
	can_execute_callback: Callable,
	is_active_callback: Callable,
	builtin: bool,
	construction_capability: RefCounted = null,
) -> bool:
	last_error = ""
	_prune_invalid_owners()
	if builtin and (
		not _accepting_initial_builtins
		or construction_capability == null
		or _construction_capability_ref == null
		or _construction_capability_ref.get_ref() != construction_capability
		or not _BUILTIN_IDS.has(action_id)
	):
		last_error = "built-in action catalog is sealed"
		return false
	var id := String(action_id)
	if not _is_valid_action_id(id, builtin):
		last_error = (
			"built-in action ID is invalid"
			if builtin
			else "project action ID must be a lowercase namespaced identifier"
		)
		return false
	if (
		not owner is Node
		or not is_instance_valid(owner)
		or not (owner as Node).is_inside_tree()
		or (owner as Node).is_queued_for_deletion()
	):
		last_error = "action owner must be a live tree-bound Node"
		return false
	var owner_id := (owner as Node).get_instance_id()
	if (
		_retiring_owner_ids.has(owner_id)
		or (
			_owners.has(owner_id)
			and bool((_owners[owner_id] as Dictionary).get("exiting", false))
		)
	):
		last_error = "action owner is exiting the SceneTree"
		return false
	if not execute_callback.is_valid():
		last_error = "action execute callback is invalid"
		return false
	if not _callback_belongs_to_owner(execute_callback, owner as Node):
		last_error = "action execute callback must belong to its owner"
		return false
	if (
		can_execute_callback.is_valid()
		and not _callback_belongs_to_owner(
			can_execute_callback, owner as Node)
	):
		last_error = "action can_execute callback must belong to its owner"
		return false
	if (
		is_active_callback.is_valid()
		and not _callback_belongs_to_owner(
			is_active_callback, owner as Node)
	):
		last_error = "action is_active callback must belong to its owner"
		return false
	if _entries.has(action_id):
		last_error = "action ID is already registered"
		return false
	if not builtin and _builtin_ids.has(action_id):
		last_error = "built-in action ID cannot be replaced"
		return false
	var normalized := _normalize_metadata(action_id, metadata, builtin)
	if normalized.is_empty():
		return false

	_next_generation += 1
	_track_owner_action(owner as Node, action_id, _next_generation)
	_entries[action_id] = {
		"generation": _next_generation,
		"execution_count": 0,
		"pending_confirmation_token": 0,
		"owner_id": owner.get_instance_id(),
		"owner_ref": weakref(owner),
		"metadata": normalized,
		"execute": execute_callback,
		"can_execute": can_execute_callback,
		"is_active": is_active_callback,
	}
	var added_receipt := {
		"generation": _next_generation,
		"owner_id": owner.get_instance_id(),
	}
	if builtin:
		_builtin_ids[action_id] = true
	catalog_changed.emit()
	if _entry_receipt_is_current(action_id, added_receipt):
		action_state_changed.emit(action_id)
	return true


## Only the exact registration owner can remove its project action. Built-ins
## remain attached to the Runtime composition root for the process lifetime.
func unregister_action(action_id: StringName, owner: Object) -> bool:
	_prune_invalid_owners()
	if not _entries.has(action_id) or _builtin_ids.has(action_id):
		return false
	if owner == null or not is_instance_valid(owner):
		return false
	var entry: Dictionary = _entries[action_id]
	if int(entry["owner_id"]) != owner.get_instance_id():
		return false
	_erase_entry(action_id, true)
	return true


## Stable, ordered, defensive catalog suitable for action pickers.
func list_actions() -> Array[Dictionary]:
	_prune_invalid_owners()
	var result: Array[Dictionary] = []
	for action_id: StringName in _entries:
		result.append(get_action(action_id))
	result.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		var left_order := int(left.get("order", 0))
		var right_order := int(right.get("order", 0))
		if left_order != right_order:
			return left_order < right_order
		return String(left.get("id", "")) < String(right.get("id", ""))
	)
	return result


func get_action(action_id: StringName) -> Dictionary:
	var entry := _get_live_entry(action_id)
	if entry.is_empty():
		return {}
	return (entry["metadata"] as Dictionary).duplicate(true)


func get_label(action_id: StringName) -> String:
	var metadata := get_action(action_id)
	if metadata.is_empty():
		return ""
	var label_key := String(metadata.get("label_key", ""))
	if not label_key.is_empty():
		var translated := TranslationServer.translate(label_key)
		if translated != label_key:
			return translated
	return String(metadata.get("label", ""))


func get_confirmation_policy(action_id: StringName) -> StringName:
	var metadata := get_action(action_id)
	if metadata.is_empty():
		return CONFIRMATION_NONE
	return StringName(metadata.get(
		"confirmation_policy", CONFIRMATION_NONE))


func can_execute(
	action_id: StringName,
	context: Dictionary = {},
) -> bool:
	var entry := _get_live_entry(action_id)
	if entry.is_empty():
		return false
	return _query_can_execute(action_id, entry, context)


func is_active(
	action_id: StringName,
	context: Dictionary = {},
) -> bool:
	var entry := _get_live_entry(action_id)
	if entry.is_empty():
		return false
	var callback: Callable = entry["is_active"]
	if not callback.is_valid():
		return false
	var result: Variant = callback.call(context.duplicate(true))
	if not _entry_receipt_is_current(action_id, entry):
		return false
	return result is bool and bool(result)


## Dispatch exactly one registered action. Disruptive/destructive actions must
## be resubmitted with `confirmation_granted=true` and the opaque token supplied
## in the confirmation request context. A token is single-use, so synchronous or
## asynchronous competing confirmation consumers cannot execute twice.
func execute(
	action_id: StringName,
	context: Dictionary = {},
) -> ExecuteResult:
	var entry := _get_live_entry(action_id)
	if entry.is_empty():
		return ExecuteResult.NOT_FOUND
	if not _query_can_execute(action_id, entry, context):
		if not _entry_receipt_is_current(action_id, entry):
			return ExecuteResult.FAILED
		return ExecuteResult.UNAVAILABLE
	if not _entry_receipt_is_current(action_id, entry):
		return ExecuteResult.FAILED
	var metadata: Dictionary = entry["metadata"]
	var policy := StringName(metadata.get(
		"confirmation_policy", CONFIRMATION_NONE))
	if policy != CONFIRMATION_NONE:
		var confirmation_granted: Variant = context.get(
			"confirmation_granted", false)
		if not confirmation_granted is bool:
			return ExecuteResult.FAILED
		if bool(confirmation_granted):
			var supplied_token_value: Variant = context.get(
				CONFIRMATION_TOKEN_CONTEXT_KEY, 0)
			if typeof(supplied_token_value) != TYPE_INT:
				return ExecuteResult.FAILED
			var supplied_token := int(supplied_token_value)
			if (
				supplied_token <= 0
				or supplied_token != int(entry["pending_confirmation_token"])
			):
				return ExecuteResult.FAILED
			# Consume before the callback; nested or competing consumers fail closed.
			entry["pending_confirmation_token"] = 0
		else:
			_next_confirmation_token += 1
			entry["pending_confirmation_token"] = _next_confirmation_token
			var confirmation_context := context.duplicate(true)
			confirmation_context[CONFIRMATION_TOKEN_CONTEXT_KEY] = (
				_next_confirmation_token)
			var execution_count := int(entry["execution_count"])
			confirmation_requested.emit(
				action_id, policy, confirmation_context)
			if not _entry_receipt_is_current(action_id, entry):
				return ExecuteResult.FAILED
			var current := _get_live_entry(action_id)
			if int(current["execution_count"]) != execution_count:
				return ExecuteResult.EXECUTED
			if int(current["pending_confirmation_token"]) == 0:
				return ExecuteResult.FAILED
			return ExecuteResult.CONFIRMATION_REQUIRED
	var callback: Callable = entry["execute"]
	if not callback.is_valid():
		_prune_invalid_owners()
		return ExecuteResult.FAILED
	var callback_result: Variant = callback.call(context.duplicate(true))
	if not _entry_receipt_is_current(action_id, entry):
		return ExecuteResult.FAILED
	if not callback_result is bool or not bool(callback_result):
		return ExecuteResult.FAILED
	var live_entry := _get_live_entry(action_id)
	live_entry["execution_count"] = int(live_entry["execution_count"]) + 1
	action_state_changed.emit(action_id)
	return ExecuteResult.EXECUTED


## Owners call this after their can_execute/is_active inputs change. There is no
## polling or timer; declarative bindings repaint from this exact event.
func notify_action_state_changed(action_id: StringName) -> void:
	if _get_live_entry(action_id).is_empty():
		return
	action_state_changed.emit(action_id)


func notify_all_action_states_changed() -> void:
	_prune_invalid_owners()
	var receipts: Array[Dictionary] = []
	for action_id: StringName in _entries:
		var entry: Dictionary = _entries[action_id]
		receipts.append({
			"action_id": action_id,
			"generation": int(entry["generation"]),
			"owner_id": int(entry["owner_id"]),
		})
	for receipt: Dictionary in receipts:
		var action_id := StringName(receipt["action_id"])
		if _entry_receipt_is_current(action_id, receipt):
			action_state_changed.emit(action_id)


func _get_live_entry(action_id: StringName) -> Dictionary:
	if not _entries.has(action_id):
		return {}
	var entry: Dictionary = _entries[action_id]
	var owner_ref: WeakRef = entry["owner_ref"]
	var owner := owner_ref.get_ref()
	if owner == null or not is_instance_valid(owner):
		_erase_entry(action_id, true)
		return {}
	return entry


func _prune_invalid_owners() -> void:
	for action_id: StringName in _entries.keys():
		var entry: Dictionary = _entries[action_id]
		var owner_ref: WeakRef = entry["owner_ref"]
		var owner := owner_ref.get_ref()
		if owner == null or not is_instance_valid(owner):
			_erase_entry(action_id, true)


func _on_owner_tree_exiting(
	owner_id: int,
) -> void:
	if not _owners.has(owner_id):
		return
	var owner_record: Dictionary = _owners[owner_id]
	# Mark the owner before the first public signal. catalog_changed listeners
	# may synchronously try to register against the same still-inside-tree Node;
	# the tombstone remains until every snapshotted entry has been retired.
	owner_record["exiting"] = true
	_retiring_owner_ids[owner_id] = true
	var actions: Dictionary = (owner_record["actions"] as Dictionary).duplicate()
	for action_id: StringName in actions.keys():
		if not _entries.has(action_id):
			continue
		var entry: Dictionary = _entries[action_id]
		if (
			int(entry["owner_id"]) == owner_id
			and int(entry["generation"]) == int(actions[action_id])
		):
			_erase_entry(action_id, true)
	_owners.erase(owner_id)
	_retiring_owner_ids.erase(owner_id)


func _erase_entry(action_id: StringName, publish: bool) -> void:
	if not _entries.has(action_id):
		return
	var entry: Dictionary = _entries[action_id]
	_entries.erase(action_id)
	_untrack_owner_action(int(entry["owner_id"]), action_id)
	if publish:
		catalog_changed.emit()
		# catalog_changed already repaints a synchronously registered replacement;
		# never deliver the retired entry's second event to that new generation.
		if not _entries.has(action_id):
			action_state_changed.emit(action_id)


func _fail_construction(message: String) -> void:
	_accepting_initial_builtins = false
	_construction_capability_ref = null
	for action_id: StringName in _entries.keys():
		_erase_entry(action_id, false)
	_builtin_ids.clear()
	last_error = message
	_construction_valid = false


func _track_owner_action(
	owner: Node,
	action_id: StringName,
	generation: int,
) -> void:
	var owner_id := owner.get_instance_id()
	if not _owners.has(owner_id):
		var callback := _on_owner_tree_exiting.bind(owner_id)
		owner.tree_exiting.connect(callback, CONNECT_ONE_SHOT)
		_owners[owner_id] = {
			"owner_ref": weakref(owner),
			"tree_exit_callback": callback,
			"exiting": false,
			"actions": {},
		}
	var owner_record: Dictionary = _owners[owner_id]
	var actions: Dictionary = owner_record["actions"]
	actions[action_id] = generation


func _untrack_owner_action(owner_id: int, action_id: StringName) -> void:
	if not _owners.has(owner_id):
		return
	var owner_record: Dictionary = _owners[owner_id]
	var actions: Dictionary = owner_record["actions"]
	actions.erase(action_id)
	if not actions.is_empty():
		return
	var owner_ref: WeakRef = owner_record["owner_ref"]
	var owner := owner_ref.get_ref()
	var callback: Callable = owner_record["tree_exit_callback"]
	if (
		owner is Node
		and is_instance_valid(owner)
		and callback.is_valid()
		and (owner as Node).tree_exiting.is_connected(callback)
	):
		(owner as Node).tree_exiting.disconnect(callback)
	_owners.erase(owner_id)


func _query_can_execute(
	action_id: StringName,
	entry: Dictionary,
	context: Dictionary,
) -> bool:
	var callback: Callable = entry["can_execute"]
	if not callback.is_valid():
		return _entry_receipt_is_current(action_id, entry)
	var result: Variant = callback.call(context.duplicate(true))
	if not _entry_receipt_is_current(action_id, entry):
		return false
	return result is bool and bool(result)


func _entry_receipt_is_current(
	action_id: StringName,
	receipt: Dictionary,
) -> bool:
	var current := _get_live_entry(action_id)
	return (
		not current.is_empty()
		and int(current["generation"]) == int(receipt["generation"])
		and int(current["owner_id"]) == int(receipt["owner_id"])
	)


func _callback_belongs_to_owner(callback: Callable, owner: Node) -> bool:
	return callback.get_object_id() == owner.get_instance_id()


func _normalize_metadata(
	action_id: StringName,
	metadata: Dictionary,
	builtin: bool,
) -> Dictionary:
	var label := String(metadata.get("label", "")).strip_edges()
	var label_key := String(metadata.get("label_key", "")).strip_edges()
	var category := String(metadata.get("category", "")).strip_edges()
	var policy := StringName(metadata.get(
		"confirmation_policy", CONFIRMATION_NONE))
	if label.is_empty():
		last_error = "action metadata requires a fallback label"
		return {}
	if category.is_empty():
		last_error = "action metadata requires a category"
		return {}
	if not _CONFIRMATION_POLICIES.has(policy):
		last_error = "action metadata has an invalid confirmation policy"
		return {}
	var order_value: Variant = metadata.get("order", 0)
	if typeof(order_value) != TYPE_INT:
		last_error = "action metadata order must be an integer"
		return {}
	return {
		"id": String(action_id),
		"label": label,
		"label_key": label_key,
		"category": category,
		"description": String(metadata.get("description", "")),
		"description_key": String(metadata.get("description_key", "")),
		"toggle": bool(metadata.get("toggle", false)),
		"confirmation_policy": String(policy),
		"order": int(order_value),
		"builtin": builtin,
	}


func _is_valid_action_id(action_id: String, builtin: bool) -> bool:
	if (
		action_id.is_empty()
		or action_id.length() > _MAX_ACTION_ID_LENGTH
		or action_id != action_id.to_lower()
		or action_id.begins_with(".")
		or action_id.ends_with(".")
	):
		return false
	var segments := action_id.split(".", false)
	if not builtin and segments.size() < 2:
		return false
	for segment: String in segments:
		if segment.is_empty():
			return false
		var first := segment.unicode_at(0)
		if not _is_ascii_lower(first):
			return false
		for index: int in range(1, segment.length()):
			var code := segment.unicode_at(index)
			if (
				not _is_ascii_lower(code)
				and not (code >= 48 and code <= 57)
				and code != 95
				and code != 45
			):
				return false
	return true


func _is_ascii_lower(code: int) -> bool:
	return code >= 97 and code <= 122
