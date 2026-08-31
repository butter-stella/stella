extends GutTest
## Canonical parser and stable-state contract for marker-synchronized BGM mix (#190).

const SOURCE_PATH := "res://synthetic/bgm_marker_contract.stla"


func _parse(source: String) -> ScenarioData:
	return DslParser.parse(
		DslLexer.tokenize(source),
		"bgm_marker_contract",
		SOURCE_PATH,
	)


func _commands(data: ScenarioData) -> Array[CommandData]:
	var result: Array[CommandData] = []
	for scene_value: Variant in data.scenes:
		for command_value: Variant in (scene_value as SceneData).commands:
			result.append(command_value as CommandData)
	return result


func _errors(data: ScenarioData) -> Array:
	return data.diagnostics.filter(func(diagnostic: Dictionary) -> bool:
		return String(diagnostic.get("level", "")) == "error"
	)


func _payload(command: CommandData) -> Dictionary:
	return command.params["operations"][0]["payload"] as Dictionary


func test_unicode_marker_lowers_to_the_single_canonical_bgm_operation() -> void:
	var data := _parse("""@chapter synthetic
@scene start
@bgm mix rhythm,bass:0.7 marker="サビ" fade=0.1""")
	assert_eq(_errors(data), [], str(data.diagnostics))
	var commands := _commands(data)
	assert_eq(commands.size(), 1)
	if commands.size() != 1:
		return
	assert_eq(_payload(commands[0]), {
		"action": "mix",
		"asset": "",
		"cue": "",
		"fade_duration": 0.1,
		"marker": "サビ",
		"resume_position": 0.0,
		"stem_mix": {"bass": 0.7, "rhythm": 1.0},
		"volume": 1.0,
	})


func test_quoted_marker_preserves_whitespace_delimiters_and_exact_escapes() -> void:
	var data := _parse(
		"@chapter synthetic\n@scene start\n"
		+ "@bgm mix rhythm marker=\"A B,=\\t\\\"C\\\"\""
	)
	assert_eq(_errors(data), [], str(data.diagnostics))
	var commands := _commands(data)
	assert_eq(commands.size(), 1)
	if commands.size() == 1:
		assert_eq(_payload(commands[0]).get("marker", null), "A B,=\t\"C\"")


func test_immediate_mix_uses_an_explicit_empty_marker_field() -> void:
	var data := _parse("""@chapter synthetic
@scene start
@bgm mix rhythm""")
	assert_eq(_errors(data), [], str(data.diagnostics))
	var commands := _commands(data)
	assert_eq(commands.size(), 1)
	if commands.size() == 1:
		assert_eq(_payload(commands[0]).get("marker", null), "")


func test_marker_grammar_fails_closed_at_the_authored_source_line() -> void:
	var cases := [
		{"line": "@bgm mix rhythm marker=", "message": "marker"},
		{"line": "@bgm mix rhythm marker=\"サビ\" marker=\"verse\"", "message": "duplicate"},
		{"line": "@bgm play ensemble marker=\"サビ\"", "message": "does not accept"},
		{"line": "@bgm pause marker=\"サビ\"", "message": "does not accept"},
		{"line": "@bgm mix rhythm marker=サビ", "message": "quoted"},
		{"line": "@bgm mix rhythm marker='サビ'", "message": "double quote"},
		{"line": "@bgm mix rhythm marker=“サビ”", "message": "double quote"},
		{"line": "@bgm mix rhythm marker=\"bad\\q\"", "message": "escape"},
		{"line": "@bgm mix rhythm marker=\"unterminated", "message": "unterminated"},
	]
	for case: Dictionary in cases:
		var data := _parse(
			"@chapter synthetic\n@scene start\n" + String(case["line"]))
		assert_eq(_commands(data), [], String(case["line"]))
		assert_eq(_errors(data).size(), 1, str(data.diagnostics))
		if _errors(data).size() == 1:
			var error: Dictionary = _errors(data)[0]
			assert_eq(int(error.get("line", 0)), 3)
			var message := String(error.get("message", ""))
			assert_true(String(case["message"]) in message, message)
			assert_true("%s:3" % SOURCE_PATH in message, message)


func test_marker_operation_and_pending_state_use_exact_closed_schemas() -> void:
	var operation := {
		"action": "mix", "asset": "", "cue": "",
		"fade_duration": 0.1, "marker": "サビ",
		"resume_position": 0.0,
		"stem_mix": {"bass": 0.7, "rhythm": 1.0},
		"volume": 1.0,
	}
	var state := {
		"asset": "ensemble", "cue": "", "loop": true,
		"pending_marker_mix": {
			"fade_duration": 0.1,
			"marker": "サビ",
			"marker_frame": 48000,
			"marker_loop_epoch": 0,
			"marker_ordinal": 2,
			"marker_table_fingerprint": "a".repeat(64),
			"phase": "armed",
			"restore_horizon_frame": 12000,
			"restore_horizon_loop_epoch": 0,
			"schema_version": 2,
			"stem_mix": {"bass": 0.7, "rhythm": 1.0},
			"track_fingerprint": "b".repeat(64),
			"wraps_loop": false,
		},
		"position": 0.25, "status": "playing",
		"stem_mix": {"bass": 0.0, "rhythm": 1.0},
		"volume": 1.0,
	}
	assert_true(BgmChannelState.validate_operation(operation, false))
	assert_true(BgmChannelState.validate_snapshot_state(state, false))
	assert_not_null(JSON.parse_string(JSON.stringify(state)))

	var invalid_operation := operation.duplicate(true)
	invalid_operation["marker"] = String.chr(1)
	assert_false(BgmChannelState.validate_operation(invalid_operation, false))
	var invalid_state := state.duplicate(true)
	invalid_state["pending_marker_mix"]["marker_ordinal"] = -1
	assert_false(BgmChannelState.validate_snapshot_state(invalid_state, false))


func test_pre_marker_save_defaults_clean_and_invalid_pending_versions_fail_closed() -> void:
	var old_snapshot := {
		"asset": "ensemble", "cue": "", "loop": true,
		"position": 0.25, "status": "playing",
		"stem_mix": {"bass": 0.0, "rhythm": 1.0},
		"volume": 1.0,
	}
	assert_true(BgmChannelState.validate_snapshot_state(old_snapshot, false))
	var normalized := BgmChannelState.normalize_snapshot_state(old_snapshot)
	assert_true(normalized.has("pending_marker_mix"))
	assert_eq(normalized["pending_marker_mix"], {})

	var canonical_pending := BgmPendingMarkerMixState.queued(
		"サビ",
		{"bass": 0.7, "rhythm": 1.0},
		0.1,
		"a".repeat(64),
		"b".repeat(64),
		12000,
		0,
	).to_snapshot()
	for invalid_version: Variant in [2.0, "2", true]:
		var mistyped := canonical_pending.duplicate(true)
		mistyped["schema_version"] = invalid_version
		assert_null(BgmPendingMarkerMixState.from_snapshot(mistyped),
			"schema_version never accepts Variant coercion from %s" % invalid_version)

	for invalid_pending: Variant in [
		{"schema_version": 99},
		{"schema_version": 2, "phase": "armed"},
		"not-a-dictionary",
	]:
		var invalid := normalized.duplicate(true)
		invalid["pending_marker_mix"] = invalid_pending
		assert_false(BgmChannelState.validate_snapshot_state(invalid, false))
		assert_eq(BgmChannelState.normalize_snapshot_state(invalid), {})


func test_marker_and_track_fingerprints_match_exact_schema_vectors() -> void:
	var markers: Array[BgmMarkerDefinition] = []
	for encoded: Dictionary in [
		{"name": "old", "frame": 16},
		{"name": "サビ", "frame": 32},
		{"name": "サビ", "frame": 48},
		{"name": "A B,=\t\"C\"", "frame": 64},
	]:
		var marker := BgmMarkerDefinition.new()
		marker.marker_name = String(encoded["name"])
		marker.sample_frame = int(encoded["frame"])
		markers.append(marker)
	var marker_fingerprint := BgmMarkerFingerprint.marker_table(markers)
	assert_eq(
		marker_fingerprint,
		"dc6339ed68dc587cfcda7a1ea4cbcd552203dc856e75a5f883a6d02339ec367c",
		"the schema-tagged UTF-8/u64 marker encoding is cross-platform stable",
	)
	assert_eq(BgmMarkerFingerprint.track(
		["rhythm", "bass"],
		["abc".to_utf8_buffer(), "def".to_utf8_buffer()],
		44100,
		1024,
		true,
		0,
		1024,
		marker_fingerprint,
	), "57f525a830230dd8980d57a122190818b6ac08ccfadf0887fa1bfd44af604662")


func test_ogg_packet_rebuild_terminates_a_full_255_segment_page() -> void:
	var full_page_packet := PackedByteArray()
	full_page_packet.resize(255 * 255)
	var rebuilt := BgmOggPacketEncoder.encode(
		[[full_page_packet], [PackedByteArray([1])], [PackedByteArray([2])]],
		PackedInt64Array([0, 1, 2]),
		0x53540001,
	)
	assert_false(rebuilt.is_empty())
	var second_page_offset := 27 + 255 + full_page_packet.size()
	assert_eq(rebuilt.slice(second_page_offset, second_page_offset + 4),
		"OggS".to_ascii_buffer())
	assert_eq(rebuilt[second_page_offset + 5] & 0x01, 0x01,
		"the terminator page continues the exact-multiple packet")
	assert_eq(rebuilt[second_page_offset + 26], 1)
	assert_eq(rebuilt[second_page_offset + 27], 0,
		"a zero lacing segment closes a 65025-byte packet")
