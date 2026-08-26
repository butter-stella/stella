## Runtime-owned snapshot-capable selection authority for clip audio choices.
##
## One hold captures the exact previous RNG/last-choice state. Commit advances
## that private candidate state once; abort restores it, and complete seals it.
class_name PresentationClipAudioChoiceAuthority extends RefCounted

const PROVIDER_ID := "presentation_clip_audio_choice"
const SNAPSHOT_VERSION := 1
const MULTIPLIER := 48271
const MODULUS := 2147483647

var _configured_seed: int
var _entropy_source: Callable
var _initialized := false
var _initial_seed := 0
var _state := 0
var _last_choices: Dictionary = {}
var _transaction: Dictionary = {}


func _init(configured_seed: int = 0, entropy_source: Callable = Callable()) -> void:
	_configured_seed = configured_seed
	_entropy_source = entropy_source


func get_provider_id() -> String:
	return PROVIDER_ID


func set_configured_seed(configured_seed: int) -> bool:
	if configured_seed < 0 or configured_seed >= MODULUS:
		return false
	_configured_seed = configured_seed
	return true


func start_fresh_run() -> bool:
	if not _transaction.is_empty() or _configured_seed < 0 or _configured_seed >= MODULUS:
		return false
	var seed := _configured_seed
	if seed == 0:
		seed = _entropy_seed()
	if seed <= 0 or seed >= MODULUS:
		return false
	_transaction.clear()
	_initialized = true
	_initial_seed = seed
	_state = seed
	_last_choices.clear()
	return true


func clear_to_unstarted() -> bool:
	if not _transaction.is_empty():
		return false
	_initialized = false
	_initial_seed = 0
	_state = 0
	_last_choices.clear()
	return true


func hold(transaction_id: int) -> bool:
	if not _initialized or transaction_id == 0 or not _transaction.is_empty():
		return false
	_transaction = {
		"id": transaction_id,
		"before": _raw_snapshot(),
		"committed": false,
	}
	return true


func commit(transaction_id: int, plans: Array) -> Dictionary:
	if not _transaction_is_current(transaction_id) or bool(
		_transaction.get("committed", false)):
		return {"ok": false, "selections": {}}
	var validation_error := _plans_validation_error(plans)
	if not validation_error.is_empty():
		return {"ok": false, "selections": {}, "error": validation_error}
	var selections: Dictionary = {}
	for plan_value: Variant in plans:
		var plan: Dictionary = plan_value
		var eligible: Array = (plan["eligible_ids"] as Array).duplicate()
		if eligible.is_empty():
			continue
		var clip_asset := String(plan["clip_asset"])
		var cue_ordinal := int(plan["cue_ordinal"])
		var cue_key := str(cue_ordinal)
		var repeat_policy := StringName(plan["repeat_policy"])
		var previous := String(
			(_last_choices.get(clip_asset, {}) as Dictionary).get(cue_key, ""))
		var selection_pool := eligible
		if repeat_policy == &"no_repeat" and eligible.size() >= 2 and previous in eligible:
			selection_pool = eligible.duplicate()
			selection_pool.erase(previous)
		_state = (_state * MULTIPLIER) % MODULUS
		var selection_index := int(
			(_state * selection_pool.size()) / MODULUS)
		selection_index = mini(selection_index, selection_pool.size() - 1)
		var selected := String(selection_pool[selection_index])
		selections[cue_ordinal] = selected
		var clip_last: Dictionary = (
			(_last_choices.get(clip_asset, {}) as Dictionary).duplicate())
		clip_last[cue_key] = selected
		_last_choices[clip_asset] = clip_last
	_transaction["committed"] = true
	_transaction["selections"] = selections.duplicate()
	return {"ok": true, "selections": selections.duplicate()}


func complete(transaction_id: int) -> bool:
	if not _transaction_is_current(transaction_id) or not bool(
		_transaction.get("committed", false)):
		return false
	_transaction.clear()
	return true


func abort(transaction_id: int) -> bool:
	if not _transaction_is_current(transaction_id):
		return false
	var before: Dictionary = _transaction.get("before", {})
	_transaction.clear()
	if not validate_snapshot(before):
		return false
	_apply_validated_snapshot(before)
	return true


func capture_snapshot() -> Dictionary:
	if not _transaction.is_empty():
		return (_transaction.get("before", {}) as Dictionary).duplicate(true)
	return _raw_snapshot()


static func initial_playthrough_snapshot(raw_snapshot: Variant) -> Dictionary:
	if (
		not validate_snapshot(raw_snapshot)
		or not bool((raw_snapshot as Dictionary).get("initialized", false))
	):
		return {}
	var snapshot := raw_snapshot as Dictionary
	var seed := int(snapshot["initial_seed"])
	return {
		"version": SNAPSHOT_VERSION,
		"initialized": true,
		"initial_seed": seed,
		"state": seed,
		"last_choices": {},
	}


func _raw_snapshot() -> Dictionary:
	return {
		"version": SNAPSHOT_VERSION,
		"initialized": _initialized,
		"initial_seed": _initial_seed,
		"state": _state,
		"last_choices": _last_choices.duplicate(true),
	}


func restore_snapshot(snapshot: Dictionary) -> bool:
	if not _transaction.is_empty() or not validate_snapshot(snapshot):
		return false
	_apply_validated_snapshot(snapshot)
	return true


func _apply_validated_snapshot(snapshot: Dictionary) -> void:
	_initialized = bool(snapshot["initialized"])
	_initial_seed = int(snapshot["initial_seed"])
	_state = int(snapshot["state"])
	_last_choices = (snapshot["last_choices"] as Dictionary).duplicate(true)


static func validate_snapshot(raw_snapshot: Variant) -> bool:
	if not raw_snapshot is Dictionary:
		return false
	var snapshot: Dictionary = raw_snapshot
	var exact_keys := [
		"version", "initialized", "initial_seed", "state", "last_choices",
	]
	if snapshot.size() != exact_keys.size():
		return false
	for key: String in exact_keys:
		if not snapshot.has(key):
			return false
	if not _integer_equals(snapshot["version"], SNAPSHOT_VERSION):
		return false
	if not snapshot["initialized"] is bool:
		return false
	var initialized := bool(snapshot["initialized"])
	if not _integer_in_range(snapshot["initial_seed"], 0, MODULUS - 1):
		return false
	if not _integer_in_range(snapshot["state"], 0, MODULUS - 1):
		return false
	var initial_seed := int(snapshot["initial_seed"])
	var state := int(snapshot["state"])
	if initialized != (initial_seed > 0 and state > 0):
		return false
	if not snapshot["last_choices"] is Dictionary:
		return false
	if not initialized and not (snapshot["last_choices"] as Dictionary).is_empty():
		return false
	for clip_value: Variant in snapshot["last_choices"]:
		if not clip_value is String or not PresentationClipDefinition.is_logical_id(
			String(clip_value)):
			return false
		var cue_map: Variant = snapshot["last_choices"][clip_value]
		if (
			not cue_map is Dictionary
			or (cue_map as Dictionary).size() > PresentationClipDefinition.MAX_CUES
		):
			return false
		for cue_value: Variant in cue_map:
			if (
				not cue_value is String
				or not String(cue_value).is_valid_int()
				or str(int(cue_value)) != String(cue_value)
				or int(cue_value) < 0
				or int(cue_value) >= PresentationClipDefinition.MAX_CUES
				or not cue_map[cue_value] is String
				or not PresentationClipDefinition.is_logical_id(
					String(cue_map[cue_value]))
			):
				return false
	return true


static func validate_playthrough_snapshot(raw_snapshot: Variant) -> bool:
	return (
		validate_snapshot(raw_snapshot)
		and bool((raw_snapshot as Dictionary).get("initialized", false))
	)


func _entropy_seed() -> int:
	var raw_bytes: Variant = (
		_entropy_source.call()
		if _entropy_source.is_valid()
		else Crypto.new().generate_random_bytes(8))
	if not raw_bytes is PackedByteArray:
		return 0
	var bytes := raw_bytes as PackedByteArray
	if bytes.is_empty():
		return 0
	var value := 0
	for byte_value: int in bytes:
		value = (value * 256 + byte_value) % (MODULUS - 1)
	return value + 1


func _transaction_is_current(transaction_id: int) -> bool:
	return (
		transaction_id != 0
		and int(_transaction.get("id", 0)) == transaction_id
	)


func _plans_validation_error(plans: Array) -> String:
	var ordinals: Dictionary = {}
	var previous_ordinal := -1
	var total_eligible_candidates := 0
	for plan_value: Variant in plans:
		if not plan_value is Dictionary:
			return "audio-choice transaction plan must be a Dictionary"
		var plan: Dictionary = plan_value
		if (
			plan.size() != 4
			or not plan.get("clip_asset", null) is String
			or not PresentationClipDefinition.is_logical_id(String(plan["clip_asset"]))
			or not plan.get("cue_ordinal", null) is int
			or int(plan["cue_ordinal"]) < 0
			or int(plan["cue_ordinal"]) >= PresentationClipDefinition.MAX_CUES
			or not plan.get("eligible_ids", null) is Array
			or not plan.get("repeat_policy", null) is String
			or StringName(plan["repeat_policy"]) not in [
				&"allow_repeat", &"no_repeat",
			]
		):
			return "audio-choice transaction plan has an invalid closed schema"
		var ordinal := int(plan["cue_ordinal"])
		if ordinal <= previous_ordinal:
			return "audio-choice transaction plans must use ascending cue ordinals"
		previous_ordinal = ordinal
		if ordinals.has(ordinal):
			return "audio-choice transaction plan repeats cue ordinal %d" % ordinal
		ordinals[ordinal] = true
		var candidate_ids: Dictionary = {}
		if (
			(plan["eligible_ids"] as Array).size()
			> PresentationClipAudioChoiceCue.MAX_CANDIDATES
		):
			return "audio-choice transaction plan exceeds the per-cue candidate cap"
		total_eligible_candidates += (plan["eligible_ids"] as Array).size()
		if (
			total_eligible_candidates
			> PresentationClipDefinition.MAX_TOTAL_AUDIO_CHOICE_CANDIDATES
		):
			return "audio-choice transaction plans exceed the definition candidate cap"
		for candidate_value: Variant in plan["eligible_ids"]:
			if (
				not candidate_value is String
				or not PresentationClipDefinition.is_logical_id(String(candidate_value))
				or candidate_ids.has(String(candidate_value))
			):
				return "audio-choice transaction contains an invalid eligible candidate id"
			candidate_ids[String(candidate_value)] = true
	return ""


static func _integer_equals(value: Variant, expected: int) -> bool:
	return (
		value is int and int(value) == expected
		or value is float and is_finite(value) and value == float(expected)
	)


static func _integer_in_range(value: Variant, minimum: int, maximum: int) -> bool:
	return (
		(value is int or value is float)
		and is_finite(float(value))
		and float(value) == floor(float(value))
		and int(value) >= minimum
		and int(value) <= maximum
	)
