## Character rendering configuration.
## Supports "sprite" (single image per expression) and "layered" (body + face composite).
class_name CharacterConfig extends RefCounted

var render_mode: String = "sprite"  # "sprite" or "layered"
var default_body: String = ""
var bodies: Dictionary = {}          # body_name -> file_name
var expressions: Dictionary = {}     # expression_name -> face_file_name
var crop: float = 1.0                # 0.0-1.0, show top N% of sprite (1.0 = full body)


func load_from_dict(data: Dictionary) -> void:
	render_mode = data.get("render_mode", "sprite")
	default_body = data.get("default_body", "")
	bodies = data.get("bodies", {})
	expressions = data.get("expressions", {})
	crop = data.get("crop", 1.0)


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
