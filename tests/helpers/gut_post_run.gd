extends GutHookScript
## Test-runner shutdown boundary for the persistent Runtime-owned audio graph.
##
## GUT exits SceneTree immediately after this hook. Exercise Stella's existing
## typed quiesce handshake and the exact AudioServer mix rollover first so no
## active stream is left to the engine shutdown tail.


func run() -> void:
	if not await StellaRuntime._await_runtime_audio_quiesce():
		gut.logger.error(
			"GUT post-run: Runtime audio quiesce was not acknowledged")
		set_exit_code(1)
		return
	if not await StellaRuntime._await_audio_mix_boundary():
		gut.logger.error(
			"GUT post-run: AudioServer did not reach the bounded mix boundary")
		set_exit_code(1)
