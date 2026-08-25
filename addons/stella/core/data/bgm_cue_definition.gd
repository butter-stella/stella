## Complete named BGM cue. Cues do not inherit fields from the track default.
class_name BgmCueDefinition extends Resource

@export var cue_name: String = ""
@export var loop: bool = true
@export_range(0.0, 36000.0, 0.001, "or_greater") var start_position: float = 0.0
@export_range(0.0, 36000.0, 0.001, "or_greater") var loop_position: float = 0.0
@export_range(-1.0, 36000.0, 0.001, "or_greater") var loop_end_position: float = -1.0
