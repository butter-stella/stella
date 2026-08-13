## Sends a typed playback request; SignalBus mirrors the legacy signal only as
## an outbound compatibility notification.
class_name VoiceHandler extends CommandHandler


func get_command_type() -> String:
	return "voice"


func execute(data: CommandData, _context: ScenarioContext) -> void:
	var asset = data.get_string("asset", "")
	if asset == "":
		return
	SignalBus.request_voice_playback(asset, "")
