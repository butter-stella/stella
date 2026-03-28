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


func _get_slot(position: String) -> TextureRect:
	match position:
		"left": return slot_left
		"center": return slot_center
		"right": return slot_right
		_: return slot_center


func _load_character_texture(character: String, expression: String) -> Texture2D:
	var path = "res://game/art/characters/%s/%s.png" % [character, expression]
	var texture = load(path) as Texture2D
	if texture == null:
		push_warning("CharacterPresenter: texture not found: %s" % path)
	return texture
