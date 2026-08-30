## Typed runtime/save value for a marker mix that has not triggered yet.
class_name BgmPendingMarkerMixState extends RefCounted

enum Phase { QUEUED, ARMED }

const SCHEMA_VERSION := 2
const EXACT_KEYS := [
	"fade_duration", "marker", "marker_frame", "marker_loop_epoch",
	"marker_ordinal", "marker_table_fingerprint", "phase",
	"restore_horizon_frame", "restore_horizon_loop_epoch", "schema_version",
	"stem_mix", "track_fingerprint", "wraps_loop",
]

var phase: Phase = Phase.QUEUED
var marker: String = ""
var marker_frame: int = -1
var marker_ordinal: int = -1
var marker_loop_epoch: int = -1
var restore_horizon_frame: int = -1
var restore_horizon_loop_epoch: int = -1
var wraps_loop: bool = false
var stem_mix: Dictionary = {}
var fade_duration: float = 0.0
var marker_table_fingerprint: String = ""
var track_fingerprint: String = ""


static func queued(
	marker_value: String,
	stem_mix_value: Dictionary,
	fade_duration_value: float,
	marker_table_fingerprint_value: String,
	track_fingerprint_value: String,
	restore_horizon_frame_value: int,
	restore_horizon_loop_epoch_value: int,
) -> BgmPendingMarkerMixState:
	var state := BgmPendingMarkerMixState.new()
	state.phase = Phase.QUEUED
	state.marker = marker_value
	state.stem_mix = stem_mix_value.duplicate(true)
	state.fade_duration = fade_duration_value
	state.marker_table_fingerprint = marker_table_fingerprint_value
	state.track_fingerprint = track_fingerprint_value
	state.restore_horizon_frame = restore_horizon_frame_value
	state.restore_horizon_loop_epoch = restore_horizon_loop_epoch_value
	return state if state.is_valid() else null


static func from_snapshot(raw_snapshot: Variant) -> BgmPendingMarkerMixState:
	if not raw_snapshot is Dictionary:
		return null
	var snapshot: Dictionary = raw_snapshot
	var keys := snapshot.keys()
	keys.sort()
	if (
		keys != EXACT_KEYS
		or not snapshot.get("schema_version", null) is int
		or snapshot["schema_version"] != SCHEMA_VERSION
	):
		return null
	if (
		not snapshot.get("phase", null) is String
		or not snapshot.get("marker", null) is String
		or not snapshot.get("marker_frame", null) is int
		or not snapshot.get("marker_ordinal", null) is int
		or not snapshot.get("marker_loop_epoch", null) is int
		or not snapshot.get("restore_horizon_frame", null) is int
		or not snapshot.get("restore_horizon_loop_epoch", null) is int
		or not snapshot.get("wraps_loop", null) is bool
		or not snapshot.get("fade_duration", null) is float
		or not snapshot.get("marker_table_fingerprint", null) is String
		or not snapshot.get("track_fingerprint", null) is String
	):
		return null
	var state := BgmPendingMarkerMixState.new()
	state.phase = (
		Phase.QUEUED if String(snapshot["phase"]) == "queued"
		else Phase.ARMED if String(snapshot["phase"]) == "armed"
		else -1
	)
	if state.phase < 0:
		return null
	state.marker = String(snapshot["marker"])
	state.marker_frame = int(snapshot["marker_frame"])
	state.marker_ordinal = int(snapshot["marker_ordinal"])
	state.marker_loop_epoch = int(snapshot["marker_loop_epoch"])
	state.restore_horizon_frame = int(snapshot["restore_horizon_frame"])
	state.restore_horizon_loop_epoch = int(
		snapshot["restore_horizon_loop_epoch"])
	state.wraps_loop = bool(snapshot["wraps_loop"])
	state.stem_mix = (snapshot.get("stem_mix", {}) as Dictionary).duplicate(true) \
		if snapshot.get("stem_mix", null) is Dictionary else {}
	state.fade_duration = float(snapshot["fade_duration"])
	state.marker_table_fingerprint = String(snapshot["marker_table_fingerprint"])
	state.track_fingerprint = String(snapshot["track_fingerprint"])
	return state if state.is_valid() else null


func armed(
	frame: int,
	ordinal: int,
	loop_epoch: int,
	horizon_frame: int,
	horizon_loop_epoch: int,
) -> BgmPendingMarkerMixState:
	var result := duplicate_value()
	result.phase = Phase.ARMED
	result.marker_frame = frame
	result.marker_ordinal = ordinal
	result.marker_loop_epoch = loop_epoch
	result.restore_horizon_frame = horizon_frame
	result.restore_horizon_loop_epoch = horizon_loop_epoch
	result.wraps_loop = loop_epoch > horizon_loop_epoch
	return result if result.is_valid() else null


func at_restore_horizon(
	horizon_frame: int,
	horizon_loop_epoch: int,
) -> BgmPendingMarkerMixState:
	var result := duplicate_value()
	result.restore_horizon_frame = horizon_frame
	result.restore_horizon_loop_epoch = horizon_loop_epoch
	if result.phase == Phase.ARMED:
		result.wraps_loop = result.marker_loop_epoch > horizon_loop_epoch
	return result if result.is_valid() else null


func duplicate_value() -> BgmPendingMarkerMixState:
	var result := BgmPendingMarkerMixState.new()
	result.phase = phase
	result.marker = marker
	result.marker_frame = marker_frame
	result.marker_ordinal = marker_ordinal
	result.marker_loop_epoch = marker_loop_epoch
	result.restore_horizon_frame = restore_horizon_frame
	result.restore_horizon_loop_epoch = restore_horizon_loop_epoch
	result.wraps_loop = wraps_loop
	result.stem_mix = stem_mix.duplicate(true)
	result.fade_duration = fade_duration
	result.marker_table_fingerprint = marker_table_fingerprint
	result.track_fingerprint = track_fingerprint
	return result


func to_snapshot() -> Dictionary:
	if not is_valid():
		return {}
	return {
		"fade_duration": fade_duration,
		"marker": marker,
		"marker_frame": marker_frame,
		"marker_loop_epoch": marker_loop_epoch,
		"marker_ordinal": marker_ordinal,
		"marker_table_fingerprint": marker_table_fingerprint,
		"phase": "queued" if phase == Phase.QUEUED else "armed",
		"schema_version": SCHEMA_VERSION,
		"stem_mix": stem_mix.duplicate(true),
		"track_fingerprint": track_fingerprint,
		"restore_horizon_frame": restore_horizon_frame,
		"restore_horizon_loop_epoch": restore_horizon_loop_epoch,
		"wraps_loop": wraps_loop,
	}


func is_valid() -> bool:
	if (
		phase not in [Phase.QUEUED, Phase.ARMED]
		or not BgmChannelState.is_valid_marker_label(marker)
		or not BgmChannelState.validate_stem_mix(stem_mix, false, true)
		or not is_finite(fade_duration)
		or fade_duration < 0.0
		or not _is_sha256(marker_table_fingerprint)
		or not _is_sha256(track_fingerprint)
		or restore_horizon_frame < 0
		or restore_horizon_loop_epoch < 0
	):
		return false
	if phase == Phase.QUEUED:
		return (
			marker_frame == -1
			and marker_ordinal == -1
			and marker_loop_epoch == -1
			and not wraps_loop
		)
	return (
		marker_frame >= 0
		and marker_ordinal >= 0
		and marker_loop_epoch >= restore_horizon_loop_epoch
		and wraps_loop == (marker_loop_epoch > restore_horizon_loop_epoch)
	)


func target_equals(marker_value: String, mix: Dictionary, fade: float) -> bool:
	return (
		marker == marker_value
		and fade_duration == fade
		and BgmChannelState.stem_mix_equal(stem_mix, mix)
	)


static func _is_sha256(value: String) -> bool:
	if value.length() != 64 or value != value.to_lower():
		return false
	for character: String in value:
		if character not in "0123456789abcdef":
			return false
	return true
