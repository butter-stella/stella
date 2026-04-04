## Demo title screen — shows how to build a custom title using Facade API.
## Copy and modify this for your own game.
extends CanvasLayer

@onready var title_label: Label = %TitleLabel
@onready var buttons_container: VBoxContainer = %TitleButtons


func _ready():
	title_label.text = NatsumeRuntime.config.game_title

	# Build buttons
	_add_button("开始游戏", func(): NatsumeRuntime.start_game())

	if NatsumeRuntime.has_continue_save():
		_add_button("继续游戏", func(): NatsumeRuntime.continue_game())

	_add_button("设置", func(): NatsumeRuntime.show_settings())
	_add_button("退出", func(): get_tree().quit())


func _add_button(text: String, callback: Callable):
	var btn = Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(250, 50)
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.pressed.connect(callback)
	buttons_container.add_child(btn)
