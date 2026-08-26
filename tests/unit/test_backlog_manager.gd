extends GutTest
## Tests for BacklogManager — entry storage, cursor / browser-history model,
## per-entry snapshots, and jump_to lookups.


var _mgr: BacklogManager


func before_each():
	_mgr = BacklogManager.new()


func _segs(text: String, voice: String = "") -> Array:
	return [{
		"text": text,
		"voice_layers": (
			[] if voice.is_empty() else [{
				"id": "main", "asset": voice, "character": "",
				"dsp": "", "line": 0,
			}]),
	}]


# A test snapshot factory: returns a unique dict each call so we can verify
# identity if needed.
var _snapshot_counter: int = 0
func _snap() -> Dictionary:
	_snapshot_counter += 1
	return {"id": _snapshot_counter}


# ─── Basic add / get ───

func test_add_entry_stores_basic_fields():
	_mgr.add_entry("sakura", _segs("hello"), 0, func(): return {})
	var entries = _mgr.get_entries()
	assert_eq(entries.size(), 1)
	assert_eq(entries[0]["character"], "sakura")
	assert_eq(entries[0]["text"], "hello")
	assert_eq(entries[0]["command_uid"], 0)
	assert_eq(entries[0]["entry_id"], "command:0")


func test_enrichment_updates_only_the_stable_entry_id():
	_mgr.add_entry("a", _segs("first"), 10, func(): return {})
	_mgr.add_entry("b", _segs("second"), 11, func(): return {})

	var updated := _mgr.enrich_entry(
		"command:10", _segs("[custom amp=2]first[/custom]"), ["custom"])

	assert_true(updated)
	assert_eq(_mgr.get_entries()[0]["text"], "first")
	assert_eq(_mgr.get_entries()[1]["text"], "second",
		"a delayed enrichment for A cannot rewrite the current B entry")


func test_enrichment_can_arrive_before_canonical_entry_capture() -> void:
	var updated := _mgr.enrich_entry(
		"entry:early", _segs("[custom amp=2]visible[/custom]"), ["custom"])
	assert_false(updated)

	_mgr.add_entry(
		"a", _segs("[custom amp=2]visible[/custom]"), 12,
		func(): return {}, [], "entry:early")

	assert_eq(_mgr.get_entries().size(), 1)
	assert_eq(_mgr.get_entries()[0]["text"], "visible",
		"subscriber order cannot turn enrichment into a duplicate backlog row")


func test_add_entry_strips_inline_effect_markers():
	# {wait:N} / {speed:fast} are typewriter directives — they should NOT
	# leak into the backlog history text.
	var segs = [{"text": "你好{wait:500}世界{speed:30}！", "voice_layers": []}]
	_mgr.add_entry("a", segs, 0, func(): return {})
	assert_eq(_mgr.get_entries()[0]["text"], "你好世界！")


func test_add_entry_strips_expression_markers():
	# [expr:expression] single-word brackets should be stripped too.
	var segs = [{"text": "嗨[expr:smile]，最近好吗？[expr:sad]", "voice_layers": []}]
	_mgr.add_entry("a", segs, 0, func(): return {})
	assert_eq(_mgr.get_entries()[0]["text"], "嗨，最近好吗？")


func test_add_entry_preserves_unknown_brackets_as_literal_text():
	var segs = [{"text": "[note]重要[/note]文本", "voice_layers": []}]
	_mgr.add_entry("a", segs, 0, func(): return {})
	assert_eq(_mgr.get_entries()[0]["text"], "[note]重要[/note]文本")


func test_add_entry_converts_builtin_bbcode_to_visible_plain_text():
	var source := (
		"[b]A[/b][br][ul]B[/ul]"
		+ "[p note='a]b' align=right]C[/p][expr:happy]D{wait:10}"
	)
	_mgr.add_entry("a", _segs(source), 0, func(): return {})
	assert_eq(
		_mgr.get_entries()[0]["text"],
		"A\n• B\nC\nD",
		"a plain Button must receive the same visible words, never raw BBCode",
	)


func test_add_entry_preserves_literal_brackets_and_bbcode_bracket_escapes():
	_mgr.add_entry("a", _segs("[[b]literal[lb]x[rb] [note: value]"), 0, func(): return {})
	assert_eq(_mgr.get_entries()[0]["text"], "[literal[x] [note: value]")

	_mgr.clear()
	_mgr.add_entry("a", _segs("[[expr:happy]escaped marker"), 1, func(): return {})
	assert_eq(_mgr.get_entries()[0]["text"], "[expr:happy]escaped marker",
		"an escaped marker remains player-visible instead of becoming an expression")


func test_add_entry_matches_godot_hex_char_tag_semantics():
	_mgr.add_entry("a", _segs("[char=65][char=0x42][char=invalid]"), 0,
		func(): return {})
	assert_eq(_mgr.get_entries()[0]["text"], "eB�",
		"Godot parses char values as hexadecimal and displays invalid values as U+FFFD")

	_mgr.clear()
	_mgr.add_entry("a", _segs("A[rli]B"), 1, func(): return {})
	assert_eq(_mgr.get_entries()[0]["text"], "A‧B",
		"plain text mirrors Godot's current player-visible [rli] codepoint")


func test_add_entry_recovers_visible_text_after_malformed_image_source():
	_mgr.add_entry("a", _segs(
		"[img]res://missing.png[/b]after[/img]tail"), 0, func(): return {})
	assert_eq(_mgr.get_entries()[0]["text"], "￼[/b]aftertail",
		"a mismatched tag terminates the image source and must not swallow trailing text")

	_mgr.clear()
	_mgr.add_entry("a", _segs(
		"[img]res://missing.png[b]bold[/b][/img]after"), 1, func(): return {})
	assert_eq(_mgr.get_entries()[0]["text"], "￼boldafter",
		"BBCode following an image source is ordinary visible content")

	_mgr.clear()
	_mgr.add_entry("a", _segs(
		"[img]res://missing[expr:happy].png[/img]after"), 2, func(): return {})
	assert_eq(_mgr.get_entries()[0]["text"], "￼after",
		"a removed expression marker stays inside the image source token")

	_mgr.clear()
	_mgr.add_entry("a", _segs(
		"[imgbogus]res://missing[/img]after"), 3, func(): return {})
	assert_eq(_mgr.get_entries()[0]["text"], "￼[/img]after",
		"broad img tag recognition does not make a mismatched close disappear")


func test_add_entry_formats_each_list_line_and_nested_ordered_lists():
	var source := (
		"[ul]one\ntwo[/ul]"
		+ "[ol type=A]alpha\nbeta[/ol]"
		+ "[ul]outer\n[ol type=i]inner one\ninner two[/ol]\nafter[/ul]"
	)
	_mgr.add_entry("a", _segs(source), 0, func(): return {})
	assert_eq(
		_mgr.get_entries()[0]["text"],
		"• one\n• two\nA. alpha\nB. beta\n"
			+ "• outer\n  i. inner one\n  ii. inner two\n• after",
		"list markers belong to every item and preserve ordered style and nesting",
	)


func test_add_entry_preserves_authored_blank_lines_inside_and_outside_lists():
	_mgr.add_entry("a", _segs(
		"first\n\nsecond[ul]one\n\ntwo[/ul]after"), 0, func(): return {})
	assert_eq(
		_mgr.get_entries()[0]["text"],
		"first\n\nsecond\n• one\n\n• two\nafter",
		"structural list breaks must not collapse authored blank lines",
	)


func test_add_entry_strips_only_registered_custom_bbcode_effects():
	_mgr.add_entry("a", _segs(
		"[custom amp=2]visible[/custom]"
		+ "[custom=2]literal main value[/custom]"
		+ "[unknown amp=2]literal[/unknown]"), 0, func(): return {}, ["custom"])
	assert_eq(
		_mgr.get_entries()[0]["text"],
		"visible[custom=2]literal main value[/custom]"
			+ "[unknown amp=2]literal[/unknown]",
		"registered custom effects are formatting; truly unknown tags stay literal",
	)

	_mgr.clear()
	_mgr.add_entry("a", _segs("[custom amp=2]literal[/custom]"), 1,
		func(): return {}, [])
	assert_eq(
		_mgr.get_entries()[0]["text"],
		"[custom amp=2]literal[/custom]",
		"an active scene with no custom effects clears the previous registry",
	)


func test_add_entry_concatenates_combine_segments():
	var segs = [
		{"text": "foo", "voice_layers": [{"id": "main", "asset": "v1", "character": "a", "dsp": "radio", "line": 7}]},
		{"text": "bar", "voice_layers": [{"id": "main", "asset": "v2", "character": "a", "dsp": "echo", "line": 8}]},
	]
	_mgr.add_entry("a", segs, 0, func(): return {})
	var e = _mgr.get_entries()[0]
	assert_eq(e["text"], "foobar")
	assert_eq(e["voices"], ["v1", "v2"])
	assert_eq_deep(e["voice_segments"], [
		{"voice_layers": [{"id": "main", "asset": "v1", "character": "a", "dsp": "radio", "line": 7}]},
		{"voice_layers": [{"id": "main", "asset": "v2", "character": "a", "dsp": "echo", "line": 8}]},
	])


func test_every_entry_carries_a_snapshot():
	for i in range(5):
		_mgr.add_entry("a", _segs(str(i)), i, func(): return _snap())
	for entry in _mgr.get_entries():
		assert_not_null(entry.get("snapshot"))


# ─── Cursor + browser history model ───

func test_cursor_starts_at_minus_one():
	assert_eq(_mgr.get_cursor(), -1)


func test_cursor_advances_on_each_append():
	_mgr.add_entry("a", _segs("1"), 0, func(): return _snap())
	assert_eq(_mgr.get_cursor(), 0)
	_mgr.add_entry("a", _segs("2"), 1, func(): return _snap())
	assert_eq(_mgr.get_cursor(), 1)


func test_walking_known_path_only_advances_cursor_no_duplicate():
	# Build a 3-entry history (uids 0, 1, 2)
	_mgr.add_entry("a", _segs("1"), 0, func(): return _snap())
	_mgr.add_entry("a", _segs("2"), 1, func(): return _snap())
	_mgr.add_entry("a", _segs("3"), 2, func(): return _snap())
	assert_eq(_mgr.get_entries().size(), 3)

	# Jump back to entry 0 — cursor goes to -1 (one before target), so the
	# next add_entry that re-displays uid 0 advances cursor to 0.
	_mgr.jump_to(0)
	assert_eq(_mgr.get_cursor(), -1)
	assert_eq(_mgr.get_entries().size(), 3, "history preserved on jump")

	# Re-add entries with same uids → cursor advances, no append
	_mgr.add_entry("a", _segs("1"), 0, func(): return _snap())
	assert_eq(_mgr.get_entries().size(), 3)
	assert_eq(_mgr.get_cursor(), 0)
	_mgr.add_entry("a", _segs("2"), 1, func(): return _snap())
	assert_eq(_mgr.get_entries().size(), 3)
	assert_eq(_mgr.get_cursor(), 1)
	_mgr.add_entry("a", _segs("3"), 2, func(): return _snap())
	assert_eq(_mgr.get_entries().size(), 3)
	assert_eq(_mgr.get_cursor(), 2)


func test_divergent_path_truncates_then_appends():
	_mgr.add_entry("a", _segs("1"), 0, func(): return _snap())
	_mgr.add_entry("a", _segs("2"), 1, func(): return _snap())
	_mgr.add_entry("a", _segs("3"), 2, func(): return _snap())

	# Jump to entry 1 (cursor goes to 0) then re-walk uid 1 normally so
	# the cursor lands on 1 — this mimics what happens after the engine
	# replays to a target.
	_mgr.jump_to(1)
	_mgr.add_entry("a", _segs("2"), 1, func(): return _snap())
	assert_eq(_mgr.get_cursor(), 1)

	# Now diverge: next dialogue has a different uid (100 vs the
	# previously-recorded uid 2 at cursor+1)
	_mgr.add_entry("a", _segs("alt"), 100, func(): return _snap())

	var entries = _mgr.get_entries()
	assert_eq(entries.size(), 3, "old future truncated past cursor")
	assert_eq(entries[0]["text"], "1")
	assert_eq(entries[1]["text"], "2")
	assert_eq(entries[2]["text"], "alt")
	assert_eq(_mgr.get_cursor(), 2)


func test_command_uid_decoupled_from_indices():
	# Issue #88: BacklogManager identifies commands by stable uid, not
	# (scene_index, command_index). Two commands with the SAME uid match
	# regardless of execution position; two commands with DIFFERENT uids
	# diverge regardless of position. This test exercises the contract
	# directly with hand-picked uids.
	_mgr.add_entry("a", _segs("first"), 42, func(): return _snap())
	_mgr.add_entry("a", _segs("second"), 99, func(): return _snap())
	_mgr.jump_to(0)

	# Re-fire the same uid 42 → cursor advances, no append.
	_mgr.add_entry("a", _segs("first"), 42, func(): return _snap())
	assert_eq(_mgr.get_cursor(), 0)
	assert_eq(_mgr.get_entries().size(), 2)

	# Different uid → divergence, append.
	_mgr.add_entry("a", _segs("alt"), 7, func(): return _snap())
	assert_eq(_mgr.get_entries().size(), 2)  # truncated then appended
	assert_eq(_mgr.get_entries()[1]["text"], "alt")
	assert_eq(_mgr.get_entries()[1]["command_uid"], 7)


# ─── jump_to ───

func test_jump_to_returns_snapshot_and_uid():
	for i in range(5):
		_mgr.add_entry("a", _segs(str(i)), i, func(): return _snap())

	var info = _mgr.jump_to(3)
	assert_not_null(info)
	assert_eq(info["command_uid"], 3)
	assert_not_null(info["snapshot"])
	assert_eq(_mgr.get_cursor(), 2,
		"cursor sits one before the target so re-display advances cleanly")


func test_jump_to_invalid_index_returns_empty():
	_mgr.add_entry("a", _segs("1"), 0, func(): return _snap())
	var info = _mgr.jump_to(99)
	assert_eq(info, {})


func test_jump_to_entry_without_snapshot_returns_empty():
	# Entry added with an invalid Callable → no snapshot stored.
	_mgr.add_entry("a", _segs("1"), 0)
	var info = _mgr.jump_to(0)
	assert_eq(info, {}, "cannot jump into an entry that has no snapshot")


# ─── max_entries trimming ───

func test_max_entries_trims_from_front():
	_mgr.max_entries = 3
	for i in range(5):
		_mgr.add_entry("a", _segs(str(i)), i, func(): return _snap())
	var entries = _mgr.get_entries()
	assert_eq(entries.size(), 3)
	assert_eq(entries[0]["text"], "2")
	assert_eq(entries[2]["text"], "4")
	assert_eq(_mgr.get_cursor(), 2)


func test_max_entries_default_is_200():
	assert_eq(BacklogManager.new().max_entries, 200)


# ─── clear ───

func test_clear_resets_everything():
	_mgr.add_entry("a", _segs("1"), 0, func(): return _snap())
	_mgr.add_entry("a", _segs("2"), 1, func(): return _snap())
	_mgr.clear()
	assert_eq(_mgr.get_entries().size(), 0)
	assert_eq(_mgr.get_cursor(), -1)
