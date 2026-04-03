## Full-screen transparent click catcher in UILayer.
## Sits behind DialoguePanel and ChoicePanel — catches all clicks
## that aren't consumed by buttons or choices above it.
extends ColorRect

@onready var _dialogue: PanelContainer = %DialoguePanel


func _ready():
	mouse_filter = Control.MOUSE_FILTER_STOP
	color = Color.TRANSPARENT
	anchors_preset = Control.PRESET_FULL_RECT


func _gui_input(event: InputEvent) -> void:
	if not event is InputEventMouseButton or not event.pressed:
		return

	if event.button_index == MOUSE_BUTTON_LEFT:
		if _dialogue and _dialogue._is_typing:
			_dialogue._is_typing = false
			_dialogue.text_label.visible_characters = -1
		elif _dialogue and _dialogue._ui_hidden:
			_dialogue._ui_hidden = false
			_dialogue.visible = true
		else:
			SignalBus.advance_requested.emit()
		accept_event()

	elif event.button_index == MOUSE_BUTTON_RIGHT:
		if _dialogue:
			if _dialogue._ui_hidden:
				_dialogue._ui_hidden = false
				_dialogue.visible = true
			elif _dialogue.visible and not _dialogue._is_typing:
				_dialogue._ui_hidden = true
				_dialogue.visible = false
		accept_event()


func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	if not NatsumeRuntime.game_state.is_playing():
		return
	if event.keycode == KEY_SPACE or event.keycode == KEY_ENTER:
		if _dialogue and _dialogue._is_typing:
			_dialogue._is_typing = false
			_dialogue.text_label.visible_characters = -1
		else:
			SignalBus.advance_requested.emit()
