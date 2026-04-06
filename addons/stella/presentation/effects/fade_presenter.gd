## Screen fade overlay — black ColorRect that fades in/out.
extends ColorRect


func _ready():
	color = Color.BLACK
	modulate.a = 0.0
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	SignalBus.fade_requested.connect(_on_fade)


func _on_fade(direction: String, duration: float):
	var target_alpha = 1.0 if direction == "out" else 0.0
	var tween = create_tween()
	tween.tween_property(self, "modulate:a", target_alpha, duration)
	await tween.finished
