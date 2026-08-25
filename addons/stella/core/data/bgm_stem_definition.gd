## One named stream inside a synchronized BGM track definition.
class_name BgmStemDefinition extends Resource

@export var stem_name: String = ""
@export var stream: AudioStream
@export_range(0.0, 1.0, 0.001) var default_gain: float = 1.0
