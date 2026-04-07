extends GutTest
## Tests for BacklogManager — entry storage, cursor / browser-history model,
## per-entry snapshots, and jump_to lookups.


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


func test_add_entry_strips_inline_effect_markers():
	# {wait:N} / {speed:fast} are typewriter directives — they should NOT
	# leak into the backlog history text.
	var segs = [{"text": "你好{wait:500}世界{speed:fast}！", "voice": "", "expression": ""}]
	_mgr.add_entry("a", segs, 0, 0, func(): return {})
	assert_eq(_mgr.get_entries()[0]["text"], "你好世界！")


func test_add_entry_strips_expression_markers():
	# [expression] single-word brackets should be stripped too.
	var segs = [{"text": "嗨[smile]，最近好吗？[sad]", "voice": "", "expression": ""}]
	_mgr.add_entry("a", segs, 0, 0, func(): return {})
	assert_eq(_mgr.get_entries()[0]["text"], "嗨，最近好吗？")


func test_add_entry_preserves_brackets_with_spaces_or_colons():
	# Brackets that aren't expression markers (have a colon or space)
	# should be left alone — they're literal text.
	var segs = [{"text": "[备注: 这是文本]", "voice": "", "expression": ""}]
	_mgr.add_entry("a", segs, 0, 0, func(): return {})
	assert_eq(_mgr.get_entries()[0]["text"], "[备注: 这是文本]")


func test_add_entry_concatenates_combine_segments():
	var segs = [
		{"text": "foo", "voice": "v1", "expression": ""},
		{"text": "bar", "voice": "v2", "expression": ""},
	]
	_mgr.add_entry("a", segs, 0, 0, func(): return {})
	var e = _mgr.get_entries()[0]
	assert_eq(e["text"], "foobar")
	assert_eq(e["voices"], ["v1", "v2"])


func test_every_entry_carries_a_snapshot():
	for i in range(5):
		_mgr.add_entry("a", _segs(str(i)), 0, i, func(): return _snap())
	for entry in _mgr.get_entries():
		assert_not_null(entry.get("snapshot"))


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


# ─── jump_to ───

func test_jump_to_returns_snapshot_and_position():
	for i in range(5):
		_mgr.add_entry("a", _segs(str(i)), 0, i, func(): return _snap())

	var info = _mgr.jump_to(3)
	assert_not_null(info)
	assert_eq(info["scene_index"], 0)
	assert_eq(info["command_index"], 3)
	assert_not_null(info["snapshot"])
	assert_eq(_mgr.get_cursor(), 2,
		"cursor sits one before the target so re-display advances cleanly")


func test_jump_to_invalid_index_returns_empty():
	_mgr.add_entry("a", _segs("1"), 0, 0, func(): return _snap())
	var info = _mgr.jump_to(99)
	assert_eq(info, {})


func test_jump_to_entry_without_snapshot_returns_empty():
	# Entry added with an invalid Callable → no snapshot stored.
	_mgr.add_entry("a", _segs("1"), 0, 0)
	var info = _mgr.jump_to(0)
	assert_eq(info, {}, "cannot jump into an entry that has no snapshot")


# ─── max_entries trimming ───

func test_max_entries_trims_from_front():
	_mgr.max_entries = 3
	for i in range(5):
		_mgr.add_entry("a", _segs(str(i)), 0, i, func(): return _snap())
	var entries = _mgr.get_entries()
	assert_eq(entries.size(), 3)
	assert_eq(entries[0]["text"], "2")
	assert_eq(entries[2]["text"], "4")
	assert_eq(_mgr.get_cursor(), 2)


func test_max_entries_default_is_200():
	assert_eq(BacklogManager.new().max_entries, 200)


# ─── clear ───

func test_clear_resets_everything():
	_mgr.add_entry("a", _segs("1"), 0, 0, func(): return _snap())
	_mgr.add_entry("a", _segs("2"), 0, 1, func(): return _snap())
	_mgr.clear()
	assert_eq(_mgr.get_entries().size(), 0)
	assert_eq(_mgr.get_cursor(), -1)
