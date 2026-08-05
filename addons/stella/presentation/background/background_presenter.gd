## Displays backgrounds with multiple transition types.
## Double-buffered: front and back TextureRect.
## Supports: fade, dissolve, wipe, slide_{left,right,up,down} transitions.
extends CanvasLayer

@onready var bg_front: TextureRect = _get_stage_texture("BgFront")
@onready var bg_back: TextureRect = _get_stage_texture("BgBack")

var _dissolve_shader: Shader
var _wipe_shader: Shader


func _get_stage_texture(node_name: String) -> TextureRect:
	var nested := get_node_or_null("ShakeRoot/%s" % node_name) as TextureRect
	if nested != null:
		return nested
	# Compatibility with custom scenes created before dedicated ShakeRoot nodes
	# were introduced. Those scenes keep the textures directly under this layer.
	return get_node(node_name) as TextureRect


func _ready():
	SignalBus.bg_changed.connect(_on_bg_changed)
	_dissolve_shader = load("res://addons/stella/presentation/background/shaders/dissolve.gdshader")
	_wipe_shader = load("res://addons/stella/presentation/background/shaders/wipe.gdshader")


func _on_bg_changed(asset: String, transition: String, duration: float):
	var texture = _load_bg_texture(asset)
	if texture == null:
		push_warning("BackgroundPresenter: texture not found: %s" % asset)
		return

	match transition:
		"dissolve":
			await _transition_dissolve(texture, duration)
		"wipe":
			await _transition_wipe(texture, duration)
		"slide_left", "slide_right", "slide_up", "slide_down":
			await _transition_slide(texture, duration, transition)
		_:  # "fade" or default
			await _transition_fade(texture, duration)


func _load_bg_texture(asset: String) -> Texture2D:
	var base = StellaRuntime.backgrounds_path
	for ext in [".png", ".jpg", ".jpeg", ".webp"]:
		var path = base + asset + ext
		if ResourceLoader.exists(path):
			return load(path) as Texture2D
	return null


func _transition_fade(texture: Texture2D, duration: float):
	# Reset any shader materials
	bg_front.material = null
	bg_back.material = null

	bg_back.texture = texture
	bg_back.modulate.a = 0.0

	var tween = create_tween().set_parallel(true)
	tween.tween_property(bg_back, "modulate:a", 1.0, duration)
	tween.tween_property(bg_front, "modulate:a", 0.0, duration)
	await tween.finished

	bg_front.texture = texture
	bg_front.modulate.a = 1.0
	bg_back.modulate.a = 0.0


func _transition_dissolve(texture: Texture2D, duration: float):
	bg_front.material = null

	bg_back.texture = texture
	bg_back.modulate.a = 1.0

	# Use dissolve shader on front image to reveal back
	if _dissolve_shader:
		var mat = ShaderMaterial.new()
		mat.shader = _dissolve_shader
		# Generate noise texture for dissolve pattern
		var noise_tex = NoiseTexture2D.new()
		noise_tex.width = 256
		noise_tex.height = 256
		var noise = FastNoiseLite.new()
		noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
		noise_tex.noise = noise
		mat.set_shader_parameter("dissolve_noise", noise_tex)
		mat.set_shader_parameter("progress", 0.0)
		bg_front.material = mat

		var tween = create_tween()
		tween.tween_method(func(val): mat.set_shader_parameter("progress", val), 0.0, 1.0, duration)
		await tween.finished
	else:
		await _transition_fade(texture, duration)
		return

	bg_front.texture = texture
	bg_front.material = null
	bg_back.modulate.a = 0.0


func _transition_slide(texture: Texture2D, duration: float, direction: String):
	# Convention: direction names the way content moves.
	#   slide_left  → old exits to the left, new enters from the right.
	#   slide_right → mirror of slide_left.
	#   slide_up / slide_down → vertical equivalents.
	var viewport_size = get_viewport().get_visible_rect().size
	if viewport_size == Vector2.ZERO:
		# Viewport not yet laid out (e.g. first-frame autoplay). Slide would
		# be invisible because delta is zero; fall back to fade so the bg
		# switch at least happens.
		push_warning("BackgroundPresenter: viewport size is zero, falling back to fade for slide")
		await _transition_fade(texture, duration)
		return

	bg_front.material = null
	bg_back.material = null

	bg_back.texture = texture
	bg_back.modulate.a = 1.0

	var front_origin = bg_front.position
	var back_origin = bg_back.position

	var delta: Vector2
	match direction:
		"slide_left":
			delta = Vector2(-viewport_size.x, 0)
		"slide_right":
			delta = Vector2(viewport_size.x, 0)
		"slide_up":
			delta = Vector2(0, -viewport_size.y)
		"slide_down":
			delta = Vector2(0, viewport_size.y)
		_:
			delta = Vector2(-viewport_size.x, 0)

	# New layer starts off-screen on the opposite side of delta; slides in to origin.
	bg_back.position = back_origin - delta

	var tween = create_tween().set_parallel(true)
	tween.tween_property(bg_front, "position", front_origin + delta, duration) \
		.set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	tween.tween_property(bg_back, "position", back_origin, duration) \
		.set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	await tween.finished

	# Commit new texture to front, reset both to origin.
	bg_front.texture = texture
	bg_front.modulate.a = 1.0
	bg_front.position = front_origin
	bg_back.modulate.a = 0.0
	bg_back.position = back_origin


func _transition_wipe(texture: Texture2D, duration: float):
	bg_front.material = null

	bg_back.texture = texture
	bg_back.modulate.a = 1.0

	if _wipe_shader:
		var mat = ShaderMaterial.new()
		mat.shader = _wipe_shader
		mat.set_shader_parameter("progress", 0.0)
		mat.set_shader_parameter("direction", 0)  # left to right
		bg_front.material = mat

		var tween = create_tween()
		tween.tween_method(func(val): mat.set_shader_parameter("progress", val), 0.0, 1.0, duration)
		await tween.finished
	else:
		await _transition_fade(texture, duration)
		return

	bg_front.texture = texture
	bg_front.material = null
	bg_back.modulate.a = 0.0
