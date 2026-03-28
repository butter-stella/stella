## Title screen — game title with start/continue/load/settings/quit buttons.
extends CanvasLayer

@onready var title_label: Label = %TitleLabel
@onready var buttons_container: VBoxContainer = %TitleButtons

## The scenario path to load when "Start" is pressed.
## Set by the game's bootstrap script.
var scenario_path: String = ""

## Custom title text — set before showing.
var game_title: String = "Natsume"


func _ready():
	layer = 3
	NatsumeRuntime.game_state.state_changed.connect(_on_state_changed)
	SignalBus.scenario_ended_event.connect(_on_scenario_ended)
	# Show title on start
	_show()


func _on_state_changed(_from: int, to: int):
	if to == GameStateMachine.State.TITLE:
		_show()
	elif to == GameStateMachine.State.PLAYING:
		visible = false


func _on_scenario_ended(_id: String):
	NatsumeRuntime.game_state.transition_to(GameStateMachine.State.TITLE)


func _show():
	visible = true
	_build_ui()


func _build_ui():
	title_label.text = game_title

	for child in buttons_container.get_children():
		child.queue_free()

	var buttons = [
		{"text": "开始游戏", "callback": _on_start},
		{"text": "继续游戏", "callback": _on_continue, "condition": NatsumeRuntime.save_manager.has_save(0)},
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
	if scenario_path != "":
		NatsumeRuntime.start_scenario(scenario_path)


func _on_continue():
	if NatsumeRuntime.save_manager.load_save(0):
		NatsumeRuntime.game_state.transition_to(GameStateMachine.State.PLAYING)


func _on_load():
	NatsumeRuntime.game_state.transition_to(GameStateMachine.State.SAVE_LOAD)


func _on_settings():
	NatsumeRuntime.game_state.transition_to(GameStateMachine.State.SETTINGS)


func _on_quit():
	get_tree().quit()
