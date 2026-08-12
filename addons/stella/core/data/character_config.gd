## Dialogue avatar asset configuration.
## `avatar_assets` optionally maps inline expression names to portrait asset
## stems. Stage character rendering is configured independently by @stage.
class_name CharacterConfig extends RefCounted

var avatar_assets: Dictionary = {}  # expression_name -> portrait asset stem
var avatar_rect: Rect2 = Rect2()    # crop region within the portrait texture


func load_from_dict(data: Dictionary) -> void:
	var raw_assets = data.get("avatar_assets", {})
	if raw_assets is Dictionary:
		avatar_assets = raw_assets.duplicate(true)
	else:
		avatar_assets = {}
		push_warning("CharacterConfig: avatar_assets must be a Dictionary")

	var ar = data.get("avatar_rect", {})
	if ar is Dictionary and ar.size() > 0:
		avatar_rect = Rect2(
			ar.get("x", 0.0),
			ar.get("y", 0.0),
			ar.get("w", 0.0),
			ar.get("h", 0.0),
		)
	elif data.has("avatar_rect") and not ar is Dictionary:
		push_warning("CharacterConfig: avatar_rect must be a Dictionary")


func resolve_avatar_asset(expression: String) -> String:
	if avatar_assets.has(expression):
		return String(avatar_assets[expression])
	if avatar_assets.has("default"):
		return String(avatar_assets["default"])
	return expression


func has_avatar_rect() -> bool:
	return avatar_rect.size.x > 0 and avatar_rect.size.y > 0
