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


# --- BacklogManager ---

func _seg(text: String, voice: String = "") -> Dictionary:
	return {"text": text, "voice": voice, "expression": ""}


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
