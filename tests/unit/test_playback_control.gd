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


# --- BacklogManager ---

func test_backlog_add_entry():
	var blm = BacklogManager.new()
	blm.add_entry("sakura", "Hello!", "voice_001")
	assert_eq(blm.get_entries().size(), 1)
	assert_eq(blm.get_entries()[0]["character"], "sakura")
	assert_eq(blm.get_entries()[0]["text"], "Hello!")


func test_backlog_order():
	var blm = BacklogManager.new()
	blm.add_entry("sakura", "First", "")
	blm.add_entry("kaito", "Second", "")
	var entries = blm.get_entries()
	assert_eq(entries[0]["text"], "First")
	assert_eq(entries[1]["text"], "Second")


func test_backlog_max_capacity():
	var blm = BacklogManager.new()
	blm.max_entries = 3
	for i in range(5):
		blm.add_entry("char", "msg_%d" % i, "")
	assert_eq(blm.get_entries().size(), 3)
	assert_eq(blm.get_entries()[0]["text"], "msg_2")  # oldest dropped


func test_backlog_clear():
	var blm = BacklogManager.new()
	blm.add_entry("sakura", "Hello", "")
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
	sc.skip_only_read = true
	assert_true(sc.should_skip("ch1", "s1", 0, rfm))


func test_skip_should_not_skip_unread_when_skip_only_read():
	var rfm = ReadFlagManager.new()
	var sc = SkipController.new()
	sc.is_active = true
	sc.skip_only_read = true
	assert_false(sc.should_skip("ch1", "s1", 0, rfm))


func test_skip_should_skip_unread_when_not_skip_only_read():
	var rfm = ReadFlagManager.new()
	var sc = SkipController.new()
	sc.is_active = true
	sc.skip_only_read = false
	assert_true(sc.should_skip("ch1", "s1", 0, rfm))


func test_skip_inactive_never_skips():
	var rfm = ReadFlagManager.new()
	rfm.mark_read("ch1", "s1", 0)
	var sc = SkipController.new()
	sc.is_active = false
	assert_false(sc.should_skip("ch1", "s1", 0, rfm))
