## One ordered system-audio cue inside a PresentationClipDefinition timeline.
class_name PresentationClipAudioCue extends PresentationClipCue

@export var asset: String = ""
@export_range(-80.0, 24.0, 0.1) var volume_db: float = 0.0
