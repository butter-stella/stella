## One uniform choice among ordered presentation-clip audio candidates.
##
## This Resource remains definition-only data. Selection is committed exactly
## once by the Runtime-owned audio-choice authority before cue publication.
class_name PresentationClipAudioChoiceCue extends PresentationClipCue

const SELECTION_POLICIES := [&"uniform"]
const REPEAT_POLICIES := [&"allow_repeat", &"no_repeat"]
const MAX_CANDIDATES := 32

@export var selection_policy: StringName = &"uniform"
@export var repeat_policy: StringName = &"allow_repeat"
@export var candidates: Array[PresentationClipAudioChoiceCandidate] = []


func validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	if selection_policy not in SELECTION_POLICIES:
		errors.append("selection_policy must be uniform")
	if repeat_policy not in REPEAT_POLICIES:
		errors.append("repeat_policy must be allow_repeat or no_repeat")
	if candidates.is_empty():
		errors.append("candidates must contain 1..32 authored candidates")
	elif candidates.size() > MAX_CANDIDATES:
		errors.append("candidates exceeds the 32-candidate work cap")
	# The count is a preflight work reservation, not merely a diagnostic. Never
	# traverse cap-exceeding authored data while explaining its rejection.
	if candidates.is_empty() or candidates.size() > MAX_CANDIDATES:
		return errors
	var ids: Dictionary = {}
	for candidate_index in range(candidates.size()):
		var candidate := candidates[candidate_index]
		if candidate == null:
			errors.append("candidates[%d] must not be null" % candidate_index)
			continue
		var provenance := " authored at <unavailable>"
		if (
			not candidate.authored_source_path.is_empty()
			and candidate.authored_source_line > 0
		):
			provenance = " authored at %s:%d" % [
				candidate.authored_source_path, candidate.authored_source_line,
			]
		for detail: String in candidate.validation_errors():
			errors.append("candidates[%d] id '%s'%s: %s" % [
				candidate_index, String(candidate.id), provenance, detail,
			])
		var candidate_id := String(candidate.id)
		if ids.has(candidate_id):
			errors.append("candidates[%d] contains duplicate candidate id '%s'" % [
				candidate_index, candidate_id,
			])
		ids[candidate_id] = true
	return errors


func canonical_candidates_snapshot() -> Array:
	if candidates.size() > MAX_CANDIDATES:
		return [{"invalid_candidate_count": candidates.size()}]
	var result: Array = []
	for candidate_index in range(candidates.size()):
		var candidate := candidates[candidate_index]
		result.append(
			candidate.canonical_value_snapshot(candidate_index)
			if candidate != null else null)
	return result
