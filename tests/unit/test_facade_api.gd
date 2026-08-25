extends GutTest
## Tests for StellaRuntime facade API and overlay management.


const DIALOGUE_VISIBILITY_SIGNALS := {
	"dialogue_visibility_operations_requested": [
		["operations", TYPE_ARRAY], ["force_cut", TYPE_BOOL],
	],
	"presentation_operation_request_finished": [
		["request_id", TYPE_INT], ["delivered", TYPE_BOOL],
	],
	"dialogue_visibility_transition_receipt_started": [
		["presenter_instance_id", TYPE_INT], ["target", TYPE_STRING],
		["token", TYPE_INT], ["operation_request_id", TYPE_INT],
		["generation", TYPE_INT],
	],
	"dialogue_visibility_transition_terminal": [
		["presenter_instance_id", TYPE_INT], ["target", TYPE_STRING],
		["token", TYPE_INT], ["operation_request_id", TYPE_INT],
		["generation", TYPE_INT], ["outcome", TYPE_STRING_NAME],
	],
	"dialogue_visibility_transition_receipts_finish_requested": [
		["transitions", TYPE_ARRAY],
	],
	"dialogue_visibility_visuals_reset_requested": [],
	"dialogue_visibility_state_apply_requested": [
		["visibility", TYPE_DICTIONARY], ["content", TYPE_DICTIONARY],
		["runtime_binding", TYPE_DICTIONARY],
	],
}

const DIALOGUE_VISIBILITY_DIRECTOR_CALLBACKS := {
	"presentation_operation_request_finished": [
		"_on_presentation_operation_request_finished",
		[["request_id", TYPE_INT], ["delivered", TYPE_BOOL]],
	],
	"dialogue_visibility_transition_receipt_started": [
		"_on_dialogue_visibility_transition_receipt_started",
		[
			["presenter_instance_id", TYPE_INT], ["target", TYPE_STRING],
			["token", TYPE_INT], ["operation_request_id", TYPE_INT],
			["generation", TYPE_INT],
		],
	],
	"dialogue_visibility_transition_terminal": [
		"_on_dialogue_visibility_transition_terminal",
		[
			["presenter_instance_id", TYPE_INT], ["target", TYPE_STRING],
			["token", TYPE_INT], ["operation_request_id", TYPE_INT],
			["generation", TYPE_INT], ["outcome", TYPE_STRING_NAME],
		],
	],
	"dialogue_visibility_visuals_reset_requested": [
		"_on_dialogue_visibility_visuals_reset_requested", [],
	],
	"dialogue_visibility_state_apply_requested": [
		"_on_dialogue_visibility_state_apply_requested",
		[
			["visibility", TYPE_DICTIONARY], ["content", TYPE_DICTIONARY],
			["runtime_binding", TYPE_DICTIONARY],
		],
	],
}


class _DialogueVisibilitySceneProbe extends Node:
	var calls := 0

	func on_finish(_transitions: Array) -> void:
		calls += 1


func _signal_contract(signal_name: String) -> Array:
	for signal_value: Variant in SignalBus.get_signal_list():
		var signal_info: Dictionary = signal_value
		if String(signal_info.get("name", "")) != signal_name:
			continue
		var contract: Array = []
		for argument_value: Variant in signal_info.get("args", []):
			var argument: Dictionary = argument_value
			contract.append([
				String(argument.get("name", "")),
				int(argument.get("type", TYPE_NIL)),
			])
		return contract
	return []


func _method_contract(object: Object, method_name: String) -> Array:
	for method_value: Variant in object.get_method_list():
		var method: Dictionary = method_value
		if String(method.get("name", "")) != method_name:
			continue
		var contract: Array = []
		for argument_value: Variant in method.get("args", []):
			var argument: Dictionary = argument_value
			contract.append([
				String(argument.get("name", "")),
				int(argument.get("type", TYPE_NIL)),
			])
		assert_eq(int(method.get("return", {}).get("type", TYPE_NIL)), TYPE_NIL,
			"Director callback returns void: %s" % method_name)
		return contract
	return []


func _assert_reduced_snapshot_families_validate(
	runtime,
	raw_data: Variant,
	parsed_config,
	label: String
) -> void:
	assert_true(raw_data is Dictionary, "%s should be raw-readable" % label)
	if not raw_data is Dictionary or parsed_config == null:
		return
	var raw_dict: Dictionary = raw_data
	assert_true(raw_dict.has("scenario_context"),
		"%s reduced validation must include scenario_context" % label)
	var base := {"scenario_context": raw_dict.get("scenario_context")}
	assert_true(runtime.save_manager.validate_data_for_scenario(base, parsed_config),
		"%s reduced validation should accept scenario_context" % label)
	for family: String in [
		"presentation_state",
		"read_flags",
		"variable_store",
		"unlocks",
		"flowchart_visited",
		"flowchart_state",
		"timestamp",
	]:
		var probe: Dictionary = base.duplicate(true)
		if raw_dict.has(family):
			if family == "presentation_state":
				var presentation_state: Variant = raw_dict.get(family)
				assert_true(presentation_state is Dictionary,
					"%s presentation_state should be a Dictionary" % label)
				if not presentation_state is Dictionary:
					return
				var presentation_dict: Dictionary = presentation_state
				if presentation_dict.has("bg"):
					assert_true(presentation_dict.get("bg") is String,
						"%s presentation_state.bg should be a String" % label)
				if presentation_dict.has("bgm"):
					assert_true(BgmChannelState.validate_snapshot_state(
						presentation_dict.get("bgm"), false),
						"%s presentation_state.bgm should use the exact stable Dictionary schema" % label)
				if presentation_dict.has("stage_layers"):
					var stage_layers: Variant = presentation_dict.get("stage_layers")
					assert_true(stage_layers is Dictionary,
						"%s presentation_state.stage_layers should be a Dictionary" % label)
					if not stage_layers is Dictionary:
						return
					for layer_id_value: Variant in (stage_layers as Dictionary).keys():
						assert_true(layer_id_value is String and not String(layer_id_value).is_empty(),
							"%s presentation_state.stage_layers keys should be non-empty Strings" % label)
						var layer_state: Variant = (stage_layers as Dictionary).get(layer_id_value)
						assert_true(StageLayerState.validate_snapshot_state(layer_state, false),
							"%s presentation_state.stage_layers[%s] should validate" % [
								label,
								String(layer_id_value),
							])
				var has_visibility := presentation_dict.has("dialogue_visibility")
				var has_content := presentation_dict.has("dialogue_content")
				assert_eq(has_visibility, has_content,
					"%s presentation_state dialogue_visibility/dialogue_content presence must be paired" % label)
				if has_visibility != has_content:
					return
				if has_visibility and has_content:
					var visibility: Variant = presentation_dict.get("dialogue_visibility")
					var content: Variant = presentation_dict.get("dialogue_content")
					assert_true(DialogueVisibilityState.validate_snapshot_state(visibility, false),
						"%s presentation_state dialogue_visibility should validate" % label)
					if content is Dictionary:
						var content_dict: Dictionary = content
						var content_keys: Array[String] = []
						for key_value: Variant in content_dict.keys():
							content_keys.append(String(key_value))
						content_keys.sort()
						assert_eq(content_keys, [
							"active",
							"avatar_expression",
							"character",
							"declarative_presentation",
							"mode",
							"nvl_entries",
							"profile_name",
							"segments",
							"version",
						], "%s presentation_state dialogue_content keys should match the exact schema" % label)
						var version_value: Variant = content_dict.get("version", null)
						assert_true(
							version_value is int or version_value is float,
							"%s presentation_state dialogue_content.version should be JSON-compatible numeric 1" % label
						)
						if version_value is int or version_value is float:
							assert_eq(int(version_value), 1,
								"%s presentation_state dialogue_content.version should equal numeric 1" % label)
						assert_true(content_dict.get("active", null) is bool,
							"%s presentation_state dialogue_content.active should be a bool" % label)
						assert_true(content_dict.get("mode", null) is String,
							"%s presentation_state dialogue_content.mode should be a String" % label)
						assert_true(content_dict.get("profile_name", null) is String,
							"%s presentation_state dialogue_content.profile_name should be a String" % label)
						assert_true(content_dict.get("character", null) is String,
							"%s presentation_state dialogue_content.character should be a String" % label)
						assert_true(content_dict.get("avatar_expression", null) is String,
							"%s presentation_state dialogue_content.avatar_expression should be a String" % label)
						assert_true(
							content_dict.get("declarative_presentation", null) is bool,
							"%s presentation_state dialogue_content.declarative_presentation should be a bool" % label
						)
						assert_true(content_dict.get("segments", null) is Array,
							"%s presentation_state dialogue_content.segments should be an Array" % label)
						assert_true(content_dict.get("nvl_entries", null) is Array,
							"%s presentation_state dialogue_content.nvl_entries should be an Array" % label)
						var mode_value := String(content_dict.get("mode", ""))
						assert_true(mode_value in ["adv", "nvl", "overlay", "monologue"],
							"%s presentation_state dialogue_content.mode should be one of adv/nvl/overlay/monologue" % label)
						if content_dict.get("segments", null) is Array:
							var top_segments: Array = content_dict.get("segments", [])
							for segment_value: Variant in top_segments:
								assert_true(segment_value is Dictionary,
									"%s presentation_state dialogue_content.segments entries should be Dictionaries" % label)
								if not segment_value is Dictionary:
									return
								var segment_dict: Dictionary = segment_value
								var segment_keys: Array[String] = []
								for key_value: Variant in segment_dict.keys():
									segment_keys.append(String(key_value))
								segment_keys.sort()
								assert_eq(segment_keys, ["text"],
									"%s presentation_state dialogue_content.segments entries should use the exact [text] schema" % label)
								assert_true(segment_dict.get("text", null) is String,
									"%s presentation_state dialogue_content.segments text should be a String" % label)
						if content_dict.get("nvl_entries", null) is Array:
							var nvl_entries: Array = content_dict.get("nvl_entries", [])
							for entry_value: Variant in nvl_entries:
								assert_true(entry_value is Dictionary,
									"%s presentation_state dialogue_content.nvl_entries entries should be Dictionaries" % label)
								if not entry_value is Dictionary:
									return
								var entry_dict: Dictionary = entry_value
								var entry_keys: Array[String] = []
								for key_value: Variant in entry_dict.keys():
									entry_keys.append(String(key_value))
								entry_keys.sort()
								assert_eq(entry_keys, ["character", "profile_name", "segments"],
									"%s presentation_state dialogue_content.nvl_entries entries should use the exact [character,profile_name,segments] schema" % label)
								assert_true(entry_dict.get("character", null) is String,
									"%s presentation_state dialogue_content.nvl_entries character should be a String" % label)
								assert_true(entry_dict.get("profile_name", null) is String,
									"%s presentation_state dialogue_content.nvl_entries profile_name should be a String" % label)
								assert_true(entry_dict.get("segments", null) is Array,
									"%s presentation_state dialogue_content.nvl_entries segments should be an Array" % label)
								if entry_dict.get("segments", null) is Array:
									for nested_segment_value: Variant in entry_dict.get("segments", []):
										assert_true(nested_segment_value is Dictionary,
											"%s presentation_state dialogue_content.nvl_entries segments entries should be Dictionaries" % label)
										if not nested_segment_value is Dictionary:
											return
										var nested_segment_dict: Dictionary = nested_segment_value
										var nested_segment_keys: Array[String] = []
										for key_value: Variant in nested_segment_dict.keys():
											nested_segment_keys.append(String(key_value))
										nested_segment_keys.sort()
										assert_eq(nested_segment_keys, ["text"],
											"%s presentation_state dialogue_content.nvl_entries segments should use the exact [text] schema" % label)
										assert_true(nested_segment_dict.get("text", null) is String,
											"%s presentation_state dialogue_content.nvl_entries segments text should be a String" % label)
						if content_dict.get("active", null) is bool:
							var is_active: bool = content_dict.get("active", false)
							if not is_active:
								assert_true(mode_value == "adv",
									"%s presentation_state inactive dialogue_content.mode should stay canonical adv" % label)
								assert_true(String(content_dict.get("profile_name", null)) == "",
									"%s presentation_state inactive dialogue_content.profile_name should stay canonical empty" % label)
								assert_true(not bool(content_dict.get("declarative_presentation", true)),
									"%s presentation_state inactive dialogue_content.declarative_presentation should stay canonical false" % label)
								assert_true(String(content_dict.get("character", null)) == "",
									"%s presentation_state inactive dialogue_content.character should stay canonical empty" % label)
								assert_true(String(content_dict.get("avatar_expression", null)) == "",
									"%s presentation_state inactive dialogue_content.avatar_expression should stay canonical empty" % label)
								if content_dict.get("segments", null) is Array:
									assert_true((content_dict.get("segments", []) as Array).is_empty(),
										"%s presentation_state inactive dialogue_content.segments should stay canonical empty" % label)
								if content_dict.get("nvl_entries", null) is Array:
									assert_true((content_dict.get("nvl_entries", []) as Array).is_empty(),
										"%s presentation_state inactive dialogue_content.nvl_entries should stay canonical empty" % label)
							elif content_dict.get("segments", null) is Array:
								var top_segments: Array = content_dict.get("segments", [])
								assert_true(not top_segments.is_empty(),
									"%s presentation_state active dialogue_content should keep at least one segment" % label)
								if mode_value == "nvl" and content_dict.get("nvl_entries", null) is Array:
									var nvl_entries: Array = content_dict.get("nvl_entries", [])
									assert_true(not nvl_entries.is_empty(),
										"%s presentation_state active nvl dialogue_content should keep at least one NVL entry" % label)
									if not nvl_entries.is_empty():
										var tail_value: Variant = nvl_entries[-1]
										if tail_value is Dictionary:
											var tail_entry: Dictionary = tail_value
											assert_true(
												tail_entry.get("profile_name", null) == content_dict.get("profile_name", null)
												and tail_entry.get("character", null) == content_dict.get("character", null)
												and tail_entry.get("segments", null) == content_dict.get("segments", null),
												"%s presentation_state active nvl dialogue_content tail should match top-level profile_name/character/segments" % label
											)
								elif content_dict.get("nvl_entries", null) is Array:
									assert_true((content_dict.get("nvl_entries", []) as Array).is_empty(),
										"%s presentation_state non-nvl dialogue_content should keep nvl_entries empty" % label)
						assert_true(PresentationState._validate_dialogue_content(content, false),
							"%s presentation_state dialogue_content anchors should validate" % label)
						assert_true(PresentationState.dialogue_content_profiles_exist(
							content_dict,
							parsed_config
						), "%s presentation_state dialogue_content profile_name/mode/active anchors should exist" % label)
			probe[family] = raw_dict.get(family)
		assert_true(runtime.save_manager.validate_data_for_scenario(probe, parsed_config),
			"%s reduced validation should accept %s" % [label, family])


## --- Save/Load Facade ---

func test_has_save_returns_false_for_empty():
	var runtime = get_tree().root.get_node("StellaRuntime")
	assert_false(runtime.has_save(99))


func test_get_save_list_returns_array():
	var runtime = get_tree().root.get_node("StellaRuntime")
	var result = runtime.get_save_list()
	assert_typeof(result, TYPE_ARRAY)


func test_get_save_metadata_empty_for_no_save():
	var runtime = get_tree().root.get_node("StellaRuntime")
	var meta = runtime.get_save_metadata(99)
	assert_eq(meta, {})


func test_reset_settings_restores_defaults():
	var runtime = get_tree().root.get_node("StellaRuntime")
	var orig = runtime.get_setting("bgm_volume")
	runtime.set_setting("bgm_volume", 0.12)
	runtime.reset_settings()
	# After reset, should be back to default (0.8)
	assert_almost_eq(runtime.get_setting("bgm_volume"), 0.8, 0.001)
	# Restore to original
	runtime.set_setting("bgm_volume", orig)


## --- Playback Control Facade ---

func test_toggle_auto_play():
	var runtime = get_tree().root.get_node("StellaRuntime")
	var was_active = runtime.is_auto_playing()
	runtime.toggle_auto_play()
	assert_ne(runtime.is_auto_playing(), was_active)
	# Restore
	runtime.toggle_auto_play()


func test_toggle_skip():
	var runtime = get_tree().root.get_node("StellaRuntime")
	var was_active = runtime.is_skipping()
	runtime.toggle_skip()
	assert_ne(runtime.is_skipping(), was_active)
	# Restore
	runtime.toggle_skip()


func test_auto_play_and_skip_mutually_exclusive():
	var runtime = get_tree().root.get_node("StellaRuntime")
	# Start auto play
	if not runtime.is_auto_playing():
		runtime.toggle_auto_play()
	assert_true(runtime.is_auto_playing())

	# Toggle skip should stop auto play
	runtime.toggle_skip()
	assert_true(runtime.is_skipping())
	assert_false(runtime.is_auto_playing())

	# Clean up
	runtime.toggle_skip()


## --- Named Stage Facade ---

func test_named_stage_facade_emits_canonical_operations():
	var runtime = get_tree().root.get_node("StellaRuntime")
	var received: Array = []
	var callback = func(operations, force_cut):
		received.append({
			"operations": operations.duplicate(true),
			"force_cut": force_cut,
		})
	SignalBus.stage_operations_requested.connect(callback)

	runtime.show_stage_layer(
		"hero",
		{"body": "stage:hero_body", "position": [400.0, 600.0]},
		"fade",
		0.25,
	)
	runtime.update_stage_layer("hero", {"face": "stage:hero_sad"})
	runtime.hide_stage_layer("hero", "fade", 0.1)
	runtime.remove_stage_layer("hero")
	runtime.clear_stage_layers()

	assert_eq(received.size(), 5)
	assert_eq(received[0]["operations"][0]["action"], "show")
	assert_eq(received[0]["operations"][0]["id"], "hero")
	assert_eq(
		received[0]["operations"][0]["properties"]["body"],
		"stage:hero_body",
	)
	assert_eq(received[0]["operations"][0]["transition"], "fade")
	assert_almost_eq(received[0]["operations"][0]["duration"], 0.25, 0.001)
	assert_eq(received[1]["operations"][0]["action"], "update")
	assert_eq(received[2]["operations"][0]["action"], "hide")
	assert_eq(received[3]["operations"][0]["action"], "remove")
	assert_eq(received[4]["operations"][0]["action"], "clear")
	SignalBus.stage_operations_requested.disconnect(callback)


func test_apply_stage_operations_deep_copies_caller_batch():
	var runtime = get_tree().root.get_node("StellaRuntime")
	var received: Array = []
	var callback = func(operations, _force_cut):
		received.append(operations)
	SignalBus.stage_operations_requested.connect(callback)
	var operations := [{
		"action": "show",
		"id": "event",
		"properties": {
			"asset": "stage:flash",
			"redraw": [
				{
					"type": "brightness_contrast",
					"brightness": -17,
					"contrast": 23,
				},
				{"type": "blur", "radius": [1, 1]},
				{"type": "blur", "radius": [2, 0]},
			],
		},
	}]
	runtime.apply_stage_operations(operations, true)
	operations[0]["properties"]["asset"] = "changed-after-emit"
	operations[0]["properties"]["redraw"][0]["brightness"] = 255
	operations[0]["properties"]["redraw"][2]["radius"][0] = 32
	assert_eq(received[0][0]["properties"]["asset"], "stage:flash")
	assert_eq(
		received[0][0]["properties"]["redraw"][0]["brightness"],
		-17,
	)
	assert_eq(received[0][0]["properties"]["redraw"][1]["radius"], [1, 1])
	assert_eq(received[0][0]["properties"]["redraw"][2]["radius"], [2, 0])
	SignalBus.stage_operations_requested.disconnect(callback)
	runtime.clear_stage_layers()


func test_named_stage_facade_canonicalizes_layer_id_whitespace():
	var runtime = get_tree().root.get_node("StellaRuntime")
	var received: Array = []
	var callback = func(operations, _force_cut):
		received.append(operations)
	SignalBus.stage_operations_requested.connect(callback)

	runtime.show_stage_layer("  hero  ", {"asset": "stage:hero"})

	assert_eq(received.size(), 1)
	assert_eq(received[0][0]["id"], "hero")
	SignalBus.stage_operations_requested.disconnect(callback)
	runtime.clear_stage_layers()


## --- UI State Facade ---

func test_show_backlog_transitions_state():
	var runtime = get_tree().root.get_node("StellaRuntime")
	runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	runtime.show_backlog()
	assert_eq(runtime.game_state.current_state, GameStateMachine.State.BACKLOG)
	runtime.close_overlay()


func test_show_save_load_transitions_state():
	var runtime = get_tree().root.get_node("StellaRuntime")
	runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	runtime.show_save_load()
	assert_eq(runtime.game_state.current_state, GameStateMachine.State.SAVE_LOAD)
	runtime.close_overlay()


func test_show_settings_transitions_state():
	var runtime = get_tree().root.get_node("StellaRuntime")
	runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	runtime.show_settings()
	assert_eq(runtime.game_state.current_state, GameStateMachine.State.SETTINGS)
	runtime.close_overlay()


func test_close_overlay_returns_to_previous():
	var runtime = get_tree().root.get_node("StellaRuntime")
	runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	runtime.show_settings()
	runtime.close_overlay()
	assert_eq(runtime.game_state.current_state, GameStateMachine.State.PLAYING)


## --- Backlog Facade ---

func test_get_backlog_returns_array():
	var runtime = get_tree().root.get_node("StellaRuntime")
	var result = runtime.get_backlog()
	assert_typeof(result, TYPE_ARRAY)


## --- Settings Facade ---

func test_get_setting():
	var runtime = get_tree().root.get_node("StellaRuntime")
	var val = runtime.get_setting("bgm_volume")
	assert_typeof(val, TYPE_FLOAT)


func test_set_setting():
	var runtime = get_tree().root.get_node("StellaRuntime")
	var orig = runtime.get_setting("bgm_volume")
	runtime.set_setting("bgm_volume", 0.42)
	assert_almost_eq(runtime.get_setting("bgm_volume"), 0.42, 0.001)
	# Restore
	runtime.set_setting("bgm_volume", orig)


## --- Overlay Lifecycle ---

func test_return_to_title_closes_overlay():
	var runtime = get_tree().root.get_node("StellaRuntime")
	runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	runtime.show_settings()
	assert_not_null(runtime._current_overlay)

	# Cleanup is intentionally not committed until the deferred scene transaction
	# confirms its final current_scene.
	runtime.return_to_title()
	assert_not_null(runtime._current_overlay)
	var completed: bool = await wait_until(
		func() -> bool: return not runtime._return_to_title_pending,
		2.0,
		"return_to_title confirms the new current_scene",
	)
	assert_true(completed)
	assert_null(runtime._current_overlay)
	assert_eq(runtime.game_state.current_state, GameStateMachine.State.TITLE)


func test_start_game_closes_overlay():
	var runtime = get_tree().root.get_node("StellaRuntime")
	runtime.show_settings()
	assert_not_null(runtime._current_overlay)

	# Clean up without actually changing scene
	runtime._close_current_overlay()
	assert_null(runtime._current_overlay)


## --- Continue Game from Title ---

func test_continue_game_returns_false_when_no_saves():
	var runtime = get_tree().root.get_node("StellaRuntime")
	runtime._last_scenario_path = ""
	var orig_scenario = runtime.config.scenario_path
	runtime.config.scenario_path = ""
	runtime.delete_quick_save()
	runtime.delete_auto_save()

	# No saves, no scenario path → false
	assert_false(runtime.continue_game())

	# Restore
	runtime.config.scenario_path = orig_scenario


func test_continue_game_falls_back_to_config_scenario_path():
	var runtime = get_tree().root.get_node("StellaRuntime")
	var orig_path = runtime._last_scenario_path
	runtime._last_scenario_path = ""

	assert_ne(runtime.config.scenario_path, "", "Config must have scenario_path for this test")

	# Create an unfinished real scenario snapshot so continue_game blocks on its
	# first command instead of immediately emitting scenario_ended and queuing an
	# unrelated return_to_title transaction into the following test.
	runtime._cancel_active_gameplay()
	runtime._prepare_scenario(runtime.config.scenario_path)
	runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	runtime.quick_save()
	assert_true(runtime.has_continue_save(), "continue_game setup must create a continue save")
	assert_eq(runtime.save_manager.get_latest_continue_type(), "quick",
		"continue_game should read the quick continue slot")
	var parsed_config = runtime._parse_scenario(runtime.config.scenario_path)
	assert_not_null(parsed_config, "config scenario should parse before continue_game")
	var quick_raw = runtime.save_manager.read_quick_save_data()
	_assert_reduced_snapshot_families_validate(
		runtime,
		quick_raw,
		parsed_config,
		"quick continue snapshot"
	)
	var quick_save_data = runtime.save_manager.read_quick_save_data(parsed_config)
	assert_true(quick_save_data is Dictionary,
		"quick continue snapshot should be readable for the configured scenario")
	if quick_save_data is Dictionary:
		assert_true(runtime.save_manager.validate_data_for_scenario(quick_save_data, parsed_config),
			"quick continue snapshot should validate before continue_game")
	assert_ne(runtime.config.scenario_path, "", "config scenario path must stay non-empty")
	assert_eq(runtime._last_scenario_path, "", "setup should keep last scenario path empty before continue_game")
	assert_false(runtime._navigation_scene_request_pending,
		"continue_game setup must not already have a pending navigation scene request")
	assert_false(runtime._return_to_title_pending,
		"continue_game setup must not already be returning to title")
	assert_not_null(runtime.engine.context, "continue_game setup must keep a live engine context")
	assert_true(runtime.engine.context.is_runtime_owner_current(),
		"continue_game setup context must remain the current runtime owner")
	assert_not_null(get_tree().current_scene,
		"continue_game setup must retain a concrete current scene")
	assert_false(runtime._is_on_title_screen(),
		"PLAYING continue_game setup must not report title-screen semantics")
	var result = await runtime.continue_game()
	assert_true(result)
	assert_ne(runtime._last_scenario_path, "", "continue_game should resolve scenario path from config")
	runtime._cancel_active_gameplay()
	await get_tree().process_frame
	runtime.game_state.transition_to(GameStateMachine.State.TITLE)

	# Clean up
	runtime._last_scenario_path = orig_path
	runtime.delete_quick_save()


func test_has_continue_save_with_quick_save():
	var runtime = get_tree().root.get_node("StellaRuntime")
	runtime.delete_quick_save()
	runtime.delete_auto_save()
	assert_false(runtime.has_continue_save())

	runtime.quick_save()
	assert_true(runtime.has_continue_save())
	runtime.delete_quick_save()


func test_has_continue_save_with_auto_save():
	var runtime = get_tree().root.get_node("StellaRuntime")
	runtime.delete_quick_save()
	runtime.delete_auto_save()
	assert_false(runtime.has_continue_save())

	# Force auto save by setting state to PLAYING
	var orig_state = runtime.game_state.current_state
	runtime.game_state.current_state = GameStateMachine.State.PLAYING
	runtime.auto_save()
	runtime.game_state.current_state = orig_state

	assert_true(runtime.has_continue_save())
	runtime.delete_auto_save()


## --- continue_from_save from TITLE state ---

func test_continue_from_save_rejects_missing_save():
	var runtime = get_tree().root.get_node("StellaRuntime")
	runtime._last_scenario_path = runtime.config.scenario_path
	# Missing save → false regardless of state
	runtime.game_state.transition_to(GameStateMachine.State.TITLE)
	var result = await runtime.continue_from_save(99)
	assert_false(result, "Should return false for missing save")

	runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	result = await runtime.continue_from_save(99)
	assert_false(result, "Should return false for missing save in-game too")


func test_continue_from_save_rejects_empty_scenario_path():
	var runtime = get_tree().root.get_node("StellaRuntime")
	var orig_path = runtime._last_scenario_path
	var orig_config = runtime.config.scenario_path
	runtime._last_scenario_path = ""
	runtime.config.scenario_path = ""

	runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	runtime.save(50)
	var result = await runtime.continue_from_save(50)
	assert_false(result, "Should return false when no scenario path available")

	# Restore
	runtime._last_scenario_path = orig_path
	runtime.config.scenario_path = orig_config
	runtime.delete_save(50)


func test_is_on_title_screen_direct():
	var runtime = get_tree().root.get_node("StellaRuntime")
	runtime.game_state.transition_to(GameStateMachine.State.TITLE)
	assert_true(runtime._is_on_title_screen(), "Direct TITLE state")

	runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	assert_false(runtime._is_on_title_screen(), "PLAYING state")


func test_is_on_title_screen_via_overlay():
	var runtime = get_tree().root.get_node("StellaRuntime")
	# Simulate: TITLE → show_save_load → state becomes SAVE_LOAD with previous_state = TITLE
	runtime.game_state.transition_to(GameStateMachine.State.TITLE)
	runtime.game_state.transition_to(GameStateMachine.State.SAVE_LOAD)
	assert_eq(runtime.game_state.current_state, GameStateMachine.State.SAVE_LOAD)
	assert_eq(runtime.game_state.previous_state, GameStateMachine.State.TITLE)
	assert_true(runtime._is_on_title_screen(),
		"SAVE_LOAD with previous=TITLE should be detected as title screen")


func test_is_on_title_screen_in_game_overlay():
	var runtime = get_tree().root.get_node("StellaRuntime")
	# Simulate: PLAYING → show_save_load → state becomes SAVE_LOAD with previous_state = PLAYING
	runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	runtime.game_state.transition_to(GameStateMachine.State.SAVE_LOAD)
	assert_false(runtime._is_on_title_screen(),
		"SAVE_LOAD with previous=PLAYING should NOT be title screen")


func test_continue_from_save_returns_false_no_scenario_path():
	var runtime = get_tree().root.get_node("StellaRuntime")
	var orig_path = runtime._last_scenario_path
	var orig_config = runtime.config.scenario_path
	runtime._last_scenario_path = ""
	runtime.config.scenario_path = ""

	# Even with a valid save, should fail if no scenario path
	runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	runtime.save(52)
	var result = await runtime.continue_from_save(52)
	assert_false(result, "Should return false when no scenario path available")

	# Restore
	runtime._last_scenario_path = orig_path
	runtime.config.scenario_path = orig_config
	runtime.delete_save(52)


func test_continue_from_save_returns_false_without_save():
	var runtime = get_tree().root.get_node("StellaRuntime")
	runtime._last_scenario_path = runtime.config.scenario_path
	var result = await runtime.continue_from_save(99)
	assert_false(result, "continue_from_save should return false for non-existent slot")


## --- show_save_load from TITLE ---

func test_show_save_load_from_title():
	var runtime = get_tree().root.get_node("StellaRuntime")
	runtime.game_state.transition_to(GameStateMachine.State.TITLE)
	runtime.show_save_load("load")
	assert_eq(runtime.game_state.current_state, GameStateMachine.State.SAVE_LOAD)
	runtime.close_overlay()


## --- Load from title: overlay must not interfere with scene change ---

func test_continue_from_save_overlay_not_closed_before_scene_change():
	# Regression: _close_current_overlay() before change_scene_to_file caused
	# tree_changed to fire from overlay removal, not scene change.
	# Verify: calling continue_from_save does NOT synchronously close the overlay.
	# The overlay must survive until after the first await (scene change).
	var runtime = get_tree().root.get_node("StellaRuntime")
	var orig_path = runtime._last_scenario_path
	runtime._last_scenario_path = runtime.config.scenario_path

	# Create a save from a live unfinished context. SaveManager intentionally
	# retains the most recently registered provider, so relying on a context left
	# by an earlier test can persist an already-finished scenario and make the
	# loaded engine auto-return before this test can observe it.
	runtime._cancel_active_gameplay()
	runtime._prepare_scenario(runtime.config.scenario_path)
	runtime.game_state.transition_to(GameStateMachine.State.PLAYING)
	runtime.save(60)
	var parsed_config = runtime._parse_scenario(runtime.config.scenario_path)
	assert_not_null(parsed_config, "save slot scenario should parse before continue_from_save")
	var slot_raw = runtime.save_manager.read_save_data(60)
	_assert_reduced_snapshot_families_validate(
		runtime,
		slot_raw,
		parsed_config,
		"save slot"
	)
	var slot_data = runtime.save_manager.read_save_data(60, parsed_config)
	assert_true(slot_data is Dictionary,
		"save slot should be readable before continue_from_save")
	if slot_data is Dictionary:
		assert_true(runtime.save_manager.validate_data_for_scenario(slot_data, parsed_config),
			"save slot should validate before continue_from_save")

	# Simulate: title → open save/load overlay → state=SAVE_LOAD, prev=TITLE
	runtime.game_state.transition_to(GameStateMachine.State.TITLE)
	runtime.show_save_load("load")
	assert_not_null(runtime._current_overlay, "overlay should exist before continue_from_save")
	var context_before_continue: ScenarioContext = runtime.engine.context
	assert_not_null(context_before_continue,
		"continue_from_save setup must begin with a live scenario context")
	assert_true(context_before_continue.is_runtime_owner_current(),
		"continue_from_save setup context must remain current before replacement")
	assert_true(runtime._is_on_title_screen(),
		"continue_from_save overlay setup should still report title-screen semantics")
	assert_false(runtime._navigation_scene_request_pending,
		"continue_from_save setup must not begin with a pending navigation scene request")
	assert_false(runtime._return_to_title_pending,
		"continue_from_save setup must not begin with a pending return_to_title")
	assert_not_null(get_tree().current_scene,
		"continue_from_save setup must retain a current scene")
	var loaded_contexts: Array[ScenarioContext] = []
	var scenario_ended_ids: Array[String] = []
	var dialogue_started := func(_character: String, _segments: Array, _mode: String) -> void:
		loaded_contexts.append(runtime.engine.context)
	var scenario_ended := func(id: String) -> void:
		scenario_ended_ids.append(id)
	SignalBus.show_dialogue.connect(dialogue_started, CONNECT_ONE_SHOT)
	runtime.engine.scenario_ended.connect(scenario_ended)

	# Call continue_from_save WITHOUT await — it runs synchronously up to the
	# first await (change_scene_to_file + tree_changed). At that suspend point,
	# _current_overlay must still be alive (not yet closed).
	runtime.continue_from_save(60)

	# After the synchronous portion, the overlay must NOT have been closed yet.
	# With the bug (old code), _current_overlay would already be null here.
	assert_not_null(runtime._current_overlay,
		"overlay must survive until after scene change — closing it before "
		+ "change_scene_to_file causes tree_changed to fire prematurely")

	# Synchronize with the first blocking command from the newly loaded context.
	# Merely waiting a fixed number of frames is not sufficient: the deferred
	# continue coroutine can create and start its context after that wait, leaving
	# a live engine loop that a later test's advance signal can accidentally
	# resume. wait_until yields until after show_dialogue dispatch has returned,
	# so DialogueHandler's request-scoped activation exists before cleanup begins.
	var reached_loaded_dialogue: bool = await wait_until(
		func() -> bool: return not loaded_contexts.is_empty(),
		2.0,
		"continue_from_save starts the newly loaded scenario",
	)
	assert_true(reached_loaded_dialogue)
	var loaded_context: ScenarioContext = (
		loaded_contexts[0] if reached_loaded_dialogue else runtime.engine.context
	)
	assert_not_null(loaded_context,
		"continue_from_save must install a scenario context")
	assert_not_same(loaded_context, context_before_continue,
		"continue_from_save must replace the previous scenario context")
	assert_same(runtime.engine.context, loaded_context,
		"the observed dialogue must belong to the active engine context")
	assert_null(runtime._current_overlay,
		"the overlay should close only after the game scene is ready")

	# Detach before aborting. ScenarioEngine uses context identity as its
	# generation guard; stopping a still-attached context lets run() fall through
	# to scenario_ended and StellaRuntime.return_to_title().
	runtime.engine.context = null
	if loaded_context != null:
		loaded_context.is_finished = true
	SignalBus.engine_abort_requested.emit()
	await get_tree().process_frame
	assert_eq(scenario_ended_ids, [],
		"test cleanup must not report an aborted scenario as completed")
	assert_eq(runtime.game_state.current_state, GameStateMachine.State.PLAYING,
		"test cleanup must not leak a return_to_title transition")
	if runtime.engine.scenario_ended.is_connected(scenario_ended):
		runtime.engine.scenario_ended.disconnect(scenario_ended)
	if SignalBus.show_dialogue.is_connected(dialogue_started):
		SignalBus.show_dialogue.disconnect(dialogue_started)

	# Clean up the scene presenters and restore facade state for later tests.
	SignalBus.hide_dialogue.emit()
	runtime._close_current_overlay()
	runtime.presentation_state.clear()
	runtime.game_state.transition_to(GameStateMachine.State.TITLE)
	runtime._last_scenario_path = orig_path
	runtime.delete_save(60)
	_disconnect_game_presenters()


## Helper: disconnect game scene presenters from SignalBus to prevent test contamination.
func _disconnect_game_presenters():
	var runtime_director: PresentationDirector = StellaRuntime.presentation_director
	var global_audio_presenter := StellaRuntime.get_node_or_null("AudioPresenter")
	for sig_name in ["bg_changed", "stage_operations_requested",
			"stage_operation_request_finished", "stage_visuals_reset_requested",
			"stage_state_apply_requested", "stage_transition_started",
			"stage_transitions_finish_requested",
			"dialogue_visibility_operations_requested",
			"presentation_operation_request_finished",
			"dialogue_visibility_transition_receipt_started",
			"dialogue_visibility_transition_terminal",
			"dialogue_visibility_transition_receipts_finish_requested",
			"dialogue_visibility_visuals_reset_requested",
			"dialogue_visibility_state_apply_requested",
			"se_play",
			"dialogue_requested", "dialogue_backlog_effects_resolved",
			"voice_play", "voice_playback_requested", "voice_playback_event",
			"dialogue_voice_replay_requested",
			"dialogue_voice_started", "dialogue_voice_progress",
			"dialogue_voice_finished",
			"system_se_play", "advance_dispatch_started",
			"show_dialogue", "hide_dialogue", "choice_show", "choice_hide",
			"choice_selected",
			"fade_requested", "effect_requested",
			"scenario_started_event", "scene_changed_event",
			"engine_abort_requested",
			"scenario_ended_event"]:
		if not SignalBus.has_signal(sig_name):
			continue
		var sig = SignalBus.get(sig_name)
		if sig is Signal:
			for conn in sig.get_connections():
				var callable = conn["callable"]
				if not callable.is_valid():
					continue
				# Godot 4.6 rejects Callable.get_object() when the target method is
				# async. Resolve the owner by id so async Presenter callbacks can be
				# inspected without invoking that compatibility path.
				var callable_owner_id: int = callable.get_object_id()
				var obj = (
					instance_from_id(callable_owner_id)
					if callable_owner_id != 0 else null
				)
				if obj != null and not obj is GutTest and obj != StellaRuntime \
						and obj != StellaRuntime.presentation_state \
						and obj != runtime_director \
						and obj != global_audio_presenter \
						and obj != SignalBus:
					sig.disconnect(callable)
	assert_true(SignalBus.show_dialogue.is_connected(
		SignalBus._on_show_dialogue_dispatch_started),
		"game presenter cleanup must preserve SignalBus dispatch hooks")
	if global_audio_presenter != null:
		assert_true(SignalBus.voice_playback_requested.is_connected(
			global_audio_presenter._on_voice_playback_requested),
			"game presenter cleanup must preserve the global AudioPresenter")
	# DialoguePresenter also observes the controller objects directly rather than
	# through SignalBus. The deferred scene loaded by this test remains alive for
	# the rest of the GUT process, so disconnect those scene-owned callbacks too.
	for controller_signal in [
		StellaRuntime.game_state.state_changed,
		StellaRuntime.auto_play.active_changed,
		StellaRuntime.skip_controller.active_changed,
	]:
		for connection in controller_signal.get_connections():
			var callback: Callable = connection["callable"]
			if not callback.is_valid():
				continue
			var callback_owner_id: int = callback.get_object_id()
			var callback_owner = (
				instance_from_id(callback_owner_id)
				if callback_owner_id != 0 else null
			)
			if callback_owner != null and callback_owner != StellaRuntime \
					and callback_owner != runtime_director \
					and not callback_owner is GutTest:
				controller_signal.disconnect(callback)
	assert_not_null(runtime_director,
		"game presenter cleanup must preserve the Runtime-owned Director")
	if runtime_director != null:
		assert_true(SignalBus.stage_transition_receipt_started.is_connected(
			runtime_director._on_stage_transition_receipt_started),
			"game presenter cleanup must preserve Director receipt authority")
		assert_true(SignalBus.stage_operation_request_finished.is_connected(
			runtime_director._on_stage_operation_request_finished),
			"game presenter cleanup must preserve Director dispatch-tail authority")
		assert_true(SignalBus.stage_transition_terminal.is_connected(
			runtime_director._on_stage_transition_terminal),
			"game presenter cleanup must preserve Director terminal authority")
		assert_true(SignalBus.advance_requested.is_connected(
			runtime_director._on_advance_requested),
			"game presenter cleanup must preserve Director advance authority")
		assert_true(SignalBus.stage_visuals_reset_requested.is_connected(
			runtime_director._on_stage_visuals_reset_requested),
			"game presenter cleanup must preserve Director reset authority")
		assert_true(SignalBus.engine_abort_requested.is_connected(
			runtime_director._on_engine_abort_requested),
			"game presenter cleanup must preserve Director abort authority")
		assert_true(StellaRuntime.skip_controller.active_changed.is_connected(
			runtime_director.on_skip_active_changed),
			"game presenter cleanup must preserve Director Skip authority")


func _runtime_director_connection_fingerprint() -> Array[String]:
	var director: PresentationDirector = StellaRuntime.presentation_director
	var fingerprint: Array[String] = []
	if director == null:
		return fingerprint
	for signal_value: Variant in SignalBus.get_signal_list():
		var signal_info: Dictionary = signal_value
		var signal_name := StringName(signal_info.get("name", &""))
		if signal_name.is_empty():
			continue
		var bus_signal: Variant = SignalBus.get(signal_name)
		if not bus_signal is Signal:
			continue
		for connection_value: Variant in (bus_signal as Signal).get_connections():
			var connection: Dictionary = connection_value
			var callback: Callable = connection.get("callable", Callable())
			if not callback.is_valid():
				continue
			var owner_id := callback.get_object_id()
			if owner_id == 0 or instance_from_id(owner_id) != director:
				continue
			fingerprint.append("SignalBus.%s->%s" % [
				String(signal_name), String(callback.get_method()),
			])
	for controller_value: Variant in [
		StellaRuntime.game_state,
		StellaRuntime.auto_play,
		StellaRuntime.skip_controller,
	]:
		var controller: Object = controller_value
		for signal_value: Variant in controller.get_signal_list():
			var signal_info: Dictionary = signal_value
			var signal_name := StringName(signal_info.get("name", &""))
			var controller_signal: Variant = controller.get(signal_name)
			if not controller_signal is Signal:
				continue
			for connection_value: Variant in (
				controller_signal as Signal).get_connections():
				var callback: Callable = (connection_value as Dictionary).get(
					"callable", Callable())
				if not callback.is_valid():
					continue
				var owner_id := callback.get_object_id()
				if owner_id == 0 or instance_from_id(owner_id) != director:
					continue
				fingerprint.append("%s.%s->%s" % [
					controller.get_class(), String(signal_name),
					String(callback.get_method()),
				])
	fingerprint.sort()
	return fingerprint


func test_game_presenter_cleanup_preserves_every_runtime_director_authority() -> void:
	var before := _runtime_director_connection_fingerprint()
	assert_gt(before.size(), 0,
		"the Runtime-owned Director must expose persistent authority connections")
	_disconnect_game_presenters()
	assert_eq(_runtime_director_connection_fingerprint(), before,
		"facade cleanup cannot disconnect Stage or Dialogue Director authority")


func test_dialogue_visibility_signals_and_runtime_director_authority_are_exact() -> void:
	var director: PresentationDirector = StellaRuntime.presentation_director
	assert_not_null(director)
	var missing: Array[String] = []
	for signal_name: String in DIALOGUE_VISIBILITY_SIGNALS:
		if not SignalBus.has_signal(signal_name):
			missing.append(signal_name)
	assert_eq(missing, [], "missing issue #166 SignalBus surface")
	if not missing.is_empty() or director == null:
		return
	for signal_name: String in DIALOGUE_VISIBILITY_SIGNALS:
		assert_eq(_signal_contract(signal_name),
			DIALOGUE_VISIBILITY_SIGNALS[signal_name],
			"exact SignalBus argument contract: %s" % signal_name)
	for signal_name: String in DIALOGUE_VISIBILITY_DIRECTOR_CALLBACKS:
		var callback_spec: Array = DIALOGUE_VISIBILITY_DIRECTOR_CALLBACKS[signal_name]
		var callback_name := String(callback_spec[0])
		assert_true(director.has_method(callback_name),
			"missing Director callback: %s" % callback_name)
		if not director.has_method(callback_name):
			continue
		assert_eq(_method_contract(director, callback_name), callback_spec[1],
			"exact Director callback contract: %s" % callback_name)
		var bus_signal: Signal = SignalBus.get(signal_name)
		var callback := Callable(director, callback_name)
		assert_true(bus_signal.is_connected(callback),
			"Runtime-owned Director keeps %s authority" % signal_name)

	var finish_signal: Signal = SignalBus.get(
		"dialogue_visibility_transition_receipts_finish_requested")
	var probe := _DialogueVisibilitySceneProbe.new()
	add_child_autoqfree(probe)
	finish_signal.connect(probe.on_finish)
	assert_true(finish_signal.is_connected(probe.on_finish))
	for connection_value: Variant in finish_signal.get_connections():
		var callback: Callable = (connection_value as Dictionary).get(
			"callable", Callable())
		if callback.is_valid():
			assert_ne(instance_from_id(callback.get_object_id()), director,
				"exact-finish is presenter authority, never a Director consumer")
	_disconnect_game_presenters()
	assert_false(finish_signal.is_connected(probe.on_finish),
		"facade cleanup removes the scene-owned exact-finish consumer")
	for signal_name: String in DIALOGUE_VISIBILITY_DIRECTOR_CALLBACKS:
		var callback_name := String(
			(DIALOGUE_VISIBILITY_DIRECTOR_CALLBACKS[signal_name] as Array)[0])
		assert_true((SignalBus.get(signal_name) as Signal).is_connected(
			Callable(director, callback_name)),
			"facade cleanup preserves Runtime authority: %s" % signal_name)
## --- Overlay Config ---

func test_config_has_overlay_scene_overrides():
	var config = StellaConfig.new()
	assert_eq(config.settings_scene, "")
	assert_eq(config.save_load_scene, "")
	assert_eq(config.backlog_scene, "")
