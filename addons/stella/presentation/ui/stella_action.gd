## Zero-code button binding — attach as child of any BaseButton.
## Select an action in the Inspector, and the button will call the
## corresponding StellaRuntime API when pressed. No script needed.
class_name StellaAction
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
		push_warning("StellaAction: parent is not a BaseButton — action won't trigger")


func _on_pressed() -> void:
	match action:
		Action.NONE:
			push_warning("StellaAction: no action selected")
		Action.START_GAME:
			StellaRuntime.start_game()
		Action.CONTINUE_GAME:
			StellaRuntime.continue_game()
		Action.RETURN_TO_TITLE:
			StellaRuntime.return_to_title()
		Action.QUICK_SAVE:
			StellaRuntime.quick_save()
		Action.QUICK_LOAD:
			StellaRuntime.quick_load()
		Action.SHOW_SAVE:
			StellaRuntime.show_save_load("save")
		Action.SHOW_LOAD:
			StellaRuntime.show_save_load("load")
		Action.SHOW_SETTINGS:
			StellaRuntime.show_settings()
		Action.SHOW_BACKLOG:
			StellaRuntime.show_backlog()
		Action.TOGGLE_AUTO_PLAY:
			StellaRuntime.toggle_auto_play()
		Action.TOGGLE_SKIP:
			StellaRuntime.toggle_skip()
		Action.QUIT:
			get_tree().quit()
