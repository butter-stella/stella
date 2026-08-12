## Loads and provides access to stella.cfg project configuration.
## All fields have sensible defaults — a missing config file is valid.
class_name StellaConfig
extends RefCounted

const _CONFIG_SCHEMA := {
	"game": {
		"title": {"property": "game_title", "type": TYPE_STRING},
		"scenario": {"property": "scenario_path", "type": TYPE_STRING},
		"title_bgm": {"property": "title_bgm", "type": TYPE_STRING},
	},
	"paths": {
		"backgrounds": {"property": "backgrounds_path", "type": TYPE_STRING},
		"characters": {"property": "characters_path", "type": TYPE_STRING},
		"stage": {"property": "stage_path", "type": TYPE_STRING},
		"bgm": {"property": "bgm_path", "type": TYPE_STRING},
		"se": {"property": "se_path", "type": TYPE_STRING},
		"voice": {"property": "voice_path", "type": TYPE_STRING},
	},
	"features": {
		"cg_gallery": {"property": "cg_gallery", "type": TYPE_BOOL},
		"backlog": {"property": "backlog", "type": TYPE_BOOL},
		"save_slots": {"property": "save_slots", "type": TYPE_INT},
	},
	"system_se": {
		"select": {"property": "se_select", "type": TYPE_STRING},
		"cancel": {"property": "se_cancel", "type": TYPE_STRING},
	},
	"overrides": {
		"title_scene": {"property": "title_scene", "type": TYPE_STRING},
		"game_scene": {"property": "game_scene", "type": TYPE_STRING},
		"settings_scene": {"property": "settings_scene", "type": TYPE_STRING},
		"save_load_scene": {"property": "save_load_scene", "type": TYPE_STRING},
		"backlog_scene": {"property": "backlog_scene", "type": TYPE_STRING},
		"flowchart_scene": {"property": "flowchart_scene", "type": TYPE_STRING},
	},
}

## Whether a config file was actually found and loaded.
var has_config_file: bool = false

## Most recent source-load failure. Successful loads clear these fields.
## Details contain only source/schema metadata, never configuration values.
var last_error: Error = OK
var last_error_source: String = ""
var last_error_detail: String = ""

# [game]
var game_title: String = "Stella"
var scenario_path: String = "res://scenarios/main.stla"
var title_bgm: String = ""  # BGM asset name for title screen

# [paths]
var backgrounds_path: String = "res://art/backgrounds/"
var characters_path: String = "res://art/characters/"
var stage_path: String = "res://art/stage/"
var bgm_path: String = "res://audio/bgm/"
var se_path: String = "res://audio/se/"
var voice_path: String = "res://audio/voice/"

# [features]
var cg_gallery: bool = false
var backlog: bool = true
var save_slots: int = 8

# [system_se] — file names (without extension) for UI sound effects
var se_select: String = ""      # choice / menu selection
var se_cancel: String = ""      # cancel / close overlay

# [overrides]
var title_scene: String = ""
var game_scene: String = ""
var settings_scene: String = ""
var save_load_scene: String = ""
var backlog_scene: String = ""
var flowchart_scene: String = ""

var _applied_sources := PackedStringArray()


## Apply one configuration source atomically.
##
## Known values are validated before any field is changed. A malformed source
## therefore leaves both the resolved values and applied-source list untouched.
func load_from_path(path: String) -> Error:
	var cf := ConfigFile.new()
	# ConfigFile's parser may include the malformed token in its own engine error.
	# Local overrides can contain private data, so suppress that raw diagnostic
	# while parsing synchronously and report only our sanitized source metadata.
	var print_error_messages := Engine.print_error_messages
	Engine.print_error_messages = false
	var err: Error = cf.load(path)
	Engine.print_error_messages = print_error_messages
	if err != OK:
		_set_error(path, err, error_string(err))
		return err

	var updates: Dictionary = {}
	for section: String in _CONFIG_SCHEMA:
		var section_schema: Dictionary = _CONFIG_SCHEMA[section]
		for key: String in section_schema:
			if not cf.has_section_key(section, key):
				continue
			var value: Variant = cf.get_value(section, key)
			var entry: Dictionary = section_schema[key]
			var expected_type: int = entry["type"]
			if typeof(value) != expected_type:
				_set_error(
					path,
					ERR_INVALID_DATA,
					"invalid type for [%s] %s: expected %s, got %s" % [
						section,
						key,
						type_string(expected_type),
						type_string(typeof(value)),
					],
				)
				return ERR_INVALID_DATA
			updates[entry["property"]] = value

	for property_name: String in updates:
		set(property_name, updates[property_name])

	_applied_sources.append(path)
	has_config_file = true
	_clear_error()
	return OK


## Restore built-in defaults and clear all source/error metadata.
func reset() -> void:
	has_config_file = false
	game_title = "Stella"
	scenario_path = "res://scenarios/main.stla"
	title_bgm = ""
	backgrounds_path = "res://art/backgrounds/"
	characters_path = "res://art/characters/"
	stage_path = "res://art/stage/"
	bgm_path = "res://audio/bgm/"
	se_path = "res://audio/se/"
	voice_path = "res://audio/voice/"
	cg_gallery = false
	backlog = true
	save_slots = 8
	se_select = ""
	se_cancel = ""
	title_scene = ""
	game_scene = ""
	settings_scene = ""
	save_load_scene = ""
	backlog_scene = ""
	flowchart_scene = ""
	_applied_sources.clear()
	_clear_error()


## Ordered paths successfully applied to this resolved configuration.
func get_applied_sources() -> PackedStringArray:
	return _applied_sources.duplicate()


func _set_error(path: String, code: Error, detail: String) -> void:
	last_error = code
	last_error_source = path
	last_error_detail = detail


func _clear_error() -> void:
	last_error = OK
	last_error_source = ""
	last_error_detail = ""
