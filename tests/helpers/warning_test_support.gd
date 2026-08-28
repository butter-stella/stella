extends RefCounted
## Exact identity matcher for intentional product warnings in negative tests.
##
## Godot reports push_warning itself as the direct GutTrackedError origin.  The
## production GDScript origin is therefore matched through ScriptBacktrace's
## structured frame API, never by substring-searching formatted log output.


static func _has_origin_frame(
	error: GutTrackedError,
	expected_file: String,
	expected_function: String,
) -> bool:
	for backtrace_value: Variant in error.backtrace:
		if not backtrace_value is ScriptBacktrace:
			continue
		var backtrace := backtrace_value as ScriptBacktrace
		for frame_index: int in range(backtrace.get_frame_count()):
			if (
				backtrace.get_frame_file(frame_index) == expected_file
				and backtrace.get_frame_function(frame_index) == expected_function
			):
				return true
	return false


static func assert_exact_warnings(
	test: GutTest,
	expected_code: String,
	expected_file: String,
	expected_function: String,
	expected_count: int = 1,
) -> void:
	var matches: Array[GutTrackedError] = []
	for error_value: Variant in test.get_errors():
		if not error_value is GutTrackedError:
			continue
		var error := error_value as GutTrackedError
		if (
			not error.handled
			and error.is_push_warning()
			and String(error.code) == expected_code
			and String(error.file) == "core/variant/variant_utility.cpp"
			and String(error.function) == "push_warning"
			and _has_origin_frame(error, expected_file, expected_function)
		):
			matches.append(error)
	test.assert_eq(matches.size(), expected_count,
		"exact warning identity %s -> %s (%s)" % [
			expected_file, expected_function, expected_code,
		])
	if matches.size() != expected_count:
		return
	for error: GutTrackedError in matches:
		error.handled = true
