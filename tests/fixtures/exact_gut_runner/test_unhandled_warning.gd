extends GutTest


func test_unhandled_warning_fails_the_post_run_gate() -> void:
	push_warning("Stella exact GUT probe: deliberate unhandled warning")
	assert_true(true, "the warning gate, not a failed assertion, rejects this probe")
