## Example voice progress bar — listens to SignalBus.voice_progress to show playback position.
## Attach to any ProgressBar node. The framework emits voice_progress(position, duration) each frame
## while voice is playing. Game developers can use this as-is or build their own UI.
extends ProgressBar


func _ready():
	visible = false
	min_value = 0.0
	max_value = 1.0
	step = 0.001
	SignalBus.voice_started.connect(_on_voice_started)
	SignalBus.voice_finished.connect(_on_voice_finished)
	SignalBus.voice_progress.connect(_on_voice_progress)
	SignalBus.hide_dialogue.connect(func(): visible = false)


func _on_voice_started(_character: String, _asset: String):
	value = 0.0
	visible = true


func _on_voice_finished():
	visible = false


func _on_voice_progress(position: float, duration: float):
	if duration > 0:
		value = position / duration
