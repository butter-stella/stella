extends GutTest
## Public synthetic typed contract for issue #201.
##
## Script probes keep missing capability diagnostics bounded and prevent a
## missing type from cascading into unrelated parser/import failures.

const CANDIDATE_SCRIPT_PATH := (
	"res://addons/stella/core/data/presentation_clip_audio_choice_candidate.gd")
const CHOICE_CUE_SCRIPT_PATH := (
	"res://addons/stella/core/data/presentation_clip_audio_choice_cue.gd")
const AUTHORITY_SCRIPT_PATH := (
	"res://addons/stella/core/presentation/"
	+ "presentation_clip_audio_choice_authority.gd")
const SOURCE_PATH := (
	"res://tests/fixtures/scenarios/presentation_clip/audio_choice.stla")
const CLIP_PATH := "res://tests/fixtures/presentation_clips/synthetic_clip.tres"
const MODULUS := 2147483647

var _temporary_config_path := "user://test_audio_choice_contract.cfg"
var _temporary_save_dir := "user://test_audio_choice_contract_saves/"


class ProbeProvider:
	extends RefCounted
	var value := {"revision": 1}

	func get_provider_id() -> String:
		return "probe"

	func capture_snapshot() -> Dictionary:
		return value.duplicate(true)

	func restore_snapshot(snapshot: Dictionary) -> void:
		value = snapshot.duplicate(true)


func after_each() -> void:
	if FileAccess.file_exists(_temporary_config_path):
		DirAccess.remove_absolute(_temporary_config_path)
	for file_name: String in ["save_3.json", "quicksave.json", "autosave.json"]:
		var path := _temporary_save_dir + file_name
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	if DirAccess.dir_exists_absolute(_temporary_save_dir):
		DirAccess.remove_absolute(_temporary_save_dir)


func _required_script(path: String, label: String) -> Script:
	var exists := ResourceLoader.exists(path)
	assert_true(
		exists,
		"#201: missing typed %s at %s" % [label, path],
	)
	return load(path) as Script if exists else null


func _choice_scripts() -> Dictionary:
	var candidate_script := _required_script(
		CANDIDATE_SCRIPT_PATH, "audio-choice candidate Resource")
	var cue_script := _required_script(
		CHOICE_CUE_SCRIPT_PATH, "audio-choice cue Resource")
	return {
		"candidate": candidate_script,
		"cue": cue_script,
		"ready": candidate_script != null and cue_script != null,
	}


func _candidate(
	script: Script,
	id: StringName,
	asset: String,
	enabled: bool = true,
	character: String = "",
	line: int = 10,
) -> Resource:
	var candidate := script.new() as Resource
	candidate.set("id", id)
	candidate.set("asset", asset)
	candidate.set("authored_enabled", enabled)
	candidate.set("character", character)
	candidate.set("authored_source_path", "res://synthetic/choice_source.stla")
	candidate.set("authored_source_line", line)
	return candidate


func _choice_cue(
	scripts: Dictionary,
	candidates: Array,
	no_repeat: bool = false,
	offset: float = 0.1,
) -> Resource:
	var cue := (scripts["cue"] as Script).new() as Resource
	cue.set("offset_seconds", offset)
	cue.set("selection_policy", &"uniform")
	cue.set(
		"repeat_policy", &"no_repeat" if no_repeat else &"allow_repeat")
	var typed_candidates: Array = cue.get("candidates")
	typed_candidates.assign(candidates)
	cue.set("authored_source_path", "res://synthetic/choice_source.stla")
	cue.set("authored_source_line", 8)
	return cue


func _definition_with_cues(cues: Array) -> PresentationClipDefinition:
	var definition := (load(CLIP_PATH) as PresentationClipDefinition).duplicate(
		true) as PresentationClipDefinition
	definition.cues.assign(cues)
	return definition


func _valid_authority_snapshot() -> Dictionary:
	return {
		"version": 1,
		"initialized": true,
		"initial_seed": 17,
		"state": 820607,
		"last_choices": {
			"synthetic_choice": {"0": "second"},
		},
	}


func _validation_scenario() -> ScenarioData:
	var data := ScenarioData.new()
	data.id = "audio_choice_save"
	data.source_identity = ScenarioData.make_source_identity(SOURCE_PATH)
	var scene := SceneData.new()
	scene.id = "start"
	scene.commands = [CommandData.new()]
	data.scenes = [scene]
	return data


func _current_save_snapshot() -> Dictionary:
	return {
		"scenario_context": {
			"scenario_id": "audio_choice_save",
			"scenario_source_identity": ScenarioData.make_source_identity(
				SOURCE_PATH),
			"scene_index": 0,
			"command_index": 0,
			"is_finished": false,
			"return_stack": [],
		},
		"presentation_state": {
			"bg": "",
			"stage_layers": {},
			"bgm": {},
			"loop_se_channels": {},
			"dialogue_visibility": DialogueVisibilityState.default_state(),
			"dialogue_content": PresentationState._inactive_dialogue_content(),
			"dialogue_avatar": DialogueAvatarState.default_state(),
			"movie": {},
		},
		"presentation_clip_audio_choice": _valid_authority_snapshot(),
		"timestamp": 1.0,
	}


func test_scenario_dsl_remains_the_short_presentation_clip_form() -> void:
	var source := FileAccess.get_file_as_string(SOURCE_PATH)
	assert_false(source.is_empty(), "the public synthetic scenario is readable")
	var data := DslParser.parse(
		DslLexer.tokenize(source), "audio_choice", SOURCE_PATH)
	assert_eq(data.diagnostics, [])
	assert_eq(data.scenes.size(), 1)
	assert_eq(data.scenes[0].commands.size(), 1)
	var command: CommandData = data.scenes[0].commands[0]
	assert_eq(command.type, "presentation_clip")
	assert_eq(command.params, {
		"asset": "synthetic_choice",
		"policy": "join",
	})


func test_ordered_candidate_value_snapshot_is_defensive_and_has_no_source_alias() -> void:
	var scripts := _choice_scripts()
	if not bool(scripts["ready"]):
		return
	var first := _candidate(scripts["candidate"], &"first", "synthetic_loop_region")
	var second := _candidate(
		scripts["candidate"], &"second", "synthetic_loop_region", true, "guide", 11)
	var cue := _choice_cue(scripts, [first, second], true)
	var definition := _definition_with_cues([cue])
	assert_eq(definition.validation_errors(), PackedStringArray())
	var snapshot := definition.canonical_value_snapshot()
	var cue_value: Dictionary = snapshot["cues"][0]
	assert_eq(cue_value.get("kind"), "audio_choice")
	assert_eq(cue_value.get("selection_policy"), "uniform")
	assert_eq(cue_value.get("repeat_policy"), "no_repeat")
	assert_eq(
		(cue_value.get("candidates", []) as Array).map(
			func(value: Dictionary) -> String: return String(value.get("id"))),
		["first", "second"],
		"candidate order is authored order, never id/character order",
	)
	(cue_value["candidates"][0] as Dictionary)["asset"] = "mutated"
	assert_eq(first.get("asset"), "synthetic_loop_region")
	var property_names := (first.get_property_list() as Array).map(
		func(value: Dictionary) -> String: return String(value.get("name")))
	for forbidden_name: String in ["volume", "volume_db", "source_format", "weight"]:
		assert_false(forbidden_name in property_names,
			"choice candidates do not duplicate settings/source ownership")


func test_choice_policy_candidate_shape_and_provenance_fail_closed() -> void:
	var scripts := _choice_scripts()
	if not bool(scripts["ready"]):
		return
	var candidate := _candidate(
		scripts["candidate"], &"primary", "synthetic_loop_region")
	var cue := _choice_cue(scripts, [candidate])
	var definition := _definition_with_cues([cue])
	for invalid_policy: StringName in [&"weighted", &"opaque_randomizer", &""]:
		cue.set("selection_policy", invalid_policy)
		assert_true("selection_policy" in "\n".join(definition.validation_errors()))
	cue.set("selection_policy", &"uniform")
	for invalid_repeat: StringName in [&"repeat", &"source_default", &""]:
		cue.set("repeat_policy", invalid_repeat)
		assert_true("repeat_policy" in "\n".join(definition.validation_errors()))
	cue.set("repeat_policy", &"allow_repeat")
	candidate.set("id", &"bad id")
	assert_true("candidate id" in "\n".join(definition.validation_errors()))
	candidate.set("id", &"primary")
	candidate.set("asset", "res://private.ogg")
	assert_true("asset" in "\n".join(definition.validation_errors()))
	candidate.set("asset", "synthetic_loop_region")
	candidate.set("character", "x".repeat(257))
	assert_true("bounded canonical id" in "\n".join(definition.validation_errors()))
	candidate.set("character", "")
	candidate.set("authored_source_line", 0)
	var provenance_error := "\n".join(definition.validation_errors())
	assert_true("cues[0]" in provenance_error)
	assert_true("candidates[0]" in provenance_error)
	assert_true("authored_source" in provenance_error)


func test_null_and_duplicate_candidates_preserve_ordinals_and_fail_closed() -> void:
	var scripts := _choice_scripts()
	if not bool(scripts["ready"]):
		return
	var first := _candidate(scripts["candidate"], &"same", "synthetic_loop_region")
	var duplicate := _candidate(
		scripts["candidate"], &"same", "synthetic_loop_region", false, "", 12)
	var cue := _choice_cue(scripts, [first, null, duplicate])
	var definition := _definition_with_cues([cue])
	var errors := "\n".join(definition.validation_errors())
	assert_true("candidates[1]" in errors and "null" in errors)
	assert_true("candidates[2]" in errors and "duplicate" in errors)
	var candidates: Array = (
		definition.canonical_value_snapshot()["cues"][0]["candidates"])
	assert_eq(candidates.size(), 3)
	assert_null(candidates[1], "null remains at authored ordinal 1")
	assert_eq(candidates[2].get("ordinal"), 2)


func test_per_cue_and_definition_candidate_work_caps_are_exact() -> void:
	var scripts := _choice_scripts()
	if not bool(scripts["ready"]):
		return
	var candidate_script: Script = scripts["candidate"]
	var cues: Array = []
	for cue_index in range(8):
		var candidates: Array = []
		for candidate_index in range(32):
			candidates.append(_candidate(
				candidate_script,
				StringName("c%d_%d" % [cue_index, candidate_index]),
				"synthetic_loop_region",
				true,
				"",
				100 + cue_index * 32 + candidate_index,
			))
		cues.append(_choice_cue(scripts, candidates, false, cue_index * 0.01))
	var exact := _definition_with_cues(cues)
	assert_eq(exact.validation_errors(), PackedStringArray(),
		"8x32 candidates is the exact cumulative 256 work boundary")
	var overflow_candidate := _candidate(
		candidate_script, &"overflow", "synthetic_loop_region", true, "", 400)
	var ninth := _choice_cue(scripts, [overflow_candidate], false, 0.09)
	exact.cues.append(ninth)
	assert_true(
		"256 total audio-choice candidate" in "\n".join(exact.validation_errors()))
	var too_many: Array = []
	for candidate_index in range(33):
		too_many.append(_candidate(
			candidate_script,
			StringName("one_%d" % candidate_index),
			"synthetic_loop_region",
			true,
			"",
			500 + candidate_index,
		))
	var per_cue := _definition_with_cues([_choice_cue(scripts, too_many)])
	assert_true("32-candidate" in "\n".join(per_cue.validation_errors()))
	var empty := _definition_with_cues([_choice_cue(scripts, [])])
	assert_true("1..32" in "\n".join(empty.validation_errors()),
		"a choice cue requires at least one authored candidate")


func test_fixed_seed_transaction_draws_once_and_no_repeat_uses_last_id() -> void:
	var authority_script := _required_script(
		AUTHORITY_SCRIPT_PATH, "Runtime-owned audio-choice RNG authority")
	if authority_script == null:
		return
	var entropy_calls := [0]
	var authority: RefCounted = authority_script.new(
		17,
		func() -> PackedByteArray:
			entropy_calls[0] += 1
			return PackedByteArray([0, 0, 0, 0, 0, 0, 0, 5]),
	)
	assert_true(authority.call("start_fresh_run"))
	assert_eq(entropy_calls[0], 0, "explicit seed never touches OS entropy")
	assert_true(authority.call("hold", 41))
	var committed: Dictionary = authority.call("commit", 41, [{
		"clip_asset": "synthetic_choice",
		"cue_ordinal": 0,
		"eligible_ids": ["first", "second", "third"],
		"repeat_policy": "no_repeat",
	}])
	assert_true(bool(committed.get("ok", false)))
	assert_eq(committed.get("selections"), {0: "first"})
	assert_eq(authority.call("capture_snapshot").get("state"), 17,
		"provider capture keeps exposing A until whole-quorum complete")
	assert_true(authority.call("complete", 41))
	assert_eq(authority.call("capture_snapshot").get("state"), 820607)
	assert_true(authority.call("hold", 42))
	var second_commit: Dictionary = authority.call("commit", 42, [{
		"clip_asset": "synthetic_choice",
		"cue_ordinal": 0,
		"eligible_ids": ["first", "second", "third"],
		"repeat_policy": "no_repeat",
	}])
	assert_eq(second_commit.get("selections"), {0: "second"})
	assert_eq(authority.call("capture_snapshot").get("state"), 820607,
		"tentative B is not externally snapshot-visible")
	assert_true(authority.call("abort", 42))
	assert_eq(authority.call("capture_snapshot").get("state"), 820607,
		"abort restores RNG and last-id atomically")
	assert_eq(
		PresentationClipAudioChoiceAuthority.initial_playthrough_snapshot(
			authority.call("capture_snapshot")),
		{
			"version": 1, "initialized": true,
			"initial_seed": 17, "state": 17, "last_choices": {},
		},
		"fixed-seed load rebuilds the unvisited-flowchart checkpoint",
	)


func test_one_eligible_consumes_one_and_zero_eligible_consumes_zero() -> void:
	var authority_script := _required_script(
		AUTHORITY_SCRIPT_PATH, "Runtime-owned audio-choice RNG authority")
	if authority_script == null:
		return
	var authority: RefCounted = authority_script.new(17)
	assert_true(authority.call("start_fresh_run"))
	var before: Dictionary = authority.call("capture_snapshot")
	assert_true(authority.call("hold", 51))
	var zero: Dictionary = authority.call("commit", 51, [{
		"clip_asset": "synthetic_choice", "cue_ordinal": 0,
		"eligible_ids": [], "repeat_policy": "no_repeat",
	}])
	assert_eq(zero.get("selections"), {})
	assert_eq(authority.call("capture_snapshot").get("state"), before.get("state"))
	assert_true(authority.call("complete", 51))
	assert_true(authority.call("hold", 52))
	var one: Dictionary = authority.call("commit", 52, [{
		"clip_asset": "synthetic_choice", "cue_ordinal": 0,
		"eligible_ids": ["only"], "repeat_policy": "no_repeat",
	}])
	assert_eq(one.get("selections"), {0: "only"})
	assert_eq(authority.call("capture_snapshot").get("state"), before.get("state"),
		"N=1 draw remains private until completion")
	assert_true(authority.call("complete", 52))
	assert_eq(authority.call("capture_snapshot").get("state"), 820607,
		"N=1 still consumes exactly one published value")


func test_no_repeat_last_missing_uses_the_complete_current_eligible_order() -> void:
	var authority_script := _required_script(
		AUTHORITY_SCRIPT_PATH, "Runtime-owned audio-choice RNG authority")
	if authority_script == null:
		return
	var authority: RefCounted = authority_script.new(17)
	assert_true(authority.call("start_fresh_run"))
	assert_true(authority.call("hold", 61))
	var first: Dictionary = authority.call("commit", 61, [{
		"clip_asset": "synthetic_choice", "cue_ordinal": 0,
		"eligible_ids": ["old"], "repeat_policy": "no_repeat",
	}])
	assert_eq(first.get("selections"), {0: "old"})
	assert_true(authority.call("complete", 61))
	assert_true(authority.call("hold", 62))
	var replacement: Dictionary = authority.call("commit", 62, [{
		"clip_asset": "synthetic_choice", "cue_ordinal": 0,
		"eligible_ids": ["new_a", "new_b"], "repeat_policy": "no_repeat",
	}])
	assert_eq(replacement.get("selections"), {0: "new_a"},
		"an ineligible historical last id does not remove a current candidate")


func test_malformed_restore_is_total_and_preserves_live_rng_state() -> void:
	var authority_script := _required_script(
		AUTHORITY_SCRIPT_PATH, "Runtime-owned audio-choice RNG authority")
	if authority_script == null:
		return
	var authority: RefCounted = authority_script.new(17)
	assert_true(authority.call("start_fresh_run"))
	var before: Dictionary = authority.call("capture_snapshot")
	for malformed: Dictionary in [
		{},
		before.merged({"version": 2}, true),
		before.merged({"state": 0}, true),
		before.merged({"last_choices": {"clip": {"bad": "candidate"}}}, true),
	]:
		assert_false(bool(authority.call("restore_snapshot", malformed)))
		assert_eq(authority.call("capture_snapshot"), before,
			"invalid current save/rollback state causes zero authority mutation")
	for invalid_key: String in ["00", "+1", "-0", "96"]:
		var invalid_key_snapshot := before.duplicate(true)
		invalid_key_snapshot["last_choices"] = {
			"synthetic_choice": {invalid_key: "first"},
		}
		assert_false(bool(authority.call(
			"restore_snapshot", invalid_key_snapshot)), invalid_key)
	assert_eq(authority.call("capture_snapshot"), before)
	var boundary := before.duplicate(true)
	boundary["last_choices"] = {"synthetic_choice": {"95": "first"}}
	assert_true(bool(authority.call("restore_snapshot", boundary)),
		"cue ordinal 95 is the exact MAX_CUES-1 boundary")


func test_auto_seed_uses_one_entropy_read_per_fresh_run_and_title_clear_uses_zero() -> void:
	var authority_script := _required_script(
		AUTHORITY_SCRIPT_PATH, "Runtime-owned audio-choice RNG authority")
	if authority_script == null:
		return
	var calls := [0]
	var authority: RefCounted = authority_script.new(
		0,
		func() -> PackedByteArray:
			calls[0] += 1
			return PackedByteArray([0, 0, 0, 0, 0, 0, 0, calls[0]]),
	)
	assert_true(authority.call("start_fresh_run"))
	var first: Dictionary = authority.call("capture_snapshot")
	assert_true(bool(first.get("initialized", false)))
	var initial_seed := int(first.get("initial_seed", 0))
	assert_true(initial_seed >= 1 and initial_seed < MODULUS)
	assert_eq(calls[0], 1)
	assert_true(authority.call("hold", 63))
	assert_true(bool((authority.call("commit", 63, [{
		"clip_asset": "synthetic_choice", "cue_ordinal": 0,
		"eligible_ids": ["first", "second"], "repeat_policy": "allow_repeat",
	}]) as Dictionary).get("ok", false)))
	assert_true(authority.call("complete", 63))
	assert_eq(
		PresentationClipAudioChoiceAuthority.initial_playthrough_snapshot(
			authority.call("capture_snapshot")),
		{
			"version": 1,
			"initialized": true,
			"initial_seed": initial_seed,
			"state": initial_seed,
			"last_choices": {},
		},
		"auto-seed load derives initial state without another entropy read",
	)
	assert_eq(calls[0], 1)
	authority.call("clear_to_unstarted")
	assert_eq(calls[0], 1, "return-title clear does not prefetch entropy")
	assert_false(bool(authority.call("capture_snapshot").get("initialized", true)))
	assert_true(authority.call("start_fresh_run"))
	assert_eq(calls[0], 2, "the next fresh playthrough acquires one new seed")


func test_authority_rejects_unsorted_or_unbounded_plan_ordinals() -> void:
	var authority := PresentationClipAudioChoiceAuthority.new(17)
	assert_true(authority.start_fresh_run())
	var before := authority.capture_snapshot()
	assert_true(authority.hold(64))
	var unsorted := authority.commit(64, [
		{"clip_asset": "synthetic_choice", "cue_ordinal": 1,
			"eligible_ids": ["first"], "repeat_policy": "allow_repeat"},
		{"clip_asset": "synthetic_choice", "cue_ordinal": 0,
			"eligible_ids": ["second"], "repeat_policy": "allow_repeat"},
	])
	assert_false(bool(unsorted.get("ok", true)))
	assert_eq(authority.capture_snapshot(), before)
	assert_true(authority.abort(64))
	assert_true(authority.hold(65))
	var unbounded := authority.commit(65, [{
		"clip_asset": "synthetic_choice", "cue_ordinal": 96,
		"eligible_ids": ["first"], "repeat_policy": "allow_repeat",
	}])
	assert_false(bool(unbounded.get("ok", true)))
	assert_eq(authority.capture_snapshot(), before)
	assert_true(authority.abort(65))
	assert_true(authority.hold(66))
	var coerced_policy := authority.commit(66, [{
		"clip_asset": "synthetic_choice", "cue_ordinal": 0,
		"eligible_ids": ["first"], "repeat_policy": 1,
	}])
	assert_false(bool(coerced_policy.get("ok", true)),
		"authority plan fields require exact types before comparison")
	assert_eq(authority.capture_snapshot(), before)
	assert_true(authority.abort(66))


func test_signed_object_token_is_an_opaque_nonzero_transaction_identity() -> void:
	var authority := PresentationClipAudioChoiceAuthority.new(17)
	assert_true(authority.start_fresh_run())
	var before := authority.capture_snapshot()
	var signed_object_token := -9223371859704149841
	var plan := [{
		"clip_asset": "synthetic_choice",
		"cue_ordinal": 0,
		"eligible_ids": ["first", "second"],
		"repeat_policy": "no_repeat",
	}]
	assert_false(authority.hold(0), "zero is not a transaction identity")
	assert_true(authority.hold(signed_object_token))
	assert_true(bool(authority.commit(signed_object_token, plan).get("ok", false)))
	assert_eq(authority.capture_snapshot(), before,
		"a negative Object-style token still keeps tentative B private")
	assert_false(authority.complete(0), "zero cannot complete a signed transaction")
	assert_false(authority.abort(0), "zero cannot abort a signed transaction")
	assert_true(authority.abort(signed_object_token))
	assert_eq(authority.capture_snapshot(), before,
		"negative-token abort restores exact A")
	assert_true(authority.hold(signed_object_token))
	assert_true(bool(authority.commit(signed_object_token, plan).get("ok", false)))
	assert_true(authority.complete(signed_object_token))
	assert_eq(authority.capture_snapshot().get("state"), 820607,
		"negative-token completion publishes B")


func test_choice_seed_config_is_closed_bounded_and_resets_to_auto() -> void:
	var config := StellaConfig.new()
	var default_value: Variant = config.get("presentation_clip_audio_choice_seed")
	assert_eq(default_value, 0,
		"#201: [presentation_clips] audio_choice_seed defaults to auto")
	if default_value == null:
		return
	var file := FileAccess.open(_temporary_config_path, FileAccess.WRITE)
	file.store_string("[presentation_clips]\naudio_choice_seed = 2147483646\n")
	file.close()
	assert_eq(config.load_from_path(_temporary_config_path), OK)
	assert_eq(config.get("presentation_clip_audio_choice_seed"), 2147483646)
	config.reset()
	assert_eq(config.get("presentation_clip_audio_choice_seed"), 0)
	for invalid_case: Dictionary in [
		{"value": "-1", "error": ERR_INVALID_DATA},
		{"value": "2147483647", "error": ERR_INVALID_DATA},
		{"value": "1.5", "error": ERR_PARSE_ERROR},
		{"value": "\"seed\"", "error": ERR_INVALID_DATA},
	]:
		file = FileAccess.open(_temporary_config_path, FileAccess.WRITE)
		file.store_string(
			"[presentation_clips]\naudio_choice_seed = %s\n"
			% String(invalid_case["value"]))
		file.close()
		assert_eq(
			config.load_from_path(_temporary_config_path),
			int(invalid_case["error"]),
		)
		assert_eq(config.get("presentation_clip_audio_choice_seed"), 0,
			"invalid config leaves the exact resolved snapshot unchanged")


func test_current_save_and_rollback_require_exact_choice_authority_snapshot() -> void:
	var authority_script := _required_script(
		AUTHORITY_SCRIPT_PATH, "Runtime-owned audio-choice RNG authority")
	if authority_script == null:
		return
	var manager := SaveManager.new()
	var scenario := _validation_scenario()
	var valid := _current_save_snapshot()
	assert_true(manager.validate_data_for_scenario(valid, scenario))
	var missing := valid.duplicate(true)
	missing.erase("presentation_clip_audio_choice")
	assert_false(manager.validate_data_for_scenario(missing, scenario),
		"current saves never infer a seed or retain the live authority")
	for malformed: Variant in [
		{},
		{"version": 2, "initialized": true, "initial_seed": 17,
			"state": 17, "last_choices": {}},
		{"version": 1, "initialized": true, "initial_seed": 0,
			"state": 17, "last_choices": {}},
		{"version": 1, "initialized": true, "initial_seed": 17,
			"state": 0, "last_choices": {}},
		{"version": 1, "initialized": true, "initial_seed": 17,
			"state": 17, "last_choices": {"clip": {"bad": "candidate"}}},
		{"version": 1, "initialized": false, "initial_seed": 0,
			"state": 0, "last_choices": {}},
	]:
		var invalid := valid.duplicate(true)
		invalid["presentation_clip_audio_choice"] = malformed
		assert_false(manager.validate_data_for_scenario(invalid, scenario))
	var rollback := {
		"scenario_context": valid["scenario_context"],
		"presentation_state": valid["presentation_state"],
		"presentation_clip_audio_choice": valid[
			"presentation_clip_audio_choice"],
	}
	assert_true(manager.call("_rollback_snapshot_is_valid", rollback, scenario))
	rollback.erase("presentation_clip_audio_choice")
	assert_false(manager.call("_rollback_snapshot_is_valid", rollback, scenario))
	var authority: RefCounted = authority_script.new(17)
	assert_true(authority.call("start_fresh_run"))
	var probe := ProbeProvider.new()
	manager.register_provider(probe)
	manager.register_provider(authority)
	assert_false(manager.restore_data({"probe": {"revision": 2}}))
	assert_eq(probe.value, {"revision": 1},
		"missing authority state rejects before any sibling provider mutation")
	var valid_restore := {
		"probe": {"revision": 2},
		"presentation_clip_audio_choice": _valid_authority_snapshot(),
	}
	assert_true(manager.restore_data(valid_restore))
	assert_eq(probe.value, {"revision": 2})
	assert_true(authority.call("hold", 72))
	var reentrant_restore := valid_restore.duplicate(true)
	reentrant_restore["probe"] = {"revision": 3}
	assert_false(manager.restore_data(reentrant_restore),
		"an active whole-quorum transaction rejects external provider restore")
	assert_eq(probe.value, {"revision": 2},
		"fallible authority restore runs before sibling provider mutation")
	assert_true(authority.call("abort", 72))


func test_manual_quick_and_auto_files_capture_the_same_exact_authority_state() -> void:
	var authority_script := _required_script(
		AUTHORITY_SCRIPT_PATH, "Runtime-owned audio-choice RNG authority")
	if authority_script == null:
		return
	var authority: RefCounted = authority_script.new(17)
	assert_true(authority.call("start_fresh_run"))
	assert_true(authority.call("hold", 71))
	assert_true(bool((authority.call("commit", 71, [{
		"clip_asset": "synthetic_choice",
		"cue_ordinal": 0,
		"eligible_ids": ["first", "second"],
		"repeat_policy": "no_repeat",
	}]) as Dictionary).get("ok", false)))
	assert_true(authority.call("complete", 71))
	var expected: Dictionary = authority.call("capture_snapshot")
	var manager := SaveManager.new()
	manager.save_dir = _temporary_save_dir
	manager.register_provider(authority)
	manager.save(3)
	manager.quick_save()
	manager.auto_save()
	for snapshot_value: Variant in [
		manager.read_save_data(3),
		manager.read_quick_save_data(),
		manager.read_auto_save_data(),
	]:
		assert_true(snapshot_value is Dictionary)
		if snapshot_value is Dictionary:
			var serialized: Variant = snapshot_value.get(
				PresentationClipAudioChoiceAuthority.PROVIDER_ID, null)
			assert_true(
				PresentationClipAudioChoiceAuthority.validate_playthrough_snapshot(
					serialized),
				"serialized JSON preserves the exact provider schema",
			)
			var restored := authority_script.new(17) as RefCounted
			assert_true(restored.call("restore_snapshot", serialized))
			assert_eq(restored.call("capture_snapshot"), expected,
				"manual, quick, and auto saves canonicalize integral JSON numbers")


func test_candidate_diagnostics_are_bounded_and_source_located() -> void:
	var scripts := _choice_scripts()
	if not bool(scripts["ready"]):
		return
	var candidate := _candidate(
		scripts["candidate"], &"broken", "res://not-logical", false, "guide", 77)
	var cue := _choice_cue(scripts, [candidate])
	var definition := _definition_with_cues([cue])
	var error := "\n".join(definition.validation_errors())
	assert_true("<embedded PresentationClipDefinition>" in error)
	assert_true("cues[0]" in error)
	assert_true("candidates[0]" in error)
	assert_true("broken" in error)
	assert_true("res://synthetic/choice_source.stla:77" in error)
	assert_true("asset" in error)
	assert_false("PackedByteArray" in error)
	assert_false("candidates = [" in error,
		"diagnostics never dump the full candidate set or stream bytes")
