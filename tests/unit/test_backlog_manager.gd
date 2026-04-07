extends GutTest
## Tests for BacklogManager — entry storage, cursor / browser-history model,
## sparse anchor snapshots, and jump_to lookups.


var _mgr: BacklogManager


func before_each():
	_mgr = BacklogManager.new()


func _segs(text: String, voice: String = "") -> Array:
	return [{"text": text, "voice": voice, "expression": ""}]


# A test snapshot factory: returns a unique dict each call so we can verify
# identity if needed.
var _snapshot_counter: int = 0
func _snap() -> Dictionary:
	_snapshot_counter += 1
	return {"id": _snapshot_counter}


# ─── Basic add / get ───

func test_add_entry_stores_basic_fields():
	_mgr.add_entry("sakura", _segs("hello"), 0, 0, func(): return {})
	var entries = _mgr.get_entries()
	assert_eq(entries.size(), 1)
	assert_eq(entries[0]["character"], "sakura")
	assert_eq(entries[0]["text"], "hello")
	assert_eq(entries[0]["scene_index"], 0)
	assert_eq(entries[0]["command_index"], 0)


func test_add_entry_concatenates_combine_segments():
	var segs = [
		{"text": "foo", "voice": "v1", "expression": ""},
		{"text": "bar", "voice": "v2", "expression": ""},
	]
	_mgr.add_entry("a", segs, 0, 0, func(): return {})
	var e = _mgr.get_entries()[0]
	assert_eq(e["text"], "foobar")
	assert_eq(e["voices"], ["v1", "v2"])


# ─── Cursor + browser history model ───

func test_cursor_starts_at_minus_one():
	assert_eq(_mgr.get_cursor(), -1)


func test_cursor_advances_on_each_append():
	_mgr.add_entry("a", _segs("1"), 0, 0, func(): return _snap())
	assert_eq(_mgr.get_cursor(), 0)
	_mgr.add_entry("a", _segs("2"), 0, 1, func(): return _snap())
	assert_eq(_mgr.get_cursor(), 1)


func test_walking_known_path_only_advances_cursor_no_duplicate():
	# Build a 3-entry history
	_mgr.add_entry("a", _segs("1"), 0, 0, func(): return _snap())
	_mgr.add_entry("a", _segs("2"), 0, 1, func(): return _snap())
	_mgr.add_entry("a", _segs("3"), 0, 2, func(): return _snap())
	assert_eq(_mgr.get_entries().size(), 3)

	# Jump back to entry 0 — cursor goes to -1 (one before target), so the
	# next add_entry that re-displays entry 0 advances cursor to 0.
	_mgr.jump_to(0)
	assert_eq(_mgr.get_cursor(), -1)
	assert_eq(_mgr.get_entries().size(), 3, "history preserved on jump")

	# Re-add entries 0,1,2 with same positions → cursor advances, no append
	_mgr.add_entry("a", _segs("1"), 0, 0, func(): return _snap())
	assert_eq(_mgr.get_entries().size(), 3)
	assert_eq(_mgr.get_cursor(), 0)
	_mgr.add_entry("a", _segs("2"), 0, 1, func(): return _snap())
	assert_eq(_mgr.get_entries().size(), 3)
	assert_eq(_mgr.get_cursor(), 1)
	_mgr.add_entry("a", _segs("3"), 0, 2, func(): return _snap())
	assert_eq(_mgr.get_entries().size(), 3)
	assert_eq(_mgr.get_cursor(), 2)


func test_divergent_path_truncates_then_appends():
	_mgr.add_entry("a", _segs("1"), 0, 0, func(): return _snap())
	_mgr.add_entry("a", _segs("2"), 0, 1, func(): return _snap())
	_mgr.add_entry("a", _segs("3"), 0, 2, func(): return _snap())

	# Jump to entry 1 (cursor goes to 0) then re-walk entry 1 normally so
	# the cursor lands on 1 — this mimics what happens after the engine
	# replays to a target.
	_mgr.jump_to(1)
	_mgr.add_entry("a", _segs("2"), 0, 1, func(): return _snap())
	assert_eq(_mgr.get_cursor(), 1)

	# Now diverge: next dialogue at (1, 0) doesn't match existing (0, 2)
	_mgr.add_entry("a", _segs("alt"), 1, 0, func(): return _snap())

	var entries = _mgr.get_entries()
	assert_eq(entries.size(), 3, "old future truncated past cursor")
	assert_eq(entries[0]["text"], "1")
	assert_eq(entries[1]["text"], "2")
	assert_eq(entries[2]["text"], "alt")
	assert_eq(_mgr.get_cursor(), 2)


# ─── Sparse anchor snapshots ───

func test_first_entry_is_anchor():
	_mgr.anchor_interval = 5
	_mgr.add_entry("a", _segs("1"), 0, 0, func(): return _snap())
	var e = _mgr.get_entries()[0]
	assert_true(e.has("snapshot"))
	assert_not_null(e["snapshot"])


func test_anchor_only_every_N_entries():
	_mgr.anchor_interval = 3
	for i in range(7):
		_mgr.add_entry("a", _segs(str(i)), 0, i, func(): return _snap())
	var entries = _mgr.get_entries()
	# Indices 0, 3, 6 are anchors
	assert_not_null(entries[0].get("snapshot"))
	assert_null(entries[1].get("snapshot"))
	assert_null(entries[2].get("snapshot"))
	assert_not_null(entries[3].get("snapshot"))
	assert_null(entries[4].get("snapshot"))
	assert_null(entries[5].get("snapshot"))
	assert_not_null(entries[6].get("snapshot"))


func test_force_anchor_flag_makes_next_entry_an_anchor():
	_mgr.anchor_interval = 100  # disable interval anchors
	_mgr.add_entry("a", _segs("1"), 0, 0, func(): return _snap())  # always anchor (first)
	_mgr.add_entry("a", _segs("2"), 0, 1, func(): return _snap())  # not anchor
	assert_null(_mgr.get_entries()[1].get("snapshot"))

	_mgr.force_next_anchor()
	_mgr.add_entry("a", _segs("3"), 1, 0, func(): return _snap())  # forced anchor
	assert_not_null(_mgr.get_entries()[2].get("snapshot"))

	# flag consumed
	_mgr.add_entry("a", _segs("4"), 1, 1, func(): return _snap())
	assert_null(_mgr.get_entries()[3].get("snapshot"))


# ─── jump_to ───

func test_jump_to_finds_nearest_preceding_anchor():
	_mgr.anchor_interval = 3
	for i in range(7):
		_mgr.add_entry("a", _segs(str(i)), 0, i, func(): return _snap())
	# Anchors at 0, 3, 6

	# Jump to entry 5 → nearest anchor at 3
	var info = _mgr.jump_to(5)
	assert_not_null(info)
	assert_eq(info["anchor_scene_index"], 0)
	assert_eq(info["anchor_command_index"], 3, "anchor entry 3 has command_index 3")
	assert_eq(info["target_scene_index"], 0)
	assert_eq(info["target_command_index"], 5)
	assert_not_null(info["snapshot"])
	assert_eq(_mgr.get_cursor(), 4,
		"cursor sits one before the target so re-display advances cleanly")


func test_jump_to_anchor_itself():
	_mgr.anchor_interval = 3
	for i in range(7):
		_mgr.add_entry("a", _segs(str(i)), 0, i, func(): return _snap())

	var info = _mgr.jump_to(3)
	assert_eq(info["anchor_command_index"], 3)
	assert_eq(info["target_command_index"], 3)


func test_jump_to_invalid_index_returns_empty():
	_mgr.add_entry("a", _segs("1"), 0, 0, func(): return _snap())
	var info = _mgr.jump_to(99)
	assert_eq(info, {})


# ─── max_entries trimming ───

func test_max_entries_trims_from_front():
	_mgr.max_entries = 3
	_mgr.anchor_interval = 100  # only first entry is anchor
	for i in range(5):
		_mgr.add_entry("a", _segs(str(i)), 0, i, func(): return _snap())
	var entries = _mgr.get_entries()
	assert_eq(entries.size(), 3)
	assert_eq(entries[0]["text"], "2")
	assert_eq(entries[2]["text"], "4")
	# cursor should still point to last
	assert_eq(_mgr.get_cursor(), 2)


func test_trim_evicted_anchor_becomes_head_anchor():
	# When an anchor entry is trimmed off the front, its snapshot is preserved
	# as _head_anchor so jump_to from any remaining index can still replay
	# linearly from before the window.
	_mgr.max_entries = 3
	_mgr.anchor_interval = 100  # only entry 0 is anchor unless forced
	for i in range(5):
		_mgr.add_entry("a", _segs(str(i)), 0, i, func(): return _snap())

	# entries window is now [2, 3, 4] (no inner anchors); only entry 0's
	# snapshot survived as the head anchor.
	var head = _mgr.get_head_anchor()
	assert_not_null(head)
	assert_eq(head["scene_index"], 0)
	assert_eq(head["command_index"], 0)
	assert_not_null(head["snapshot"])

	# jump_to(0) (now pointing at original entry 2) → uses head_anchor to
	# replay forward from (0,0) to (0,2)
	var info = _mgr.jump_to(0)
	assert_eq(info["anchor_command_index"], 0, "from head_anchor")
	assert_eq(info["target_command_index"], 2)


func test_trim_keeps_latest_anchor_when_multiple_evicted():
	# If two anchors get evicted, head_anchor holds the most recent of them.
	_mgr.max_entries = 2
	_mgr.anchor_interval = 1  # every entry is an anchor
	for i in range(5):
		_mgr.add_entry("a", _segs(str(i)), 0, i, func(): return _snap())
	var head = _mgr.get_head_anchor()
	assert_eq(head["command_index"], 2,
		"latest evicted anchor (entry idx 2) wins")


# ─── clear ───

func test_clear_resets_everything():
	_mgr.add_entry("a", _segs("1"), 0, 0, func(): return _snap())
	_mgr.add_entry("a", _segs("2"), 0, 1, func(): return _snap())
	_mgr.clear()
	assert_eq(_mgr.get_entries().size(), 0)
	assert_eq(_mgr.get_cursor(), -1)
