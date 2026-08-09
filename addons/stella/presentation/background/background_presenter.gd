## Displays backgrounds with multiple transition types.
## Double-buffered: front and back TextureRect.
## Supports: fade, dissolve, wipe, slide_{left,right,up,down} transitions.
extends CanvasLayer

@onready var bg_front: TextureRect = _get_stage_texture("BgFront")
@onready var bg_back: TextureRect = _get_stage_texture("BgBack")

var _dissolve_shader: Shader
var _wipe_shader: Shader
var _active_tween: Tween
var _transition_generation: int = 0
var _front_rest_position: Vector2
var _back_rest_position: Vector2
var _has_active_transition: bool = false


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
	if asset == "":
		_begin_transition()
		_transition_clear()
		return
	var texture = _load_bg_texture(asset)
	if texture == null:
		push_warning("BackgroundPresenter: texture not found: %s" % asset)
		return

	var generation = _begin_transition()
	match transition:
		"cut", "none":
			_transition_cut(texture)
		"dissolve":
			_transition_dissolve(texture, duration, generation)
		"wipe":
			_transition_wipe(texture, duration, generation)
		"slide_left", "slide_right", "slide_up", "slide_down":
			_transition_slide(texture, duration, transition, generation)
		_:  # "fade" or default
			_transition_fade(texture, duration, generation)


func _load_bg_texture(asset: String) -> Texture2D:
	var base = StellaRuntime.backgrounds_path
	for ext in [".png", ".jpg", ".jpeg", ".webp"]:
		var path = base + asset + ext
		if ResourceLoader.exists(path):
			return load(path) as Texture2D
	return null


## Cancel the previous transition and normalize both buffers before a new
## request takes ownership. No stale tween is allowed to keep mutating nodes
## after a cut or a newer transition starts.
func _begin_transition() -> int:
	_transition_generation += 1

	if _active_tween and _active_tween.is_valid():
		_active_tween.kill()
	_active_tween = null

	if _has_active_transition:
		bg_front.position = _front_rest_position
		bg_back.position = _back_rest_position

	bg_front.material = null
	bg_back.material = null
	bg_front.modulate.a = 1.0
	bg_back.modulate.a = 0.0

	_front_rest_position = bg_front.position
	_back_rest_position = bg_back.position
	_has_active_transition = true
	return _transition_generation


func _transition_cut(texture: Texture2D) -> void:
	bg_front.material = null
	bg_back.material = null
	bg_front.texture = texture
	bg_back.texture = texture
	bg_front.modulate.a = 1.0
	bg_back.modulate.a = 0.0
	_has_active_transition = false


func _transition_clear() -> void:
	bg_front.material = null
	bg_back.material = null
	bg_front.texture = null
	bg_back.texture = null
	bg_front.modulate.a = 1.0
	bg_back.modulate.a = 0.0
	bg_front.position = _front_rest_position
	bg_back.position = _back_rest_position
	_active_tween = null
	_has_active_transition = false


func _transition_fade(texture: Texture2D, duration: float, generation: int = -1):
	if generation < 0:
		generation = _begin_transition()
	if duration <= 0.0:
		_transition_cut(texture)
		return

	# Reset any shader materials
	bg_front.material = null
	bg_back.material = null

	bg_back.texture = texture
	bg_back.modulate.a = 0.0

	var tween = create_tween().set_parallel(true)
	_active_tween = tween
	# BgBack is drawn above BgFront. Keep the old frame opaque and fade only
	# the new frame in; fading both buffers exposes the black viewport midway.
	tween.tween_property(bg_back, "modulate:a", 1.0, duration)
	tween.finished.connect(func():
		if generation != _transition_generation:
			return
		_transition_cut(texture)
		_active_tween = null
	)


func _transition_dissolve(texture: Texture2D, duration: float, generation: int = -1):
	if generation < 0:
		generation = _begin_transition()
	if duration <= 0.0:
		_transition_cut(texture)
		return

	bg_front.material = null

	bg_back.texture = texture
	bg_back.modulate.a = 1.0

	# Use dissolve shader on front image to reveal back
	if _dissolve_shader:
		var mat = ShaderMaterial.new()
		mat.shader = _dissolve_shader
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
		_active_tween = tween
		tween.tween_method(func(val): mat.set_shader_parameter("progress", val), 0.0, 1.0, duration)
		tween.finished.connect(func():
			if generation != _transition_generation:
				return
			_transition_cut(texture)
			_active_tween = null
		)
	else:
		_transition_fade(texture, duration, generation)


func _transition_slide(
	texture: Texture2D,
	duration: float,
	direction: String,
	generation: int = -1,
):
	if generation < 0:
		generation = _begin_transition()
	if duration <= 0.0:
		_transition_cut(texture)
		return

	# Convention: direction names the way content moves.
	var viewport_size = get_viewport().get_visible_rect().size
	if viewport_size == Vector2.ZERO:
		push_warning("BackgroundPresenter: viewport size is zero, falling back to fade for slide")
		_transition_fade(texture, duration, generation)
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

	bg_back.position = back_origin - delta

	var tween = create_tween().set_parallel(true)
	_active_tween = tween
	tween.tween_property(bg_front, "position", front_origin + delta, duration) \
		.set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	tween.tween_property(bg_back, "position", back_origin, duration) \
		.set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	tween.finished.connect(func():
		if generation != _transition_generation:
			return
		bg_front.position = _front_rest_position
		bg_back.position = _back_rest_position
		_transition_cut(texture)
		_active_tween = null
	)


func _transition_wipe(texture: Texture2D, duration: float, generation: int = -1):
	if generation < 0:
		generation = _begin_transition()
	if duration <= 0.0:
		_transition_cut(texture)
		return

	bg_front.material = null

	bg_back.texture = texture
	bg_back.modulate.a = 1.0

	if _wipe_shader:
		var mat = ShaderMaterial.new()
		mat.shader = _wipe_shader
		mat.set_shader_parameter("progress", 0.0)
		mat.set_shader_parameter("direction", 0)
		bg_front.material = mat

		var tween = create_tween()
		_active_tween = tween
		tween.tween_method(func(val): mat.set_shader_parameter("progress", val), 0.0, 1.0, duration)
		tween.finished.connect(func():
			if generation != _transition_generation:
				return
			_transition_cut(texture)
			_active_tween = null
		)
	else:
		_transition_fade(texture, duration, generation)
