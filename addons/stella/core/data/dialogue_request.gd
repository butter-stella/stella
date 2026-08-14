## Typed, self-contained dialogue request used by Stella's canonical runtime
## path. Value fields are immutable snapshots; advance()/abort() resolve the
## request-scoped activation. The legacy three-argument show_dialogue signal is
## emitted only as a compatibility view.
class_name DialogueRequest extends RefCounted

var _character: String = ""
var _segments: Array = []
var _mode: String = "adv"
var _presentation_profile: Dictionary = {}
var _presentation_provenance: Dictionary = {}
var _declarative_presentation: bool = false
var _nvl_page_key: String = ""
var _nvl_page_entries: Array = []
var _entry_id: String = ""
var _command_uid: int = -1
var _activation: DialogueActivation
var _scenario_identity: String = ""
var _legacy_scenario_id: String = ""
var _scene_id: String = ""
var _legacy_command_index: int = -1


func _init(
	p_character: String = "",
	p_segments: Array = [],
	p_mode: String = "adv",
	p_presentation_profile: Dictionary = {},
	p_declarative_presentation: bool = false,
	p_nvl_page_key: String = "",
	p_presentation_provenance: Dictionary = {},
	p_nvl_page_entries: Array = [],
	p_entry_id: String = "",
	p_command_uid: int = -1,
	p_activation: DialogueActivation = null,
	p_scenario_identity: String = "",
	p_legacy_scenario_id: String = "",
	p_scene_id: String = "",
	p_legacy_command_index: int = -1,
) -> void:
	_character = p_character
	_segments = p_segments.duplicate(true)
	_mode = p_mode
	_presentation_profile = p_presentation_profile.duplicate(true)
	_declarative_presentation = p_declarative_presentation
	_nvl_page_key = p_nvl_page_key
	_presentation_provenance = p_presentation_provenance.duplicate(true)
	_nvl_page_entries = p_nvl_page_entries.duplicate(true)
	_entry_id = p_entry_id
	_command_uid = p_command_uid
	_activation = p_activation
	_scenario_identity = p_scenario_identity
	_legacy_scenario_id = p_legacy_scenario_id
	_scene_id = p_scene_id
	_legacy_command_index = p_legacy_command_index


func get_character() -> String:
	return _character


func get_segments() -> Array:
	return _segments.duplicate(true)


func get_mode() -> String:
	return _mode


func get_presentation_profile() -> Dictionary:
	return _presentation_profile.duplicate(true)


func get_presentation_provenance() -> Dictionary:
	return _presentation_provenance.duplicate(true)


func uses_declarative_presentation() -> bool:
	return _declarative_presentation


func get_nvl_page_key() -> String:
	return _nvl_page_key


func get_nvl_page_entries() -> Array:
	return _nvl_page_entries.duplicate(true)


func get_entry_id() -> String:
	return _entry_id


func get_command_uid() -> int:
	return _command_uid


## Acknowledge this exact command activation. Returns false after another
## outcome won or for a legacy request that has no blocking command owner.
func advance() -> bool:
	return _activation != null and _activation.advance()


## Abort this exact command activation. Returns false after it already resolved.
func abort() -> bool:
	return _activation != null and _activation.abort()


func get_activation() -> DialogueActivation:
	return _activation


func get_scenario_identity() -> String:
	return _scenario_identity


func get_legacy_scenario_id() -> String:
	return _legacy_scenario_id


func get_scene_id() -> String:
	return _scene_id


func get_legacy_command_index() -> int:
	return _legacy_command_index


func duplicate_request() -> DialogueRequest:
	return DialogueRequest.new(
		_character,
		_segments,
		_mode,
		_presentation_profile,
		_declarative_presentation,
		_nvl_page_key,
		_presentation_provenance,
		_nvl_page_entries,
		_entry_id,
		_command_uid,
		_activation,
		_scenario_identity,
		_legacy_scenario_id,
		_scene_id,
		_legacy_command_index,
	)
