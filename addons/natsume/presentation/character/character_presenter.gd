## Manages character sprites on screen.
## Supports single-image (sprite) and layered (body + face) rendering.
## Subscribes to char_show, char_hide, char_expression_changed, char_anim, char_move.
extends CanvasLayer

@onready var slot_left: Control = $SlotLeft
@onready var slot_center: Control = $SlotCenter
@onready var slot_right: Control = $SlotRight

# Track state per character
var _character_positions: Dictionary = {}   # character_id -> position_name
var _character_expressions: Dictionary = {} # character_id -> expression
var _character_bodies: Dictionary = {}      # character_id -> body_name
var _config_loader: CharacterConfigLoader = CharacterConfigLoader.new()


func _ready():
	_config_loader.set_base_path(NatsumeRuntime.characters_path)

	SignalBus.char_show.connect(_on_char_show)
	SignalBus.char_hide.connect(_on_char_hide)
	SignalBus.char_expression_changed.connect(_on_char_expr_changed)
	SignalBus.char_anim_requested.connect(_on_char_anim)
	SignalBus.char_move_requested.connect(_on_char_move)

	for slot in [slot_left, slot_center, slot_right]:
		slot.visible = false


func _on_char_show(character: String, expression: String, position: String):
	var slot = _get_slot(position)
	if slot == null:
		return

	var config = _config_loader.get_config(character)

	# Clear old content in this slot
	_clear_slot(slot)

	if config.is_layered():
		_show_layered(slot, character, config, expression, "")
	else:
		_show_sprite(slot, character, expression)

	_character_positions[character] = position
	_character_expressions[character] = expression

	# Fade in
	slot.visible = true
	slot.modulate.a = 0.0
	var tween = create_tween()
	tween.tween_property(slot, "modulate:a", 1.0, 0.3)


func _on_char_hide(character: String):
	if character == "all":
		for slot in [slot_left, slot_center, slot_right]:
			var tween = create_tween()
			tween.tween_property(slot, "modulate:a", 0.0, 0.3)
			tween.tween_callback(func():
				slot.visible = false
				_clear_slot(slot)
			)
		_character_positions.clear()
		_character_expressions.clear()
		_character_bodies.clear()
		return

	var position = _character_positions.get(character, "")
	var slot = _get_slot(position)
	if slot:
		var tween = create_tween()
		tween.tween_property(slot, "modulate:a", 0.0, 0.3)
		tween.tween_callback(func():
			slot.visible = false
			_clear_slot(slot)
		)
	_character_positions.erase(character)
	_character_expressions.erase(character)
	_character_bodies.erase(character)


func _on_char_expr_changed(character: String, expression: String):
	var position = _character_positions.get(character, "")
	var slot = _get_slot(position)
	if slot == null:
		return

	var config = _config_loader.get_config(character)

	if config.is_layered():
		# Only update the face layer
		var face_node = slot.get_node_or_null("FaceSprite")
		if face_node:
			var face_file = config.get_face(expression)
			var path = NatsumeRuntime.characters_path + "%s/%s.png" % [character, face_file]
			var texture = load(path) as Texture2D
			if texture:
				face_node.texture = texture
	else:
		# Single image: replace the whole sprite
		var sprite_node = slot.get_node_or_null("Sprite")
		if sprite_node:
			var path = NatsumeRuntime.characters_path + "%s/%s.png" % [character, expression]
			var texture = load(path) as Texture2D
			if texture:
				sprite_node.texture = texture

	_character_expressions[character] = expression


func _on_char_anim(character: String, anim: String, intensity: String):
	var position = _character_positions.get(character, "")
	var slot = _get_slot(position)
	if slot == null:
		return

	var strength = 10.0
	match intensity:
		"light": strength = 5.0
		"strong": strength = 20.0

	match anim:
		"jump":
			var tween = create_tween()
			tween.tween_property(slot, "position:y", slot.position.y - strength * 3, 0.15)
			tween.tween_property(slot, "position:y", slot.position.y, 0.25).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BOUNCE)
		"shake":
			var orig_x = slot.position.x
			var tween = create_tween()
			for i in range(4):
				var offset = strength if i % 2 == 0 else -strength
				tween.tween_property(slot, "position:x", orig_x + offset, 0.05)
			tween.tween_property(slot, "position:x", orig_x, 0.05)
		"nod":
			var orig_y = slot.position.y
			var tween = create_tween()
			tween.tween_property(slot, "position:y", orig_y + strength, 0.15)
			tween.tween_property(slot, "position:y", orig_y, 0.2).set_ease(Tween.EASE_OUT)
		"bounce":
			var tween = create_tween()
			tween.tween_property(slot, "scale", Vector2(1.1, 0.9), 0.1)
			tween.tween_property(slot, "scale", Vector2(0.95, 1.05), 0.1)
			tween.tween_property(slot, "scale", Vector2(1.0, 1.0), 0.15).set_ease(Tween.EASE_OUT)


func _on_char_move(character: String, target_position: String, duration: float):
	var old_position = _character_positions.get(character, "")
	var old_slot = _get_slot(old_position)
	var new_slot = _get_slot(target_position)
	if old_slot == null or new_slot == null or old_slot == new_slot:
		return

	# Clone content to new slot
	_clear_slot(new_slot)
	for child in old_slot.get_children():
		var copy = child.duplicate()
		new_slot.add_child(copy)

	new_slot.visible = true
	new_slot.modulate.a = 0.0

	var tween = create_tween().set_parallel(true)
	tween.tween_property(old_slot, "modulate:a", 0.0, duration)
	tween.tween_property(new_slot, "modulate:a", 1.0, duration)
	await tween.finished

	old_slot.visible = false
	_clear_slot(old_slot)
	_character_positions[character] = target_position


# --- Rendering helpers ---

func _show_sprite(slot: Control, character: String, expression: String):
	var path = NatsumeRuntime.characters_path + "%s/%s.png" % [character, expression]
	var texture = load(path) as Texture2D
	if texture == null:
		push_warning("CharacterPresenter: texture not found: %s" % path)
		return

	var sprite = TextureRect.new()
	sprite.name = "Sprite"
	sprite.texture = texture
	sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	sprite.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	sprite.anchors_preset = Control.PRESET_FULL_RECT
	slot.add_child(sprite)


func _show_layered(slot: Control, character: String, config: CharacterConfig, expression: String, body_override: String):
	var base_path = NatsumeRuntime.characters_path + "%s/" % character

	# Body layer
	var body_file = config.get_body(body_override)
	if body_file != "":
		var body_texture = load(base_path + body_file + ".png") as Texture2D
		if body_texture:
			var body_sprite = TextureRect.new()
			body_sprite.name = "BodySprite"
			body_sprite.texture = body_texture
			body_sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			body_sprite.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
			body_sprite.anchors_preset = Control.PRESET_FULL_RECT
			slot.add_child(body_sprite)

	# Face layer (on top of body)
	var face_file = config.get_face(expression)
	if face_file != "":
		var face_texture = load(base_path + face_file + ".png") as Texture2D
		if face_texture:
			var face_sprite = TextureRect.new()
			face_sprite.name = "FaceSprite"
			face_sprite.texture = face_texture
			face_sprite.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			face_sprite.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
			face_sprite.anchors_preset = Control.PRESET_FULL_RECT
			slot.add_child(face_sprite)

	_character_bodies[character] = body_override


func _clear_slot(slot: Control):
	for child in slot.get_children():
		child.queue_free()


func _get_slot(position: String) -> Control:
	match position:
		"left": return slot_left
		"center": return slot_center
		"right": return slot_right
		_: return slot_center
