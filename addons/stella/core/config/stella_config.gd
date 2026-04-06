## Loads and provides access to stella.cfg project configuration.
## All fields have sensible defaults — a missing config file is valid.
class_name StellaConfig
extends RefCounted

## Whether a config file was actually found and loaded.
var has_config_file: bool = false

# [game]
var game_title: String = "Stella"
var scenario_path: String = "res://scenarios/main.stl"
var title_bgm: String = ""  # BGM asset name for title screen

# [paths]
var backgrounds_path: String = "res://art/backgrounds/"
var characters_path: String = "res://art/characters/"
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


func load_from_path(path: String) -> void:
	var cf = ConfigFile.new()
	var err = cf.load(path)
	if err != OK:
		has_config_file = false
		return

	has_config_file = true

	# [game]
	game_title = cf.get_value("game", "title", game_title)
	scenario_path = cf.get_value("game", "scenario", scenario_path)
	title_bgm = cf.get_value("game", "title_bgm", title_bgm)

	# [paths]
	backgrounds_path = cf.get_value("paths", "backgrounds", backgrounds_path)
	characters_path = cf.get_value("paths", "characters", characters_path)
	bgm_path = cf.get_value("paths", "bgm", bgm_path)
	se_path = cf.get_value("paths", "se", se_path)
	voice_path = cf.get_value("paths", "voice", voice_path)

	# [features]
	cg_gallery = cf.get_value("features", "cg_gallery", cg_gallery)
	backlog = cf.get_value("features", "backlog", backlog)
	save_slots = cf.get_value("features", "save_slots", save_slots)

	# [system_se]
	se_select = cf.get_value("system_se", "select", se_select)
	se_cancel = cf.get_value("system_se", "cancel", se_cancel)

	# [overrides]
	title_scene = cf.get_value("overrides", "title_scene", title_scene)
	game_scene = cf.get_value("overrides", "game_scene", game_scene)
	settings_scene = cf.get_value("overrides", "settings_scene", settings_scene)
	save_load_scene = cf.get_value("overrides", "save_load_scene", save_load_scene)
	backlog_scene = cf.get_value("overrides", "backlog_scene", backlog_scene)
