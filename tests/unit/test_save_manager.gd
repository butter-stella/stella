extends GutTest
## Tests for SaveManager — save/load with snapshot providers.


var _manager: SaveManager
var _save_dir: String = "user://test_saves/"


func before_each():
	_manager = SaveManager.new()
	_manager.save_dir = _save_dir


func after_each():
	# Clean up test save files
	var dir = DirAccess.open("user://")
	if dir and dir.dir_exists("test_saves"):
		var saves = DirAccess.open(_save_dir)
		if saves:
			saves.list_dir_begin()
			var file_name = saves.get_next()
			while file_name != "":
				if not saves.current_is_dir():
					saves.remove(file_name)
				file_name = saves.get_next()
		dir.remove("test_saves")


# --- Mock snapshot provider ---
class MockProvider:
	var id: String
	var data: Dictionary = {}

	func _init(p_id: String = "mock"):
		id = p_id

	func get_provider_id() -> String:
		return id

	func capture_snapshot() -> Dictionary:
		return data.duplicate()

	func restore_snapshot(snapshot: Dictionary) -> void:
		data = snapshot.duplicate()


func _make_validation_scenario() -> ScenarioData:
	var data := ScenarioData.new()
	data.id = "save_validation"
	data.source_identity = ScenarioData.make_source_identity(
		"res://tests/save_validation.stla",
	)
	var scene := SceneData.new()
	scene.id = "start"
	scene.commands = [CommandData.new(), CommandData.new()]
	data.scenes = [scene]
	data.dialogue_profiles = {
		"message": {"line_spacing": 4},
		"novel_first": {"entry_prefix": "A"},
		"novel_second": {"entry_prefix": "B"},
	}
	return data


func _make_valid_save_snapshot() -> Dictionary:
	return {
		"scenario_context": {
			"scenario_id": "save_validation",
			"scenario_source_identity": ScenarioData.make_source_identity(
				"res://tests/save_validation.stla",
			),
			"scene_index": 0,
			"command_index": 1,
			"is_finished": false,
			"return_stack": [{"scene_index": 0, "command_index": 2}],
			"dialogue_mode": "nvl",
			"nvl_page_epoch": 1,
			"nvl_page_entries": [{
				"command_uid": 1,
				"scene_index": 0,
				"command_index": 1,
				"profile_name": "",
				"character": "probe",
				"segments": [{"text": "safe", "voice": ""}],
			}],
		},
		"variable_store": {"scenario": {}, "global": {}},
		"presentation_state": {
			"bg": "",
			"stage_layers": {},
			"bgm": "",
		},
		"read_flags": {"save_validation:start:0": true},
		"unlocks": {"cg": ["safe"]},
		"flowchart_visited": {
			"visited_chapters": {},
			"visited_chapter_edges": {},
		},
		"flowchart_state": {
			"current_path": [],
			"chapter_snapshots": {},
		},
		"timestamp": 1.0,
	}


func _make_valid_dialogue_save_snapshot(mode: String = "adv") -> Dictionary:
	var snapshot := _make_valid_save_snapshot()
	snapshot["presentation_state"]["dialogue_visibility"] = {
		"surface": false,
		"quick_menu": true,
	}
	var content := {
		"version": 1,
		"active": true,
		"mode": "adv",
		"profile_name": "message",
		"declarative_presentation": true,
		"character": "sakura",
		"segments": [{"text": "Stable ADV"}],
		"avatar_expression": "happy",
		"nvl_entries": [],
	}
	if mode == "nvl":
		content = {
			"version": 1,
			"active": true,
			"mode": "nvl",
			"profile_name": "novel_second",
			"declarative_presentation": true,
			"character": "senpai",
			"segments": [{"text": "Second"}],
			"avatar_expression": "smile",
			"nvl_entries": [
				{
					"profile_name": "novel_first",
					"character": "sakura",
					"segments": [{"text": "First"}],
				},
				{
					"profile_name": "novel_second",
					"character": "senpai",
					"segments": [{"text": "Second"}],
				},
			],
		}
	elif mode in ["overlay", "monologue"]:
		content["mode"] = mode
	snapshot["presentation_state"]["dialogue_content"] = content
	return snapshot


func test_register_provider():
	var provider = MockProvider.new("test")
	_manager.register_provider(provider)
	assert_eq(_manager.get_provider_count(), 1)


func test_save_creates_file():
	var provider = MockProvider.new("vars")
	provider.data = {"hp": 100, "name": "sakura"}
	_manager.register_provider(provider)

	_manager.save(1)

	assert_true(FileAccess.file_exists(_save_dir + "save_1.json"))


func test_save_and_load_restores_state():
	var provider = MockProvider.new("vars")
	provider.data = {"hp": 100, "location": "school"}
	_manager.register_provider(provider)

	_manager.save(1)

	# Modify state
	provider.data = {"hp": 50, "location": "home"}

	# Load should restore
	_manager.load_save(1)

	assert_eq(provider.data["hp"], 100)
	assert_eq(provider.data["location"], "school")


func test_multiple_providers():
	var vars_provider = MockProvider.new("vars")
	vars_provider.data = {"hp": 100}
	var engine_provider = MockProvider.new("engine")
	engine_provider.data = {"scene": "start", "cmd": 3}

	_manager.register_provider(vars_provider)
	_manager.register_provider(engine_provider)

	_manager.save(1)

	vars_provider.data = {"hp": 0}
	engine_provider.data = {"scene": "ending", "cmd": 0}

	_manager.load_save(1)

	assert_eq(vars_provider.data["hp"], 100)
	assert_eq(engine_provider.data["scene"], "start")


func test_multiple_save_slots():
	var provider = MockProvider.new("vars")
	provider.data = {"slot": "first"}
	_manager.register_provider(provider)
	_manager.save(1)

	provider.data = {"slot": "second"}
	_manager.save(2)

	_manager.load_save(1)
	assert_eq(provider.data["slot"], "first")

	_manager.load_save(2)
	assert_eq(provider.data["slot"], "second")


func test_load_merges_real_monotonic_providers():
	var old_read_flags = ReadFlagManager.new()
	old_read_flags.mark_read("route_a", "scene_1", 3)
	var old_unlocks = UnlockManager.new()
	old_unlocks.unlock("cg", "route_a_cg")
	old_unlocks.unlock("cg", "shared_cg")
	_manager.register_provider(old_read_flags)
	_manager.register_provider(old_unlocks)
	_manager.save(1)

	# Replace providers to model a later playthrough whose global state came
	# from another source. register_provider() swaps providers with the same ID.
	var current_read_flags = ReadFlagManager.new()
	current_read_flags.mark_read("route_b", "scene_2", 7)
	var current_unlocks = UnlockManager.new()
	current_unlocks.unlock("cg", "route_b_cg")
	current_unlocks.unlock("cg", "shared_cg")
	current_unlocks.unlock("bgm", "route_b_theme")
	_manager.register_provider(current_read_flags)
	_manager.register_provider(current_unlocks)

	assert_true(_manager.load_save(1))
	assert_true(_manager.load_save(1), "loading the same old save twice should be idempotent")

	assert_true(current_read_flags.is_read("route_a", "scene_1", 3))
	assert_true(current_read_flags.is_read("route_b", "scene_2", 7))
	assert_true(current_unlocks.is_unlocked("cg", "route_a_cg"))
	assert_true(current_unlocks.is_unlocked("cg", "route_b_cg"))
	assert_true(current_unlocks.is_unlocked("bgm", "route_b_theme"))
	assert_eq(current_unlocks.get_unlocked("cg").count("shared_cg"), 1)


func test_load_nonexistent_slot_returns_false():
	assert_false(_manager.load_save(999))


func test_read_save_data_rejects_non_dictionary_provider_snapshot():
	var provider := MockProvider.new("vars")
	provider.data = {"preserved": true}
	_manager.register_provider(provider)
	_manager._ensure_dir()
	var file := FileAccess.open(_save_dir + "save_1.json", FileAccess.WRITE)
	file.store_string('{"vars":"invalid","timestamp":1}')
	file.close()

	assert_null(_manager.read_save_data(1))
	assert_false(_manager.load_save(1))
	assert_eq(provider.data, {"preserved": true})


func test_scenario_aware_read_rejects_semantically_invalid_position():
	_manager._ensure_dir()
	var invalid := _make_valid_save_snapshot()
	invalid["scenario_context"]["scene_index"] = 999999
	var file := FileAccess.open(_save_dir + "save_1.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(invalid))
	file.close()

	# A generic tool may still inspect a structurally valid snapshot, while the
	# Runtime transaction always supplies the destination ScenarioData.
	assert_not_null(_manager.read_save_data(1))
	assert_null(_manager.read_save_data(1, _make_validation_scenario()))


func test_scenario_identity_distinguishes_same_basename_and_rejects_legacy():
	var scenario_a := _make_validation_scenario()
	scenario_a.id = "shared"
	scenario_a.source_identity = ScenarioData.make_source_identity(
		"res://tests/review_a/shared.stla",
	)
	var scenario_b := _make_validation_scenario()
	scenario_b.id = "shared"
	scenario_b.source_identity = ScenarioData.make_source_identity(
		"res://tests/review_b/shared.stla",
	)
	var snapshot := _make_valid_save_snapshot()
	snapshot["scenario_context"]["scenario_id"] = "shared"
	snapshot["scenario_context"]["scenario_source_identity"] = (
		scenario_a.source_identity
	)

	assert_true(scenario_a.source_identity.begins_with(
		"stella-source-v1:sha256:",
	))
	assert_false(scenario_a.source_identity.contains("review_a"),
		"save identity must not copy the authored source path")
	assert_eq(
		scenario_a.source_identity,
		ScenarioData.make_source_identity(
			"res://tests/review_a/../review_a/shared.stla",
		),
		"equivalent normalized paths must share an identity",
	)
	assert_true(_manager.validate_data_for_scenario(snapshot, scenario_a))
	assert_false(_manager.validate_data_for_scenario(snapshot, scenario_b),
		"same-basename authored sources must not share persisted state")

	var legacy := snapshot.duplicate(true)
	legacy["scenario_context"].erase("scenario_source_identity")
	assert_false(_manager.validate_data_for_scenario(legacy, scenario_a),
		"pre-v1 saves require explicit migration and must fail closed")


func test_public_parser_identity_keeps_extension_saves_eligible():
	var parsed := DslParser.parse(
		DslLexer.tokenize('@scene start "Start"\n「one」\n「two」'),
		"public_parser",
		"res://extensions/public_parser.stla",
	)
	var snapshot := _make_valid_save_snapshot()
	snapshot["scenario_context"]["scenario_id"] = parsed.id
	snapshot["scenario_context"]["scenario_source_identity"] = (
		parsed.source_identity
	)
	assert_false(parsed.source_identity.is_empty())
	assert_true(_manager.validate_data_for_scenario(snapshot, parsed))
	_manager._ensure_dir()
	var file := FileAccess.open(_save_dir + "save_1.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(snapshot))
	file.close()
	assert_not_null(_manager.read_save_data(1, parsed),
		"public-parser scenarios must remain eligible for scenario-aware reads")


func test_scenario_aware_read_accepts_current_read_flag_snapshot():
	var scenario := _make_validation_scenario()
	var snapshot := _make_valid_save_snapshot()
	var read_flags := ReadFlagManager.new()
	read_flags.mark_dialogue_read(
		scenario.source_identity,
		"start",
		1,
	)
	snapshot["read_flags"] = read_flags.capture_snapshot()
	assert_true(_manager.validate_data_for_scenario(snapshot, scenario))

	var invalid_record := snapshot.duplicate(true)
	invalid_record["read_flags"]["flags"][0]["command_uid"] = -1
	assert_false(_manager.validate_data_for_scenario(invalid_record, scenario))
	var invalid_legacy := snapshot.duplicate(true)
	invalid_legacy["read_flags"]["legacy_flags"] = [1]
	assert_false(_manager.validate_data_for_scenario(invalid_legacy, scenario))
	var invalid_version := snapshot.duplicate(true)
	invalid_version["read_flags"]["version"] = 999
	assert_false(_manager.validate_data_for_scenario(invalid_version, scenario))


func test_programmatic_scenario_can_set_stable_authored_identity():
	var scenario := _make_validation_scenario()
	var previous_identity := scenario.source_identity
	assert_eq(scenario.set_authored_identity("my_extension:route-a:v1"), OK)
	assert_true(scenario.source_identity.begins_with(
		"stella-authored-v1:sha256:",
	))
	assert_false(scenario.source_identity.contains("my_extension"),
		"authored key must not be copied into save identity")
	var snapshot := _make_valid_save_snapshot()
	snapshot["scenario_context"]["scenario_source_identity"] = (
		scenario.source_identity
	)
	assert_true(_manager.validate_data_for_scenario(snapshot, scenario))
	_manager._ensure_dir()
	var file := FileAccess.open(_save_dir + "save_2.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(snapshot))
	file.close()
	assert_not_null(_manager.read_save_data(2, scenario),
		"programmatic scenarios with an authored identity must remain loadable")
	var assigned_identity := scenario.source_identity
	assert_eq(scenario.set_authored_identity("  "), ERR_INVALID_PARAMETER)
	assert_eq(scenario.source_identity, assigned_identity,
		"invalid assignment must preserve the existing identity")
	assert_ne(scenario.source_identity, previous_identity)


func test_save_validation_covers_builtin_provider_field_types_atomically():
	var scenario := _make_validation_scenario()
	var valid := _make_valid_save_snapshot()
	assert_true(_manager.validate_data_for_scenario(valid, scenario))

	var corruptions: Array[Dictionary] = []
	var invalid_command := valid.duplicate(true)
	invalid_command["scenario_context"]["command_index"] = 999999
	corruptions.append(invalid_command)
	var invalid_return_stack := valid.duplicate(true)
	invalid_return_stack["scenario_context"]["return_stack"] = ["invalid"]
	corruptions.append(invalid_return_stack)
	var invalid_nvl := valid.duplicate(true)
	invalid_nvl["scenario_context"]["nvl_page_entries"][0]["segments"] = [1]
	corruptions.append(invalid_nvl)
	var invalid_variables := valid.duplicate(true)
	invalid_variables["variable_store"]["scenario"] = []
	corruptions.append(invalid_variables)
	var invalid_presentation := valid.duplicate(true)
	invalid_presentation["presentation_state"]["stage_layers"] = {
		"hero": {"position": [1.0]},
	}
	corruptions.append(invalid_presentation)
	var invalid_unlocks := valid.duplicate(true)
	invalid_unlocks["unlocks"]["cg"] = "invalid"
	corruptions.append(invalid_unlocks)
	var invalid_visited := valid.duplicate(true)
	invalid_visited["flowchart_visited"]["visited_chapters"] = {"intro": 1}
	corruptions.append(invalid_visited)
	var invalid_flowchart := valid.duplicate(true)
	invalid_flowchart["flowchart_state"]["current_path"] = [1]
	corruptions.append(invalid_flowchart)

	for invalid: Dictionary in corruptions:
		assert_false(_manager.validate_data_for_scenario(invalid, scenario))


func test_dialogue_projection_adv_and_nvl_snapshots_validate_exactly() -> void:
	var scenario := _make_validation_scenario()
	var adv := _make_valid_dialogue_save_snapshot("adv")
	var nvl := _make_valid_dialogue_save_snapshot("nvl")
	var overlay := _make_valid_dialogue_save_snapshot("overlay")
	var monologue := _make_valid_dialogue_save_snapshot("monologue")
	assert_true(_manager.validate_data_for_scenario(adv, scenario),
		"stable ADV content and visibility are valid save inputs")
	assert_true(_manager.validate_data_for_scenario(nvl, scenario),
		"ordered NVL content and per-entry profiles are valid save inputs")
	assert_true(_manager.validate_data_for_scenario(overlay, scenario),
		"the existing public overlay visual mode has a stable projection")
	assert_true(_manager.validate_data_for_scenario(monologue, scenario),
		"the existing public monologue visual mode has a stable projection")
	var round_tripped: Variant = JSON.parse_string(JSON.stringify(nvl))
	assert_true(round_tripped is Dictionary)
	if round_tripped is Dictionary:
		assert_true(_manager.validate_data_for_scenario(round_tripped, scenario))


func test_save_without_dialogue_projection_remains_a_valid_old_save() -> void:
	var scenario := _make_validation_scenario()
	var old_save := _make_valid_save_snapshot()
	assert_false(old_save["presentation_state"].has("dialogue_visibility"))
	assert_false(old_save["presentation_state"].has("dialogue_content"))
	assert_true(_manager.validate_data_for_scenario(old_save, scenario),
		"missing issue #166 fields use read-time defaults without rewriting disk")


func test_dialogue_visibility_schema_is_exact_and_never_truthy_coerced() -> void:
	var scenario := _make_validation_scenario()
	var invalid_values: Array[Variant] = [
		[],
		{"surface": 1, "quick_menu": true},
		{"surface": false, "quick_menu": "true"},
		{"surface": false},
		{"surface": false, "quick_menu": true, "extra": false},
	]
	for invalid_visibility: Variant in invalid_values:
		var snapshot := _make_valid_dialogue_save_snapshot()
		snapshot["presentation_state"]["dialogue_visibility"] = (
			invalid_visibility
		)
		assert_false(_manager.validate_data_for_scenario(snapshot, scenario),
			"invalid visibility is rejected atomically: %s" % str(invalid_visibility))


func test_dialogue_content_exact_schema_rejects_transient_or_malformed_data() -> void:
	var scenario := _make_validation_scenario()
	var invalid_contents: Array[Dictionary] = []
	var extra_key: Dictionary = _make_valid_dialogue_save_snapshot()[
		"presentation_state"]["dialogue_content"].duplicate(true)
	extra_key["token"] = 7
	invalid_contents.append(extra_key)
	var missing_key := extra_key.duplicate(true)
	missing_key.erase("token")
	missing_key.erase("avatar_expression")
	invalid_contents.append(missing_key)
	var bad_version := extra_key.duplicate(true)
	bad_version.erase("token")
	bad_version["version"] = 2
	invalid_contents.append(bad_version)
	var bad_mode := extra_key.duplicate(true)
	bad_mode.erase("token")
	bad_mode["mode"] = "future_mode"
	invalid_contents.append(bad_mode)
	var empty_active := extra_key.duplicate(true)
	empty_active.erase("token")
	empty_active["segments"] = []
	invalid_contents.append(empty_active)
	var bad_segment := extra_key.duplicate(true)
	bad_segment.erase("token")
	bad_segment["segments"] = [{"text": "safe", "voice": "forbidden"}]
	invalid_contents.append(bad_segment)
	var non_string_text := extra_key.duplicate(true)
	non_string_text.erase("token")
	non_string_text["segments"] = [{"text": 7}]
	invalid_contents.append(non_string_text)
	var string_name_profile := extra_key.duplicate(true)
	string_name_profile.erase("token")
	string_name_profile["profile_name"] = &"message"
	invalid_contents.append(string_name_profile)
	var truthy_active := extra_key.duplicate(true)
	truthy_active.erase("token")
	truthy_active["active"] = 1
	invalid_contents.append(truthy_active)
	var unknown_profile := extra_key.duplicate(true)
	unknown_profile.erase("token")
	unknown_profile["profile_name"] = "missing_profile"
	invalid_contents.append(unknown_profile)
	var non_nvl_entries := extra_key.duplicate(true)
	non_nvl_entries.erase("token")
	non_nvl_entries["nvl_entries"] = [{
		"profile_name": "message",
		"character": "sakura",
		"segments": [{"text": "forbidden"}],
	}]
	invalid_contents.append(non_nvl_entries)
	var bad_nvl_tail: Dictionary = _make_valid_dialogue_save_snapshot("nvl")[
		"presentation_state"]["dialogue_content"].duplicate(true)
	bad_nvl_tail["segments"] = [{"text": "not the tail"}]
	invalid_contents.append(bad_nvl_tail)
	var bad_entry_profile: Dictionary = _make_valid_dialogue_save_snapshot("nvl")[
		"presentation_state"]["dialogue_content"].duplicate(true)
	bad_entry_profile["nvl_entries"][0]["profile_name"] = "missing_profile"
	invalid_contents.append(bad_entry_profile)

	for invalid_content: Dictionary in invalid_contents:
		var snapshot := _make_valid_dialogue_save_snapshot()
		snapshot["presentation_state"]["dialogue_content"] = invalid_content
		assert_false(_manager.validate_data_for_scenario(snapshot, scenario),
			"invalid Dialogue projection rejects the entire save")


func test_inactive_dialogue_projection_must_be_the_exact_canonical_default() -> void:
	var scenario := _make_validation_scenario()
	var valid := _make_valid_dialogue_save_snapshot()
	valid["presentation_state"]["dialogue_content"] = {
		"version": 1,
		"active": false,
		"mode": "adv",
		"profile_name": "",
		"declarative_presentation": false,
		"character": "",
		"segments": [],
		"avatar_expression": "",
		"nvl_entries": [],
	}
	assert_true(_manager.validate_data_for_scenario(valid, scenario))
	var smuggled := valid.duplicate(true)
	smuggled["presentation_state"]["dialogue_content"]["character"] = "hidden"
	assert_false(_manager.validate_data_for_scenario(smuggled, scenario),
		"inactive content cannot smuggle a hidden visual document")
	var round_tripped: Variant = JSON.parse_string(JSON.stringify(valid))
	assert_true(round_tripped is Dictionary)
	if round_tripped is Dictionary:
		assert_true(_manager.validate_data_for_scenario(round_tripped, scenario),
			"canonical inactive dialogue content survives a persisted JSON round-trip")
	var noncanonical_mode := valid.duplicate(true)
	noncanonical_mode["presentation_state"]["dialogue_content"]["mode"] = "overlay"
	assert_false(_manager.validate_data_for_scenario(noncanonical_mode, scenario),
		"inactive content must fail closed when the canonical mode drifts")
	var noncanonical_version := valid.duplicate(true)
	noncanonical_version["presentation_state"]["dialogue_content"]["version"] = 2.0
	assert_false(_manager.validate_data_for_scenario(noncanonical_version, scenario),
		"inactive content must fail closed when the canonical version drifts")


func test_invalid_dialogue_projection_never_mutates_registered_provider() -> void:
	var scenario := _make_validation_scenario()
	var provider := MockProvider.new("presentation_state")
	provider.data = {"preserved": true}
	_manager.register_provider(provider)
	_manager._ensure_dir()
	var invalid := _make_valid_dialogue_save_snapshot()
	invalid["presentation_state"]["dialogue_content"]["segments"] = [1]
	var file := FileAccess.open(_save_dir + "save_1.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(invalid))
	file.close()

	assert_null(_manager.read_save_data(1, scenario))
	assert_false(_manager.load_save(1, scenario))
	assert_eq(provider.data, {"preserved": true},
		"complete validation precedes every provider restore mutation")


func test_has_save():
	var provider = MockProvider.new("vars")
	provider.data = {"x": 1}
	_manager.register_provider(provider)

	assert_false(_manager.has_save(1))
	_manager.save(1)
	assert_true(_manager.has_save(1))


func test_delete_save():
	var provider = MockProvider.new("vars")
	provider.data = {"x": 1}
	_manager.register_provider(provider)

	_manager.save(1)
	assert_true(_manager.has_save(1))

	_manager.delete_save(1)
	assert_false(_manager.has_save(1))


func test_get_save_list():
	var provider = MockProvider.new("vars")
	provider.data = {"x": 1}
	_manager.register_provider(provider)

	_manager.save(1)
	_manager.save(3)

	var saves = _manager.get_save_list()
	assert_true(saves.size() >= 2)


func test_save_includes_timestamp():
	var provider = MockProvider.new("vars")
	provider.data = {"x": 1}
	_manager.register_provider(provider)

	_manager.save(1)

	var file = FileAccess.open(_save_dir + "save_1.json", FileAccess.READ)
	var data = JSON.parse_string(file.get_as_text())
	assert_true(data.has("timestamp"))
	assert_true(data["timestamp"] > 0)
