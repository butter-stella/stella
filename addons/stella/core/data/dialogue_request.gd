## Typed, self-contained dialogue request used by Stella's canonical runtime
## path. The legacy three-argument show_dialogue signal is emitted only as a
## compatibility view of this immutable snapshot.
class_name DialogueRequest extends RefCounted

var character: String = ""
var segments: Array = []
var mode: String = "adv"
var presentation_profile: Dictionary = {}
var presentation_provenance: Dictionary = {}
var declarative_presentation: bool = false
var nvl_page_key: String = ""
var nvl_page_entries: Array = []


func _init(
	p_character: String = "",
	p_segments: Array = [],
	p_mode: String = "adv",
	p_presentation_profile: Dictionary = {},
	p_declarative_presentation: bool = false,
	p_nvl_page_key: String = "",
	p_presentation_provenance: Dictionary = {},
	p_nvl_page_entries: Array = [],
) -> void:
	character = p_character
	segments = p_segments.duplicate(true)
	mode = p_mode
	presentation_profile = p_presentation_profile.duplicate(true)
	declarative_presentation = p_declarative_presentation
	nvl_page_key = p_nvl_page_key
	presentation_provenance = p_presentation_provenance.duplicate(true)
	nvl_page_entries = p_nvl_page_entries.duplicate(true)


func duplicate_request() -> DialogueRequest:
	return DialogueRequest.new(
		character,
		segments,
		mode,
		presentation_profile,
		declarative_presentation,
		nvl_page_key,
		presentation_provenance,
		nvl_page_entries,
	)
