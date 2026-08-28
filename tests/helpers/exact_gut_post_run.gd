extends "res://tests/helpers/gut_post_run.gd"
## Exact CLI post-run capability layered on the editor-safe shared GUT gates.

func run() -> void:
	var failed := await _run_shared_gates()
	var result := ExactGutRunState.validate_manifest(gut)
	print("Stella exact GUT accounting: requested=%d collected=%d ran=%d" % [
		int(result.get("requested_count", 0)),
		int(result.get("collected_count", 0)),
		int(result.get("ran_count", 0)),
	])
	if not bool(result.get("ok", false)):
		for message: String in result.get("messages", []):
			printerr("GUT exact manifest gate: %s" % message)
		failed = true
	if failed:
		set_exit_code(1)
