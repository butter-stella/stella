extends GutTest
## Tests for WaitController — async wait/complete mechanism.


func test_complete_resolves_wait():
	var wc = WaitController.new()
	assert_false(wc.is_completed())
	wc.complete()
	assert_true(wc.is_completed())


func test_reset_clears_completed():
	var wc = WaitController.new()
	wc.complete()
	assert_true(wc.is_completed())
	wc.reset()
	assert_false(wc.is_completed())
