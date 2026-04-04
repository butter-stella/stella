## Emits voice_play signal for voice playback.
class_name VoiceHandler extends CommandHandler


func get_command_type() -> String:
	return "voice"


func execute(data: CommandData, _context: ScenarioContext) -> void:
	var asset = data.get_string("asset", "")
	SignalBus.voice_play.emit(asset)
