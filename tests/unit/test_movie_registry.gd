extends GutTest
## Registry stale-identity cleanup for the Runtime-owned movie participant.


func test_stale_movie_identity_releases_every_bound_callable() -> void:
	var saved := {
		"presenter": SignalBus._movie_presenter,
		"capability": SignalBus._movie_capability,
		"input": SignalBus._movie_presenter_input_claim,
		"active": SignalBus._movie_presenter_active_query,
		"recovery": SignalBus._movie_presenter_recovery_discard,
		"restore": SignalBus._movie_presenter_restore_apply,
		"rollback_prepare": SignalBus._movie_presenter_rollback_prepare,
		"rollback_apply": SignalBus._movie_presenter_rollback_apply,
		"rollback_release": SignalBus._movie_presenter_rollback_release,
	}
	var stale := Node.new()
	SignalBus._movie_presenter = weakref(stale)
	SignalBus._movie_capability = RefCounted.new()
	var stale_callable := Callable(stale, "is_inside_tree")
	SignalBus._movie_presenter_input_claim = stale_callable
	SignalBus._movie_presenter_active_query = stale_callable
	SignalBus._movie_presenter_recovery_discard = stale_callable
	SignalBus._movie_presenter_restore_apply = stale_callable
	SignalBus._movie_presenter_rollback_prepare = stale_callable
	SignalBus._movie_presenter_rollback_apply = stale_callable
	SignalBus._movie_presenter_rollback_release = stale_callable
	stale.free()

	assert_null(SignalBus._current_movie_presenter())
	assert_null(SignalBus._movie_presenter)
	assert_null(SignalBus._movie_capability)
	for key: String in [
		"_movie_presenter_input_claim",
		"_movie_presenter_active_query",
		"_movie_presenter_recovery_discard",
		"_movie_presenter_restore_apply",
		"_movie_presenter_rollback_prepare",
		"_movie_presenter_rollback_apply",
		"_movie_presenter_rollback_release",
	]:
		var callback: Callable = SignalBus.get(key)
		assert_false(callback.is_valid(), key)

	# Restore the exact Runtime-owned registry before the next test script runs.
	SignalBus._movie_presenter = saved["presenter"]
	SignalBus._movie_capability = saved["capability"]
	SignalBus._movie_presenter_input_claim = saved["input"]
	SignalBus._movie_presenter_active_query = saved["active"]
	SignalBus._movie_presenter_recovery_discard = saved["recovery"]
	SignalBus._movie_presenter_restore_apply = saved["restore"]
	SignalBus._movie_presenter_rollback_prepare = saved["rollback_prepare"]
	SignalBus._movie_presenter_rollback_apply = saved["rollback_apply"]
	SignalBus._movie_presenter_rollback_release = saved["rollback_release"]
