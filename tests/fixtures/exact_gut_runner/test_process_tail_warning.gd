extends GutTest

const ExactGutRunState = preload("res://tests/helpers/exact_gut_run_state.gd")


func test_process_tail_after_final_marker_fails_the_shell_gate() -> void:
	ExactGutRunState.enable_process_tail_probe()
	assert_true(ExactGutRunState.process_tail_probe_enabled)
