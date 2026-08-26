extends GutTest
## Tests for ReadFlagManager, BacklogManager, AutoPlayController, SkipController.


# --- ReadFlagManager ---

func test_read_flag_mark_and_check():
	var rfm = ReadFlagManager.new()
	assert_false(rfm.is_read("chapter1", "scene1", 0))
	rfm.mark_read("chapter1", "scene1", 0)
	assert_true(rfm.is_read("chapter1", "scene1", 0))


func test_read_flag_different_positions():
	var rfm = ReadFlagManager.new()
	rfm.mark_read("ch1", "s1", 0)
	rfm.mark_read("ch1", "s1", 1)
	assert_true(rfm.is_read("ch1", "s1", 0))
	assert_true(rfm.is_read("ch1", "s1", 1))
	assert_false(rfm.is_read("ch1", "s1", 2))


func test_read_flag_snapshot():
	var rfm = ReadFlagManager.new()
	rfm.mark_read("ch1", "s1", 0)

	assert_eq(rfm.get_provider_id(), "read_flags")
	var snapshot = rfm.capture_snapshot()

	var rfm2 = ReadFlagManager.new()
	rfm2.restore_snapshot(snapshot)
	assert_true(rfm2.is_read("ch1", "s1", 0))


func test_read_flag_restore_merges_cross_playthrough_progress():
	var rfm = ReadFlagManager.new()
	rfm.mark_read("route_b", "scene_2", 7)

	# Loading an older save must add its read flags without erasing lines read
	# in another playthrough after that save was created.
	rfm.restore_snapshot({"route_a:scene_1:3": true})

	assert_true(rfm.is_read("route_a", "scene_1", 3), "loaded flag should be restored")
	assert_true(rfm.is_read("route_b", "scene_2", 7), "newer read progress must survive")

	# An old save made before any dialogue was read is also monotonic: it must
	# not act as a request to clear global progress.
	rfm.restore_snapshot({})
	assert_true(rfm.is_read("route_b", "scene_2", 7), "empty snapshot must not clear progress")


func test_read_flag_structured_key_does_not_collide_on_colons() -> void:
	var rfm := ReadFlagManager.new()
	rfm.mark_read("route:branch", "scene", 4)

	assert_true(rfm.is_read("route:branch", "scene", 4))
	assert_false(rfm.is_read("route", "branch:scene", 4),
		"tuple components must not collide through delimiter concatenation")


func test_read_flag_legacy_snapshot_migrates_to_v2_and_remains_queryable() -> void:
	var rfm := ReadFlagManager.new()
	rfm.restore_snapshot({"main:start:3": true})

	assert_true(rfm.is_dialogue_read(
		"path:res://story/main.stla", "main", "start", 30, 3),
		"a canonical request may fall back to an actually migrated v1 address")
	var snapshot := rfm.capture_snapshot()
	assert_eq(snapshot.get("version"), 2)
	assert_eq(snapshot.get("flags", []).size(), 0)
	assert_eq(snapshot.get("legacy_flags", []), ["main:start:3"])


func test_ambiguous_v1_key_preserves_raw_lookup_instead_of_guessing_tuple() -> void:
	var rfm := ReadFlagManager.new()
	rfm.restore_snapshot({"route:a:scene:7": true})

	assert_true(rfm.is_read("route:a", "scene", 7))
	assert_true(rfm.is_read("route", "a:scene", 7),
		"v1 ambiguity preserves both historical string-equivalent queries")
	var snapshot := rfm.capture_snapshot()
	var restored := ReadFlagManager.new()
	restored.restore_snapshot(snapshot)
	assert_eq(restored.capture_snapshot().get("legacy_flags", []),
		["route:a:scene:7"])


func test_unknown_snapshot_version_is_rejected_without_mutation() -> void:
	var rfm := ReadFlagManager.new()
	rfm.mark_read("current", "scene", 1)
	rfm.restore_snapshot({"version": 99, "flags": []})

	assert_push_error("ReadFlagManager: unsupported snapshot version")
	assert_true(rfm.is_read("current", "scene", 1))


func test_malformed_v2_is_rejected_atomically() -> void:
	var rfm := ReadFlagManager.new()
	rfm.restore_snapshot({
		"version": 2,
		"flags": [
			{"scenario": "valid", "scene": "start", "command_uid": 1},
			{"scenario": "broken"},
		],
	})

	assert_push_error("ReadFlagManager: malformed v2 snapshot record")
	assert_false(rfm.is_read("valid", "start", 1),
		"a malformed snapshot cannot be partially applied")


func test_v2_rejects_out_of_range_json_uids_atomically() -> void:
	for invalid_uid in [
		-1,
		-1e100,
		1e100,
		9007199254740992,
		9007199254740992.0,
	]:
		var rfm := ReadFlagManager.new()
		rfm.restore_snapshot({
			"version": 2,
			"flags": [
				{"scenario": "valid", "scene": "start", "command_uid": 1},
				{
					"scenario": "invalid",
					"scene": "start",
					"command_uid": invalid_uid,
				},
			],
		})

		assert_push_error("ReadFlagManager: malformed v2 snapshot record")
		assert_false(rfm.is_read("valid", "start", 1),
			"one invalid UID must reject the whole snapshot")


func test_v2_accepts_exact_json_integer_boundaries() -> void:
	var rfm := ReadFlagManager.new()
	var encoded := JSON.stringify({
		"version": 2,
		"flags": [
			{"scenario": "zero", "scene": "start", "command_uid": 0.0},
			{
				"scenario": "large-float",
				"scene": "start",
				"command_uid": 9007199254740990.0,
			},
			{
				"scenario": "max-int",
				"scene": "start",
				"command_uid": 9007199254740991,
			},
		],
	})
	var decoded: Dictionary = JSON.parse_string(encoded)
	rfm.restore_snapshot(decoded)

	assert_true(rfm.is_read("zero", "start", 0))
	assert_true(rfm.is_read("large-float", "start", 9007199254740990))
	assert_true(rfm.is_read("max-int", "start", 9007199254740991))


func test_public_read_writes_round_trip_through_json_snapshot() -> void:
	var rfm := ReadFlagManager.new()
	rfm.mark_read("compat", "start", 0)
	rfm.mark_dialogue_read(
		"path:res://story/main.stla", "chapter", 9007199254740991)
	var decoded: Dictionary = JSON.parse_string(
		JSON.stringify(rfm.capture_snapshot()))
	var restored := ReadFlagManager.new()
	restored.restore_snapshot(decoded)

	assert_true(restored.is_read("compat", "start", 0))
	assert_true(restored.is_dialogue_read(
		"path:res://story/main.stla", "main", "chapter",
		9007199254740991, -1))


func test_public_read_writes_reject_uids_outside_snapshot_schema() -> void:
	var rfm := ReadFlagManager.new()
	rfm.mark_read("negative", "start", -1)
	assert_push_error(
		"ReadFlagManager: command UID must be a non-negative JSON-safe integer")
	rfm.mark_dialogue_read("unsafe", "start", 9007199254740992)
	assert_push_error(
		"ReadFlagManager: command UID must be a non-negative JSON-safe integer")

	assert_eq(rfm.capture_snapshot().get("flags", []), [],
		"the public API cannot create state that its restore path rejects")


func test_equal_basenames_keep_distinct_canonical_read_history() -> void:
	var rfm := ReadFlagManager.new()
	rfm.mark_dialogue_read("path:res://route_a/main.stla", "start", 7)

	assert_true(rfm.is_dialogue_read(
		"path:res://route_a/main.stla", "main", "start", 7, 0))
	assert_false(rfm.is_dialogue_read(
		"path:res://route_b/main.stla", "main", "start", 7, 0),
		"new canonical records must never activate the basename fallback")


func test_dialogue_activation_abort_wins_over_late_advance() -> void:
	var activation := DialogueActivation.new()
	assert_true(activation.abort())
	assert_false(activation.advance())
	assert_eq(activation.get_outcome(), DialogueActivation.Outcome.ABORTED)


func test_dialogue_activation_advance_wins_over_late_abort() -> void:
	var activation := DialogueActivation.new()
	assert_true(activation.advance())
	assert_false(activation.abort())
	assert_eq(activation.get_outcome(), DialogueActivation.Outcome.ADVANCED)


# --- BacklogManager ---

func _seg(text: String, voice: String = "") -> Dictionary:
	return {
		"text": text,
		"voice_layers": (
			[] if voice.is_empty() else [{
				"id": "main", "asset": voice, "character": "",
				"dsp": "", "line": 0,
			}]),
	}


func test_backlog_add_entry():
	var blm = BacklogManager.new()
	blm.add_entry("sakura", [_seg("Hello!", "voice_001")])
	assert_eq(blm.get_entries().size(), 1)
	assert_eq(blm.get_entries()[0]["character"], "sakura")
	assert_eq(blm.get_entries()[0]["text"], "Hello!")
	assert_eq(blm.get_entries()[0]["voices"], ["voice_001"])


func test_backlog_combined_entry_concatenates_voices():
	var blm = BacklogManager.new()
	blm.add_entry("sakura", [
		_seg("一", "v1"),
		_seg("二", "v2"),
		_seg("三", "v3"),
	])
	var entry = blm.get_entries()[0]
	assert_eq(entry["text"], "一二三")
	assert_eq(entry["voices"], ["v1", "v2", "v3"])


func test_backlog_order():
	var blm = BacklogManager.new()
	blm.add_entry("sakura", [_seg("First")])
	blm.add_entry("kaito", [_seg("Second")])
	var entries = blm.get_entries()
	assert_eq(entries[0]["text"], "First")
	assert_eq(entries[1]["text"], "Second")


func test_backlog_max_capacity():
	var blm = BacklogManager.new()
	blm.max_entries = 3
	for i in range(5):
		blm.add_entry("char", [_seg("msg_%d" % i)])
	assert_eq(blm.get_entries().size(), 3)
	assert_eq(blm.get_entries()[0]["text"], "msg_2")  # oldest dropped


func test_backlog_clear():
	var blm = BacklogManager.new()
	blm.add_entry("sakura", [_seg("Hello")])
	blm.clear()
	assert_eq(blm.get_entries().size(), 0)


# --- AutoPlayController ---

func test_auto_play_default_off():
	var apc = AutoPlayController.new()
	assert_false(apc.is_active)


func test_auto_play_toggle():
	var apc = AutoPlayController.new()
	apc.toggle()
	assert_true(apc.is_active)
	apc.toggle()
	assert_false(apc.is_active)


func test_auto_play_stop():
	var apc = AutoPlayController.new()
	apc.is_active = true
	apc.stop()
	assert_false(apc.is_active)


func test_auto_play_suspension_owners_are_idempotent_and_composable() -> void:
	var controller := AutoPlayController.new()
	var effective_edges: Array[bool] = []
	controller.effective_changed.connect(
		func(effective: bool) -> void: effective_edges.append(effective))
	controller.is_active = true
	assert_true(controller.is_effective())

	controller.acquire_suspension("choice-a")
	controller.acquire_suspension("choice-a")
	controller.acquire_suspension("choice-b")
	assert_false(controller.is_effective())
	assert_eq(effective_edges, [true, false],
		"reacquiring the same owner cannot publish a duplicate edge")

	controller.release_suspension("choice-a")
	controller.release_suspension("choice-a")
	assert_false(controller.is_effective(),
		"one owner cannot release another owner's suspension")
	controller.release_suspension("choice-b")
	assert_true(controller.is_effective())
	assert_eq(effective_edges, [true, false, true])


func test_auto_play_intent_edges_and_hard_clear_have_stable_order() -> void:
	var controller := AutoPlayController.new()
	var events: Array[String] = []
	controller.active_changed.connect(
		func(active: bool) -> void:
			events.append("intent:%s" % active))
	controller.effective_changed.connect(
		func(effective: bool) -> void:
			events.append("effective:%s" % effective))

	controller.toggle()
	controller.acquire_suspension("choice")
	controller.stop()
	controller.toggle()
	controller.clear_suspensions()

	assert_eq(events, [
		"intent:true",
		"effective:true",
		"effective:false",
		"intent:false",
		"intent:true",
		"effective:true",
	], "intent publishes before its resulting effective edge")
	assert_true(controller.is_active)
	assert_true(controller.is_effective())

	events.clear()
	controller.acquire_suspension("hard-a")
	controller.acquire_suspension("hard-b")
	controller.stop()
	controller.clear_suspensions()
	assert_eq(events, ["effective:false", "intent:false"],
		"stop-before-clear cannot emit a positive hard-boundary effective edge")
	assert_false(controller.is_active)
	assert_false(controller.is_effective())


func test_auto_play_hard_cleanup_preserves_only_replacement_owner() -> void:
	var controller := AutoPlayController.new()
	controller.is_active = true
	controller.acquire_suspension("retired-choice")
	controller.acquire_suspension("replacement-choice")

	controller.clear_suspensions_except("replacement-choice")

	assert_false(controller.is_effective(),
		"the replacement choice keeps its exact suspension")
	controller.release_suspension("retired-choice")
	assert_false(controller.is_effective(),
		"the retired owner was already removed")
	controller.release_suspension("replacement-choice")
	assert_true(controller.is_effective())


# --- SkipController ---

func test_skip_default_off():
	var sc = SkipController.new()
	assert_false(sc.is_active)


func test_skip_toggle():
	var sc = SkipController.new()
	sc.toggle()
	assert_true(sc.is_active)
	sc.toggle()
	assert_false(sc.is_active)


func test_skip_should_skip_read_content():
	var rfm = ReadFlagManager.new()
	rfm.mark_read("ch1", "s1", 0)
	var sc = SkipController.new()
	sc.is_active = true
	assert_true(sc.should_skip("ch1", "s1", 0, rfm, true))


func test_skip_should_not_skip_unread_when_skip_only_read():
	var rfm = ReadFlagManager.new()
	var sc = SkipController.new()
	sc.is_active = true
	assert_false(sc.should_skip("ch1", "s1", 0, rfm, true))


func test_skip_should_skip_unread_when_not_skip_only_read():
	var rfm = ReadFlagManager.new()
	var sc = SkipController.new()
	sc.is_active = true
	assert_true(sc.should_skip("ch1", "s1", 0, rfm, false))


func test_skip_inactive_never_skips():
	var rfm = ReadFlagManager.new()
	rfm.mark_read("ch1", "s1", 0)
	var sc = SkipController.new()
	sc.is_active = false
	assert_false(sc.should_skip("ch1", "s1", 0, rfm, true))
