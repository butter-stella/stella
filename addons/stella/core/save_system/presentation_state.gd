## Tracks presentation-layer state (background, characters, BGM) for save/load.
## Listens to SignalBus to mirror visual state; restores via signals on load.
class_name PresentationState extends RefCounted

var current_bg: String = ""
var visible_characters: Dictionary = {}  # id -> {expression, position}
var current_bgm: String = ""

var _connected: bool = false


func get_provider_id() -> String:
	return "presentation_state"


func connect_signals() -> void:
	if _connected:
		return
	SignalBus.bg_changed.connect(_on_bg_changed)
	SignalBus.char_show.connect(_on_char_show)
	SignalBus.char_hide.connect(_on_char_hide)
	SignalBus.char_expression_changed.connect(_on_char_expr)
	SignalBus.char_move_requested.connect(_on_char_move)
	SignalBus.bgm_play.connect(_on_bgm_play)
	SignalBus.bgm_stop.connect(_on_bgm_stop)
	_connected = true


func disconnect_signals() -> void:
	if not _connected:
		return
	SignalBus.bg_changed.disconnect(_on_bg_changed)
	SignalBus.char_show.disconnect(_on_char_show)
	SignalBus.char_hide.disconnect(_on_char_hide)
	SignalBus.char_expression_changed.disconnect(_on_char_expr)
	SignalBus.char_move_requested.disconnect(_on_char_move)
	SignalBus.bgm_play.disconnect(_on_bgm_play)
	SignalBus.bgm_stop.disconnect(_on_bgm_stop)
	_connected = false


func clear() -> void:
	current_bg = ""
	visible_characters.clear()
	current_bgm = ""


func capture_snapshot() -> Dictionary:
	return {
		"bg": current_bg,
		"characters": visible_characters.duplicate(true),
		"bgm": current_bgm,
	}


func restore_snapshot(snapshot: Dictionary) -> void:
	current_bg = snapshot.get("bg", "")
	current_bgm = snapshot.get("bgm", "")
	var chars = snapshot.get("characters", {})
	visible_characters.clear()
	for id in chars:
		visible_characters[id] = chars[id].duplicate()


## Project the current PresentationState onto the visual presenters by
## emitting bg/char/bgm signals with snap-to (no transition) parameters.
##
## Idempotent and side-effect-free outside the visual presenter layer:
## safe to call from save/load restore, backlog jump replay, or any other
## context that needs visuals to match a freshly-restored state.
func apply_to_presenters() -> void:
	if current_bg != "":
		SignalBus.bg_changed.emit(current_bg, "none", 0.0)
	for id in visible_characters:
		var info = visible_characters[id]
		SignalBus.char_show.emit(id, info.get("expression", ""), info.get("position", ""))
	if current_bgm != "":
		SignalBus.bgm_play.emit(current_bgm, 0.0)


# ─── Signal callbacks ───

func _on_bg_changed(asset: String, _transition: String, _duration: float) -> void:
	current_bg = asset


func _on_char_show(character: String, expression: String, position: String) -> void:
	visible_characters[character] = {"expression": expression, "position": position}


func _on_char_hide(character: String) -> void:
	if character == "all":
		visible_characters.clear()
	else:
		visible_characters.erase(character)


func _on_char_expr(character: String, expression: String) -> void:
	if visible_characters.has(character):
		visible_characters[character]["expression"] = expression


func _on_char_move(character: String, position: String, _duration: float) -> void:
	if visible_characters.has(character):
		visible_characters[character]["position"] = position


func _on_bgm_play(asset: String, _fade_duration: float) -> void:
	current_bgm = asset


func _on_bgm_stop(_fade_duration: float) -> void:
	current_bgm = ""
