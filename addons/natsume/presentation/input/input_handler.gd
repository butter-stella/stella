## Captures player input for dialogue advance.
## Full-screen transparent ColorRect in UILayer — sits behind DialoguePanel
## and ChoicePanel so they get GUI priority. Catches all clicks that miss them.
## Overlay at higher CanvasLayer naturally blocks everything.
## Keyboard advance uses _unhandled_input so overlays naturally block it.
extends ColorRect


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			SignalBus.advance_requested.emit()
			accept_event()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_SPACE or event.keycode == KEY_ENTER:
			SignalBus.advance_requested.emit()
