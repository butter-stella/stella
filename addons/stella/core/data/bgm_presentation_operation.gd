## Typed adapter for the single canonical BGM lifecycle channel.
class_name BgmPresentationOperation extends PresentationOperation


func _init(payload: Dictionary = {}, source: Dictionary = {}) -> void:
	super(&"bgm", &"bgm:main", payload, source)
