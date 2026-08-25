## Deterministic band-pass primitive expressed as two ordered Godot filters.
class_name VoiceDspBandPassEffect extends VoiceDspEffectDefinition

@export_range(1.0, 20500.0, 0.001) var center_hz: float = 2000.0
@export_range(0.001, 40998.0, 0.001) var bandwidth_hz: float = 1000.0
## Maps 1..4 to Godot's 6/12/18/24 dB-per-octave FilterDB values.
@export_range(1, 4, 1) var order: int = 2
