## Emits voice_play signal for voice playback.
class_name VoiceHandler extends CommandHandler


func get_command_type() -> String:
	return "voice"


func execute(data: CommandData, context: ScenarioContext) -> void:
	if context.is_replay:
		return

	var asset = data.get_string("asset", "")
	if asset == "":
		return
	SignalBus.voice_play.emit(asset, "")
