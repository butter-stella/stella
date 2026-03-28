## Manages character sprites on screen.
## Subscribes to char_show, char_hide, char_expression_changed signals.
extends CanvasLayer

@onready var slot_left: TextureRect = $SlotLeft
@onready var slot_center: TextureRect = $SlotCenter
@onready var slot_right: TextureRect = $SlotRight

# Track which character is at which position
var _character_positions: Dictionary = {}  # character_id -> position_name
var _character_expressions: Dictionary = {}  # character_id -> expression


func _ready():
	SignalBus.char_show.connect(_on_char_show)
	SignalBus.char_hide.connect(_on_char_hide)
	SignalBus.char_expression_changed.connect(_on_char_expr_changed)
	SignalBus.char_anim_requested.connect(_on_char_anim)
	SignalBus.char_move_requested.connect(_on_char_move)

	# Hide all slots initially
	for slot in [slot_left, slot_center, slot_right]:
		slot.visible = false


func _on_char_show(character: String, expression: String, position: String):
	var slot = _get_slot(position)
	if slot == null:
		return

	var texture = _load_character_texture(character, expression)
	if texture:
		slot.texture = texture
		slot.visible = true
		_character_positions[character] = position
		_character_expressions[character] = expression

		# Fade in
		slot.modulate.a = 0.0
		var tween = create_tween()
		tween.tween_property(slot, "modulate:a", 1.0, 0.3)


func _on_char_hide(character: String):
	if character == "all":
		for slot in [slot_left, slot_center, slot_right]:
			var tween = create_tween()
			tween.tween_property(slot, "modulate:a", 0.0, 0.3)
			tween.tween_callback(func(): slot.visible = false)
		_character_positions.clear()
		_character_expressions.clear()
		return

	var position = _character_positions.get(character, "")
	var slot = _get_slot(position)
	if slot:
		var tween = create_tween()
		tween.tween_property(slot, "modulate:a", 0.0, 0.3)
		tween.tween_callback(func(): slot.visible = false)
	_character_positions.erase(character)
	_character_expressions.erase(character)


func _on_char_expr_changed(character: String, expression: String):
	var position = _character_positions.get(character, "")
	var slot = _get_slot(position)
	if slot == null:
		return

	var texture = _load_character_texture(character, expression)
	if texture:
		slot.texture = texture
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

	# Move texture to new slot
	new_slot.texture = old_slot.texture
	new_slot.modulate = old_slot.modulate
	new_slot.visible = true
	new_slot.modulate.a = 0.0

	var tween = create_tween().set_parallel(true)
	tween.tween_property(old_slot, "modulate:a", 0.0, duration)
	tween.tween_property(new_slot, "modulate:a", 1.0, duration)
	await tween.finished

	old_slot.visible = false
	old_slot.texture = null
	_character_positions[character] = target_position


func _get_slot(position: String) -> TextureRect:
	match position:
		"left": return slot_left
		"center": return slot_center
		"right": return slot_right
		_: return slot_center


func _load_character_texture(character: String, expression: String) -> Texture2D:
	var path = NatsumeRuntime.characters_path + "%s/%s.png" % [character, expression]
	var texture = load(path) as Texture2D
	if texture == null:
		push_warning("CharacterPresenter: texture not found: %s" % path)
	return texture
