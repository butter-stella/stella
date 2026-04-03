## Zero-code button binding — attach as child of any BaseButton.
## Select an action in the Inspector, and the button will call the
## corresponding NatsumeRuntime API when pressed. No script needed.
class_name NatsumeAction
extends Node

enum Action {
	NONE,
	START_GAME,
	CONTINUE_GAME,
	RETURN_TO_TITLE,
	QUICK_SAVE,
	QUICK_LOAD,
	SHOW_SAVE,
	SHOW_LOAD,
	SHOW_SETTINGS,
	SHOW_BACKLOG,
	TOGGLE_AUTO_PLAY,
	TOGGLE_SKIP,
	QUIT,
}

@export var action: Action = Action.NONE


func _ready() -> void:
	var parent = get_parent()
	if parent is BaseButton:
		parent.pressed.connect(_on_pressed)
	else:
		push_warning("NatsumeAction: parent is not a BaseButton — action won't trigger")


func _on_pressed() -> void:
	match action:
		Action.NONE:
			push_warning("NatsumeAction: no action selected")
		Action.START_GAME:
			NatsumeRuntime.start_game()
		Action.CONTINUE_GAME:
			NatsumeRuntime.load_game(0)
		Action.RETURN_TO_TITLE:
			NatsumeRuntime.return_to_title()
		Action.QUICK_SAVE:
			NatsumeRuntime.quick_save()
		Action.QUICK_LOAD:
			NatsumeRuntime.quick_load()
		Action.SHOW_SAVE:
			NatsumeRuntime.show_save_load("save")
		Action.SHOW_LOAD:
			NatsumeRuntime.show_save_load("load")
		Action.SHOW_SETTINGS:
			NatsumeRuntime.show_settings()
		Action.SHOW_BACKLOG:
			NatsumeRuntime.show_backlog()
		Action.TOGGLE_AUTO_PLAY:
			NatsumeRuntime.toggle_auto_play()
		Action.TOGGLE_SKIP:
			NatsumeRuntime.toggle_skip()
		Action.QUIT:
			get_tree().quit()
