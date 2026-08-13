## Example voice progress bar — listens to the typed logical voice lifecycle
## so a @combine multi-segment dialogue shows as ONE continuous bar
## spanning the total combined duration, instead of resetting per segment.
## Attach to any ProgressBar node.
extends ProgressBar


func _ready():
	visible = false
	min_value = 0.0
	max_value = 1.0
	step = 0.001
	SignalBus.dialogue_voice_playback_event.connect(_on_dialogue_voice_event)
	SignalBus.hide_dialogue.connect(func(): visible = false)


func _on_dialogue_voice_event(event: DialogueVoicePlaybackEvent) -> void:
	if event == null or not event.is_current():
		return
	match event.get_kind():
		DialogueVoicePlaybackEvent.Kind.STARTED:
			value = 0.0
			visible = true
		DialogueVoicePlaybackEvent.Kind.PROGRESS:
			if event.get_total_duration() > 0.0:
				value = event.get_position() / event.get_total_duration()
		DialogueVoicePlaybackEvent.Kind.FINISHED:
			visible = false
