## Displays backgrounds with fade transitions.
## Double-buffered: front and back TextureRect.
extends CanvasLayer

@onready var bg_front: TextureRect = $BgFront
@onready var bg_back: TextureRect = $BgBack


func _ready():
	SignalBus.bg_changed.connect(_on_bg_changed)


func _on_bg_changed(asset: String, _transition: String, duration: float):
	var path = NatsumeRuntime.backgrounds_path + "%s.png" % asset
	var texture = load(path) as Texture2D
	if texture == null:
		push_warning("BackgroundPresenter: texture not found: %s" % path)
		return

	bg_back.texture = texture
	bg_back.modulate.a = 0.0

	var tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(bg_back, "modulate:a", 1.0, duration)
	tween.tween_property(bg_front, "modulate:a", 0.0, duration)
	await tween.finished

	bg_front.texture = texture
	bg_front.modulate.a = 1.0
	bg_back.modulate.a = 0.0
