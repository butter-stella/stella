## One ordered canonical candidate inside a presentation-clip audio choice.
##
## Character bindings select the existing voice settings domain. Empty bindings
## select the existing system-SE settings domain. Volume and eligibility remain
## authoritative Runtime settings and are deliberately not duplicated here.
class_name PresentationClipAudioChoiceCandidate extends Resource

@export var id: StringName = &""
@export var asset: String = ""
@export var authored_enabled: bool = true
@export var character: String = ""
@export var authored_source_path: String = ""
@export var authored_source_line: int = 0


func validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	if not PresentationClipDefinition.is_logical_id(String(id)):
		errors.append("candidate id must be a canonical stable id")
	if not PresentationClipDefinition.is_logical_id(asset):
		errors.append("asset must be a canonical logical id")
	if (
		character != character.strip_edges()
		or character.length() > VoicePlaybackRequest.MAX_LOGICAL_ID_LENGTH
	):
		errors.append("character binding must be a bounded canonical id")
	if authored_source_path.is_empty() and authored_source_line == 0:
		return errors
	if authored_source_path.is_empty() or authored_source_line <= 0:
		errors.append(
			"authored_source provenance requires both path and positive line")
	return errors


func canonical_value_snapshot(ordinal: int) -> Dictionary:
	return {
		"ordinal": ordinal,
		"id": String(id),
		"asset": asset,
		"authored_enabled": authored_enabled,
		"character": character,
		"authored_source_path": authored_source_path,
		"authored_source_line": authored_source_line,
	}
