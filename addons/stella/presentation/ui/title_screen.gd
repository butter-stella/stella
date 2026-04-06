## Title screen — game title with start/continue/settings/quit buttons.
## This is a standalone scene, NOT part of the game scene.
## Starting a game switches to the game scene via StellaRuntime.
extends CanvasLayer

@onready var title_label: Label = %TitleLabel
@onready var buttons_container: VBoxContainer = %TitleButtons


func _ready():
	_build_ui()


func _build_ui():
	var cfg = StellaRuntime.config
	title_label.text = cfg.game_title

	for child in buttons_container.get_children():
		child.queue_free()

	var buttons = [
		{"text": "开始游戏", "callback": _on_start},
		{"text": "继续游戏", "callback": _on_continue, "condition": StellaRuntime.has_continue_save()},
		{"text": "读档", "callback": _on_load},
		{"text": "设置", "callback": _on_settings},
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
	StellaRuntime.start_game()


func _on_continue():
	StellaRuntime.continue_game()


func _on_load():
	StellaRuntime.show_save_load("load")


func _on_settings():
	StellaRuntime.show_settings()


func _on_quit():
	get_tree().quit()
