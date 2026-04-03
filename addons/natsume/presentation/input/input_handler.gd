## Converts player input (click, space, enter) into SignalBus.advance_requested.
extends Node


func _input(event: InputEvent) -> void:
	if not NatsumeRuntime.game_state.is_playing():
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			SignalBus.advance_requested.emit()
	elif event is InputEventKey:
		if event.pressed and not event.echo:
			if event.keycode == KEY_SPACE or event.keycode == KEY_ENTER:
				SignalBus.advance_requested.emit()
