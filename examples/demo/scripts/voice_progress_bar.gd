## Example voice progress bar — listens to the high-level dialogue_voice_*
## signals so a @combine multi-segment dialogue shows as ONE continuous bar
## spanning the total combined duration, instead of resetting per segment.
## Attach to any ProgressBar node.
extends ProgressBar


func _ready():
	visible = false
	min_value = 0.0
	max_value = 1.0
	step = 0.001
	SignalBus.dialogue_voice_started.connect(_on_dialogue_voice_started)
	SignalBus.dialogue_voice_progress.connect(_on_dialogue_voice_progress)
	SignalBus.dialogue_voice_finished.connect(_on_dialogue_voice_finished)
	SignalBus.hide_dialogue.connect(func(): visible = false)


func _on_dialogue_voice_started(total_duration: float):
	if not SignalBus.dialogue_voice_started_event_is_current(
		total_duration, get_instance_id()):
		return
	value = 0.0
	visible = true


func _on_dialogue_voice_finished():
	if not SignalBus.dialogue_voice_finished_event_is_current(get_instance_id()):
		return
	visible = false


func _on_dialogue_voice_progress(position: float, total_duration: float):
	if not SignalBus.dialogue_voice_progress_event_is_current(
		position, total_duration, get_instance_id()):
		return
	if total_duration > 0:
		value = position / total_duration
