extends GutTest
## Tests for VariableStore — three-scope variable storage.


var _store: VariableStore


func before_each():
	_store = VariableStore.new()


func test_set_and_get():
	_store.set_var("hp", 100)
	assert_eq(_store.get_var("hp"), 100)


func test_get_returns_default_when_missing():
	assert_eq(_store.get_var("missing", -1), -1)


func test_get_returns_null_default():
	assert_null(_store.get_var("missing"))


func test_scope_priority_temp_wins():
	_store.set_var("flag", "global", VariableStore.Scope.GLOBAL)
	_store.set_var("flag", "scenario", VariableStore.Scope.SCENARIO)
	_store.set_var("flag", "temp", VariableStore.Scope.TEMP)
	assert_eq(_store.get_var("flag"), "temp")


func test_scope_priority_scenario_over_global():
	_store.set_var("flag", "global", VariableStore.Scope.GLOBAL)
	_store.set_var("flag", "scenario", VariableStore.Scope.SCENARIO)
	assert_eq(_store.get_var("flag"), "scenario")


func test_scope_fallback_to_global():
	_store.set_var("flag", "global", VariableStore.Scope.GLOBAL)
	assert_eq(_store.get_var("flag"), "global")


func test_default_scope_is_scenario():
	_store.set_var("x", 42)
	# Should only be in scenario scope
	assert_eq(_store.get_var("x"), 42)


func test_snapshot_and_restore():
	_store.set_var("hp", 100, VariableStore.Scope.SCENARIO)
	_store.set_var("unlocked", true, VariableStore.Scope.GLOBAL)
	var snapshot = _store.capture_snapshot()
	_store.set_var("hp", 50, VariableStore.Scope.SCENARIO)
	_store.set_var("unlocked", false, VariableStore.Scope.GLOBAL)
	_store.restore_snapshot(snapshot)
	assert_eq(_store.get_var("hp"), 100)
	assert_eq(_store.get_var("unlocked"), true)


func test_clear_temp():
	_store.set_var("tmp", "value", VariableStore.Scope.TEMP)
	_store.clear_temp()
	assert_null(_store.get_var("tmp"))


func test_set_numeric_operations():
	_store.set_var("score", 10)
	_store.set_var("score", 5, VariableStore.Scope.SCENARIO, "+=")
	assert_eq(_store.get_var("score"), 15)
	_store.set_var("score", 3, VariableStore.Scope.SCENARIO, "-=")
	assert_eq(_store.get_var("score"), 12)


func test_increment_reads_from_same_scope():
	# Bug: += on GLOBAL should read from GLOBAL, not create shadow in SCENARIO
	_store.set_var("score", 10, VariableStore.Scope.GLOBAL)
	_store.set_var("score", 5, VariableStore.Scope.GLOBAL, "+=")
	assert_eq(_store.get_var("score"), 15)


func test_increment_does_not_cross_scope():
	# If var is in GLOBAL and we += in SCENARIO, it should read from the
	# correct scope chain but write to the specified scope
	_store.set_var("score", 10, VariableStore.Scope.GLOBAL)
	_store.set_var("score", 5, VariableStore.Scope.SCENARIO, "+=")
	# Scenario scope should have 15 (read 10 from global + 5)
	assert_eq(_store.get_var("score"), 15)


# ─── Scoped snapshot (for rollback paths like backlog/flowchart jump) ───
# Rationale: rollback must NOT touch Scope.GLOBAL (monotonic, cross-playthrough).
# See issue #98.

func test_capture_scenario_scope_returns_only_scenario_dict():
	_store.set_var("hp", 100, VariableStore.Scope.SCENARIO)
	_store.set_var("unlocked", true, VariableStore.Scope.GLOBAL)
	var snap = _store.capture_scenario_scope()
	assert_eq(snap.get("hp"), 100, "scenario var should be in snapshot")
	assert_false(snap.has("unlocked"), "global var should NOT be in scenario-scope snapshot")


func test_capture_scenario_scope_is_a_copy_not_reference():
	_store.set_var("hp", 100, VariableStore.Scope.SCENARIO)
	var snap = _store.capture_scenario_scope()
	_store.set_var("hp", 50, VariableStore.Scope.SCENARIO)
	assert_eq(snap.get("hp"), 100, "snapshot must be detached from later mutations")


func test_restore_scenario_scope_does_not_touch_global():
	# This is THE bug fix: rollback path must preserve global state.
	_store.set_var("hp", 100, VariableStore.Scope.SCENARIO)
	_store.set_var("unlocked_true_ending", true, VariableStore.Scope.GLOBAL)
	var snap = _store.capture_scenario_scope()

	# Player advances: scenario state changes, global state monotonically grows
	_store.set_var("hp", 50, VariableStore.Scope.SCENARIO)
	_store.set_var("cg_count", 5, VariableStore.Scope.GLOBAL)

	# Rollback to earlier scenario snapshot
	_store.restore_scenario_scope(snap)

	# Scenario rolled back
	assert_eq(_store.get_var("hp"), 100, "scenario var should be rolled back")
	# But global preserved
	assert_eq(_store.get_var("unlocked_true_ending"), true,
		"pre-existing global var must survive rollback")
	assert_eq(_store.get_var("cg_count"), 5,
		"global var added AFTER snapshot must NOT be rolled back")


func test_restore_scenario_scope_clears_old_scenario_keys():
	# Restoring a snapshot that doesn't contain key K should remove K from
	# scenario scope (otherwise stale state from after the snapshot leaks back)
	_store.set_var("hp", 100, VariableStore.Scope.SCENARIO)
	var snap = _store.capture_scenario_scope()
	_store.set_var("new_flag", "leaked", VariableStore.Scope.SCENARIO)
	_store.restore_scenario_scope(snap)
	assert_null(_store.get_var("new_flag"),
		"scenario keys absent from snapshot should be removed on restore")


func test_restore_scenario_scope_tolerates_legacy_full_snapshot_format():
	# Backwards compat: if a caller passes the full {scenario, global} dict
	# (the legacy capture_snapshot format), restore_scenario_scope should
	# pull only the "scenario" sub-dict and ignore "global".
	_store.set_var("existing_global", "preserved", VariableStore.Scope.GLOBAL)
	var legacy_snap = {
		"scenario": {"hp": 200},
		"global": {"existing_global": "OVERWRITTEN", "extra": "ignored"},
	}
	_store.restore_scenario_scope(legacy_snap)
	assert_eq(_store.get_var("hp"), 200, "scenario sub-dict should restore")
	assert_eq(_store.get_var("existing_global"), "preserved",
		"legacy format's global sub-dict must NOT be applied")
