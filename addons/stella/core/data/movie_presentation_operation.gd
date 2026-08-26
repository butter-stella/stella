## Immutable typed operation for the one Runtime-owned movie surface.
class_name MoviePresentationOperation extends PresentationOperation


func _init(payload: Dictionary = {}, source: Dictionary = {}) -> void:
	super(&"movie", &"movie:main", payload, source)
