## Emits char_anim_requested signal for character animations.
class_name AnimHandler extends CommandHandler


func get_command_type() -> String:
	return "char_anim"


func execute(data: CommandData, _context: ScenarioContext) -> void:
	var character = data.get_string("character", "")
	var anim = data.get_string("anim", "")
	var intensity = data.get_string("intensity", "normal")
	SignalBus.char_anim_requested.emit(character, anim, intensity)
