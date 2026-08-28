extends GutTest


func should_skip_script() -> String:
	return "Stella exact GUT probe: collected script deliberately skipped"


func test_collected_but_not_run_must_fail() -> void:
	assert_true(true)
