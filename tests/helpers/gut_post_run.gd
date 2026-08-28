extends GutHookScript
## Shared editor and exact-runner shutdown gates.
##
## This hook intentionally does not validate an exact-run manifest: editor GUT
## runs do not have one.  The CLI entry point uses exact_gut_post_run.gd, which
## adds exact selection/collection/execution accounting to these shared gates.

const ExactGutRunState = preload("res://tests/helpers/exact_gut_run_state.gd")


func run() -> void:
	if await _run_shared_gates():
		set_exit_code(1)


func _run_shared_gates() -> bool:
	var failed := false
	if not await StellaRuntime._await_runtime_audio_quiesce():
		printerr(
			"GUT post-run: Runtime audio quiesce was not acknowledged")
		failed = true
	if not await StellaRuntime._await_audio_mix_boundary():
		printerr(
			"GUT post-run: AudioServer did not reach the bounded mix boundary")
		failed = true

	var result := ExactGutRunState.validate_diagnostics(gut.error_tracker)
	print("Stella GUT warnings: raw=%d handled_expected=%d unexpected_unhandled=%d" % [
		int(result.get("raw_warning_count", 0)),
		int(result.get("handled_warning_count", 0)),
		int(result.get("unhandled_warning_count", 0)),
	])
	if not bool(result.get("ok", false)):
		for message: String in result.get("messages", []):
			printerr("GUT warning gate: %s" % message)
		failed = true
	return failed
