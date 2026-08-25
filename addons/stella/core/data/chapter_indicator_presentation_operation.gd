## Typed adapter for one canonical current-chapter indicator operation.
class_name ChapterIndicatorPresentationOperation extends PresentationOperation


func _init(payload: Dictionary = {}, source: Dictionary = {}) -> void:
	super(&"chapter_indicator", &"chapter:indicator", payload, source)
