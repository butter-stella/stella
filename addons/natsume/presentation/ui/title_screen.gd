## Title screen — game title with start/continue/quit buttons.
## This is a standalone scene, NOT part of the game scene.
## Starting a game switches to the game scene via NatsumeRuntime.
extends CanvasLayer

@onready var title_label: Label = %TitleLabel
@onready var buttons_container: VBoxContainer = %TitleButtons

## The scenario path to load when "Start" is pressed.
var scenario_path: String = ""

## The game scene path to switch to.
var game_scene_path: String = ""

## Custom title text.
var game_title: String = "Natsume"


func _ready():
	_build_ui()


func _build_ui():
	title_label.text = game_title

	for child in buttons_container.get_children():
		child.queue_free()

	var buttons = [
		{"text": "开始游戏", "callback": _on_start},
		{"text": "继续游戏", "callback": _on_continue, "condition": NatsumeRuntime.save_manager.has_save(0)},
		{"text": "退出", "callback": _on_quit},
	]

	for btn_info in buttons:
		if btn_info.has("condition") and not btn_info["condition"]:
			continue

		var btn = Button.new()
		btn.text = btn_info["text"]
		btn.custom_minimum_size = Vector2(250, 50)
		btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		btn.pressed.connect(btn_info["callback"])
		buttons_container.add_child(btn)


func _on_start():
	if scenario_path == "" or game_scene_path == "":
		push_error("TitleScreen: scenario_path or game_scene_path not configured")
		return
	NatsumeRuntime.start_game(scenario_path, game_scene_path)


func _on_continue():
	if game_scene_path == "":
		return
	NatsumeRuntime.load_game(0, scenario_path, game_scene_path)


func _on_quit():
	get_tree().quit()
