## Base contract for one authored cue in a PresentationClipDefinition timeline.
##
## Concrete cue Resources remain semantic: the visual presenter applies named
## state cues and the audio presenter owns system-audio cues. Their single
## ordered array is the authored cross-domain order.
class_name PresentationClipCue extends Resource

@export_range(0.0, 120.0, 0.001, "or_greater") var offset_seconds: float = 0.0
@export var authored_source_path: String = ""
@export var authored_source_line: int = 0
