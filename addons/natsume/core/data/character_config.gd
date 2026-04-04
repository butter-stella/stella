## Character rendering configuration.
## Supports "sprite" (single image per expression) and "layered" (body + face composite).
class_name CharacterConfig extends RefCounted

var render_mode: String = "sprite"  # "sprite" or "layered"
var default_body: String = ""
var bodies: Dictionary = {}          # body_name -> file_name
var expressions: Dictionary = {}     # expression_name -> face_file_name
var avatars: Dictionary = {}         # expression_name -> avatar_file_name


func load_from_dict(data: Dictionary) -> void:
	render_mode = data.get("render_mode", "sprite")
	default_body = data.get("default_body", "")
	bodies = data.get("bodies", {})
	expressions = data.get("expressions", {})
	avatars = data.get("avatars", {})


func is_layered() -> bool:
	return render_mode == "layered"


func get_face(expression: String) -> String:
	if expressions.has(expression):
		return expressions[expression]
	if expressions.has("default"):
		return expressions["default"]
	return ""


func get_body(body_override: String = "") -> String:
	if body_override != "" and bodies.has(body_override):
		return bodies[body_override]
	return default_body


func has_avatars() -> bool:
	return avatars.size() > 0


func get_avatar(expression: String) -> String:
	if avatars.has(expression):
		return avatars[expression]
	if avatars.has("default"):
		return avatars["default"]
	return ""
