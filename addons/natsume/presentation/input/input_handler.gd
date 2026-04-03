## Captures player input for dialogue advance.
## Full-screen Control on the lowest CanvasLayer — catches all clicks not
## consumed by higher-layer UI (dialogue box, overlays, toolbar buttons).
## Keyboard advance uses _unhandled_input so overlays naturally block it.
extends ColorRect


func _ready():
	# Full-screen transparent click catcher
	mouse_filter = Control.MOUSE_FILTER_STOP
	color = Color.TRANSPARENT
	anchors_preset = Control.PRESET_FULL_RECT


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			SignalBus.advance_requested.emit()
			accept_event()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_SPACE or event.keycode == KEY_ENTER:
			SignalBus.advance_requested.emit()
