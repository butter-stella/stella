## Canonical JSON-safe state and operation reducer for persistent loop-SE channels.
class_name LoopSeChannelState extends RefCounted

const VALID_ACTIONS := ["play", "stop"]
const EXACT_OPERATION_KEYS := [
	"action", "asset", "channel", "fade_duration", "resume_position", "volume",
]
const EXACT_STATE_KEYS := ["asset", "loop", "position", "volume"]
const MAX_CHANNEL_ID_LENGTH := 64


static func is_valid_channel_id(channel_id: String) -> bool:
	if channel_id.is_empty() or channel_id.length() > MAX_CHANNEL_ID_LENGTH:
		return false
	var first := channel_id.unicode_at(0)
	if not _is_ascii_letter(first) and first != 95:
		return false
	for index in range(1, channel_id.length()):
		var code := channel_id.unicode_at(index)
		if (
			not _is_ascii_letter(code)
			and not (code >= 48 and code <= 57)
			and code not in [45, 95]
		):
			return false
	return true


static func validate_operation(raw_operation: Variant, report: bool = true) -> bool:
	if not raw_operation is Dictionary:
		return _reject(report, "operation must be a Dictionary")
	var operation: Dictionary = raw_operation
	var keys := operation.keys()
	keys.sort()
	if keys != EXACT_OPERATION_KEYS:
		return _reject(report, "operation must use the canonical six-field schema")
	for key: String in ["action", "asset", "channel"]:
		if not operation.get(key, null) is String:
			return _reject(report, "%s must be a String" % key)
	for key: String in ["fade_duration", "resume_position", "volume"]:
		var value: Variant = operation.get(key, null)
		if not (value is int or value is float) or not is_finite(float(value)):
			return _reject(report, "%s must be finite" % key)
	var action := String(operation["action"])
	var channel_id := String(operation["channel"])
	var asset := String(operation["asset"])
	var fade_duration := float(operation["fade_duration"])
	var resume_position := float(operation["resume_position"])
	var volume := float(operation["volume"])
	if action not in VALID_ACTIONS:
		return _reject(report, "action must be play or stop")
	if not is_valid_channel_id(channel_id):
		return _reject(report, "invalid loop-SE channel id '%s'" % channel_id)
	if fade_duration < 0.0:
		return _reject(report, "fade_duration must be non-negative")
	if resume_position < 0.0:
		return _reject(report, "resume_position must be non-negative")
	if volume < 0.0 or volume > 1.0:
		return _reject(report, "volume must be between 0 and 1")
	if action == "play":
		if asset.is_empty() or asset != asset.strip_edges():
			return _reject(report, "play requires a canonical non-empty asset")
	else:
		if not asset.is_empty() or volume != 1.0 or resume_position != 0.0:
			return _reject(
				report,
				"stop requires empty asset, volume=1, and resume_position=0",
			)
	return true


static func validate_snapshot_state(raw_state: Variant, report: bool = true) -> bool:
	if not raw_state is Dictionary:
		return _reject(report, "channel state must be a Dictionary")
	var state: Dictionary = raw_state
	var keys := state.keys()
	keys.sort()
	if keys != EXACT_STATE_KEYS:
		return _reject(report, "channel state must use the canonical four-field schema")
	if (
		not state.get("asset", null) is String
		or String(state["asset"]).is_empty()
		or String(state["asset"]) != String(state["asset"]).strip_edges()
		or not state.get("loop", null) is bool
		or not bool(state["loop"])
	):
		return _reject(report, "channel state requires a canonical asset and loop=true")
	for key: String in ["position", "volume"]:
		var value: Variant = state.get(key, null)
		if not (value is int or value is float) or not is_finite(float(value)):
			return _reject(report, "%s must be finite" % key)
	if float(state["position"]) < 0.0:
		return _reject(report, "position must be non-negative")
	if float(state["volume"]) < 0.0 or float(state["volume"]) > 1.0:
		return _reject(report, "volume must be between 0 and 1")
	return true


static func validate_channels(raw_channels: Variant, report: bool = true) -> bool:
	if not raw_channels is Dictionary:
		return _reject(report, "loop-SE channels must be a Dictionary")
	for raw_channel_id: Variant in raw_channels:
		if (
			not raw_channel_id is String
			or not is_valid_channel_id(String(raw_channel_id))
			or not validate_snapshot_state(raw_channels[raw_channel_id], report)
		):
			return false
	return true


static func reduce(channels: Dictionary, operations: Array, report: bool = true) -> Dictionary:
	var result := channels.duplicate(true)
	for operation_value: Variant in operations:
		if not validate_operation(operation_value, report):
			return channels.duplicate(true)
		var operation: Dictionary = operation_value
		if not operation_has_work(result, operation):
			continue
		var channel_id := String(operation["channel"])
		if String(operation["action"]) == "stop":
			result.erase(channel_id)
		else:
			var position := float(operation["resume_position"])
			var current: Variant = result.get(channel_id)
			if (
				validate_snapshot_state(current, false)
				and String((current as Dictionary)["asset"])
					== String(operation["asset"])
			):
				# Volume-only updates preserve playback progress. The authored resume
				# cursor belongs only to a new channel or asset replacement.
				position = float((current as Dictionary)["position"])
			result[channel_id] = {
				"asset": String(operation["asset"]),
				"loop": true,
				"position": position,
				"volume": float(operation["volume"]),
			}
	return result


## Position is playback progress, not authored target identity. Replaying the
## same asset+volume at a restored cursor must not duplicate or seek the channel.
static func operation_has_work(channels: Dictionary, operation: Dictionary) -> bool:
	if not validate_operation(operation, false):
		return false
	var channel_id := String(operation["channel"])
	if String(operation["action"]) == "stop":
		return channels.has(channel_id)
	if not channels.has(channel_id):
		return true
	var current: Variant = channels[channel_id]
	if not validate_snapshot_state(current, false):
		return true
	var state: Dictionary = current
	return (
		String(state["asset"]) != String(operation["asset"])
		or float(state["volume"]) != float(operation["volume"])
	)


static func with_positions(channels: Dictionary, positions: Dictionary) -> Dictionary:
	var result := channels.duplicate(true)
	for raw_channel_id: Variant in result:
		var channel_id := String(raw_channel_id)
		if not positions.has(channel_id):
			continue
		var position_value: Variant = positions[channel_id]
		if (
			(position_value is int or position_value is float)
			and is_finite(float(position_value))
			and float(position_value) >= 0.0
		):
			(result[channel_id] as Dictionary)["position"] = float(position_value)
	return result


static func _is_ascii_letter(code: int) -> bool:
	return (code >= 65 and code <= 90) or (code >= 97 and code <= 122)


static func _reject(report: bool, message: String) -> bool:
	if report:
		push_warning("LoopSeChannelState: %s" % message)
	return false
