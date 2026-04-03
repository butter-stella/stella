## Converts player input (click, space, enter) into SignalBus.advance_requested.
## Uses _unhandled_input so overlay scenes naturally block advance input.
extends Node


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			SignalBus.advance_requested.emit()
	elif event is InputEventKey:
		if event.pressed and not event.echo:
			if event.keycode == KEY_SPACE or event.keycode == KEY_ENTER:
				SignalBus.advance_requested.emit()
