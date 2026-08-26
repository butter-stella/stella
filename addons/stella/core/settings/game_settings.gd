## Game settings data model.
## Framework provides the data; UI is implemented by the game project.
class_name GameSettings extends RefCounted

# --- Text display ---
var character_interval: int = 50       # ms per character (0 = instant)
var punctuation_pause: int = 200       # extra ms after punctuation
var click_to_complete: bool = true     # normal advance during typing shows full text
var text_window_opacity: float = 0.8

# --- Auto play ---
var auto_play_delay: float = 1.5       # seconds after text completes
var auto_play_wait_voice: bool = true
var auto_play_pause_on_choice: bool = true
var auto_play_click_interrupt: bool = true  # left click can interrupt auto-play

# --- Skip ---
var skip_interval: int = 50            # ms per dialogue in skip mode
var skip_only_read: bool = true
var skip_unread_confirm: bool = true
var skip_stop_on_choice: bool = true

# --- Volume ---
var master_volume: float = 1.0
var bgm_volume: float = 0.8
var se_volume: float = 1.0
var system_se_volume: float = 1.0
var voice_volume: float = 1.0
var movie_volume: float = 1.0
var character_voice_volume: Dictionary = {}   # character_id -> float
var character_voice_enabled: Dictionary = {}  # character_id -> bool

# --- Movie input policy ---
var movie_right_click_skip: bool = true
var movie_skip_on_skip: bool = false

# --- Voice behavior ---
var voice_continue_on_advance: bool = false
var voice_replay_on_backlog: bool = true

# --- Display ---
var fullscreen: bool = false
var resolution: String = "1920x1080"
var effect_enabled: bool = true


func to_dict() -> Dictionary:
	return {
		"character_interval": character_interval,
		"punctuation_pause": punctuation_pause,
		"click_to_complete": click_to_complete,
		"text_window_opacity": text_window_opacity,
		"auto_play_delay": auto_play_delay,
		"auto_play_wait_voice": auto_play_wait_voice,
		"auto_play_pause_on_choice": auto_play_pause_on_choice,
		"auto_play_click_interrupt": auto_play_click_interrupt,
		"skip_interval": skip_interval,
		"skip_only_read": skip_only_read,
		"skip_unread_confirm": skip_unread_confirm,
		"skip_stop_on_choice": skip_stop_on_choice,
		"master_volume": master_volume,
		"bgm_volume": bgm_volume,
		"se_volume": se_volume,
		"system_se_volume": system_se_volume,
		"voice_volume": voice_volume,
		"movie_volume": movie_volume,
		"character_voice_volume": character_voice_volume.duplicate(),
		"character_voice_enabled": character_voice_enabled.duplicate(),
		"movie_right_click_skip": movie_right_click_skip,
		"movie_skip_on_skip": movie_skip_on_skip,
		"voice_continue_on_advance": voice_continue_on_advance,
		"voice_replay_on_backlog": voice_replay_on_backlog,
		"fullscreen": fullscreen,
		"resolution": resolution,
		"effect_enabled": effect_enabled,
	}


func from_dict(data: Dictionary) -> void:
	for key in data:
		if key in self:
			self[key] = data[key]
