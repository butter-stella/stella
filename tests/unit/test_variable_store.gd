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
