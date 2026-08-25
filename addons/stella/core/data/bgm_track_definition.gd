## Authored stream plus complete default and named BGM cue definitions.
class_name BgmTrackDefinition extends Resource

@export var stream: AudioStream
@export var loop: bool = true
@export_range(0.0, 36000.0, 0.001, "or_greater") var start_position: float = 0.0
@export_range(0.0, 36000.0, 0.001, "or_greater") var loop_position: float = 0.0
@export var cues: Array[BgmCueDefinition] = []
