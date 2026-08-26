extends Node2D


func _init() -> void:
	ProjectSettings.set_setting(
		"stella/tests/presentation_clip_forbidden_init_count",
		int(ProjectSettings.get_setting(
			"stella/tests/presentation_clip_forbidden_init_count", 0)) + 1,
	)
