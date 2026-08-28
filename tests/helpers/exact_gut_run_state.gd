extends RefCounted
## Process-local manifest and fail-closed accounting for Stella's exact GUT run.
##
## The entry point records the independently preflighted selection here.  The
## post-run hook then compares that manifest with GUT's collector and execution
## state.  This script deliberately stores no state in user://: every process
## starts with an empty manifest and cannot consume a stale run artifact.

const FINAL_MARKER_PREFIX := "STELLA_EXACT_GUT_FINAL "

static var manifest: Dictionary = {}
static var post_run_checked := false
static var post_run_passed := false
static var process_tail_probe_enabled := false


static func reset() -> void:
	manifest = {}
	post_run_checked = false
	post_run_passed = false
	process_tail_probe_enabled = false


static func install_manifest(value: Dictionary) -> void:
	manifest = value.duplicate(true)


static func enable_process_tail_probe() -> void:
	process_tail_probe_enabled = true


static func _method_id(collected_script: Variant, test: Variant) -> String:
	return "%s::%s" % [collected_script.get_full_name(), String(test.name)]


static func collector_inventory(collector: Variant) -> Array[String]:
	var result: Array[String] = []
	for collected_script: Variant in collector.get_scripts():
		for test: Variant in collected_script.tests:
			result.append(_method_id(collected_script, test))
	result.sort()
	return result


static func collector_script_paths(collector: Variant) -> Array[String]:
	var unique_paths: Dictionary = {}
	for collected_script: Variant in collector.get_scripts():
		unique_paths[String(collected_script.path)] = true
	var result: Array[String] = []
	result.assign(unique_paths.keys())
	result.sort()
	return result


static func selected_inventory(collector: Variant, exact_method: String) -> Array[String]:
	var result: Array[String] = []
	for collected_script: Variant in collector.get_scripts():
		for test: Variant in collected_script.tests:
			if exact_method.is_empty() or String(test.name) == exact_method:
				result.append(_method_id(collected_script, test))
	result.sort()
	return result


static func ran_inventory(collector: Variant) -> Array[String]:
	var result: Array[String] = []
	for collected_script: Variant in collector.get_scripts():
		for test: Variant in collected_script.tests:
			if bool(test.was_run):
				result.append(_method_id(collected_script, test))
	result.sort()
	return result


static func ran_counts_by_script(collector: Variant) -> Dictionary:
	var result: Dictionary = {}
	for collected_script: Variant in collector.get_scripts():
		var path := String(collected_script.path)
		for test: Variant in collected_script.tests:
			if bool(test.was_run):
				result[path] = int(result.get(path, 0)) + 1
	return result


static func _tracked_errors(error_tracker: GutErrorTracker) -> Array[GutTrackedError]:
	var result: Array[GutTrackedError] = []
	for test_id: Variant in error_tracker.errors.items:
		for error: Variant in error_tracker.errors.items[test_id]:
			if error is GutTrackedError:
				result.append(error as GutTrackedError)
	return result


static func diagnostic_counts(error_tracker: GutErrorTracker) -> Dictionary:
	var raw_warning_count := 0
	var handled_warning_count := 0
	var unhandled_warning_count := 0
	var unhandled_diagnostic_count := 0
	for error: GutTrackedError in _tracked_errors(error_tracker):
		if error.is_push_warning():
			raw_warning_count += 1
			if error.handled:
				handled_warning_count += 1
			else:
				unhandled_warning_count += 1
		if not error.handled:
			unhandled_diagnostic_count += 1
	return {
		"raw_warning_count": raw_warning_count,
		"handled_warning_count": handled_warning_count,
		"unhandled_warning_count": unhandled_warning_count,
		"unhandled_diagnostic_count": unhandled_diagnostic_count,
	}


static func _unhandled_diagnostic_descriptions(
	error_tracker: GutErrorTracker,
) -> Array[String]:
	var result: Array[String] = []
	for error: GutTrackedError in _tracked_errors(error_tracker):
		if error.handled:
			continue
		result.append("%s: %s (%s:%d -> %s)" % [
			error.get_error_type_name(),
			String(error.code),
			String(error.file),
			int(error.line),
			String(error.function),
		])
	return result


static func validate_manifest(gut: Variant) -> Dictionary:
	post_run_checked = true
	var messages: Array[String] = []
	if manifest.is_empty():
		messages.append("exact run manifest is missing")
		post_run_passed = false
		return {"ok": false, "messages": messages}

	var collector: Variant = gut.get_test_collector()
	var actual_scripts := collector_script_paths(collector)
	var actual_collected := collector_inventory(collector)
	var exact_method := String(manifest.get("exact_method", ""))
	var actual_selected := selected_inventory(collector, exact_method)
	var actual_ran := ran_inventory(collector)
	var expected_scripts: Array = manifest.get("requested_scripts", [])
	var expected_collected: Array = manifest.get("collected_methods", [])
	var expected_selected: Array = manifest.get("selected_methods", [])
	var ran_by_script := ran_counts_by_script(collector)

	if actual_scripts != expected_scripts:
		messages.append("requested scripts do not equal GUT-collected scripts: expected=%s actual=%s"
			% [expected_scripts, actual_scripts])
	if actual_collected != expected_collected:
		messages.append("preflight collection does not equal GUT collection: expected=%s actual=%s"
			% [expected_collected, actual_collected])
	if actual_selected != expected_selected:
		messages.append("requested methods do not equal selected collection: expected=%s actual=%s"
			% [expected_selected, actual_selected])
	if actual_ran != expected_selected:
		messages.append("requested methods do not equal ran methods: expected=%s actual=%s"
			% [expected_selected, actual_ran])
	if expected_selected.is_empty() or actual_ran.is_empty():
		messages.append("exact GUT run must request, collect, and run at least one test")
	for path_value: Variant in expected_scripts:
		var path := String(path_value)
		if int(ran_by_script.get(path, 0)) == 0:
			messages.append("requested test script ran zero methods: %s" % path)

	post_run_passed = messages.is_empty()
	return {
		"ok": post_run_passed,
		"messages": messages,
		"requested_count": expected_selected.size(),
		"collected_count": actual_selected.size(),
		"ran_count": actual_ran.size(),
	}


static func validate_diagnostics(error_tracker: GutErrorTracker) -> Dictionary:
	var messages: Array[String] = []
	var counts := diagnostic_counts(error_tracker)
	if int(counts["unhandled_warning_count"]) > 0:
		messages.append("unexpected/unhandled warnings: %d" %
			int(counts["unhandled_warning_count"]))
	if int(counts["unhandled_diagnostic_count"]) > 0:
		messages.append_array(_unhandled_diagnostic_descriptions(error_tracker))
	return {
		"ok": messages.is_empty(),
		"messages": messages,
		"raw_warning_count": int(counts["raw_warning_count"]),
		"handled_warning_count": int(counts["handled_warning_count"]),
		"unhandled_warning_count": int(counts["unhandled_warning_count"]),
		"unhandled_diagnostic_count": int(counts["unhandled_diagnostic_count"]),
	}


static func final_summary(gut: Variant, exit_code: int) -> Dictionary:
	var collector: Variant = gut.get_test_collector()
	var exact_method := String(manifest.get("exact_method", ""))
	var counts := diagnostic_counts(gut.error_tracker)
	return {
		"status": "passed" if exit_code == 0 else "failed",
		"exit_code": exit_code,
		"requested_count": (manifest.get("selected_methods", []) as Array).size(),
		"collected_count": selected_inventory(collector, exact_method).size(),
		"ran_count": ran_inventory(collector).size(),
		"raw_warning_count": int(counts["raw_warning_count"]),
		"handled_warning_count": int(counts["handled_warning_count"]),
		"unhandled_warning_count": int(counts["unhandled_warning_count"]),
		"unhandled_diagnostic_count": int(counts["unhandled_diagnostic_count"]),
		"post_run_checked": post_run_checked,
	}
