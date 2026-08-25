## Canonical JSON-safe state and operation validation for the single BGM channel.
class_name BgmChannelState extends RefCounted

const VALID_ACTIONS := ["play", "mix", "pause", "resume", "stop"]
const VALID_STATUSES := ["playing", "paused"]
const EXACT_OPERATION_KEYS := [
	"action", "asset", "cue", "fade_duration", "resume_position", "stem_mix",
	"volume",
]
const EXACT_STATE_KEYS := [
	"asset", "cue", "loop", "position", "status", "stem_mix", "volume",
]
const MAX_CUE_NAME_LENGTH := 64
const MAX_STEM_NAME_LENGTH := 64


static func empty_state() -> Dictionary:
	return {}


static func is_valid_cue_name(cue_name: String, allow_empty: bool = true) -> bool:
	if cue_name.is_empty():
		return allow_empty
	if cue_name.length() > MAX_CUE_NAME_LENGTH:
		return false
	var first := cue_name.unicode_at(0)
	if not _is_ascii_letter(first) and first != 95:
		return false
	for index in range(1, cue_name.length()):
		var code := cue_name.unicode_at(index)
		if (
			not _is_ascii_letter(code)
			and not (code >= 48 and code <= 57)
			and code not in [45, 95]
		):
			return false
	return true


static func is_valid_stem_name(stem_name: String) -> bool:
	if stem_name.is_empty() or stem_name.length() > MAX_STEM_NAME_LENGTH:
		return false
	var first := stem_name.unicode_at(0)
	if not _is_ascii_letter(first) and first != 95:
		return false
	for index in range(1, stem_name.length()):
		var code := stem_name.unicode_at(index)
		if (
			not _is_ascii_letter(code)
			and not (code >= 48 and code <= 57)
			and code not in [45, 95]
		):
			return false
	return true


static func validate_stem_mix(
	raw_mix: Variant,
	allow_empty: bool = true,
	require_audible: bool = false,
) -> bool:
	if not raw_mix is Dictionary:
		return false
	var stem_mix: Dictionary = raw_mix
	if stem_mix.is_empty():
		return allow_empty and not require_audible
	if stem_mix.size() > AudioStreamSynchronized.MAX_STREAMS:
		return false
	var has_audible_stem := false
	for key_value: Variant in stem_mix.keys():
		if not key_value is String or not is_valid_stem_name(String(key_value)):
			return false
		var gain: Variant = stem_mix[key_value]
		if (
			not (gain is int or gain is float)
			or not is_finite(float(gain))
			or float(gain) < 0.0
			or float(gain) > 1.0
		):
			return false
		has_audible_stem = has_audible_stem or float(gain) > 0.0
	return not require_audible or has_audible_stem


static func validate_operation(raw_operation: Variant, report: bool = true) -> bool:
	if not raw_operation is Dictionary:
		return _reject(report, "operation must be a Dictionary")
	var operation: Dictionary = raw_operation
	var keys := operation.keys()
	keys.sort()
	if keys != EXACT_OPERATION_KEYS:
		return _reject(report, "operation must use the canonical seven-field schema")
	for key: String in ["action", "asset", "cue"]:
		if not operation.get(key, null) is String:
			return _reject(report, "%s must be a String" % key)
	for key: String in ["fade_duration", "resume_position", "volume"]:
		var value: Variant = operation.get(key, null)
		if not (value is int or value is float) or not is_finite(float(value)):
			return _reject(report, "%s must be finite" % key)
	var action := String(operation["action"])
	var asset := String(operation["asset"])
	var cue := String(operation["cue"])
	var fade_duration := float(operation["fade_duration"])
	var resume_position := float(operation["resume_position"])
	var stem_mix: Variant = operation["stem_mix"]
	var volume := float(operation["volume"])
	if action not in VALID_ACTIONS:
		return _reject(report, "action must be play, mix, pause, resume, or stop")
	var explicit_mix := (
		stem_mix is Dictionary and not (stem_mix as Dictionary).is_empty())
	if not validate_stem_mix(
		stem_mix, action != "mix", action == "mix" or explicit_mix):
		return _reject(report, "stem_mix must be a canonical gain Dictionary")
	if fade_duration < 0.0:
		return _reject(report, "fade_duration must be non-negative")
	if resume_position < 0.0:
		return _reject(report, "resume_position must be non-negative")
	if volume < 0.0 or volume > 1.0:
		return _reject(report, "volume must be between 0 and 1")
	if action == "play":
		if asset.is_empty() or asset != asset.strip_edges() or "\u0000" in asset:
			return _reject(report, "play requires a canonical non-empty asset")
		if cue != cue.strip_edges() or not is_valid_cue_name(cue):
			return _reject(report, "play has an invalid cue name")
	elif action == "mix":
		if (
			not asset.is_empty()
			or not cue.is_empty()
			or volume != 1.0
			or resume_position != 0.0
		):
			return _reject(
				report,
				"mix requires empty asset/cue, volume=1, and resume_position=0",
			)
	else:
		if (
			not asset.is_empty()
			or not cue.is_empty()
			or not (stem_mix as Dictionary).is_empty()
			or volume != 1.0
			or resume_position != 0.0
		):
			return _reject(
				report,
				"%s requires empty asset/cue, volume=1, and resume_position=0"
					% action,
			)
	return true


static func validate_snapshot_state(raw_state: Variant, report: bool = true) -> bool:
	if not raw_state is Dictionary:
		return _reject(report, "BGM state must be a Dictionary")
	var state: Dictionary = raw_state
	if state.is_empty():
		return true
	var keys := state.keys()
	keys.sort()
	if keys != EXACT_STATE_KEYS:
		return _reject(report, "active BGM state must use the canonical seven-field schema")
	if (
		not state.get("asset", null) is String
		or String(state["asset"]).is_empty()
		or String(state["asset"]) != String(state["asset"]).strip_edges()
		or "\u0000" in String(state["asset"])
		or not state.get("cue", null) is String
		or String(state["cue"]) != String(state["cue"]).strip_edges()
		or not is_valid_cue_name(String(state["cue"]))
		or not state.get("loop", null) is bool
		or not state.get("status", null) is String
		or String(state["status"]) not in VALID_STATUSES
	):
		return _reject(report, "active BGM state has invalid identity or lifecycle fields")
	var state_mix: Variant = state.get("stem_mix", null)
	var requires_audible_mix := (
		state_mix is Dictionary and not (state_mix as Dictionary).is_empty())
	if not validate_stem_mix(state_mix, true, requires_audible_mix):
		return _reject(report, "active BGM state has an invalid stem_mix")
	for key: String in ["position", "volume"]:
		var value: Variant = state.get(key, null)
		if not (value is int or value is float) or not is_finite(float(value)):
			return _reject(report, "%s must be finite" % key)
	if float(state["position"]) < 0.0:
		return _reject(report, "position must be non-negative")
	if float(state["volume"]) < 0.0 or float(state["volume"]) > 1.0:
		return _reject(report, "volume must be between 0 and 1")
	return true


static func operation_is_supported(state: Dictionary, operation: Dictionary) -> bool:
	if not validate_snapshot_state(state, false) or not validate_operation(operation, false):
		return false
	var action := String(operation["action"])
	if action == "mix":
		return not state.is_empty() and not (state["stem_mix"] as Dictionary).is_empty()
	return action in ["play", "stop"] or not state.is_empty()


## Playback position is progress, not authored target identity. A same-cursor
## replay after load must validate the resource and live projection without
## restarting a stable player.
static func operation_has_work(state: Dictionary, operation: Dictionary) -> bool:
	if not operation_is_supported(state, operation):
		return false
	var action := String(operation["action"])
	if action == "stop":
		return not state.is_empty()
	if action == "pause":
		return String(state.get("status", "")) != "paused"
	if action == "resume":
		return String(state.get("status", "")) != "playing"
	if action == "mix":
		return not stem_mix_equal(
			state.get("stem_mix", {}) as Dictionary,
			operation["stem_mix"] as Dictionary,
		)
	return (
		state.is_empty()
		or String(state.get("status", "")) != "playing"
		or String(state.get("asset", "")) != String(operation["asset"])
		or String(state.get("cue", "")) != String(operation["cue"])
		or (
			not (operation["stem_mix"] as Dictionary).is_empty()
			and not stem_mix_equal(
				state.get("stem_mix", {}) as Dictionary,
				operation["stem_mix"] as Dictionary,
			)
		)
		or float(state.get("volume", -1.0)) != float(operation["volume"])
	)


static func with_position(state: Dictionary, position: float) -> Dictionary:
	var result := state.duplicate(true)
	if (
		result.is_empty()
		or not is_finite(position)
		or position < 0.0
	):
		return result
	result["position"] = position
	return result


static func _is_ascii_letter(code: int) -> bool:
	return (code >= 65 and code <= 90) or (code >= 97 and code <= 122)


static func stem_mix_equal(first: Dictionary, second: Dictionary) -> bool:
	if first.size() != second.size():
		return false
	for stem_name: Variant in first.keys():
		if (
			not second.has(stem_name)
			or not is_equal_approx(float(first[stem_name]), float(second[stem_name]))
		):
			return false
	return true


static func _reject(report: bool, message: String) -> bool:
	if report:
		push_warning("BgmChannelState: %s" % message)
	return false
