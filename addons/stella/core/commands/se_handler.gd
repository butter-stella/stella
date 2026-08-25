## Emits one non-addressable, one-shot sound effect.
class_name SeHandler extends CommandHandler


func get_command_type() -> String:
	return "se"


func execute(data: CommandData, context: ScenarioContext) -> void:
	var keys := data.params.keys() if data != null else []
	keys.sort()
	if (
		data == null
		or data.type != "se"
		or keys != ["asset"]
		or not data.params.get("asset", null) is String
		or String(data.params["asset"]).strip_edges().is_empty()
	):
		push_error(
			"SeHandler: @se accepts exactly one one-shot asset; use @loop_se for addressable persistent audio"
		)
		if context != null and context.is_runtime_owner_current():
			context.is_finished = true
		return
	SignalBus.se_play.emit(String(data.params["asset"]))
