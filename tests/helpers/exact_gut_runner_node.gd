extends "res://addons/gut/gui/GutRunner.gd"
## Stella-owned final runner boundary.
##
## GUT's post hook runs before end_run.  Keep the tracker registered through
## the real end_run signal tail, validate again on the runner's lifecycle frame,
## and print the structured marker immediately before SceneTree.quit().  The
## outer shell gate treats all output after that marker as a shutdown-tail
## failure which no in-process Logger can reliably convert into an exit code.

const ExactGutRunState = preload("res://tests/helpers/exact_gut_run_state.gd")


func _end_run(override_exit_code: int = EXIT_OK) -> void:
	var exit_code := override_exit_code
	if gut.get_fail_count() > 0:
		exit_code = EXIT_ERROR
	var post_hook_inst: Variant = gut.get_post_run_script_instance()
	if post_hook_inst != null and post_hook_inst.get_exit_code() != null:
		exit_code = int(post_hook_inst.get_exit_code())
	if not ExactGutRunState.post_run_checked or not ExactGutRunState.post_run_passed:
		exit_code = EXIT_ERROR

	# This is the runner shutdown lifecycle boundary, not gameplay timing.
	# end_run callbacks resume before this continuation, so their diagnostics
	# remain observable by the registered tracker.
	await get_tree().process_frame
	var counts := ExactGutRunState.diagnostic_counts(error_tracker)
	if int(counts["unhandled_diagnostic_count"]) > 0:
		exit_code = EXIT_ERROR

	GutErrorTracker.deregister_logger(error_tracker)
	var summary := ExactGutRunState.final_summary(gut, exit_code)
	print(ExactGutRunState.FINAL_MARKER_PREFIX + JSON.stringify(summary))
	get_tree().quit(exit_code)


func _exit_tree() -> void:
	super()
	if ExactGutRunState.process_tail_probe_enabled:
		push_warning("Stella exact GUT probe: process-tail warning after final marker")
