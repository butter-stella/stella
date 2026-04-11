extends GutTest
## Tests for ChoiceHistoryManager — the per-choice snapshot stack that
## powers the "回到上一选项" toolbar action.


var _mgr: ChoiceHistoryManager


func before_each():
	_mgr = ChoiceHistoryManager.new()


var _snapshot_counter: int = 0
func _snap() -> Dictionary:
	_snapshot_counter += 1
	return {"id": _snapshot_counter}


# ─── record / size ───

func test_starts_empty():
	assert_eq(_mgr.size(), 0)


func test_record_appends_entry():
	_mgr.record(42, func(): return _snap())
	assert_eq(_mgr.size(), 1)


func test_record_captures_uid_and_snapshot():
	_mgr.record(42, func(): return {"marker": "A"})
	_mgr.record(99, func(): return {"marker": "B"})
	assert_eq(_mgr.size(), 2)
	# pop_previous with a current uid that doesn't match either → returns last
	var info = _mgr.pop_previous(-1)
	assert_eq(info["snapshot"]["marker"], "B")


# ─── pop_previous — core semantics ───

func test_pop_previous_returns_empty_when_no_history():
	var info = _mgr.pop_previous(-1)
	assert_eq(info, {})


func test_pop_previous_returns_latest_entry_when_not_at_it():
	# Two recorded choices; current command uid is unrelated (dialogue).
	# pop_previous returns the most recent choice.
	_mgr.record(10, func(): return {"marker": "choice1"})
	_mgr.record(20, func(): return {"marker": "choice2"})

	var info = _mgr.pop_previous(999)  # current command is unrelated
	assert_eq(info["snapshot"]["marker"], "choice2")


func test_pop_previous_skips_top_when_current_command_matches():
	# Player is parked ON choice2 (cur_uid == 20). "Previous choice" means
	# the choice BEFORE this one, not this one itself.
	_mgr.record(10, func(): return {"marker": "choice1"})
	_mgr.record(20, func(): return {"marker": "choice2"})

	var info = _mgr.pop_previous(20)
	assert_eq(info["snapshot"]["marker"], "choice1")


func test_pop_previous_truncates_to_target():
	# After pop_previous returns choice1, it and everything after it should
	# be dropped — when the engine re-enters choice1, record() will push a
	# fresh entry back in its place.
	_mgr.record(10, func(): return {"marker": "choice1"})
	_mgr.record(20, func(): return {"marker": "choice2"})
	_mgr.pop_previous(999)  # returns choice2
	assert_eq(_mgr.size(), 1, "the entry returned is removed from the stack")


func test_pop_previous_truncates_when_skipping_current():
	# If current_cmd_uid matches the top, pop_previous skips it and returns
	# the next one down. BOTH the skipped top and the returned entry should
	# be dropped, because the player is navigating away from both.
	_mgr.record(10, func(): return {"marker": "choice1"})
	_mgr.record(20, func(): return {"marker": "choice2"})
	_mgr.pop_previous(20)  # skips top (choice2), returns choice1
	assert_eq(_mgr.size(), 0)


func test_pop_previous_returns_empty_when_only_current_in_stack():
	# Player is parked on the only recorded choice — no earlier choice to go
	# back to. Return empty, don't mutate the stack.
	_mgr.record(10, func(): return {"marker": "choice1"})
	var info = _mgr.pop_previous(10)
	assert_eq(info, {})
	assert_eq(_mgr.size(), 1, "stack preserved when there's nowhere to go")


func test_pop_previous_multi_level():
	# Three choices recorded; pop twice should reach choice1.
	_mgr.record(10, func(): return {"marker": "choice1"})
	_mgr.record(20, func(): return {"marker": "choice2"})
	_mgr.record(30, func(): return {"marker": "choice3"})

	var info_a = _mgr.pop_previous(999)
	assert_eq(info_a["snapshot"]["marker"], "choice3")
	var info_b = _mgr.pop_previous(999)
	assert_eq(info_b["snapshot"]["marker"], "choice2")
	var info_c = _mgr.pop_previous(999)
	assert_eq(info_c["snapshot"]["marker"], "choice1")
	var info_d = _mgr.pop_previous(999)
	assert_eq(info_d, {})


# ─── has_previous ───

func test_has_previous_false_when_empty():
	assert_false(_mgr.has_previous(-1))


func test_has_previous_true_when_entry_available():
	_mgr.record(10, func(): return _snap())
	assert_true(_mgr.has_previous(999))


func test_has_previous_false_when_only_current():
	_mgr.record(10, func(): return _snap())
	assert_false(_mgr.has_previous(10),
		"only entry matches current — no earlier choice available")


# ─── max_entries cap ───

func test_max_entries_default_is_50():
	assert_eq(ChoiceHistoryManager.new().max_entries, 50)


func test_max_entries_trims_from_front():
	_mgr.max_entries = 3
	for i in range(5):
		_mgr.record(i, func(): return _snap())
	assert_eq(_mgr.size(), 3)
	# After trimming: uids [2,3,4]. pop_previous with 999 returns uid 4.
	var info = _mgr.pop_previous(999)
	assert_not_null(info.get("snapshot"))
	assert_eq(_mgr.size(), 2)


# ─── clear ───

func test_clear_empties_stack():
	_mgr.record(10, func(): return _snap())
	_mgr.record(20, func(): return _snap())
	_mgr.clear()
	assert_eq(_mgr.size(), 0)
	assert_eq(_mgr.pop_previous(-1), {})
