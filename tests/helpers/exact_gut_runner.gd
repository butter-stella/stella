extends SceneTree
## Exact Stella GUT entry point.  This intentionally does not read .gutconfig.

const ExactGutRunState = preload("res://tests/helpers/exact_gut_run_state.gd")
const RUNNER_SCENE := preload("res://tests/helpers/exact_gut_runner.tscn")
const POST_RUN_SCRIPT := "res://tests/helpers/exact_gut_post_run.gd"
const FULL_DIRECTORIES := ["res://tests/unit", "res://tests/integration"]

var _error_tracker: GutErrorTracker


func _init() -> void:
	ExactGutRunState.reset()
	_error_tracker = GutUtils.get_error_tracker()
	GutErrorTracker.register_logger(_error_tracker)
	if "--startup-warning-probe" in OS.get_cmdline_user_args():
		push_warning("Stella exact GUT probe: startup warning before deferred preflight")
	call_deferred("_run")


func _run() -> void:
	var selection := _parse_selection(OS.get_cmdline_user_args())
	if not bool(selection.get("ok", false)):
		await _fail_preflight(
			String(selection.get("error", "invalid exact GUT selection")))
		return

	var requested_scripts_result := _resolve_requested_scripts(selection)
	if not bool(requested_scripts_result.get("ok", false)):
		await _fail_preflight(String(requested_scripts_result.get(
			"error", "invalid requested scripts")))
		return
	var requested_scripts: Array[String] = requested_scripts_result["scripts"]

	var manifest_result := _preflight_manifest(
		requested_scripts,
		String(selection.get("exact_method", "")),
		_error_tracker,
	)
	if not bool(manifest_result.get("ok", false)):
		await _fail_preflight(
			String(manifest_result.get("error", "test preflight failed")))
		return
	ExactGutRunState.install_manifest(manifest_result["manifest"])

	var config_script: Variant = load("res://addons/gut/gut_config.gd")
	var gut_config: Variant = config_script.new()
	gut_config.options = gut_config.default_options.duplicate(true)
	gut_config.options.config_file = ""
	gut_config.options.dirs = []
	gut_config.options.tests = requested_scripts
	gut_config.options.post_run_script = POST_RUN_SCRIPT
	gut_config.options.should_exit = true
	gut_config.options.should_exit_on_success = true
	gut_config.options.log_level = int(selection.get("log_level", 1))
	gut_config.options.unit_test_name = String(selection.get("exact_method", ""))

	var runner: Variant = RUNNER_SCENE.instantiate()
	runner.set_gut_config(gut_config)
	root.add_child(runner)
	runner.run_tests(false)


func _fail_preflight(message: String) -> void:
	printerr("Stella exact GUT preflight failed: %s" % message)
	GutErrorTracker.deregister_logger(_error_tracker)
	var runtime := root.get_node_or_null("StellaRuntime")
	if runtime == null:
		printerr("Stella exact GUT preflight cleanup: StellaRuntime is missing")
	elif not await runtime.call("_await_runtime_audio_quiesce"):
		printerr("Stella exact GUT preflight cleanup: Runtime audio did not quiesce")
	if runtime != null and not await runtime.call("_await_audio_mix_boundary"):
		printerr("Stella exact GUT preflight cleanup: audio mix boundary was not reached")
	# Give ResourceLoader, autoloads, and the tracker one final lifecycle frame to
	# release preflight-only references before the process cleanup boundary.
	await process_frame
	quit(1)


func _parse_selection(arguments: PackedStringArray) -> Dictionary:
	var use_full := false
	var directories: Array[String] = []
	var tests: Array[String] = []
	var exact_case := ""
	var log_level := 1
	for argument: String in arguments:
		if argument == "--full":
			use_full = true
		elif argument.begins_with("--dir="):
			directories.append(argument.trim_prefix("--dir="))
		elif argument.begins_with("--test="):
			tests.append(argument.trim_prefix("--test="))
		elif argument.begins_with("--case="):
			exact_case = argument.trim_prefix("--case=")
		elif argument.begins_with("--log-level="):
			log_level = argument.trim_prefix("--log-level=").to_int()
		elif argument == "--startup-warning-probe":
			pass
		else:
			return {"ok": false, "error": "unknown argument '%s'" % argument}

	var selection_kinds := int(use_full) + int(not directories.is_empty()) \
		+ int(not tests.is_empty()) + int(not exact_case.is_empty())
	if selection_kinds != 1:
		return {"ok": false, "error": (
			"choose exactly one of --full, --dir, --test, or --case")}
	if log_level < 0 or log_level > 3:
		return {"ok": false, "error": "--log-level must be between 0 and 3"}

	var exact_method := ""
	if not exact_case.is_empty():
		var separator := exact_case.rfind("::")
		if separator <= 0 or separator + 2 >= exact_case.length():
			return {"ok": false, "error": (
				"--case must be res://path/test_file.gd::test_method")}
		tests = [exact_case.left(separator)]
		exact_method = exact_case.substr(separator + 2)

	return {
		"ok": true,
		"full": use_full,
		"directories": directories,
		"tests": tests,
		"exact_method": exact_method,
		"log_level": log_level,
	}


func _normalize_res_path(path: String) -> String:
	if not path.begins_with("res://"):
		return ""
	return "res://" + path.trim_prefix("res://").simplify_path()


func _scripts_in_directory(path: String) -> Dictionary:
	var normalized := _normalize_res_path(path)
	if normalized.is_empty() or not DirAccess.dir_exists_absolute(normalized):
		return {"ok": false, "error": "test directory does not exist: %s" % path}
	var scripts: Array[String] = []
	for filename: String in DirAccess.get_files_at(normalized):
		if filename.begins_with("test_") and filename.ends_with(".gd"):
			scripts.append(normalized.path_join(filename))
	scripts.sort()
	return {"ok": true, "scripts": scripts}


func _resolve_requested_scripts(selection: Dictionary) -> Dictionary:
	var directories: Array = selection.get("directories", [])
	if bool(selection.get("full", false)):
		directories = FULL_DIRECTORIES
	var requested: Array[String] = []
	for directory_value: Variant in directories:
		var directory_result := _scripts_in_directory(String(directory_value))
		if not bool(directory_result.get("ok", false)):
			return directory_result
		requested.append_array(directory_result["scripts"])
	for path_value: Variant in selection.get("tests", []):
		var normalized := _normalize_res_path(String(path_value))
		if normalized.is_empty() or not normalized.ends_with(".gd"):
			return {"ok": false, "error": "test script must be a res:// .gd path: %s" % path_value}
		if not FileAccess.file_exists(normalized):
			return {"ok": false, "error": "test script does not exist: %s" % normalized}
		requested.append(normalized)

	requested.sort()
	for index: int in range(1, requested.size()):
		if requested[index] == requested[index - 1]:
			return {"ok": false, "error": "duplicate requested test script: %s" % requested[index]}
	if requested.is_empty():
		return {"ok": false, "error": "test selection resolved to zero scripts"}
	return {"ok": true, "scripts": requested}


func _preflight_manifest(
	requested_scripts: Array[String],
	exact_method: String,
	error_tracker: GutErrorTracker,
) -> Dictionary:
	var collector: Variant = GutUtils.TestCollector.new()
	for path: String in requested_scripts:
		var loaded: Variant = ResourceLoader.load(
			path, "Script", ResourceLoader.CACHE_MODE_IGNORE)
		if not loaded is Script or not (loaded as Script).can_instantiate():
			return {"ok": false, "error": "test script could not be parsed/loaded: %s" % path}
		collector.add_script(path)

	var actual_scripts := ExactGutRunState.collector_script_paths(collector)
	if actual_scripts != requested_scripts:
		return {"ok": false, "error": (
			"requested scripts do not equal preflight collection: expected=%s actual=%s"
			% [requested_scripts, actual_scripts])}
	var collected_methods := ExactGutRunState.collector_inventory(collector)
	if collected_methods.is_empty():
		return {"ok": false, "error": "preflight collected zero test methods"}
	var method_counts_by_script: Dictionary = {}
	for collected_script: Variant in collector.get_scripts():
		var path := String(collected_script.path)
		method_counts_by_script[path] = int(method_counts_by_script.get(path, 0)) \
			+ collected_script.tests.size()
	for path: String in requested_scripts:
		if int(method_counts_by_script.get(path, 0)) == 0:
			return {"ok": false, "error": (
				"requested test script collected zero methods: %s" % path)}
	var counts := ExactGutRunState.diagnostic_counts(error_tracker)
	if int(counts["unhandled_diagnostic_count"]) > 0:
		return {"ok": false, "error": (
			"preflight emitted %d unhandled diagnostics"
			% int(counts["unhandled_diagnostic_count"]))}

	var selected_methods := ExactGutRunState.selected_inventory(collector, exact_method)
	if not exact_method.is_empty():
		if selected_methods.size() != 1:
			return {"ok": false, "error": (
				"exact method '%s' matched %d collected methods"
				% [exact_method, selected_methods.size()])}
		var substring_matches: Array[String] = []
		for method_id: String in collected_methods:
			var method_name := method_id.substr(method_id.rfind("::") + 2)
			if exact_method in method_name:
				substring_matches.append(method_id)
		if substring_matches != selected_methods:
			return {"ok": false, "error": (
				"GUT's method filter is not unique for exact method '%s': %s"
				% [exact_method, substring_matches])}

	return {"ok": true, "manifest": {
		"requested_scripts": requested_scripts.duplicate(),
		"collected_methods": collected_methods,
		"selected_methods": selected_methods,
		"exact_method": exact_method,
	}}
