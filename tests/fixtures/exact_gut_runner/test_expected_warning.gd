extends GutTest

const WarningTestSupport = preload("res://tests/helpers/warning_test_support.gd")
const EXPECTED_WARNING := "Stella exact GUT probe: exact expected warning"


func test_exact_expected_warning_is_visible_and_handled() -> void:
	push_warning(EXPECTED_WARNING)
	WarningTestSupport.assert_exact_warnings(
		self,
		EXPECTED_WARNING,
		"res://tests/fixtures/exact_gut_runner/test_expected_warning.gd",
		"test_exact_expected_warning_is_visible_and_handled",
	)
