## One dry-preserving delay tap with an optional repeating feedback branch.
class_name VoiceDspDelayEffect extends VoiceDspEffectDefinition

@export_range(0.0, 1500.0, 0.001) var time_ms: float = 250.0
## Linear feedback gain. Zero disables feedback; nonzero values must be at
## least VoiceDspChainDefinition.MIN_NONZERO_LINEAR_GAIN.
@export_range(0.0, 1.0, 0.001) var feedback: float = 0.0
## Linear wet/tap gain. The dry signal always remains at 1.0.
@export_range(0.0, 1.0, 0.001) var mix: float = 0.5
